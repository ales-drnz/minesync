// Package events: log append-only (jsonl) + bus di broadcast per SSE.
package events

import (
	"bufio"
	"encoding/json"
	"os"
	"sync"
	"time"

	"minesync/server/internal/i18n"
)

// Event è una voce del registro attività dell'hub.
//
// Msg resta per compatibilità: nel log è il testo italiano, sull'API viene
// reso nella lingua della richiesta (Localized). Text, se presente, è la
// forma strutturata ("key" = id italiano del messaggio, "args" = argomenti).
type Event struct {
	TS    time.Time `json:"ts"`
	Type  string    `json:"type"` // push, lock, unlock, force, restore, space, gc
	Space string    `json:"space,omitempty"`
	Actor string    `json:"actor,omitempty"`
	Msg   string    `json:"msg"`
	*i18n.Text
	Data map[string]any `json:"data,omitempty"`
}

// Localized restituisce una copia dell'evento con Msg nella lingua l (gli
// eventi vecchi, senza Text, restano col loro testo).
func (e Event) Localized(l i18n.Lang) Event {
	if e.Text != nil && e.Text.Key != "" {
		e.Msg = e.Text.Localize(l)
	}
	return e
}

// Bus scrive gli eventi su file e li rilancia agli iscritti (SSE).
type Bus struct {
	mu      sync.Mutex
	path    string
	subs    map[chan Event]struct{}
	recent  []Event // ring in memoria per /events senza stream
	maxRing int
}

func NewBus(path string) *Bus {
	b := &Bus{path: path, subs: map[chan Event]struct{}{}, maxRing: 500}
	b.loadRecent()
	return b
}

func (b *Bus) loadRecent() {
	f, err := os.Open(b.path)
	if err != nil {
		return
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	for sc.Scan() {
		var e Event
		if json.Unmarshal(sc.Bytes(), &e) == nil {
			b.recent = append(b.recent, e)
			if len(b.recent) > b.maxRing {
				b.recent = b.recent[1:]
			}
		}
	}
}

// Publish registra e trasmette un evento.
func (b *Bus) Publish(e Event) {
	if e.TS.IsZero() {
		e.TS = time.Now().UTC()
	}
	if e.Msg == "" && e.Text != nil {
		e.Msg = e.Text.Localize(i18n.IT)
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if f, err := os.OpenFile(b.path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o664); err == nil {
		if line, err := json.Marshal(e); err == nil {
			f.Write(append(line, '\n'))
		}
		f.Close()
	}
	b.recent = append(b.recent, e)
	if len(b.recent) > b.maxRing {
		b.recent = b.recent[1:]
	}
	for ch := range b.subs {
		select {
		case ch <- e:
		default: // iscritto lento: perde l'evento, mai bloccare l'hub
		}
	}
}

// Recent restituisce gli ultimi n eventi (più recente per ultimo).
func (b *Bus) Recent(n int) []Event {
	b.mu.Lock()
	defer b.mu.Unlock()
	if n <= 0 || n > len(b.recent) {
		n = len(b.recent)
	}
	out := make([]Event, n)
	copy(out, b.recent[len(b.recent)-n:])
	return out
}

// Subscribe registra un canale per ricevere gli eventi futuri.
func (b *Bus) Subscribe() chan Event {
	ch := make(chan Event, 64)
	b.mu.Lock()
	b.subs[ch] = struct{}{}
	b.mu.Unlock()
	return ch
}

// Unsubscribe rimuove un iscritto.
func (b *Bus) Unsubscribe(ch chan Event) {
	b.mu.Lock()
	delete(b.subs, ch)
	b.mu.Unlock()
	close(ch)
}
