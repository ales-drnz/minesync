package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"time"

	"minesync/server/internal/events"
	"minesync/server/internal/i18n"
	"minesync/server/internal/notify"
	"minesync/server/internal/settings"
	"minesync/server/internal/store"
)

// TelegramBot è il bot visto dall'API (notify.Telegram; un finto nei test).
type TelegramBot interface {
	Test(ctx context.Context, c notify.Config, space string) error
	Status() notify.Status
}

// testEvery: al massimo un messaggio di prova ogni tanto (Telegram limita
// i bot, e un doppio clic non deve diventare due messaggi nel gruppo).
const testEvery = 3 * time.Second

var (
	errUpstream = i18n.Errorf("invio non riuscito")                                    // 502
	errTooMany  = i18n.Errorf("troppi messaggi di prova: riprova tra qualche secondo") // 429
)

// telegramView è la sezione telegram come la vede la web UI: il token non
// esce MAI dall'hub, solo se è impostato e le sue ultime 4 cifre.
type telegramView struct {
	Enabled     bool             `json:"enabled"`
	TokenSet    bool             `json:"tokenSet"`
	TokenHint   string           `json:"tokenHint,omitempty"`
	ChatID      string           `json:"chatId"`
	Lang        string           `json:"lang"`
	Notify      settings.Notify  `json:"notify"`
	Topics      map[string]int64 `json:"topics"` // id spazio → thread id del topic
	State       string           `json:"state"`  // disabled | active | error
	LastError   string           `json:"lastError,omitempty"`
	LastErrorAt *time.Time       `json:"lastErrorAt,omitempty"`
	LastSentAt  *time.Time       `json:"lastSentAt,omitempty"`
}

func (s *Server) telegramView(lang i18n.Lang) telegramView {
	tg, _ := s.Settings.Telegram()
	v := telegramView{
		Enabled: tg.Enabled, TokenSet: tg.Token != "", ChatID: tg.ChatID,
		Lang: tg.Lang, Notify: tg.Notify, State: "disabled",
		Topics: map[string]int64{},
	}
	names := s.spaceNames()
	for id, th := range tg.Topics {
		if _, ok := names[id]; ok { // voci di server eliminati: ignorate
			v.Topics[id] = th
		}
	}
	if n := len(tg.Token); n >= 8 {
		v.TokenHint = tg.Token[n-4:]
	}
	if tg.Enabled {
		v.State = "active"
		if s.Telegram != nil {
			st := s.Telegram.Status()
			if st.LastError != nil {
				v.State = "error"
				v.LastError = i18n.Localize(lang, st.LastError)
				v.LastErrorAt = &st.LastErrorAt
			}
			if !st.LastSentAt.IsZero() {
				v.LastSentAt = &st.LastSentAt
			}
		}
	}
	return v
}

func (s *Server) handleGetSettings(_ http.ResponseWriter, r *http.Request, _ Identity) (any, error) {
	if s.Settings == nil {
		return nil, store.ErrNotFound
	}
	return map[string]any{"telegram": s.telegramView(reqLang(r))}, nil
}

// handlePutTelegram: modifica parziale. Il token cambia solo se ne arriva uno
// non vuoto; clearToken lo cancella.
func (s *Server) handlePutTelegram(_ http.ResponseWriter, r *http.Request, who Identity) (any, error) {
	if s.Settings == nil {
		return nil, store.ErrNotFound
	}
	req, err := decode[struct {
		Enabled    *bool   `json:"enabled"`
		Token      *string `json:"token"`
		ClearToken bool    `json:"clearToken"`
		ChatID     *string `json:"chatId"`
		Lang       *string `json:"lang"`
		Notify     *struct {
			Open   *bool `json:"open"`
			Close  *bool `json:"close"`
			Alerts *bool `json:"alerts"`
			Status *bool `json:"status"`
		} `json:"notify"`
		// mappa completa (sostituisce quella salvata): numero o link del topic
		Topics *map[string]json.RawMessage `json:"topics"`
	}](r)
	if err != nil {
		return nil, err
	}
	names := s.spaceNames()
	before, _ := s.Settings.Telegram()
	after, err := s.Settings.UpdateTelegram(func(tg *settings.Telegram) error {
		if req.ClearToken {
			tg.Token = ""
		}
		if req.Token != nil && strings.TrimSpace(*req.Token) != "" {
			tg.Token = strings.TrimSpace(*req.Token)
		}
		if req.ChatID != nil {
			tg.ChatID = strings.TrimSpace(*req.ChatID)
		}
		if req.Lang != nil {
			tg.Lang = strings.TrimSpace(*req.Lang)
		}
		if req.Enabled != nil {
			tg.Enabled = *req.Enabled
		}
		if n := req.Notify; n != nil {
			for _, f := range []struct {
				src *bool
				dst *bool
			}{{n.Open, &tg.Notify.Open}, {n.Close, &tg.Notify.Close}, {n.Alerts, &tg.Notify.Alerts}, {n.Status, &tg.Notify.Status}} {
				if f.src != nil {
					*f.dst = *f.src
				}
			}
		}
		if req.Topics != nil {
			topics := map[string]int64{}
			for id, raw := range *req.Topics {
				name, ok := names[id]
				if !ok {
					continue // server che non esiste (più): ignorato
				}
				th, err := parseTopic(raw, name, tg.ChatID)
				if err != nil {
					return err
				}
				if th != 0 {
					topics[id] = th
				}
			}
			tg.Topics = topics
		}
		// le voci dei server eliminati si perdono al primo salvataggio
		for id := range tg.Topics {
			if _, ok := names[id]; !ok {
				delete(tg.Topics, id)
			}
		}
		if len(tg.Topics) == 0 {
			tg.Topics = nil
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	if !after.Equal(before) {
		s.Bus.Publish(events.Event{Type: "settings", Actor: who.Name,
			Text: i18n.M("%s ha modificato le impostazioni di Telegram", who.Name)})
	}
	return map[string]any{"telegram": s.telegramView(reqLang(r))}, nil
}

// handleTestTelegram manda un messaggio di prova. Senza body usa la
// configurazione salvata; token, chatId e lang nel body (anche parziali)
// sostituiscono quelli salvati SOLO per questa prova, senza salvarli: così si
// prova una configurazione prima di salvarla. Non serve che il bot sia attivo.
func (s *Server) handleTestTelegram(_ http.ResponseWriter, r *http.Request, _ Identity) (any, error) {
	if s.Settings == nil || s.Telegram == nil {
		return nil, store.ErrNotFound
	}
	var req struct {
		Token  string  `json:"token"`
		ChatID *string `json:"chatId"`
		Lang   *string `json:"lang"`
		// prova del topic di un server: quello salvato, o topic (numero o
		// link) se presente
		SpaceID string          `json:"spaceId"`
		Topic   json.RawMessage `json:"topic"`
	}
	raw, err := io.ReadAll(io.LimitReader(r.Body, 64<<10))
	if err != nil {
		return nil, err
	}
	if len(bytes.TrimSpace(raw)) > 0 {
		if err := json.Unmarshal(raw, &req); err != nil {
			return nil, i18n.Errorf("%w: body JSON non valido: %v", store.ErrBadRequest, err)
		}
	}
	tg, _ := s.Settings.Telegram()
	if t := strings.TrimSpace(req.Token); t != "" {
		tg.Token = t
	}
	if req.ChatID != nil {
		tg.ChatID = strings.TrimSpace(*req.ChatID)
	}
	if req.Lang != nil {
		tg.Lang = strings.TrimSpace(*req.Lang)
	}
	if tg.Token == "" || tg.ChatID == "" {
		return nil, i18n.Errorf("%w: per il messaggio di prova servono token e chat id", store.ErrBadRequest)
	}
	if req.SpaceID != "" {
		name, ok := s.spaceNames()[req.SpaceID]
		if !ok {
			return nil, store.ErrNotFound
		}
		if len(req.Topic) > 0 {
			th, err := parseTopic(req.Topic, name, tg.ChatID)
			if err != nil {
				return nil, err
			}
			tg.Topics = map[string]int64{}
			if th != 0 {
				tg.Topics[req.SpaceID] = th
			}
		}
	}
	tg.Enabled = false // la validazione di "attivo" qui non c'entra
	if err := tg.Validate(); err != nil {
		return nil, err
	}

	s.testMu.Lock()
	if time.Since(s.lastTest) < testEvery {
		s.testMu.Unlock()
		return nil, errTooMany
	}
	s.lastTest = time.Now()
	s.testMu.Unlock()

	if err := s.Telegram.Test(r.Context(), notify.FromSettings(tg), req.SpaceID); err != nil {
		return nil, i18n.Errorf("%w: %v", errUpstream, err)
	}
	return map[string]bool{"ok": true}, nil
}

// spaceNames: id → nome dei server esistenti.
func (s *Server) spaceNames() map[string]string {
	out := map[string]string{}
	for _, sp := range s.Store.ListSpaces() {
		out[sp.ID] = sp.Name
	}
	return out
}

// parseTopic legge il topic di un server dal JSON: numero, stringa col numero
// o link del topic copiato da Telegram; null, "" o 1 = topic Generale (0).
func parseTopic(raw json.RawMessage, name, chatID string) (int64, error) {
	var v string
	switch b := bytes.TrimSpace(raw); {
	case len(b) == 0 || string(b) == "null":
	case b[0] == '"':
		if err := json.Unmarshal(b, &v); err != nil {
			return 0, i18n.Errorf("%w: body JSON non valido: %v", store.ErrBadRequest, err)
		}
	default:
		v = string(b) // numero: ParseTopic accetta solo cifre
	}
	th, err := settings.ParseTopic(v, chatID)
	var ce *settings.TopicChatError
	switch {
	case errors.As(err, &ce):
		return 0, i18n.Errorf("%w: il link del topic di %s è di un'altra chat (%s), mentre il chat id configurato è %s: copia il link da questo gruppo o correggi il chat id",
			store.ErrBadRequest, name, ce.Chat, chatID)
	case err != nil:
		return 0, i18n.Errorf("%w: topic di %s non valido: incolla il link del topic (https://t.me/c/…/…) oppure il suo numero", store.ErrBadRequest, name)
	}
	return th, nil
}
