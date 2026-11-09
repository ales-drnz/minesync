// Package notify: annuncia nel gruppo Telegram quando un server apre e chiude.
//
// Si iscrive al bus eventi come un qualsiasi client SSE: lock = aperto,
// unlock/force = chiuso. In più sorveglia i lock scaduti, perché a un client
// che sparisce (crash, corrente, chiusura brutale) non arriva mai l'unlock e
// senza questo controllo il gruppo resterebbe con l'ultimo "ha aperto".
package notify

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"log"
	"net"
	"net/http"
	neturl "net/url"
	"strings"
	"time"

	"minesync/server/internal/events"
	"minesync/server/internal/i18n"
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

// Telegram inoltra gli eventi di apertura e chiusura a una chat, risponde a
// /status e avvisa se una sessione viva smette di salvare sull'hub.
type Telegram struct {
	token, chatID string
	zone          string // zona DNS, per mostrare l'indirizzo fisso ("" = niente)
	st            *store.Store
	bus           *events.Bus
	hc            *http.Client
	base          string // override per i test
	out           chan string
	open          map[string]session
	lang          i18n.Lang // lingua dei messaggi: quella dell'hub
}

func (t *Telegram) tr(id string) string            { return i18n.T(t.lang, id) }
func (t *Telegram) trf(id string, a ...any) string { return i18n.Tf(t.lang, id, a...) }

type session struct {
	owner      string
	since      time.Time
	lastPush   time.Time // ultimo push visto (all'apertura: l'apertura stessa)
	pushWarned bool      // avviso "non salva più" già mandato per questa sessione
}

// New restituisce il notificatore, o nil se token o chat non sono configurati
// (il bot è opzionale: senza le due env l'hub gira identico a prima).
func New(token, chatID, zone string, st *store.Store, bus *events.Bus) *Telegram {
	if token == "" || chatID == "" {
		return nil
	}
	return &Telegram{
		token: token, chatID: chatID, zone: zone, st: st, bus: bus,
		hc:   &http.Client{Timeout: 15 * time.Second},
		base: apiBase,
		out:  make(chan string, 64),
		open: map[string]session{},
		lang: i18n.Default(),
	}
}

// Run consuma gli eventi finché il contesto non viene chiuso.
func (t *Telegram) Run(ctx context.Context) {
	t.adopt() // lock già attivi al riavvio dell'hub: niente annuncio, solo stato
	go t.sender(ctx)
	go t.poller(ctx) // /status nel gruppo

	ch := t.bus.Subscribe()
	defer t.bus.Unsubscribe(ch)
	tick := time.NewTicker(staleCheck)
	defer tick.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case e := <-ch:
			t.handle(e)
		case <-tick.C:
			t.sweepStale()
			t.sweepPushWatchdog()
		}
	}
}

// adopt registra i server già aperti quando l'hub parte, così un riavvio
// dell'hub non fa ripartire l'annuncio di apertura né perde la chiusura.
func (t *Telegram) adopt() {
	for _, sp := range t.st.ListSpaces() {
		if lk, err := t.st.CurrentLock(sp.ID); err == nil && lk != nil {
			t.open[sp.ID] = session{owner: lk.Owner, since: lk.Since, lastPush: time.Now()}
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
		t.open[e.Space] = session{owner: lk.Owner, since: lk.Since, lastPush: time.Now()}
		t.queue(t.openMsg(e.Space, lk))
	case "push":
		if s, was := t.open[e.Space]; was {
			s.lastPush = time.Now()
			s.pushWarned = false
			t.open[e.Space] = s
		}
	case "unlock", "force":
		s, was := t.open[e.Space]
		if !was {
			return
		}
		delete(t.open, e.Space)
		t.queue(t.closeMsg(e.Space, s, ""))
	}
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
		if err != nil || lk == nil || lk.Stale(now.UTC()) {
			continue // chiuso o stale: ci pensa sweepStale
		}
		s.pushWarned = true
		t.open[id] = s
		t.queue(t.trf(
			"⚠️ <b>%s</b> è aperto ma non salva sull'hub da %s\n👤 host <b>%s</b>: i salvataggi automatici non arrivano, lo stato recente non è protetto",
			esc(t.name(id)), dur(now.Sub(s.lastPush)), esc(s.owner)))
	}
}

// sweepStale chiude i server il cui client ha smesso di battere il cuore.
func (t *Telegram) sweepStale() {
	now := time.Now().UTC()
	for id, s := range t.open {
		lk, err := t.st.CurrentLock(id)
		if err != nil {
			continue
		}
		switch {
		case lk == nil: // rilasciato senza che passassimo dall'evento
			delete(t.open, id)
			t.queue(t.closeMsg(id, s, ""))
		case lk.Stale(now):
			delete(t.open, id)
			t.queue(t.closeMsg(id, s, t.trf("il client di %s non risponde più", esc(s.owner))))
		}
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
	} `json:"message"`
}

// poller ascolta i comandi del gruppo con getUpdates (long-poll).
// Risponde solo a /status e solo nella chat configurata.
func (t *Telegram) poller(ctx context.Context) {
	var offset int64
	for ctx.Err() == nil {
		upds, err := t.getUpdates(ctx, offset)
		if err != nil {
			select {
			case <-ctx.Done():
				return
			case <-time.After(10 * time.Second):
			}
			continue
		}
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
			if fmt.Sprint(u.Message.Chat.ID) != t.chatID {
				continue
			}
			t.queue(t.statusMsg())
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

func (t *Telegram) getUpdates(ctx context.Context, offset int64) ([]tgUpdate, error) {
	body, _ := json.Marshal(map[string]any{
		"offset": offset, "timeout": pollTimeout, "allowed_updates": []string{"message"},
	})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		fmt.Sprintf("%s/bot%s/getUpdates", t.base, t.token), bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := t.hc.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
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

// statusMsg fotografa lo stato di tutti i server: la risposta a /status.
func (t *Telegram) statusMsg() string {
	now := time.Now().UTC()
	lines := []string{t.tr("📊 <b>Stato dei server</b>")}
	for _, sp := range t.st.ListSpaces() {
		lk, err := t.st.CurrentLock(sp.ID)
		if err != nil {
			continue
		}
		if lk == nil || lk.Stale(now) {
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

func (t *Telegram) closeMsg(id string, s session, why string) string {
	lines := []string{t.trf("🔴 <b>%s</b> è chiuso", esc(t.name(id)))}
	if why != "" {
		lines = append(lines, "⚠️ "+why)
	}
	if d := dur(time.Since(s.since)); d != "" {
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
// coda si riempie, si perde l'annuncio, non la sessione di gioco.
func (t *Telegram) queue(msg string) {
	select {
	case t.out <- msg:
	default:
		log.Print(i18n.Lf("telegram: coda piena, annuncio scartato"))
	}
}

func (t *Telegram) sender(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case msg := <-t.out:
			t.send(ctx, msg)
		}
	}
}

func (t *Telegram) send(ctx context.Context, msg string) {
	body, err := json.Marshal(map[string]any{
		"chat_id": t.chatID, "text": msg, "parse_mode": "HTML",
		"disable_web_page_preview": true,
	})
	if err != nil {
		return
	}
	url := fmt.Sprintf("%s/bot%s/sendMessage", t.base, t.token)
	for try := 1; ; try++ {
		err := t.post(ctx, url, body)
		if err == nil {
			return
		}
		if try == sendTries || ctx.Err() != nil {
			log.Print(i18n.Lf("telegram: annuncio non inviato: %v", t.redact(err)))
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(time.Duration(try) * 2 * time.Second):
		}
	}
}

// redact toglie il token del bot da un errore: un *url.Error contiene l'URL
// completo (…/bot<TOKEN>/…) e finirebbe nei log.
func (t *Telegram) redact(err error) error {
	if err == nil {
		return nil
	}
	var ue *neturl.Error
	if errors.As(err, &ue) {
		err = fmt.Errorf("%s: %w", ue.Op, ue.Err)
	}
	if t.token != "" && strings.Contains(err.Error(), t.token) {
		return errors.New(strings.ReplaceAll(err.Error(), t.token, "<token>"))
	}
	return err
}

func (t *Telegram) post(ctx context.Context, url string, body []byte) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := t.hc.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return i18n.Errorf("telegram ha risposto %s", resp.Status)
	}
	return nil
}
