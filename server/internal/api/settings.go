package api

import (
	"bytes"
	"context"
	"encoding/json"
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
	Test(ctx context.Context, c notify.Config) error
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
	Enabled     bool            `json:"enabled"`
	TokenSet    bool            `json:"tokenSet"`
	TokenHint   string          `json:"tokenHint,omitempty"`
	ChatID      string          `json:"chatId"`
	Lang        string          `json:"lang"`
	Notify      settings.Notify `json:"notify"`
	State       string          `json:"state"` // disabled | active | error
	LastError   string          `json:"lastError,omitempty"`
	LastErrorAt *time.Time      `json:"lastErrorAt,omitempty"`
	LastSentAt  *time.Time      `json:"lastSentAt,omitempty"`
}

func (s *Server) telegramView(lang i18n.Lang) telegramView {
	tg, _ := s.Settings.Telegram()
	v := telegramView{
		Enabled: tg.Enabled, TokenSet: tg.Token != "", ChatID: tg.ChatID,
		Lang: tg.Lang, Notify: tg.Notify, State: "disabled",
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
	}](r)
	if err != nil {
		return nil, err
	}
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
		return nil
	})
	if err != nil {
		return nil, err
	}
	if after != before {
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

	if err := s.Telegram.Test(r.Context(), notify.FromSettings(tg)); err != nil {
		return nil, i18n.Errorf("%w: %v", errUpstream, err)
	}
	return map[string]bool{"ok": true}, nil
}
