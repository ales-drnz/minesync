// Package api: client HTTP verso minesync-hub.
package api

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"minesync/client/internal/i18n"
	"minesync/client/internal/version"
)

// FileMeta / Manifest rispecchiano i tipi dell'hub.
// Un file grande viaggia a chunk (delta sync): Hash resta quello dell'INTERO
// file (per diff e verifica finale), ma i blob sull'hub sono i chunk.
type Chunk struct {
	Hash string `json:"h"`
	Size int64  `json:"s"`
}
type FileMeta struct {
	Hash   string  `json:"h"`
	Size   int64   `json:"s"`
	Exec   bool    `json:"x,omitempty"`
	Chunks []Chunk `json:"c,omitempty"`
}
type Manifest map[string]FileMeta

type Stats struct {
	Files   int   `json:"files"`
	Bytes   int64 `json:"bytes"`
	Added   int   `json:"added"`
	Changed int   `json:"changed"`
	Removed int   `json:"removed"`
}

type GenSummary struct {
	N       int       `json:"n"`
	Parent  int       `json:"parent"`
	Author  string    `json:"author"`
	Message string    `json:"message"`
	TS      time.Time `json:"ts"`
	Restore int       `json:"restore,omitempty"`
	Stats   Stats     `json:"stats"`
}

type LockInfo struct {
	Owner     string            `json:"owner"`
	Since     time.Time         `json:"since"`
	LastBeat  time.Time         `json:"lastBeat"`
	TTLSec    int               `json:"ttlSec"`
	Info      map[string]string `json:"info,omitempty"`
	Players   []string          `json:"players,omitempty"`
	Ready     bool              `json:"ready,omitempty"`
	Reachable *bool             `json:"reachable,omitempty"`
}

type Space struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	Profile   string    `json:"profile"`
	Ignore    []string  `json:"ignore"`
	CreatedAt time.Time `json:"createdAt"`
	Head      int       `json:"head"`
	Lock      *LockInfo `json:"lock,omitempty"`
	LockStale bool      `json:"lockStale,omitempty"`
}

type Event struct {
	TS    time.Time      `json:"ts"`
	Type  string         `json:"type"`
	Space string         `json:"space,omitempty"`
	Actor string         `json:"actor,omitempty"`
	Msg   string         `json:"msg"`
	Data  map[string]any `json:"data,omitempty"`
}

type Status struct {
	Name      string `json:"name"`
	Version   string `json:"version"`
	UptimeSec int    `json:"uptimeSec"`
	Spaces    int    `json:"spaces"`
	DNSZone   string `json:"dnsZone"` // zona del DNS interno dell'hub ("" se off)
}

type Whoami struct {
	Name  string `json:"name"`
	Admin bool   `json:"admin"`
}

// APIError è un errore strutturato dell'hub.
type APIError struct {
	Status int
	Msg    string
	Code   string    // codice macchina opzionale (es. "mass_delete")
	Holder *LockInfo // valorizzato sui 409 da lock
	Stale  bool
}

func (e *APIError) Error() string { return e.Msg }

// IsConflict riporta se err è un 409.
func IsConflict(err error) bool {
	var ae *APIError
	return errors.As(err, &ae) && ae.Status == 409
}

// IsLockLost riporta se err è un 409 dovuto al lock: tenuto da un altro
// (Holder valorizzato) o non più nostro ("lock non tuo", "push senza lock").
// Un 409 per base vecchia o cancellazione di massa NON è un lock perso.
func IsLockLost(err error) bool {
	var ae *APIError
	if !errors.As(err, &ae) || ae.Status != 409 || ae.Code == "mass_delete" {
		return false
	}
	// code "locked" dagli hub recenti; il testo resta come ripiego per hub più
	// vecchi (in entrambe le lingue i messaggi di lock contengono "lock")
	return ae.Code == "locked" || ae.Holder != nil || strings.Contains(strings.ToLower(ae.Msg), "lock")
}

// Timeout di rete. Il client HTTP non ha un timeout globale (i blob possono
// essere grandi e lenti), ma nessuna fase può restare appesa per sempre: una
// connessione mezza aperta bloccava l'autosave e con lui stop e kill, e il
// lock restava vivo all'infinito.
const (
	dialTimeout           = 10 * time.Second
	tlsHandshakeTimeout   = 10 * time.Second
	responseHeaderTimeout = 30 * time.Second
	// DefaultIdleTimeout: un trasferimento di blob in cui non si muove nemmeno
	// un byte per tutto questo tempo viene interrotto (e ritentato).
	DefaultIdleTimeout = 60 * time.Second
)

// ErrStalled: il trasferimento è rimasto fermo oltre IdleTimeout.
var ErrStalled = i18n.NewError("trasferimento fermo: nessun byte in movimento da troppo tempo")

// Client parla con l'hub. Nessuna credenziale: l'hub ci riconosce
// dall'IP della rete ZeroTier.
type Client struct {
	Base string
	HC   *http.Client
	// IdleTimeout: watchdog di progresso per upload e download dei blob
	// (0 = DefaultIdleTimeout).
	IdleTimeout time.Duration
}

func New(base string) *Client {
	tr := &http.Transport{
		Proxy:                 http.ProxyFromEnvironment,
		DialContext:           (&net.Dialer{Timeout: dialTimeout, KeepAlive: 30 * time.Second}).DialContext,
		TLSHandshakeTimeout:   tlsHandshakeTimeout,
		ResponseHeaderTimeout: responseHeaderTimeout,
		ExpectContinueTimeout: time.Second,
		IdleConnTimeout:       90 * time.Second,
		MaxIdleConnsPerHost:   16,
		ForceAttemptHTTP2:     true,
	}
	return &Client{
		Base: strings.TrimRight(base, "/"),
		// niente timeout globale: i blob possono essere grandi (c'è il watchdog)
		HC: &http.Client{Timeout: 0, Transport: tr},
	}
}

// req costruisce una richiesta verso l'API. Ogni richiesta porta
// X-MineSync: l'hub rifiuta le mutazioni senza (difesa CSRF / DNS rebinding).
// Accept-Language: l'hub risponde con i messaggi d'errore nella nostra lingua.
func (c *Client) req(ctx context.Context, method, path string, body io.Reader) (*http.Request, error) {
	r, err := http.NewRequestWithContext(ctx, method, c.Base+"/api/v1"+path, body)
	if err != nil {
		return nil, err
	}
	r.Header.Set("X-MineSync", version.Client)
	r.Header.Set("Accept-Language", string(i18n.Current()))
	return r, nil
}

func (c *Client) idleTimeout() time.Duration {
	if c.IdleTimeout > 0 {
		return c.IdleTimeout
	}
	return DefaultIdleTimeout
}

// watchdog annulla un trasferimento quando per idle non si muove nessun byte.
type watchdog struct {
	last   atomic.Int64 // UnixNano dell'ultimo progresso
	cancel context.CancelCauseFunc
	stop   chan struct{}
	once   sync.Once
}

// startWatchdog deriva da ctx un contesto che viene annullato (causa
// ErrStalled) se touch non viene chiamato per più di idle.
func startWatchdog(ctx context.Context, idle time.Duration) (context.Context, *watchdog) {
	wctx, cancel := context.WithCancelCause(ctx)
	w := &watchdog{cancel: cancel, stop: make(chan struct{})}
	w.touch()
	tick := idle / 4
	if tick < 5*time.Millisecond {
		tick = 5 * time.Millisecond
	}
	go func() {
		t := time.NewTicker(tick)
		defer t.Stop()
		for {
			select {
			case <-w.stop:
				return
			case <-wctx.Done():
				return
			case now := <-t.C:
				if now.Sub(time.Unix(0, w.last.Load())) > idle {
					cancel(ErrStalled)
					return
				}
			}
		}
	}()
	return wctx, w
}

func (w *watchdog) touch() { w.last.Store(time.Now().UnixNano()) }

// done ferma il watchdog e libera il contesto derivato.
func (w *watchdog) done() {
	w.once.Do(func() {
		close(w.stop)
		w.cancel(context.Canceled)
	})
}

// explain sostituisce l'errore generico di contesto annullato con ErrStalled
// quando è stato il watchdog a interrompere.
func explain(ctx context.Context, err error) error {
	if err != nil && errors.Is(context.Cause(ctx), ErrStalled) && !errors.Is(err, ErrStalled) {
		return fmt.Errorf("%w (%v)", ErrStalled, err)
	}
	return err
}

// netError dà un messaggio localizzato agli errori di trasporto (hub spento,
// rete assente, timeout), tenendo in coda il dettaglio tecnico di Go.
// L'errore originale resta raggiungibile con errors.Is/As.
func netError(err error) error {
	switch {
	case err == nil, errors.Is(err, context.Canceled), errors.Is(err, ErrStalled):
		return err
	case errors.Is(err, context.DeadlineExceeded):
		return i18n.Errorf("l'hub non risponde (timeout): %w", err)
	}
	return i18n.Errorf("hub non raggiungibile: %w", err)
}

// touchReader segnala al watchdog ogni byte che passa.
type touchReader struct {
	r  io.Reader
	wd *watchdog
}

func (p *touchReader) Read(b []byte) (int, error) {
	n, err := p.r.Read(b)
	if n > 0 {
		p.wd.touch()
	}
	return n, err
}

// doJSON esegue una chiamata JSON→JSON con timeout breve.
func (c *Client) doJSON(ctx context.Context, method, path string, in, out any) error {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	var body io.Reader
	if in != nil {
		b, err := json.Marshal(in)
		if err != nil {
			return err
		}
		body = bytes.NewReader(b)
	}
	req, err := c.req(ctx, method, path, body)
	if err != nil {
		return err
	}
	if in != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	res, err := c.HC.Do(req)
	if err != nil {
		return netError(err)
	}
	defer res.Body.Close()
	return decodeResponse(res, out)
}

func decodeResponse(res *http.Response, out any) error {
	if res.StatusCode >= 400 {
		var e struct {
			Error  string    `json:"error"`
			Code   string    `json:"code"`
			Holder *LockInfo `json:"holder"`
			Stale  bool      `json:"stale"`
		}
		b, _ := io.ReadAll(io.LimitReader(res.Body, 1<<20))
		json.Unmarshal(b, &e)
		msg := e.Error
		if msg == "" {
			msg = fmt.Sprintf("HTTP %d", res.StatusCode)
		}
		return &APIError{Status: res.StatusCode, Msg: msg, Code: e.Code, Holder: e.Holder, Stale: e.Stale}
	}
	if out == nil {
		io.Copy(io.Discard, res.Body)
		return nil
	}
	return json.NewDecoder(res.Body).Decode(out)
}

// --- endpoints ---

func (c *Client) Status(ctx context.Context) (Status, error) {
	var s Status
	return s, c.doJSON(ctx, "GET", "/status", nil, &s)
}

func (c *Client) Whoami(ctx context.Context) (Whoami, error) {
	var w Whoami
	return w, c.doJSON(ctx, "GET", "/whoami", nil, &w)
}

func (c *Client) Spaces(ctx context.Context) ([]Space, error) {
	var out []Space
	return out, c.doJSON(ctx, "GET", "/spaces", nil, &out)
}

func (c *Client) Space(ctx context.Context, id string) (Space, error) {
	var out Space
	return out, c.doJSON(ctx, "GET", "/spaces/"+id, nil, &out)
}

func (c *Client) CreateSpace(ctx context.Context, name, profile string) (Space, error) {
	var out Space
	return out, c.doJSON(ctx, "POST", "/spaces", map[string]string{"name": name, "profile": profile}, &out)
}

type ManifestResp struct {
	Gen   int      `json:"gen"`
	Head  int      `json:"head"`
	Files Manifest `json:"files"`
}

func (c *Client) Manifest(ctx context.Context, id string, gen int) (ManifestResp, error) {
	path := "/spaces/" + id + "/manifest"
	if gen > 0 {
		path += fmt.Sprintf("?gen=%d", gen)
	}
	var out ManifestResp
	return out, c.doJSON(ctx, "GET", path, nil, &out)
}

func (c *Client) Generations(ctx context.Context, id string, limit int) ([]GenSummary, error) {
	var out []GenSummary
	return out, c.doJSON(ctx, "GET", fmt.Sprintf("/spaces/%s/generations?limit=%d", id, limit), nil, &out)
}

func (c *Client) Events(ctx context.Context, limit int) ([]Event, error) {
	var out []Event
	return out, c.doJSON(ctx, "GET", fmt.Sprintf("/events?limit=%d", limit), nil, &out)
}

// DownloadBlob apre lo stream di un blob, già decompresso (chiamante chiude).
// L'hub ≥1.7 tiene i blob in gzip e li manda così come sono: dichiariamo
// Accept-Encoding noi (disattivando l'automatismo del Transport) e
// decomprimiamo qui, così l'hash si verifica sempre sui byte originali.
//
// Il trasferimento è sorvegliato dal watchdog di progresso: se per
// IdleTimeout non arriva nemmeno un byte, la lettura fallisce con ErrStalled.
func (c *Client) DownloadBlob(ctx context.Context, id, hash string) (io.ReadCloser, int64, error) {
	wctx, wd := startWatchdog(ctx, c.idleTimeout())
	req, err := c.req(wctx, "GET", "/spaces/"+id+"/blobs/"+hash, nil)
	if err != nil {
		wd.done()
		return nil, 0, err
	}
	req.Header.Set("Accept-Encoding", "gzip")
	res, err := c.HC.Do(req)
	if err != nil {
		err = netError(explain(wctx, err))
		wd.done()
		return nil, 0, err
	}
	if res.StatusCode >= 400 {
		defer wd.done()
		defer res.Body.Close()
		return nil, 0, decodeResponse(res, nil)
	}
	raw := &blobBody{r: &touchReader{r: res.Body, wd: wd}, body: res.Body, wd: wd, ctx: wctx}
	if strings.Contains(res.Header.Get("Content-Encoding"), "gzip") {
		zr, err := gzip.NewReader(raw)
		if err != nil {
			raw.Close()
			return nil, 0, err
		}
		return &gzipBody{zr: zr, raw: raw}, -1, nil
	}
	return raw, res.ContentLength, nil
}

// blobBody è il corpo di un download sorvegliato dal watchdog.
type blobBody struct {
	r    io.Reader
	body io.Closer
	wd   *watchdog
	ctx  context.Context
}

func (b *blobBody) Read(p []byte) (int, error) {
	n, err := b.r.Read(p)
	if err != nil && err != io.EOF {
		err = explain(b.ctx, err)
	}
	return n, err
}

func (b *blobBody) Close() error {
	err := b.body.Close()
	b.wd.done()
	return err
}

type gzipBody struct {
	zr  *gzip.Reader
	raw *blobBody
}

func (g *gzipBody) Read(p []byte) (int, error) {
	n, err := g.zr.Read(p)
	if err != nil && err != io.EOF {
		err = explain(g.raw.ctx, err)
	}
	return n, err
}

func (g *gzipBody) Close() error {
	g.zr.Close()
	return g.raw.Close()
}

type PushBeginResp struct {
	PushID  string   `json:"pushId"`
	Missing []string `json:"missing"`
}

// PushBegin apre una sessione di push. session è l'id della sessione di lock
// del chiamante: l'hub lega il push a quel lock e al commit ricontrolla che
// sia ancora valido. nolock=true (solo admin) pusha senza lock.
func (c *Client) PushBegin(ctx context.Context, id string, parent int, message string, files Manifest, corrupt []string, session string, nolock bool) (PushBeginResp, error) {
	path := "/spaces/" + id + "/push/begin"
	if nolock {
		path += "?nolock=1"
	}
	var out PushBeginResp
	err := c.doJSON(ctx, "POST", path, map[string]any{
		"parent": parent, "message": message, "files": files, "corrupt": corrupt,
		"session": session,
	}, &out)
	return out, err
}

// UploadBlob carica un blob. Con gzipped=true r fornisce byte già compressi
// (size ignota → chunked) e l'hub li salva così, verificando l'hash del
// contenuto originale; altrimenti r fornisce esattamente size byte piatti.
//
// Anche qui c'è il watchdog di progresso: se il trasporto non legge un byte
// per IdleTimeout, l'upload fallisce con ErrStalled.
func (c *Client) UploadBlob(ctx context.Context, id, pushID, hash string, r io.Reader, size int64, gzipped bool) error {
	wctx, wd := startWatchdog(ctx, c.idleTimeout())
	defer wd.done()
	req, err := c.req(wctx, "PUT", "/spaces/"+id+"/push/"+pushID+"/blobs/"+hash, &touchReader{r: r, wd: wd})
	if err != nil {
		return err
	}
	if gzipped {
		req.Header.Set("Content-Encoding", "gzip")
	} else {
		req.ContentLength = size
	}
	res, err := c.HC.Do(req)
	if err != nil {
		return netError(explain(wctx, err))
	}
	defer res.Body.Close()
	return explain(wctx, decodeResponse(res, nil))
}

func (c *Client) PushCommit(ctx context.Context, id, pushID string) (GenSummary, error) {
	var out GenSummary
	return out, c.doJSON(ctx, "POST", "/spaces/"+id+"/push/"+pushID+"/commit", struct{}{}, &out)
}

func (c *Client) Restore(ctx context.Context, id string, gen int) (GenSummary, error) {
	var out GenSummary
	return out, c.doJSON(ctx, "POST", "/spaces/"+id+"/restore", map[string]int{"gen": gen}, &out)
}

type LockAcquireResp struct {
	Session  string    `json:"session"`
	TTLSec   int       `json:"ttlSec"`
	TookOver *LockInfo `json:"tookOver"`
}

func (c *Client) LockAcquire(ctx context.Context, id string, info map[string]string) (LockAcquireResp, error) {
	var out LockAcquireResp
	err := c.doJSON(ctx, "POST", "/spaces/"+id+"/lock", map[string]any{"info": info}, &out)
	return out, err
}

// HeartbeatResp è la risposta a un heartbeat.
type HeartbeatResp struct {
	Reachable *bool `json:"reachable"` // esito test porta dall'hub (nil = non ancora)
}

// LockHeartbeat rinnova il lock, pubblica chi è in gioco e se il server è
// avviato (abilita il test della porta lato hub). Restituisce l'ultimo esito.
func (c *Client) LockHeartbeat(ctx context.Context, id, session string, players []string, ready bool) (HeartbeatResp, error) {
	if players == nil {
		players = []string{}
	}
	var out HeartbeatResp
	err := c.doJSON(ctx, "POST", "/spaces/"+id+"/lock/heartbeat",
		map[string]any{"session": session, "players": players, "ready": ready}, &out)
	return out, err
}

func (c *Client) LockRelease(ctx context.Context, id, session string, force bool) error {
	path := "/spaces/" + id + "/lock?session=" + session
	if force {
		path += "&force=1"
	}
	return c.doJSON(ctx, "DELETE", path, nil, nil)
}

// StreamEvents apre lo stream SSE e invia gli eventi sul canale finché ctx vive.
func (c *Client) StreamEvents(ctx context.Context, ch chan<- Event) error {
	req, err := c.req(ctx, "GET", "/events?stream=1", nil)
	if err != nil {
		return err
	}
	res, err := c.HC.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode >= 400 {
		return decodeResponse(res, nil)
	}
	sc := bufio.NewScanner(res.Body)
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	for sc.Scan() {
		line := sc.Text()
		if !strings.HasPrefix(line, "data: ") {
			continue
		}
		var e Event
		if json.Unmarshal([]byte(strings.TrimPrefix(line, "data: ")), &e) == nil {
			select {
			case ch <- e:
			case <-ctx.Done():
				return ctx.Err()
			}
		}
	}
	return sc.Err()
}
