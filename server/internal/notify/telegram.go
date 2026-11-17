// Package notify: annuncia nel gruppo Telegram quando un server apre e chiude.
//
// Si iscrive al bus eventi come un qualsiasi client SSE: lock = aperto,
// unlock/force = chiuso. In più sorveglia i lock scaduti, perché a un client
// che sparisce (crash, corrente, chiusura brutale) non arriva mai l'unlock e
// senza questo controllo il gruppo resterebbe con l'ultimo "ha aperto".
//
// Il bot è un servizio che vive quanto l'hub: la configurazione (attivo,
// token, chat, lingua, quali messaggi) arriva da Apply e vale subito, senza
// riavvii. Le sessioni aperte si seguono anche a bot spento, così riaccenderlo
// non perde la durata della sessione nel messaggio di chiusura.
package notify

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"io"
	"log"
	"maps"
	"net"
	"net/http"
	neturl "net/url"
	"strings"
	"sync"
	"time"

	"minesync/server/internal/events"
	"minesync/server/internal/i18n"
	"minesync/server/internal/settings"
	"minesync/server/internal/store"
)

const (
	apiBase    = "https://api.telegram.org"
	staleCheck = 30 * time.Second
	sendTries  = 3

	// watchdog: con l'autosave a 5 minuti, mezz'ora senza push su una
	// sessione viva vuol dire che i salvataggi non stanno arrivando
	pushWarnAfter = 30 * time.Minute
	pollTimeout   = 10 // secondi di long-poll su getUpdates
)

// Config è la configurazione corrente del bot.
type Config struct {
	Enabled bool
	Token   string
	ChatID  string
	Lang    i18n.Lang // "" = lingua dell'hub
	Open    bool      // annuncia le aperture
	Close   bool      // annuncia le chiusure (anche lock scaduti)
	Alerts  bool      // avvisi del watchdog dei salvataggi
	Status  bool      // risponde a /status nella chat
	// Topics: id dello spazio → message_thread_id del suo topic nei gruppi
	// forum (solo valori > 1). Spazi assenti: chat principale (Generale).
	Topics map[string]int64
}

// FromSettings converte la sezione telegram di settings.json.
func FromSettings(tg settings.Telegram) Config {
	l, _ := i18n.Parse(tg.Lang)
	return Config{
		Enabled: tg.Enabled, Token: tg.Token, ChatID: tg.ChatID, Lang: l,
		Open: tg.Notify.Open, Close: tg.Notify.Close, Alerts: tg.Notify.Alerts, Status: tg.Notify.Status,
		Topics: maps.Clone(tg.Topics),
	}
}

// topic è il thread in cui vanno i messaggi dello spazio (0 = chat principale).
func (c Config) topic(space string) int64 {
	if th := c.Topics[space]; th > 1 {
		return th
	}
	return 0
}

// active: il bot può davvero mandare messaggi.
func (c Config) active() bool { return c.Enabled && c.Token != "" && c.ChatID != "" }

// tipi di messaggio, ognuno col suo interruttore
type kind int

const (
	kindOpen kind = iota
	kindClose
	kindAlert
	kindStatus
)

func (c Config) wants(k kind) bool {
	switch k {
	case kindOpen:
		return c.Open
	case kindClose:
		return c.Close
	case kindAlert:
		return c.Alerts
	case kindStatus:
		return c.Status
	}
	return false
}

// Status è lo stato del bot per la pagina Impostazioni.
type Status struct {
	LastError   error // ultimo errore di Telegram (token già rimosso); nil se l'ultimo invio è riuscito
	LastErrorAt time.Time
	LastSentAt  time.Time
}

// outMsg è un annuncio in coda, con destinatario fissato al momento
// dell'accodamento. thread > 0: il topic del gruppo forum; space: il server
// di cui parla (per dire quale topic manca se è stato eliminato).
type outMsg struct {
	token, chatID, text string
	thread              int64
	space               string
}

// Telegram inoltra gli eventi di apertura e chiusura a una chat, risponde a
// /status e avvisa se una sessione viva smette di salvare sull'hub.
type Telegram struct {
	zone   string // zona DNS, per mostrare l'indirizzo fisso ("" = niente)
	st     *store.Store
	bus    *events.Bus
	hc     *http.Client
	base   string // override per i test
	out    chan outMsg
	reconf chan struct{}
	open   map[string]session // solo dalla goroutine di Run
	// pending: chiusure in attesa (solo dalla goroutine di Run). Una chiusura
	// si annuncia dopo coalesce: se nel frattempo lo stesso host riapre (riavvio
	// del server) o il lock torna vivo, non parte nessun messaggio.
	pending  map[string]pendingClose
	coalesce time.Duration

	// invii: attesa tra i tentativi (se Telegram non dice retry_after) e
	// tetto al tempo totale speso a riprovare un messaggio
	backoff     time.Duration
	retryBudget time.Duration

	mu        sync.Mutex
	cfg       Config
	lastErr   error
	lastErrAt time.Time
	pollErr   bool // lastErr viene dal poller (un getUpdates riuscito lo cancella)
	lastSent  time.Time
}

// session è un server aperto annunciato (o adottato al riavvio).
type session struct {
	owner      string
	since      time.Time // Since del lock: identifica la sessione di lock
	start      time.Time // inizio mostrato (resta quello vero se si riapre subito)
	lastPush   time.Time // ultimo push visto (all'apertura: l'apertura stessa)
	pushWarned bool      // avviso "non salva più" già mandato per questa sessione
}

// pendingClose è una chiusura non ancora annunciata.
type pendingClose struct {
	s   session
	why string
	at  time.Time // quando il server si è chiuso
}

const (
	defaultCoalesce    = time.Minute      // chiusura+riapertura entro questo tempo: silenzio
	defaultBackoff     = 2 * time.Second  // attesa base tra i tentativi di invio
	defaultRetryBudget = 90 * time.Second // tempo massimo speso a riprovare un messaggio
	pendingCheck       = 5 * time.Second  // ogni quanto si guardano le chiusure in attesa
)

// New crea il bot, spento: la configurazione arriva con Apply.
func New(zone string, st *store.Store, bus *events.Bus) *Telegram {
	return &Telegram{
		zone: zone, st: st, bus: bus,
		hc:          &http.Client{Timeout: 15 * time.Second},
		base:        apiBase,
		out:         make(chan outMsg, 64),
		reconf:      make(chan struct{}, 1),
		open:        map[string]session{},
		pending:     map[string]pendingClose{},
		coalesce:    defaultCoalesce,
		backoff:     defaultBackoff,
		retryBudget: defaultRetryBudget,
	}
}

// announceable: si annunciano solo le sessioni di gioco (info action
// "play", o dai client 3.1 un lock con "host"), mai i push manuali.
func announceable(lk *store.LockInfo) bool { return lk != nil && lk.Action() == "play" }

// Apply cambia la configurazione a caldo: i messaggi successivi seguono la
// nuova, il poller di /status si ferma o riparte se serve.
func (t *Telegram) Apply(c Config) {
	t.mu.Lock()
	old := t.cfg
	t.cfg = c
	if old.Token != c.Token || old.ChatID != c.ChatID || old.active() != c.active() ||
		!maps.Equal(old.Topics, c.Topics) {
		t.lastErr, t.lastErrAt, t.pollErr = nil, time.Time{}, false
	}
	t.mu.Unlock()
	switch {
	case c.active() && (!old.active() || old.ChatID != c.ChatID || old.Token != c.Token):
		log.Print(i18n.Lf("bot Telegram attivo (chat %s)", c.ChatID))
	case !c.active() && old.active():
		log.Print(i18n.Lf("bot Telegram disattivato"))
	}
	select {
	case t.reconf <- struct{}{}:
	default:
	}
}

func (t *Telegram) config() Config {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.cfg
}

// Status restituisce l'esito degli ultimi invii.
func (t *Telegram) Status() Status {
	t.mu.Lock()
	defer t.mu.Unlock()
	return Status{LastError: t.lastErr, LastErrorAt: t.lastErrAt, LastSentAt: t.lastSent}
}

func (t *Telegram) lang() i18n.Lang {
	if l := t.config().Lang; l != "" {
		return l
	}
	return i18n.Default()
}

func (t *Telegram) tr(id string) string            { return i18n.T(t.lang(), id) }
func (t *Telegram) trf(id string, a ...any) string { return i18n.Tf(t.lang(), id, a...) }

// poller in esecuzione: token con cui interroga getUpdates
type pollerRun struct {
	token  string
	cancel context.CancelFunc
	done   chan struct{}
}

func (p *pollerRun) stop() {
	if p.cancel == nil {
		return
	}
	p.cancel()
	<-p.done
	*p = pollerRun{}
}

// Run consuma gli eventi finché il contesto non viene chiuso.
func (t *Telegram) Run(ctx context.Context) {
	t.adopt() // lock già attivi al riavvio dell'hub: niente annuncio, solo stato
	go t.sender(ctx)

	// /status nel gruppo: il poller gira solo a bot attivo con /status
	// abilitato, e riparte da capo se cambia il token
	var poll pollerRun
	defer poll.stop()
	syncPoller := func() {
		want := ""
		if c := t.config(); c.active() && c.Status {
			want = c.Token
		}
		if want == poll.token {
			return
		}
		poll.stop()
		if want != "" {
			pctx, cancel := context.WithCancel(ctx)
			poll = pollerRun{token: want, cancel: cancel, done: make(chan struct{})}
			go func(done chan struct{}) {
				defer close(done)
				t.poller(pctx, want)
			}(poll.done)
		}
	}
	syncPoller()

	ch := t.bus.Subscribe()
	defer t.bus.Unsubscribe(ch)
	tick := time.NewTicker(staleCheck)
	defer tick.Stop()
	pend := time.NewTicker(pendingCheck)
	defer pend.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-t.reconf:
			syncPoller()
		case e := <-ch:
			t.handle(e)
		case <-tick.C:
			t.sweepStale()
			t.sweepPushWatchdog()
		case <-pend.C:
			t.flushPending(time.Now())
		}
	}
}

// adopt registra i server già aperti quando l'hub parte, così un riavvio
// dell'hub non fa ripartire l'annuncio di apertura né perde la chiusura.
func (t *Telegram) adopt() {
	for _, sp := range t.st.ListSpaces() {
		if lk, err := t.st.CurrentLock(sp.ID); err == nil && announceable(lk) {
			t.open[sp.ID] = session{owner: lk.Owner, since: lk.Since, start: lk.Since, lastPush: time.Now()}
		}
	}
}

func (t *Telegram) handle(e events.Event) {
	switch e.Type {
	case "lock":
		lk, err := t.st.CurrentLock(e.Space)
		if err != nil || lk == nil {
			return
		}
		t.opened(e.Space, lk)
	case "push":
		if s, was := t.open[e.Space]; was {
			s.lastPush = time.Now()
			s.pushWarned = false
			t.open[e.Space] = s
		}
	case "unlock", "force":
		t.closed(e.Space, "")
	case "space":
		// spazio eliminato: la sessione aperta si dimentica (l'eliminazione
		// è possibile solo senza lock vivi, quindi il server era già chiuso)
		if del, _ := e.Data["deleted"].(bool); del {
			delete(t.open, e.Space)
		}
	case "disk":
		t.queueThread(kindAlert, 0, "", e.Localized(t.lang()).Msg)
	}
}

// opened registra un lock vivo di gioco e, se serve, annuncia l'apertura.
// Idempotente per sessione di lock: lo chiamano sia l'evento "lock" sia la
// sorveglianza periodica (che vede anche i lock resuscitati da un heartbeat).
func (t *Telegram) opened(id string, lk *store.LockInfo) {
	if !announceable(lk) {
		return // push manuale o lock sconosciuto: non è un server aperto
	}
	now := time.Now()
	if s, ok := t.open[id]; ok {
		if s.since.Equal(lk.Since) {
			return // già annunciato
		}
		// la sessione precedente è finita senza che ce ne accorgessimo
		delete(t.open, id)
		t.flushClose(id, pendingClose{s: s, at: now})
	}
	if p, ok := t.pending[id]; ok {
		delete(t.pending, id)
		switch {
		case p.s.since.Equal(lk.Since):
			// lo stesso lock, tornato vivo con un heartbeat prima che la
			// chiusura partisse: per il gruppo non è mai stato chiuso
			t.open[id] = p.s
			return
		case p.s.owner == lk.Owner && now.Sub(p.at) <= t.coalesce:
			// chiuso e riaperto subito dallo stesso host (riavvio del server):
			// nessun messaggio, la sessione continua con la durata vera
			s := p.s
			s.since, s.lastPush, s.pushWarned = lk.Since, now, false
			t.open[id] = s
			return
		default:
			t.flushClose(id, p) // chiusura vera: va detta prima della nuova apertura
		}
	}
	t.open[id] = session{owner: lk.Owner, since: lk.Since, start: lk.Since, lastPush: now}
	t.queue(kindOpen, id, t.openMsg(id, lk))
}

// closed segna la fine di una sessione aperta: l'annuncio parte dopo
// t.coalesce, se nel frattempo non riapre.
func (t *Telegram) closed(id, why string) {
	s, ok := t.open[id]
	if !ok {
		return
	}
	delete(t.open, id)
	p := pendingClose{s: s, why: why, at: time.Now()}
	if t.coalesce <= 0 {
		t.flushClose(id, p)
		return
	}
	t.pending[id] = p
}

// flushPending annuncia le chiusure in attesa da almeno t.coalesce.
func (t *Telegram) flushPending(now time.Time) {
	for id, p := range t.pending {
		if now.Sub(p.at) >= t.coalesce {
			delete(t.pending, id)
			t.flushClose(id, p)
		}
	}
}

func (t *Telegram) flushClose(id string, p pendingClose) {
	t.queue(kindClose, id, t.closeMsg(id, p.s, p.why, p.at))
}

// sweepPushWatchdog avvisa (una volta per sessione) se un server è aperto,
// il client batte il cuore, ma i salvataggi non arrivano più: è il segnale
// che il mondo NON è al sicuro sull'hub, e solo l'host se ne accorgerebbe.
func (t *Telegram) sweepPushWatchdog() {
	now := time.Now()
	for id, s := range t.open {
		if s.pushWarned || now.Sub(s.lastPush) < pushWarnAfter {
			continue
		}
		lk, err := t.st.CurrentLock(id)
		if err != nil || lk == nil || lk.Stale(now) {
			continue // chiuso o stale: ci pensa sweepStale
		}
		// a avvisi spenti la sessione non si marca: se li si riaccende,
		// l'avviso arriva
		if t.queue(kindAlert, id, t.trf(
			"⚠️ <b>%s</b> è aperto ma non salva sull'hub da %s\n👤 host <b>%s</b>: i salvataggi automatici non arrivano, lo stato recente non è protetto",
			esc(t.name(id)), dur(now.Sub(s.lastPush)), esc(s.owner))) {
			s.pushWarned = true
			t.open[id] = s
		}
	}
}

// sweepStale chiude i server il cui client ha smesso di battere il cuore, e
// riprende quelli il cui lock è tornato vivo (un heartbeat dopo una lunga
// pausa resuscita il lock stale: la chiusura successiva va annunciata) o
// il cui evento di apertura si è perso.
func (t *Telegram) sweepStale() {
	now := time.Now()
	for id, s := range t.open {
		lk, err := t.st.CurrentLock(id)
		if err != nil {
			if errors.Is(err, store.ErrNotFound) {
				delete(t.open, id) // spazio eliminato: niente da annunciare
			}
			continue
		}
		switch {
		case lk == nil || !lk.Since.Equal(s.since): // rilasciato senza che passassimo dall'evento
			t.closed(id, "")
		case lk.Stale(now):
			t.closed(id, t.trf("il client di %s non risponde più", esc(s.owner)))
		}
	}
	for _, sp := range t.st.ListSpaces() {
		lk, err := t.st.CurrentLock(sp.ID)
		if err != nil || lk == nil || lk.Stale(now) {
			continue
		}
		t.opened(sp.ID, lk)
	}
}

// --- /status ---

type tgUpdate struct {
	UpdateID int64 `json:"update_id"`
	Message  *struct {
		Text string `json:"text"`
		Chat struct {
			ID int64 `json:"id"`
		} `json:"chat"`
		// nei gruppi forum: il topic del messaggio. Nei gruppi normali
		// message_thread_id c'è anche nelle risposte, ma is_topic_message no.
		ThreadID int64 `json:"message_thread_id"`
		IsTopic  bool  `json:"is_topic_message"`
	} `json:"message"`
}

// poller ascolta i comandi del gruppo con getUpdates (long-poll).
// Risponde solo a /status e solo nella chat configurata.
func (t *Telegram) poller(ctx context.Context, token string) {
	var offset int64
	for ctx.Err() == nil {
		upds, err := t.getUpdates(ctx, token, offset)
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			t.recordErr(token, "", t.redact(err, token), true)
			select {
			case <-ctx.Done():
				return
			case <-time.After(10 * time.Second):
			}
			continue
		}
		t.clearPollErr(token)
		for _, u := range upds {
			if u.UpdateID >= offset {
				offset = u.UpdateID + 1
			}
			if u.Message == nil {
				continue
			}
			cmd, _, _ := strings.Cut(strings.TrimSpace(u.Message.Text), " ")
			cmd, _, _ = strings.Cut(cmd, "@") // "/status@nomebot" nei gruppi
			if !strings.EqualFold(cmd, "/status") {
				continue
			}
			c := t.config()
			if !sameChat(u.Message.Chat.ID, c.ChatID) {
				continue
			}
			// si risponde nello stesso topic; in un topic di un server, solo
			// per quel server (o quei server, se ne condividono uno)
			var thread int64
			if u.Message.IsTopic && u.Message.ThreadID > 1 {
				thread = u.Message.ThreadID
			}
			t.queueThread(kindStatus, thread, "", t.statusMsg(spacesOfTopic(c, thread)))
		}
		if len(upds) == 0 {
			// il long-poll vero attende da solo; questa pausa protegge solo
			// dal loop stretto se il server risponde subito (test, errori soft)
			select {
			case <-ctx.Done():
				return
			case <-time.After(time.Second):
			}
		}
	}
}

// sameChat: il chat id configurato può essere numerico o un @canale (in quel
// caso i comandi non si riconoscono: i canali non mandano /status).
func sameChat(id int64, configured string) bool {
	return fmt.Sprint(id) == configured
}

func (t *Telegram) getUpdates(ctx context.Context, token string, offset int64) ([]tgUpdate, error) {
	body, _ := json.Marshal(map[string]any{
		"offset": offset, "timeout": pollTimeout, "allowed_updates": []string{"message"},
	})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		fmt.Sprintf("%s/bot%s/getUpdates", t.base, token), bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := t.hc.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		_, err := apiError(resp)
		return nil, err
	}
	var out struct {
		OK     bool       `json:"ok"`
		Result []tgUpdate `json:"result"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, err
	}
	if !out.OK {
		return nil, fmt.Errorf("telegram getUpdates: ok=false")
	}
	return out.Result, nil
}

// spacesOfTopic: gli spazi assegnati al topic thread (nil = tutti: thread 0,
// cioè il Generale, o un topic che non è di nessun server).
func spacesOfTopic(c Config, thread int64) map[string]bool {
	if thread == 0 {
		return nil
	}
	var out map[string]bool
	for id, th := range c.Topics {
		if th == thread {
			if out == nil {
				out = map[string]bool{}
			}
			out[id] = true
		}
	}
	return out
}

// statusMsg fotografa lo stato dei server: la risposta a /status. only
// limita agli spazi indicati (nil = tutti).
func (t *Telegram) statusMsg(only map[string]bool) string {
	now := time.Now()
	lines := []string{t.tr("📊 <b>Stato dei server</b>")}
	spaces := t.st.ListSpaces()
	if only != nil {
		var sel []store.Space
		for _, sp := range spaces {
			if only[sp.ID] {
				sel = append(sel, sp)
			}
		}
		if len(sel) > 0 { // altrimenti erano server eliminati: tutti
			spaces = sel
		}
	}
	for _, sp := range spaces {
		lk, err := t.st.CurrentLock(sp.ID)
		if err != nil {
			continue
		}
		// un push manuale tiene il lock ma non apre il server
		if lk == nil || lk.Stale(now) || !announceable(lk) {
			lines = append(lines, t.trf("⚪ <b>%s</b> — chiuso", esc(sp.Name)))
			continue
		}
		l := t.trf("🟢 <b>%s</b> — hosta %s", esc(sp.Name), esc(lk.Owner))
		if d := dur(time.Since(lk.Since)); d != "" {
			l += t.trf(" da %s", d)
		}
		switch n := len(lk.Players); {
		case n == 0:
			l += t.tr(", nessuno in gioco")
		case n <= 6:
			l += t.trf(", in gioco: %s", esc(strings.Join(lk.Players, ", ")))
		default:
			l += t.trf(", %d in gioco", n)
		}
		lines = append(lines, l)
		if t.zone != "" {
			lines = append(lines, fmt.Sprintf("   🌐 <code>zerotier.%s.%s</code>", esc(sp.ID), esc(t.zone)))
		} else if ip := hostAddr(lk); ip != "" {
			lines = append(lines, "   📡 <code>"+esc(ip)+"</code>")
		}
	}
	if len(lines) == 1 {
		lines = append(lines, t.tr("Nessun server configurato."))
	}
	return strings.Join(lines, "\n")
}

// Ogni riga si apre con la sua emoji, così il messaggio si legge a colpo
// d'occhio nella lista chat di Telegram.
func (t *Telegram) openMsg(id string, lk *store.LockInfo) string {
	lines := []string{
		t.trf("🟢 <b>%s</b> è aperto", esc(t.name(id))),
		t.trf("👤 hosta <b>%s</b>", esc(lk.Owner)),
	}
	if t.zone != "" {
		lines = append(lines, fmt.Sprintf("🌐 <code>zerotier.%s.%s</code>", esc(id), esc(t.zone)))
	}
	if ip := hostAddr(lk); ip != "" {
		lines = append(lines, "📡 <code>"+esc(ip)+"</code>")
	}
	return strings.Join(lines, "\n")
}

// closeMsg: end è quando il server si è chiuso (l'annuncio può partire dopo).
func (t *Telegram) closeMsg(id string, s session, why string, end time.Time) string {
	lines := []string{t.trf("🔴 <b>%s</b> è chiuso", esc(t.name(id)))}
	if why != "" {
		lines = append(lines, "⚠️ "+why)
	}
	if d := dur(end.Sub(s.start)); d != "" {
		lines = append(lines, t.trf("⏱ sessione di %s", d))
	}
	return strings.Join(lines, "\n")
}

// hostAddr è l'indirizzo diretto di chi ospita: il primo IP pubblicato nel lock
// (il client li mette ZeroTier-first, poi LAN — vedi mc.LocalIPs). La porta si
// mostra solo se non è quella di default, che Minecraft sottintende.
func hostAddr(lk *store.LockInfo) string {
	host, _, _ := strings.Cut(lk.Info["host"], ",")
	host = strings.TrimSpace(host)
	if net.ParseIP(host) == nil {
		return ""
	}
	if p := strings.TrimSpace(lk.Info["port"]); p != "" && p != "25565" {
		return net.JoinHostPort(host, p)
	}
	return host
}

func (t *Telegram) name(id string) string {
	if sp, _, _, err := t.st.GetSpace(id); err == nil && sp.Name != "" {
		return sp.Name
	}
	return id
}

// dur formatta una durata per gli umani: "2h 5m", "40m", "" sotto il minuto.
func dur(d time.Duration) string {
	switch m := int(d.Minutes()); {
	case m < 1:
		return ""
	case m < 60:
		return fmt.Sprintf("%dm", m)
	default:
		return fmt.Sprintf("%dh %dm", m/60, m%60)
	}
}

func esc(s string) string { return html.EscapeString(s) }

// queue accoda senza mai bloccare l'hub: se Telegram è irraggiungibile e la
// coda si riempie, si perde l'annuncio, non la sessione di gioco. A bot
// spento o con quel tipo di messaggio disattivato non accoda nulla (false).
// Il messaggio va nel topic dello spazio, se ne ha uno.
func (t *Telegram) queue(k kind, space, msg string) bool {
	return t.queueThread(k, t.config().topic(space), space, msg)
}

// queueThread accoda per un topic preciso (0 = chat principale).
func (t *Telegram) queueThread(k kind, thread int64, space, msg string) bool {
	c := t.config()
	if !c.active() || !c.wants(k) {
		return false
	}
	select {
	case t.out <- outMsg{token: c.Token, chatID: c.ChatID, text: msg, thread: thread, space: space}:
		return true
	default:
		log.Print(i18n.Lf("telegram: coda piena, annuncio scartato"))
		return false
	}
}

func (t *Telegram) sender(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case m := <-t.out:
			// accodato prima di un cambio di configurazione: il bot è stato
			// spento o punta altrove, l'annuncio non va più mandato
			if c := t.config(); !c.active() || c.Token != m.token || c.ChatID != m.chatID {
				continue
			}
			t.send(ctx, m)
		}
	}
}

// send manda un messaggio, riprovando gli errori transitori: rispetta il
// retry_after di Telegram (429) e non spende più di t.retryBudget in tutto.
func (t *Telegram) send(ctx context.Context, m outMsg) {
	var err error
	start := time.Now()
	for try := 1; ; try++ {
		var retry bool
		retry, err = t.sendOnce(ctx, m.token, m.chatID, m.thread, m.text)
		if err == nil {
			t.recordSent(m.token, m.chatID)
			return
		}
		if m.thread != 0 && threadNotFound(err) {
			t.sendGeneral(ctx, m)
			return
		}
		if !retry || try == sendTries || ctx.Err() != nil {
			break
		}
		wait := time.Duration(try) * t.backoff
		var ae *apiErr
		if errors.As(err, &ae) && ae.retryAfter > 0 {
			wait = ae.retryAfter // Telegram dice quanto aspettare (429)
		}
		if time.Since(start)+wait > t.retryBudget {
			break // troppo: meglio perdere l'annuncio che bloccare la coda
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(wait):
		}
	}
	err = t.redact(err, m.token)
	t.recordErr(m.token, m.chatID, err, false)
	log.Print(i18n.Lf("telegram: annuncio non inviato: %v", err))
}

// sendGeneral: il topic del server non esiste più (eliminato dal gruppo).
// L'annuncio si rimanda una volta nella chat principale e lo stato del bot
// mostra quale topic manca, finché l'admin non sistema la mappa.
func (t *Telegram) sendGeneral(ctx context.Context, m outMsg) {
	_, err := t.sendOnce(ctx, m.token, m.chatID, 0, m.text)
	if err != nil {
		err = t.redact(err, m.token)
	} else {
		err = i18n.Errorf("topic di %s non trovato su Telegram (eliminato?): i messaggi vanno nel topic Generale", t.name(m.space))
	}
	t.recordErr(m.token, m.chatID, err, false)
	log.Print(i18n.Lf("telegram: %v", err))
}

// threadNotFound: Telegram rifiuta il message_thread_id perché il topic non
// c'è più ("Bad Request: message thread not found").
func threadNotFound(err error) bool {
	var ae *apiErr
	return errors.As(err, &ae) && strings.Contains(strings.ToLower(ae.desc), "thread not found")
}

// Test manda subito un messaggio di prova con la configurazione c (anche non
// salvata), un tentativo solo. space non vuoto: la prova va nel topic di quel
// server (c.Topics), col suo nome nel testo. L'errore è già senza token.
func (t *Telegram) Test(ctx context.Context, c Config, space string) error {
	l := c.Lang
	if l == "" {
		l = i18n.Default()
	}
	msg := i18n.T(l, "✅ <b>MineSync</b>: messaggio di prova. Il bot è configurato correttamente.")
	var thread int64
	if space != "" {
		thread = c.topic(space)
		msg = i18n.Tf(l, "✅ <b>MineSync</b>: messaggio di prova per <b>%s</b>. Gli annunci di questo server arriveranno qui.", esc(t.name(space)))
	}
	_, err := t.sendOnce(ctx, c.Token, c.ChatID, thread, msg)
	if err != nil {
		if thread != 0 && threadNotFound(err) {
			// il topic provato potrebbe non essere quello salvato: lo stato
			// del bot non si tocca
			return i18n.Errorf("topic di %s non trovato su Telegram (eliminato?): i messaggi vanno nel topic Generale", t.name(space))
		}
		err = t.redact(err, c.Token)
		t.recordErr(c.Token, c.ChatID, err, false)
		return err
	}
	t.recordSent(c.Token, c.ChatID)
	return nil
}

// sendOnce chiama sendMessage; retry dice se ha senso riprovare (rete, 5xx,
// 429), non per gli errori di configurazione (401 token, 400 chat).
// thread > 0: nel topic indicato (gruppi forum); mai 1, che è il Generale e
// Telegram lo rifiuta.
func (t *Telegram) sendOnce(ctx context.Context, token, chatID string, thread int64, msg string) (retry bool, err error) {
	req := map[string]any{
		"chat_id": chatID, "text": msg, "parse_mode": "HTML",
		"disable_web_page_preview": true,
	}
	if thread > 1 {
		req["message_thread_id"] = thread
	}
	body, err := json.Marshal(req)
	if err != nil {
		return false, err
	}
	url := fmt.Sprintf("%s/bot%s/sendMessage", t.base, token)
	hreq, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return false, err
	}
	hreq.Header.Set("Content-Type", "application/json")
	resp, err := t.hc.Do(hreq)
	if err != nil {
		return true, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return apiError(resp)
	}
	return false, nil
}

// apiErr è la risposta d'errore di Telegram: status e descrizione, tenuta
// da parte per riconoscere i casi particolari (topic eliminato).
// retryAfter è parameters.retry_after delle risposte 429 (0 = assente).
type apiErr struct {
	status, desc string
	retryAfter   time.Duration
}

func (e *apiErr) Error() string {
	if e.desc == "" {
		return e.status
	}
	return e.status + " (" + e.desc + ")"
}

// apiError: lo status di Telegram con la sua descrizione ("401 Unauthorized
// (Unauthorized)", "400 Bad Request (Bad Request: chat not found)").
func apiError(resp *http.Response) (retry bool, err error) {
	var out struct {
		Description string `json:"description"`
		Parameters  struct {
			RetryAfter int `json:"retry_after"` // secondi
		} `json:"parameters"`
	}
	_ = json.NewDecoder(io.LimitReader(resp.Body, 64<<10)).Decode(&out)
	retry = resp.StatusCode >= 500 || resp.StatusCode == http.StatusTooManyRequests
	ae := &apiErr{status: resp.Status, desc: strings.TrimSpace(out.Description)}
	if ra := out.Parameters.RetryAfter; ra > 0 {
		ae.retryAfter = time.Duration(min(ra, 3600)) * time.Second
	}
	return retry, i18n.Errorf("telegram ha risposto %s", ae)
}

// recordSent e recordErr aggiornano lo stato solo se riguardano la
// configurazione corrente (un test con dati non salvati non lo sporca).
func (t *Telegram) recordSent(token, chatID string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if token != t.cfg.Token || chatID != t.cfg.ChatID {
		return
	}
	t.lastSent = time.Now().UTC()
	t.lastErr, t.lastErrAt, t.pollErr = nil, time.Time{}, false
}

// recordErr: chatID "" = errore del poller (vale per qualsiasi chat).
func (t *Telegram) recordErr(token, chatID string, err error, fromPoll bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if token != t.cfg.Token || (chatID != "" && chatID != t.cfg.ChatID) {
		return
	}
	t.lastErr, t.lastErrAt, t.pollErr = err, time.Now().UTC(), fromPoll
}

// clearPollErr: getUpdates è tornato a funzionare. Un errore di invio resta
// (il poller non dice nulla sulla chat).
func (t *Telegram) clearPollErr(token string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.pollErr && token == t.cfg.Token {
		t.lastErr, t.lastErrAt, t.pollErr = nil, time.Time{}, false
	}
}

// redact toglie il token del bot da un errore: un *url.Error contiene l'URL
// completo (…/bot<TOKEN>/…) e finirebbe nei log e nella web UI.
func (t *Telegram) redact(err error, token string) error {
	if err == nil {
		return nil
	}
	var ue *neturl.Error
	if errors.As(err, &ue) {
		err = fmt.Errorf("%s: %w", ue.Op, ue.Err)
	}
	if token != "" && strings.Contains(err.Error(), token) {
		return errors.New(strings.ReplaceAll(err.Error(), token, "<token>"))
	}
	return err
}
