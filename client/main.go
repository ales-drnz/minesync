// minesync: client TUI/CLI per minesync-hub.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"time"

	"minesync/client/internal/api"
	"minesync/client/internal/config"
	"minesync/client/internal/i18n"
	"minesync/client/internal/launch"
	"minesync/client/internal/syncx"
	"minesync/client/internal/tui"
)

func usage() string {
	return i18n.S(`minesync — sincronizza i tuoi mondi con l'hub della rete

Uso:
  minesync                       apre la TUI
  minesync login <url>           collega l'hub, es. http://<ip-hub>:8084 (l'identità arriva da ZeroTier)
  minesync spaces                elenca gli spazi dell'hub
  minesync link <space> <dir>    collega uno spazio a una cartella locale
  minesync create <nome> [-p profilo]   crea uno spazio (minecraft|generic)
  minesync status <space>        confronta locale ↔ hub
  minesync pull <space> [--discard-local]   scarica la generazione corrente
                                 (--discard-local: scarta le modifiche locali mai pushate, con backup)
  minesync push <space> [-m msg] [--nolock] [--force]   carica una nuova generazione
  minesync prefetch <space>      pre-scarica i blob nuovi (il pull poi è istantaneo)
  minesync verify <space>        controlla l'integrità dei region file locali

Lingua: MINESYNC_LANG=it|en (altrimenti quella scelta nella TUI, poi quella del sistema).
`)
}

func main() {
	initLang()
	// NB: i residui .old di un auto-aggiornamento li toglie la TUI dopo il
	// primo ping riuscito (la nuova versione funziona), non qui all'avvio.
	if len(os.Args) < 2 {
		// doppio click dal file manager: nessun terminale sotto, la TUI si
		// riapre da sola in una finestra sua (no-op se il terminale c'è già)
		launch.EnsureTerminal()
		if err := tui.Run(); err != nil {
			fail(err)
		}
		return
	}
	cmd, args := os.Args[1], os.Args[2:]
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
	defer cancel()

	var err error
	switch cmd {
	case "login":
		err = cmdLogin(ctx, args)
	case "spaces":
		err = cmdSpaces(ctx)
	case "link":
		err = cmdLink(ctx, args)
	case "create":
		err = cmdCreate(ctx, args)
	case "status":
		err = cmdStatus(ctx, args)
	case "pull":
		err = cmdPull(ctx, args)
	case "push":
		err = cmdPush(ctx, args)
	case "prefetch":
		err = cmdPrefetch(ctx, args)
	case "verify":
		err = cmdVerify(ctx, args)
	case "help", "-h", "--help":
		fmt.Print(usage())
	default:
		fmt.Print(usage())
		err = i18n.Errorf("comando sconosciuto: %s", cmd)
	}
	if err != nil {
		fail(err)
	}
}

// initLang sceglie la lingua: MINESYNC_LANG → config → sistema → inglese.
func initLang() {
	lang := ""
	if cfg, err := config.Load(); err == nil {
		lang = cfg.Lang
	}
	i18n.Set(i18n.Resolve(lang))
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, i18n.S("errore:"), err)
	logCrash(err)
	os.Exit(1)
}

// logCrash salva l'ultimo errore fatale in ~/.minesync/last-error.log:
// se la finestra si chiude subito, almeno l'errore resta leggibile.
func logCrash(err error) {
	if dir, derr := config.Dir(); derr == nil {
		os.WriteFile(filepath.Join(dir, "last-error.log"),
			[]byte(time.Now().Format(time.RFC3339)+"  "+err.Error()+"\n"), 0o644)
	}
}

func mustClient() (*config.Config, *api.Client) {
	cfg, err := config.Load()
	if err != nil {
		fail(err)
	}
	if !cfg.Ready() {
		fail(i18n.Errorf("nessun hub configurato: esegui prima `minesync login <url>` " +
			"(es. minesync login http://<ip-hub>:8084)"))
	}
	return cfg, api.New(cfg.Server)
}

func cmdLogin(ctx context.Context, args []string) error {
	addr := config.DefaultServer
	switch {
	case len(args) == 1:
		addr = args[0]
	case len(args) > 1:
		return i18n.Errorf("uso: minesync login <url>")
	}
	if addr == "" {
		return i18n.Errorf("indirizzo dell'hub mancante: uso minesync login <url> (es. http://<ip-hub>:8084)")
	}
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	url := strings.TrimRight(addr, "/")
	if !strings.HasPrefix(url, "http") {
		url = "http://" + url
	}
	c := api.New(url)
	who, err := c.Whoami(ctx)
	if err != nil {
		return i18n.Errorf("connessione fallita: %w", err)
	}
	cfg.Server, cfg.Name = url, who.Name
	if err := cfg.Save(); err != nil {
		return err
	}
	fmt.Println(i18n.Sf("Connesso come %s a %s", who.Name, url))
	return nil
}

func cmdSpaces(ctx context.Context) error {
	cfg, c := mustClient()
	spaces, err := c.Spaces(ctx)
	if err != nil {
		return err
	}
	if len(spaces) == 0 {
		fmt.Println(i18n.S("Nessuno spazio. Creane uno con `minesync create <nome>`."))
		return nil
	}
	for _, sp := range spaces {
		lock := i18n.S("libero")
		if sp.Lock != nil {
			lock = i18n.Sf("in uso da %s", sp.Lock.Owner)
			if sp.LockStale {
				lock += " (STALE)"
			}
		}
		local := i18n.S("non collegato")
		if sc, ok := cfg.Spaces[sp.ID]; ok {
			local = sc.LocalPath
		}
		fmt.Println(i18n.Sf("%-16s gen #%-4d %-24s profilo=%-10s locale: %s", sp.ID, sp.Head, lock, sp.Profile, local))
	}
	return nil
}

func cmdLink(_ context.Context, args []string) error {
	if len(args) != 2 {
		return i18n.Errorf("uso: minesync link <space> <dir>")
	}
	cfg, _ := mustClient()
	abs, err := filepath.Abs(args[1])
	if err != nil {
		return err
	}
	if err := os.MkdirAll(abs, 0o755); err != nil {
		return err
	}
	cfg.Spaces[args[0]] = config.SpaceConfig{LocalPath: abs}
	if err := cfg.Save(); err != nil {
		return err
	}
	fmt.Println(i18n.Sf("Spazio %s → %s", args[0], abs))
	return nil
}

func cmdCreate(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("create", flag.ExitOnError)
	profile := fs.String("p", "minecraft", i18n.S("profilo (minecraft|generic)"))
	fs.Parse(args)
	rest := fs.Args()
	if len(rest) == 0 {
		return i18n.Errorf("uso: minesync create <nome> [-p profilo]")
	}
	name := rest[0]
	if len(rest) > 1 {
		fs.Parse(rest[1:]) // flag messi dopo il nome
	}
	_, c := mustClient()
	sp, err := c.CreateSpace(ctx, name, *profile)
	if err != nil {
		return err
	}
	fmt.Println(i18n.Sf("Creato spazio %s (profilo %s). Ora: minesync link %s <dir>", sp.ID, sp.Profile, sp.ID))
	return nil
}

func engineFor(ctx context.Context, spaceID string, quiet bool) (*syncx.Engine, api.Space, error) {
	cfg, c := mustClient()
	sc, ok := cfg.Spaces[spaceID]
	if !ok {
		// collega automaticamente la cartella di default (~/MineSync/<spazio>)
		home, err := os.UserHomeDir()
		if err != nil {
			return nil, api.Space{}, err
		}
		def := filepath.Join(home, "MineSync", spaceID)
		if err := os.MkdirAll(def, 0o755); err != nil {
			return nil, api.Space{}, err
		}
		sc = config.SpaceConfig{LocalPath: def}
		cfg.Spaces[spaceID] = sc
		if err := cfg.Save(); err != nil {
			return nil, api.Space{}, err
		}
		fmt.Println(i18n.Sf("(cartella locale automatica: %s)", def))
	}
	sp, err := c.Space(ctx, spaceID)
	if err != nil {
		return nil, api.Space{}, err
	}
	cacheDir, err := config.CacheDir()
	if err != nil {
		return nil, api.Space{}, err
	}
	eng := &syncx.Engine{
		Client: c, SpaceID: spaceID, LocalPath: sc.LocalPath,
		CachePath: filepath.Join(cacheDir, spaceID+".json"),
		Matcher:   syncx.NewMatcher(sp.Ignore),
	}
	if !quiet {
		last := ""
		eng.Report = func(p syncx.Progress) {
			line := i18n.Sf("\r[%s] %d/%d file  %s / %s  %s/s        ",
				p.Phase, p.DoneFiles, p.TotalFiles,
				mb(p.DoneBytes), mb(p.TotalBytes), mb(int64(p.Speed)))
			if line != last {
				fmt.Print(line)
				last = line
			}
		}
	}
	return eng, sp, nil
}

func mb(n int64) string {
	switch {
	case n >= 1e9:
		return fmt.Sprintf("%.2fGB", float64(n)/1e9)
	case n >= 1e6:
		return fmt.Sprintf("%.1fMB", float64(n)/1e6)
	default:
		return fmt.Sprintf("%.0fkB", float64(n)/1e3)
	}
}

func cmdStatus(ctx context.Context, args []string) error {
	if len(args) != 1 {
		return i18n.Errorf("uso: minesync status <space>")
	}
	eng, sp, err := engineFor(ctx, args[0], true)
	if err != nil {
		return err
	}
	plan, err := eng.PlanPull(ctx)
	var dirty *syncx.DirtyLocalError
	if err != nil && !errors.As(err, &dirty) {
		return err
	}
	fmt.Println(i18n.Sf("Spazio %s — hub alla generazione #%d", sp.ID, sp.Head))
	if sp.Lock != nil {
		fmt.Println(i18n.Sf("Lock: %s (dal %s)", sp.Lock.Owner, sp.Lock.Since.Local().Format("15:04")))
	}
	if dirty != nil {
		fmt.Println(i18n.Sf("Modifiche locali mai pushate: %d file modificati o aggiunti, %d cancellati",
			len(dirty.Changed), len(dirty.Removed)))
		if dirty.Diverged() {
			fmt.Println(i18n.S("  l'hub nel frattempo è andato avanti: `minesync pull --discard-local` le scarta (con backup)"))
		} else {
			fmt.Println(i18n.S("  caricale con `minesync push` (sono un fast-forward)"))
		}
	}
	if len(plan.Download) == 0 && len(plan.Delete) == 0 {
		fmt.Println(i18n.S("Locale allineato ✔"))
		return nil
	}
	fmt.Println(i18n.Sf("Da scaricare: %d file (%s), da eliminare: %d", len(plan.Download), mb(plan.Bytes), len(plan.Delete)))
	for i, f := range plan.Download {
		if i == 15 {
			fmt.Println(i18n.Sf("  … e altri %d", len(plan.Download)-15))
			break
		}
		fmt.Println("  ↓", f)
	}
	return nil
}

func cmdPull(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("pull", flag.ExitOnError)
	discard := fs.Bool("discard-local", false, i18n.S("scarta le modifiche locali mai pushate (ne fa prima un backup)"))
	fs.Parse(args)
	rest := fs.Args()
	if len(rest) == 0 {
		return i18n.Errorf("uso: minesync pull <space> [--discard-local]")
	}
	space := rest[0]
	if len(rest) > 1 {
		fs.Parse(rest[1:]) // flag messi dopo lo spazio
	}
	eng, _, err := engineFor(ctx, space, false)
	if err != nil {
		return err
	}
	eng.DiscardLocal = *discard
	start := time.Now()
	plan, err := eng.Pull(ctx)
	fmt.Println()
	var dirty *syncx.DirtyLocalError
	if errors.As(err, &dirty) {
		if dirty.Diverged() {
			return i18n.Errorf("%w\nPer scartarle (con backup in %s): minesync pull %s --discard-local",
				err, syncx.BackupRoot(eng.LocalPath), space)
		}
		return i18n.Errorf("%w\nCaricale con: minesync push %s", err, space)
	}
	if err != nil {
		return err
	}
	fmt.Println(i18n.Sf("Pull completato: generazione #%d, %d file scaricati, %d eliminati (%s)",
		plan.Gen, len(plan.Download), len(plan.Delete), time.Since(start).Round(time.Second)))
	if plan.Backup != "" {
		fmt.Println(i18n.Sf("Modifiche locali scartate: copia di sicurezza in %s", plan.Backup))
	}
	return nil
}

func cmdPrefetch(ctx context.Context, args []string) error {
	if len(args) != 1 {
		return i18n.Errorf("uso: minesync prefetch <space>")
	}
	eng, _, err := engineFor(ctx, args[0], true)
	if err != nil {
		return err
	}
	last := ""
	n, err := eng.Prefetch(ctx, func(st syncx.PrefetchStatus) {
		line := fmt.Sprintf("\r[prefetch] %d/%d blob  %s / %s        ",
			st.Done, st.Total, mb(st.DoneBytes), mb(st.TotalBytes))
		if line != last {
			fmt.Print(line)
			last = line
		}
	})
	if last != "" {
		fmt.Println()
	}
	if err != nil {
		return err
	}
	if n == 0 {
		fmt.Println(i18n.S("Blob cache già allineata: il pull non scaricherà nulla."))
	} else {
		fmt.Println(i18n.Sf("Pre-scaricati %d blob: il prossimo pull sarà istantaneo.", n))
	}
	return nil
}

func cmdVerify(ctx context.Context, args []string) error {
	if len(args) != 1 {
		return i18n.Errorf("uso: minesync verify <space>")
	}
	eng, _, err := engineFor(ctx, args[0], true)
	if err != nil {
		return err
	}
	problems, checked, err := syncx.VerifyWorld(eng.LocalPath, eng.Matcher)
	if err != nil {
		return err
	}
	if len(problems) == 0 {
		fmt.Println(i18n.Sf("Integrità: %d region file controllati, nessun problema.", checked))
		return nil
	}
	fmt.Println(i18n.Sf("Integrità: %d region file controllati, %d danneggiati:", checked, len(problems)))
	for _, p := range problems {
		fmt.Printf("  %s — %s\n", p.Path, p.Reason)
	}
	fmt.Println(i18n.S("Ripristina la versione integra di questi file dalla web UI dell'hub."))
	return nil
}

func cmdPush(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("push", flag.ExitOnError)
	msg := fs.String("m", "", i18n.S("messaggio della generazione"))
	nolock := fs.Bool("nolock", false, i18n.S("pusha senza prendere il lock (solo admin, usa con criterio)"))
	force := fs.Bool("force", false, i18n.S("ignora le guardie: base non aggiornata e cancellazioni di massa"))
	fs.Parse(args)
	rest := fs.Args()
	if len(rest) == 0 {
		return i18n.Errorf("uso: minesync push <space> [-m msg] [--nolock] [--force]")
	}
	space := rest[0]
	if len(rest) > 1 {
		fs.Parse(rest[1:]) // flag messi dopo lo spazio
	}
	eng, _, err := engineFor(ctx, space, false)
	if err != nil {
		return err
	}
	eng.AllowStaleBase, eng.AllowMassDelete = *force, *force
	if !*nolock {
		// il push è legato alla sessione del lock: lo si prende per la
		// durata del push e lo si rilascia subito dopo
		lk, err := eng.Client.LockAcquire(ctx, space, map[string]string{"via": "cli push"})
		if err != nil {
			var ae *api.APIError
			if errors.As(err, &ae) && ae.Holder != nil {
				return i18n.Errorf("lo spazio è in uso da %s: il push deve aspettare che finisca", ae.Holder.Owner)
			}
			return i18n.Errorf("acquisizione del lock: %w", err)
		}
		eng.LockSession = lk.Session
		defer func() {
			rctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			if err := eng.Client.LockRelease(rctx, space, lk.Session, false); err != nil {
				fmt.Fprintln(os.Stderr, i18n.S("attenzione: rilascio del lock non riuscito:"), err)
			}
		}()
	}
	start := time.Now()
	res, err := eng.Push(ctx, *msg, *nolock)
	fmt.Println()
	if err != nil {
		return err
	}
	if res.NoChange {
		fmt.Println(i18n.S("Nessuna modifica: l'hub è già allineato al locale."))
		return nil
	}
	fmt.Println(i18n.Sf("Push completato: generazione #%d, %d blob caricati (%s) in %s",
		res.Gen.N, res.Uploaded, mb(res.Bytes), time.Since(start).Round(time.Second)))
	if len(res.Corrupt) > 0 {
		fmt.Println(i18n.Sf("Attenzione: %d region file danneggiati (%s%s). La generazione è marcata; ripristina la versione integra dalla web UI.",
			len(res.Corrupt), res.Corrupt[0], plural(len(res.Corrupt))))
	}
	return nil
}

func plural(n int) string {
	if n > 1 {
		return ", …"
	}
	return ""
}
