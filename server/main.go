// minesync-hub: server di sincronizzazione per la rete ZeroTier.
package main

import (
	"context"
	"errors"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"minesync/server/internal/api"
	"minesync/server/internal/events"
	"minesync/server/internal/i18n"
	"minesync/server/internal/mcdns"
	"minesync/server/internal/notify"
	"minesync/server/internal/store"
	"minesync/server/internal/web"
	"minesync/server/internal/ztauth"
)

// shutdownTimeout: quanto si aspetta che le richieste in corso (push, upload)
// finiscano dopo SIGTERM. docker stop concede 10s di default: allungalo con
// stop_grace_period se servono upload lunghi.
const shutdownTimeout = 20 * time.Second

func main() {
	dataDir := envOr("MINESYNC_DATA", "/data")
	addr := envOr("MINESYNC_ADDR", ":8084")

	if err := os.MkdirAll(dataDir, 0o775); err != nil {
		log.Fatal(i18n.Lf("impossibile creare %s: %v", dataDir, err))
	}
	st, err := store.Open(dataDir)
	if err != nil {
		log.Fatalf("store: %v", err)
	}
	bus := events.NewBus(filepath.Join(dataDir, "events.jsonl"))

	// binari client scaricabili: prima la cartella dell'immagine, poi /data/dist
	dlDir := envOr("MINESYNC_DL", "/opt/dl")
	if _, err := os.Stat(dlDir); err != nil {
		dlDir = filepath.Join(dataDir, "dist")
	}

	// L'autenticazione È la rete ZeroTier: chi arriva da un
	// IP membro è autenticato col suo nome ztnet. Gli admin si designano in
	// MINESYNC_ADMINS (nome membro o node-ID).
	devUser := os.Getenv("MINESYNC_DEV_USER")
	var zt api.MemberLookup
	if r := ztauth.New(
		os.Getenv("ZTNET_URL"), os.Getenv("ZTNET_API_TOKEN"),
		os.Getenv("ZTNET_NETWORK_ID"), strings.Split(os.Getenv("MINESYNC_ADMINS"), ",")); r != nil {
		zt = r
	}
	if devUser != "" {
		log.Print(i18n.L("!!! ATTENZIONE: MODALITÀ SVILUPPO (MINESYNC_DEV_USER) — le richieste da loopback " +
			"(127.0.0.1/::1) sono autenticate come admin. Non usarla mai in produzione !!!"))
		log.Print(i18n.Lf("!!! identità di sviluppo: «%s» (solo da loopback)", devUser))
	}
	switch {
	case zt != nil:
		admins := os.Getenv("MINESYNC_ADMINS")
		if admins == "" {
			admins = i18n.L("nessuno")
		}
		log.Print(i18n.Lf("auth ZeroTier attiva (ztnet: %s, admin: %s)", os.Getenv("ZTNET_URL"), admins))
	case devUser == "":
		log.Fatal(i18n.L("configura ZTNET_URL, ZTNET_API_TOKEN e ZTNET_NETWORK_ID: " +
			"l'autenticazione avviene tramite la rete ZeroTier (oppure MINESYNC_DEV_USER per sviluppo locale)"))
	}

	// Retention dopo ogni push: si conservano le ultime MINESYNC_KEEP versioni
	// (default 30), più tutte quelle delle ultime 24 ore e una al giorno per
	// gli ultimi 7 giorni.
	keep := 30
	if v := os.Getenv("MINESYNC_KEEP"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			keep = n
		}
	}
	st.KeepLast = keep
	log.Print(i18n.Lf("retention: si conservano le ultime %d versioni per server (più quelle delle ultime 24h e una al giorno per 7 giorni)", keep))

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()
	var bg sync.WaitGroup

	// DNS "risoluzione tardiva": zerotier.<spazio>.<zona> → IP di chi hosta ADESSO.
	// Gli amici salvano un solo indirizzo in Minecraft; l'hub dice solo "dove",
	// il traffico di gioco resta diretto P2P (niente proxy). Vedi deploy per la
	// porta 53 e la config DNS della rete ZeroTier.
	dnsAddr := envOr("MINESYNC_DNS_ADDR", ":53")
	dnsZone := strings.ToLower(strings.Trim(envOr("MINESYNC_DNS_ZONE", "internal"), "."))
	dnsOn := dnsZone != "" && !strings.EqualFold(dnsAddr, "off") && dnsAddr != ""
	if dnsOn {
		d := mcdns.New(st, dnsZone)
		bg.Add(1)
		go func() {
			defer bg.Done()
			log.Print(i18n.Lf("DNS interno su %s: zerotier.<spazio>.%s → chi hosta adesso", dnsAddr, dnsZone))
			if err := d.ListenAndServeContext(ctx, dnsAddr); err != nil {
				log.Print(i18n.Lf("DNS interno NON attivo su %s: %v — l'hub continua; serve la porta 53 (vedi deploy)", dnsAddr, err))
			}
		}()
	} else {
		log.Print(i18n.Lf("DNS interno disattivato"))
		dnsZone = ""
	}

	// Bot Telegram opzionale: annuncia nel gruppo chi apre e chiude un server.
	if tg := notify.New(os.Getenv("MINESYNC_TELEGRAM_TOKEN"), os.Getenv("MINESYNC_TELEGRAM_CHAT"),
		dnsZone, st, bus); tg != nil {
		bg.Add(1)
		go func() {
			defer bg.Done()
			tg.Run(ctx)
		}()
		log.Print(i18n.Lf("bot Telegram attivo (chat %s)", os.Getenv("MINESYNC_TELEGRAM_CHAT")))
	} else {
		log.Print(i18n.Lf("bot Telegram non configurato (MINESYNC_TELEGRAM_TOKEN/CHAT)"))
	}

	srv := &api.Server{
		Store: st, ZT: zt, DevUser: devUser, Bus: bus, Web: web.Handler(),
		Started: time.Now(), DataDir: dataDir, DLDir: dlDir, DNSZone: dnsZone,
	}
	httpSrv := &http.Server{
		Addr:              addr,
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		// il contesto delle richieste si chiude allo spegnimento: gli stream
		// SSE terminano subito invece di bloccare Shutdown fino al timeout
		BaseContext: func(_ net.Listener) context.Context { return ctx },
	}
	if h := os.Getenv("MINESYNC_HOSTS"); h != "" {
		log.Print(i18n.Lf("host ammessi oltre a IP/localhost/zona DNS: %s", h))
	}
	log.Print(i18n.Lf("minesync-hub %s in ascolto su %s (dati: %s)", api.Version, addr, dataDir))

	errc := make(chan error, 1)
	go func() { errc <- httpSrv.ListenAndServe() }()
	select {
	case err := <-errc:
		log.Fatal(err)
	case <-ctx.Done():
	}

	// spegnimento ordinato: niente nuove connessioni, si aspettano le
	// richieste in corso, poi DNS e bot, poi il flush dello store
	log.Print(i18n.Lf("arresto in corso (attendo fino a %s le richieste in corso)…", shutdownTimeout))
	sctx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancel()
	if err := httpSrv.Shutdown(sctx); err != nil {
		log.Print(i18n.Lf("arresto HTTP incompleto: %v", err))
	}
	if err := <-errc; err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Printf("HTTP: %v", err)
	}
	done := make(chan struct{})
	go func() { bg.Wait(); close(done) }()
	select {
	case <-done:
	case <-sctx.Done():
		log.Print(i18n.Lf("DNS/bot non terminati in tempo"))
	}
	st.Flush()
	log.Print(i18n.Lf("minesync-hub arrestato"))
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
