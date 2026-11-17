// Package settings: impostazioni dell'hub modificabili dalla web UI,
// persistite in <data>/settings.json (scrittura atomica con fsync, file 0600
// perché contiene il token del bot).
//
// Il file è un oggetto con una sezione per argomento ("telegram" oggi): le
// sezioni nuove si aggiungono senza toccare quelle esistenti. Chi usa le
// impostazioni si iscrive con Subscribe e si riconfigura a caldo.
package settings

import (
	"encoding/json"
	"errors"
	"maps"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"

	"minesync/server/internal/i18n"
	"minesync/server/internal/store"
)

// FileName è il nome del file nella directory dati.
const FileName = "settings.json"

// Notify: quali messaggi manda il bot.
type Notify struct {
	Open   bool `json:"open"`   // server aperto
	Close  bool `json:"close"`  // server chiuso (anche per crash/lock scaduto)
	Alerts bool `json:"alerts"` // avvisi (watchdog dei salvataggi)
	Status bool `json:"status"` // risposta a /status nella chat
}

// Telegram è la configurazione del bot. Token è un segreto: non va mai
// restituito dall'API né scritto nei log.
type Telegram struct {
	Enabled bool   `json:"enabled"`
	Token   string `json:"token,omitempty"`
	ChatID  string `json:"chatId,omitempty"`
	Lang    string `json:"lang,omitempty"` // "it", "en" o "" = lingua dell'hub
	Notify  Notify `json:"notify"`
	// Topics: gruppi "forum" con un topic per server. id dello spazio →
	// message_thread_id del suo topic (sempre > 1: il topic "Generale" non ha
	// thread id e Telegram rifiuta 1). Gli spazi senza voce scrivono nella
	// chat principale.
	Topics map[string]int64 `json:"topics,omitempty"`
}

// Equal confronta due configurazioni (Telegram ha una mappa: niente ==).
func (tg Telegram) Equal(o Telegram) bool {
	return tg.Enabled == o.Enabled && tg.Token == o.Token && tg.ChatID == o.ChatID &&
		tg.Lang == o.Lang && tg.Notify == o.Notify && maps.Equal(tg.Topics, o.Topics)
}

// clone: copia indipendente (la mappa dei topic non va condivisa).
func (tg Telegram) clone() Telegram {
	tg.Topics = maps.Clone(tg.Topics)
	return tg
}

// DefaultTelegram: bot spento, tutte le notifiche attive (quando lo si
// accende, fa tutto quello che faceva prima).
func DefaultTelegram() Telegram {
	return Telegram{Notify: Notify{Open: true, Close: true, Alerts: true, Status: true}}
}

// Settings è il contenuto di settings.json.
type Settings struct {
	Telegram *Telegram `json:"telegram,omitempty"` // nil = mai configurato
}

// Store tiene le impostazioni in memoria e su disco.
type Store struct {
	mu   sync.Mutex
	path string
	s    Settings
	subs []chan struct{}
}

// Open legge <dir>/settings.json (assente = impostazioni vuote).
func Open(dir string) (*Store, error) {
	st := &Store{path: filepath.Join(dir, FileName)}
	b, err := os.ReadFile(st.path)
	switch {
	case errors.Is(err, os.ErrNotExist):
		return st, nil
	case err != nil:
		return nil, err
	}
	// le sezioni si decodificano partendo dai default, così un campo
	// aggiunto in una versione futura non resta a zero nei file vecchi
	var raw struct {
		Telegram json.RawMessage `json:"telegram"`
	}
	if err := json.Unmarshal(b, &raw); err != nil {
		return nil, i18n.Errorf("%s non valido: %v", st.path, err)
	}
	if len(raw.Telegram) > 0 && string(raw.Telegram) != "null" {
		tg := DefaultTelegram()
		if err := json.Unmarshal(raw.Telegram, &tg); err != nil {
			return nil, i18n.Errorf("%s non valido: %v", st.path, err)
		}
		st.s.Telegram = &tg
	}
	return st, nil
}

// Telegram restituisce una copia della sezione telegram; ok=false se non è
// mai stata salvata (in quel caso la copia è DefaultTelegram).
func (s *Store) Telegram() (tg Telegram, ok bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.s.Telegram == nil {
		return DefaultTelegram(), false
	}
	return s.s.Telegram.clone(), true
}

// UpdateTelegram applica fn alla sezione telegram (ai default se assente),
// valida, salva e avvisa gli iscritti. Se fn o la validazione falliscono
// non cambia nulla.
func (s *Store) UpdateTelegram(fn func(*Telegram) error) (Telegram, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	tg := DefaultTelegram()
	if s.s.Telegram != nil {
		tg = s.s.Telegram.clone()
	}
	if err := fn(&tg); err != nil {
		return Telegram{}, err
	}
	if err := tg.Validate(); err != nil {
		return Telegram{}, err
	}
	next := s.s
	next.Telegram = &tg
	if err := s.save(next); err != nil {
		return Telegram{}, err
	}
	s.s = next
	s.notify()
	return tg, nil
}

// MigrateTelegramEnv importa token e chat dalle vecchie variabili d'ambiente,
// una volta sola: solo se la sezione telegram non esiste ancora ed entrambe
// sono impostate. Restituisce true se ha importato.
func (s *Store) MigrateTelegramEnv(token, chatID string) (bool, error) {
	if token == "" || chatID == "" {
		return false, nil
	}
	if _, ok := s.Telegram(); ok {
		return false, nil
	}
	_, err := s.UpdateTelegram(func(tg *Telegram) error {
		tg.Enabled, tg.Token, tg.ChatID = true, token, chatID
		return nil
	})
	return err == nil, err
}

// Subscribe restituisce un canale che riceve un segnale a ogni modifica
// (bufferizzato: segnali ravvicinati si fondono in uno; chi lo riceve rilegge
// le impostazioni correnti).
func (s *Store) Subscribe() <-chan struct{} {
	s.mu.Lock()
	defer s.mu.Unlock()
	ch := make(chan struct{}, 1)
	s.subs = append(s.subs, ch)
	return ch
}

func (s *Store) notify() {
	for _, ch := range s.subs {
		select {
		case ch <- struct{}{}:
		default: // un segnale è già in attesa
		}
	}
}

func (s *Store) save(v Settings) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	return store.WriteFileAtomic(s.path, append(b, '\n'))
}

// --- validazione ---

var (
	// id numerico (negativo per gruppi e supergruppi) o @username di un canale
	reChatID = regexp.MustCompile(`^(-?[0-9]{1,20}|@[A-Za-z][A-Za-z0-9_]{3,31})$`)
	// <id del bot>:<segreto>, come lo dà @BotFather
	reToken = regexp.MustCompile(`^[0-9]{3,20}:[A-Za-z0-9_-]{30,60}$`)
)

// ValidChatID dice se s ha la forma di un chat id di Telegram.
func ValidChatID(s string) bool { return reChatID.MatchString(s) }

// ValidToken dice se s ha la forma di un token di bot.
func ValidToken(s string) bool { return reToken.MatchString(s) }

// Validate controlla i campi. Gli errori sono richieste non valide (400).
func (tg Telegram) Validate() error {
	if tg.Token != "" && !ValidToken(tg.Token) {
		return i18n.Errorf("%w: token del bot non valido (formato 123456789:ABC…, lo dà @BotFather)", store.ErrBadRequest)
	}
	if tg.ChatID != "" && !ValidChatID(tg.ChatID) {
		return i18n.Errorf("%w: chat id non valido (es. -1001234567890 oppure @nomecanale)", store.ErrBadRequest)
	}
	if tg.Lang != "" && tg.Lang != string(i18n.IT) && tg.Lang != string(i18n.EN) {
		return i18n.Errorf("%w: lingua non valida (it, en o vuota)", store.ErrBadRequest)
	}
	if tg.Enabled && (tg.Token == "" || tg.ChatID == "") {
		return i18n.Errorf("%w: per attivare il bot servono token e chat id", store.ErrBadRequest)
	}
	for id, th := range tg.Topics {
		if th <= 1 {
			return i18n.Errorf("%w: topic di %s non valido (serve un numero maggiore di 1)", store.ErrBadRequest, id)
		}
	}
	return nil
}

// --- topic dei gruppi forum ---

// Errori di ParseTopic (l'API li rende con il nome del server).
var ErrTopicInvalid = errors.New("topic non valido")

// TopicChatError: il link del topic è di un'altra chat. Chat è la chat del
// link nella forma del chat id ("-100…" oppure "@nome").
type TopicChatError struct{ Chat string }

func (e *TopicChatError) Error() string { return "topic di un'altra chat: " + e.Chat }

var (
	// https://t.me/c/<id interno>/<thread>[/<messaggio>] (gruppi privati)
	reTopicPrivate = regexp.MustCompile(`^(?:https?://)?(?:t|telegram)\.me/c/([0-9]{1,20})/([0-9]{1,20})(?:/[0-9]{1,20})?/?$`)
	// https://t.me/<username>/<thread>[/<messaggio>] (gruppi pubblici)
	reTopicPublic = regexp.MustCompile(`^(?:https?://)?(?:t|telegram)\.me/([A-Za-z][A-Za-z0-9_]{3,31})/([0-9]{1,20})(?:/[0-9]{1,20})?/?$`)
	reDigits      = regexp.MustCompile(`^[0-9]{1,20}$`)
)

// ParseTopic legge il topic di un server com'è scritto dall'admin: il numero
// del thread oppure il link del topic copiato da Telegram. Restituisce 0 per
// "nessun topic" (vuoto, oppure 1 = il topic Generale). Se il link indica la
// chat e chatID è nella stessa forma, devono coincidere (*TopicChatError).
func ParseTopic(v, chatID string) (int64, error) {
	v = strings.TrimSpace(v)
	if i := strings.IndexAny(v, "?#"); i >= 0 {
		v = v[:i] // ?single, ?thread=… : non servono
	}
	if v == "" {
		return 0, nil
	}
	var linkChat, num string
	switch {
	case reDigits.MatchString(v):
		num = v
	case reTopicPrivate.MatchString(v):
		m := reTopicPrivate.FindStringSubmatch(v)
		linkChat, num = "-100"+m[1], m[2]
		if strings.HasPrefix(chatID, "-100") && chatID != linkChat {
			return 0, &TopicChatError{Chat: linkChat}
		}
	case reTopicPublic.MatchString(v):
		m := reTopicPublic.FindStringSubmatch(v)
		if strings.EqualFold(m[1], "c") || strings.EqualFold(m[1], "s") {
			return 0, ErrTopicInvalid
		}
		linkChat, num = "@"+m[1], m[2]
		if strings.HasPrefix(chatID, "@") && !strings.EqualFold(chatID, linkChat) {
			return 0, &TopicChatError{Chat: linkChat}
		}
	default:
		return 0, ErrTopicInvalid
	}
	n, err := strconv.ParseInt(num, 10, 64)
	switch {
	case err != nil || n <= 0:
		return 0, ErrTopicInvalid
	case n == 1:
		return 0, nil // il topic Generale: si scrive senza thread id
	}
	return n, nil
}
