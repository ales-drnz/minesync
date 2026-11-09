package i18n

// catalogEN: traduzioni inglesi, indicizzate dal testo italiano (l'id).
// Regole: stessi verbi di formato nello stesso ordine (lo verifica un test),
// e le etichette a larghezza fissa (es. "cartella  ") restano della stessa
// larghezza, così le colonne dei pannelli non si spostano.
var catalogEN = map[string]string{

	// --- CLI ---
	"minesync — sincronizza i tuoi mondi con l'hub della rete\n\nUso:\n  minesync                       apre la TUI\n  minesync login <url>           collega l'hub, es. http://<ip-hub>:8084 (l'identità arriva da ZeroTier)\n  minesync spaces                elenca gli spazi dell'hub\n  minesync link <space> <dir>    collega uno spazio a una cartella locale\n  minesync create <nome> [-p profilo]   crea uno spazio (minecraft|generic)\n  minesync status <space>        confronta locale ↔ hub\n  minesync pull <space> [--discard-local]   scarica la generazione corrente\n                                 (--discard-local: scarta le modifiche locali mai pushate, con backup)\n  minesync push <space> [-m msg] [--nolock] [--force]   carica una nuova generazione\n  minesync prefetch <space>      pre-scarica i blob nuovi (il pull poi è istantaneo)\n  minesync verify <space>        controlla l'integrità dei region file locali\n\nLingua: MINESYNC_LANG=it|en (altrimenti quella scelta nella TUI, poi quella del sistema).\n": "minesync — sync your worlds with the network hub\n\nUsage:\n  minesync                       open the TUI\n  minesync login <url>           connect to the hub, e.g. http://<hub-ip>:8084 (identity comes from ZeroTier)\n  minesync spaces                list the hub's spaces\n  minesync link <space> <dir>    link a space to a local folder\n  minesync create <name> [-p profile]   create a space (minecraft|generic)\n  minesync status <space>        compare local ↔ hub\n  minesync pull <space> [--discard-local]   download the current generation\n                                 (--discard-local: discard never-pushed local changes, with a backup)\n  minesync push <space> [-m msg] [--nolock] [--force]   upload a new generation\n  minesync prefetch <space>      pre-download new blobs (the next pull is then instant)\n  minesync verify <space>        check the integrity of local region files\n\nLanguage: MINESYNC_LANG=it|en (otherwise the one chosen in the TUI, then the system's).\n",

	"comando sconosciuto: %s": "unknown command: %s",

	"errore:": "error:",

	"nessun hub configurato: esegui prima `minesync login <url>` (es. minesync login http://<ip-hub>:8084)": "no hub configured: run `minesync login <url>` first (e.g. minesync login http://<hub-ip>:8084)",

	"uso: minesync login <url>": "usage: minesync login <url>",

	"indirizzo dell'hub mancante: uso minesync login <url> (es. http://<ip-hub>:8084)": "missing hub address: usage minesync login <url> (e.g. http://<hub-ip>:8084)",

	"connessione fallita: %w": "connection failed: %w",

	"Connesso come %s a %s": "Connected as %s to %s",

	"Nessuno spazio. Creane uno con `minesync create <nome>`.": "No spaces. Create one with `minesync create <name>`.",

	"libero": "free",

	"in uso da %s": "in use by %s",

	"non collegato": "not linked",

	"%-16s gen #%-4d %-24s profilo=%-10s locale: %s": "%-16s gen #%-4d %-24s profile=%-10s local: %s",

	"uso: minesync link <space> <dir>": "usage: minesync link <space> <dir>",

	"Spazio %s → %s": "Space %s → %s",

	"profilo (minecraft|generic)": "profile (minecraft|generic)",

	"uso: minesync create <nome> [-p profilo]": "usage: minesync create <name> [-p profile]",

	"Creato spazio %s (profilo %s). Ora: minesync link %s <dir>": "Created space %s (profile %s). Next: minesync link %s <dir>",

	"(cartella locale automatica: %s)": "(automatic local folder: %s)",

	"uso: minesync status <space>": "usage: minesync status <space>",

	"Spazio %s — hub alla generazione #%d": "Space %s — hub at generation #%d",

	"Lock: %s (dal %s)": "Lock: %s (since %s)",

	"Modifiche locali mai pushate: %d file modificati o aggiunti, %d cancellati": "Local changes never pushed: %d files changed or added, %d deleted",

	"  l'hub nel frattempo è andato avanti: `minesync pull --discard-local` le scarta (con backup)": "  the hub has moved on in the meantime: `minesync pull --discard-local` discards them (with a backup)",

	"  caricale con `minesync push` (sono un fast-forward)": "  upload them with `minesync push` (they are a fast-forward)",

	"Locale allineato ✔": "Local copy up to date ✔",

	"Da scaricare: %d file (%s), da eliminare: %d": "To download: %d files (%s), to delete: %d",

	"  … e altri %d": "  … and %d more",

	"scarta le modifiche locali mai pushate (ne fa prima un backup)": "discard never-pushed local changes (backing them up first)",

	"uso: minesync pull <space> [--discard-local]": "usage: minesync pull <space> [--discard-local]",

	"%w\nPer scartarle (con backup in %s): minesync pull %s --discard-local": "%w\nTo discard them (backed up in %s): minesync pull %s --discard-local",

	"%w\nCaricale con: minesync push %s": "%w\nUpload them with: minesync push %s",

	"Pull completato: generazione #%d, %d file scaricati, %d eliminati (%s)": "Pull complete: generation #%d, %d files downloaded, %d deleted (%s)",

	"Modifiche locali scartate: copia di sicurezza in %s": "Local changes discarded: safety copy in %s",

	"uso: minesync prefetch <space>": "usage: minesync prefetch <space>",

	"Blob cache già allineata: il pull non scaricherà nulla.": "Blob cache already up to date: the pull won't download anything.",

	"Pre-scaricati %d blob: il prossimo pull sarà istantaneo.": "Pre-downloaded %d blobs: the next pull will be instant.",

	"uso: minesync verify <space>": "usage: minesync verify <space>",

	"Integrità: %d region file controllati, nessun problema.": "Integrity: %d region files checked, no problems.",

	"Integrità: %d region file controllati, %d danneggiati:": "Integrity: %d region files checked, %d damaged:",

	"Ripristina la versione integra di questi file dalla web UI dell'hub.": "Restore an intact version of these files from the hub's web UI.",

	"messaggio della generazione": "generation message",

	"pusha senza prendere il lock (solo admin, usa con criterio)": "push without taking the lock (admin only, use with care)",

	"ignora le guardie: base non aggiornata e cancellazioni di massa": "skip the safety checks: stale base and mass deletions",

	"uso: minesync push <space> [-m msg] [--nolock] [--force]": "usage: minesync push <space> [-m msg] [--nolock] [--force]",

	"lo spazio è in uso da %s: il push deve aspettare che finisca": "the space is in use by %s: the push has to wait until they finish",

	"acquisizione del lock: %w": "acquiring the lock: %w",

	"attenzione: rilascio del lock non riuscito:": "warning: failed to release the lock:",

	"Nessuna modifica: l'hub è già allineato al locale.": "No changes: the hub already matches the local copy.",

	"Push completato: generazione #%d, %d blob caricati (%s) in %s": "Push complete: generation #%d, %d blobs uploaded (%s) in %s",

	"Attenzione: %d region file danneggiati (%s%s). La generazione è marcata; ripristina la versione integra dalla web UI.": "Warning: %d damaged region files (%s%s). The generation is flagged; restore an intact version from the web UI.",

	// --- rete / API ---
	"l'hub non risponde (timeout): %w": "the hub is not responding (timeout): %w",

	"hub non raggiungibile: %w": "hub unreachable: %w",

	"trasferimento fermo: nessun byte in movimento da troppo tempo": "transfer stalled: no bytes moving for too long",

	// --- auto-aggiornamento ---
	"nessun aggiornamento: la versione dell'hub non è più nuova": "no update: the hub's version is not newer",

	"chiave pubblica di aggiornamento non valida in questa build": "invalid update public key in this build",

	"firma degli aggiornamenti mancante: %w": "update signature missing: %w",

	"firma degli aggiornamenti malformata": "malformed update signature",

	"firma degli aggiornamenti NON valida: aggiornamento rifiutato": "update signature NOT valid: update rejected",

	"riga SHA256SUMS malformata per %s": "malformed SHA256SUMS line for %s",

	"%s non presente in SHA256SUMS": "%s not listed in SHA256SUMS",

	"%s non disponibile sull'hub (HTTP %d)": "%s not available on the hub (HTTP %d)",

	"%s troppo grande": "%s too large",

	"binario scaricato troppo grande": "downloaded binary too large",

	"binario scaricato troppo piccolo (%d byte): download troncato?": "downloaded binary too small (%d bytes): truncated download?",

	"SHA-256 del binario non combacia con SHA256SUMS: aggiornamento rifiutato": "binary SHA-256 does not match SHA256SUMS: update rejected",

	"binario scaricato illeggibile": "downloaded binary unreadable",

	"il file scaricato non è un eseguibile %s valido": "the downloaded file is not a valid %s executable",

	// --- sync ---
	"manifest dell'hub non valido": "invalid hub manifest",

	"%w: percorso %q non ammesso": "%w: path %q not allowed",

	"%w: hash non valido per %q": "%w: invalid hash for %q",

	"%w: dimensione negativa per %q": "%w: negative size for %q",

	"%w: chunk non valido in %q": "%w: invalid chunk in %q",

	"%w: i chunk di %q non coprono il file": "%w: the chunks of %q don't cover the file",

	"prefetch del blob %s: %w": "prefetching blob %s: %w",

	"hash non combacia (%s ≠ %s)": "hash mismatch (%s ≠ %s)",

	"hash non combacia": "hash mismatch",

	"il nome %q non è UTF-8 valido: rinominalo, altrimenti verrebbe caricato storpiato e poi cancellato": "the name %q is not valid UTF-8: rename it, otherwise it would be uploaded mangled and then deleted",

	"il nome %q contiene caratteri non ammessi (':' o '\\'): rinominalo, su Windows non potrebbe esistere": "the name %q contains forbidden characters (':' or '\\'): rename it, it couldn't exist on Windows",

	"%s è un collegamento a una cartella: MineSync non può sincronizzarne il contenuto, sostituiscilo con la cartella vera": "%s is a link to a folder: MineSync can't sync its contents, replace it with the real folder",

	"base non aggiornata": "stale base",

	"un pull precedente si è interrotto a metà: la cartella locale è incompleta. Ripeti il pull prima di pushare, altrimenti il push cancellerebbe sull'hub i file non ancora scaricati": "a previous pull was interrupted halfway: the local folder is incomplete. Pull again before pushing, otherwise the push would delete from the hub the files not downloaded yet",

	"non so da quale generazione parta la cartella locale (cache assente o di un'altra cartella) e l'hub ha già dei file (generazione #%d). Fai prima un pull, altrimenti il push potrebbe cancellare il lavoro degli altri": "I don't know which generation the local folder starts from (cache missing or from another folder) and the hub already has files (generation #%d). Pull first, otherwise the push could delete other people's work",

	"il tuo mondo parte dalla generazione #%d ma l'hub è alla #%d: qualcun altro ha giocato nel frattempo. Fai prima un pull, altrimenti il push cancellerebbe quello che ha fatto lui": "your world starts from generation #%d but the hub is at #%d: someone else has played in the meantime. Pull first, otherwise the push would erase what they did",

	"spazio vuoto sull'hub": "empty space on the hub",

	"l'hub non ha ancora nessun file per questo spazio (generazione #%d): il pull cancellerebbe i %d file in %s. Carica prima la cartella con un push.": "the hub has no files for this space yet (generation #%d): the pull would delete the %d files in %s. Upload the folder with a push first.",

	"salvataggio dello stato locale: %w": "saving the local state: %w",

	"permessi di %s: %w": "permissions of %s: %w",

	"scansione dopo il pull: %w": "scan after the pull: %w",

	"dimensione inattesa (%d ≠ %d)": "unexpected size (%d ≠ %d)",

	"push distruttivo": "destructive push",

	"questo push toglierebbe %d dei %d file presenti sull'hub: la cartella %s è vuota o incompleta (disco non montato? spazio collegato alla cartella sbagliata?). Se è davvero quello che vuoi, forza la conferma": "this push would remove %d of the %d files on the hub: the folder %s is empty or incomplete (disk not mounted? space linked to the wrong folder?). If that's really what you want, force the confirmation",

	"push riuscito (generazione #%d) ma salvataggio dello stato locale fallito: %w": "push succeeded (generation #%d) but saving the local state failed: %w",

	"l'hub chiede un blob che non fa parte di questo push (%s)": "the hub asked for a blob that isn't part of this push (%s)",

	"modifiche locali non pushate": "unpushed local changes",

	"%d file modificati o aggiunti, %d cancellati": "%d files changed or added, %d deleted",

	"la cartella locale ha modifiche mai caricate sull'hub (%s): falle arrivare con un push prima di scaricare": "the local folder has changes never uploaded to the hub (%s): push them before downloading",

	"da una generazione sconosciuta": "from an unknown generation",

	"dalla generazione #%d": "from generation #%d",

	"la cartella locale ha modifiche mai caricate sull'hub (%s) e parte %s, ma l'hub nel frattempo è alla #%d: un pull le sovrascriverebbe. Scegli se scartarle (ne viene fatta una copia di backup)": "the local folder has changes never uploaded to the hub (%s) and starts %s, but the hub is now at #%d: a pull would overwrite them. Choose whether to discard them (a backup copy is made)",

	"backup di %s: %w": "backup of %s: %w",

	"header incompleto": "incomplete header",

	"header illeggibile": "unreadable header",

	"voce di chunk malformata": "malformed chunk entry",

	"chunk oltre la fine del file": "chunk past the end of the file",

	"chunk sovrapposti (scrittura interrotta)": "overlapping chunks (interrupted write)",

	"dati del chunk illeggibili": "unreadable chunk data",

	"lunghezza del chunk incoerente": "inconsistent chunk length",

	"dati del chunk oltre la fine del file (scrittura interrotta)": "chunk data past the end of the file (interrupted write)",

	// --- server Minecraft ---
	"nessun modo di avviare il server: manca sia uno script di avvio sia un jar avviabile": "no way to start the server: there is neither a start script nor a runnable jar",

	"il server non è in esecuzione": "the server is not running",

	"console del server bloccata: comando non inviato": "server console stuck: command not sent",

	" […riga troncata da MineSync]": " […line truncated by MineSync]",

	"script PowerShell %s": "PowerShell script %s",

	"script %s": "script %s",

	"nessuno script: avvio diretto di %s": "no script: launching %s directly",

	"MineSync è uscito con errore %s. Premi invio per chiudere.": "MineSync exited with error %s. Press Enter to close.",

	// --- sessione di gioco ---
	"pronto": "ready",

	"sincronizzazione": "syncing",

	"avvio server": "starting server",

	"in gioco": "in game",

	"salvataggio mondo": "saving world",

	"push sull'hub": "pushing to hub",

	"arresto server": "stopping server",

	"terminata": "finished",

	"errore": "error",

	"lock perso": "lock lost",

	"Attenzione: %d region file risultano danneggiati (es. %s). La generazione è marcata; ripristina la versione integra dalla web UI.": "Warning: %d region files are damaged (e.g. %s). The generation is flagged; restore an intact version from the web UI.",

	"Porta raggiungibile: i giocatori possono connettersi.": "Port reachable: players can connect.",

	"La porta %s non risponde dall'hub: consentila nel firewall del sistema (via ZeroTier non serve il port forwarding).": "Port %s doesn't answer from the hub: allow it in the system firewall (over ZeroTier no port forwarding is needed).",

	"La cartella locale ha modifiche mai arrivate sull'hub (%d file modificati o aggiunti, %d cancellati): le carico ora, prima di avviare.": "The local folder has changes that never reached the hub (%d files changed or added, %d deleted): uploading them now, before starting.",

	"modifiche locali non sincronizzate di %s": "unsynced local changes by %s",

	"caricamento delle modifiche locali fallito: %w": "uploading the local changes failed: %w",

	"Modifiche locali caricate: generazione %d": "Local changes uploaded: generation %d",

	"pull fallito: %w": "pull failed: %w",

	"Modifiche locali scartate: ne trovi una copia in %s": "Local changes discarded: you'll find a copy in %s",

	"Sincronizzato alla generazione %d (%d file scaricati)": "Synced to generation %d (%d files downloaded)",

	"%w prima dell'avvio: il server non è stato avviato": "%w before starting: the server was not started",

	"non so come avviare il server in %s: non c'e' nessuno script di avvio (run.sh, start.sh, ServerStart.sh…) ne' un jar avviabile (fabric-server-launch.jar, server.jar…)": "I don't know how to start the server in %s: there is no start script (run.sh, start.sh, ServerStart.sh…) nor a runnable jar (fabric-server-launch.jar, server.jar…)",

	"Nessun runtime Java trovato dal sistema: lascio decidere allo script del pack. Se non parte, installa Java %s.": "No Java runtime found on the system: letting the pack's script decide. If it doesn't start, install Java %s.",

	"java non trovato: installane uno (Minecraft %s vuole Java %s) o selezionalo dalle impostazioni dello spazio": "java not found: install one (Minecraft %s wants Java %s) or select it in the space settings",

	"moderno": "modern",

	"Java %s è troppo vecchio: Minecraft %s richiede Java %d. Il server morirà con UnsupportedClassVersionError — installa Java %d.": "Java %s is too old: Minecraft %s requires Java %d. The server will die with UnsupportedClassVersionError — install Java %d.",

	"Uso Java %s, ma questo modpack (Minecraft %s) è fatto per Java %d: se l'avvio fallisce è il primo indiziato.": "Using Java %s, but this modpack (Minecraft %s) is made for Java %d: if startup fails, that's the prime suspect.",

	"Java %s ok": "Java %s ok",

	"Avvio: %s": "Starting: %s",

	"avvio fallito: %w": "start failed: %w",

	"Console ferma da %s durante lo spegnimento: il processo sembra piantato (pause nello script?), arresto forzato.": "Console silent for %s during shutdown: the process seems hung (pause in the script?), forcing a stop.",

	"Autosave in corso": "Autosave in progress",

	"Salvataggio manuale in corso": "Manual save in progress",

	"Nessuna conferma di salvataggio entro %s: push comunque avviato.": "No save confirmation within %s: pushing anyway.",

	"Server avviato (porta %s)": "Server started (port %s)",

	"il server si è fermato perché l'EULA di Minecraft non è accettata: apri eula.txt nella cartella del server, metti eula=true e riprova": "the server stopped because the Minecraft EULA is not accepted: open eula.txt in the server folder, set eula=true and try again",

	"Il server si è chiuso prima di completare l'avvio: è un problema di configurazione, non un crash. Nessun riavvio automatico.": "The server closed before finishing startup: it's a configuration problem, not a crash. No automatic restart.",

	"Server terminato in modo anomalo (%s): salvo lo stato e riavvio (tentativo %d/%d).": "Server terminated abnormally (%s): saving the state and restarting (attempt %d/%d).",

	"push post-crash di %s": "post-crash push by %s",

	"Push post-crash non riuscito: %v": "Post-crash push failed: %v",

	"Riavvio fallito: %v": "Restart failed: %v",

	"Lock perso: push finale saltato. Il mondo è rimasto solo su questo PC.": "Lock lost: final push skipped. The world is only on this PC.",

	"%w: il server è stato fermato e il mondo è rimasto solo sul disco locale (al prossimo avvio MineSync ti chiederà come procedere)": "%w: the server was stopped and the world is only on the local disk (on the next start MineSync will ask you how to proceed)",

	"stop di %s": "stop by %s",

	"Server terminato in modo anomalo: salvataggio dello stato sull'hub.": "Server terminated abnormally: saving the state to the hub.",

	"%w: push finale rifiutato, il mondo è rimasto solo sul disco locale: %v": "%w: final push rejected, the world is only on the local disk: %v",

	"Push finale non riuscito: %v. Il mondo resta sul disco locale; riprova con `minesync push`.": "Final push failed: %v. The world stays on the local disk; retry with `minesync push`.",

	"Push finale: generazione %d": "Final push: generation %d",

	"Nessuna modifica da salvare.": "No changes to save.",

	"il server Minecraft è crashato (%s, vedi console)": "the Minecraft server crashed (%s, see console)",

	"uscito da solo senza che fosse chiesto lo stop": "exited on its own without a stop being requested",

	"uscita: %v": "exit: %v",

	"Nessun giocatore da %s: arresto automatico e salvataggio finale.": "No players for %s: automatic stop and final save.",

	"autosave di %s": "autosave by %s",

	"Autosave non riuscito: %v": "Autosave failed: %v",

	"Autosave: nessuna modifica.": "Autosave: no changes.",

	"Autosave: generazione %d (%s)": "Autosave: generation %d (%s)",

	"LOCK PERSO (%v): qualcun altro ha preso il controllo dello spazio. Fermo il server: quello che fai da ora non potrebbe più essere salvato sull'hub. Il mondo resta su questo PC.": "LOCK LOST (%v): someone else has taken control of the space. Stopping the server: anything you do from now on could no longer be saved to the hub. The world stays on this PC.",

	"Hub di nuovo raggiungibile.": "Hub reachable again.",

	"Hub irraggiungibile (%v). Il gioco prosegue; i salvataggi riprenderanno al ritorno.": "Hub unreachable (%v). The game goes on; saves will resume when it's back.",

	"Rilascio del lock non riuscito: %v (scadrà da solo alla fine del TTL).": "Failed to release the lock: %v (it will expire on its own at the end of the TTL).",

	"Lock rilasciato.": "Lock released.",

	// --- TUI: comune ---
	"serve un terminale: apri Konsole, GNOME Terminal o xterm ed esegui minesync da lì": "a terminal is required: open Konsole, GNOME Terminal or xterm and run minesync from there",

	"MineSync: sessione di gioco ancora attiva — arresto del server e salvataggio sull'hub (max 60s, Ctrl+C di nuovo per accelerare)…": "MineSync: game session still active — stopping the server and saving to the hub (max 60s, Ctrl+C again to hurry)…",

	"MineSync: sessione chiusa.": "MineSync: session closed.",

	"MineSync: arresto rapido…": "MineSync: fast stop…",

	"MineSync: il server non si è fermato in tempo, arresto forzato…": "MineSync: the server didn't stop in time, forcing it…",

	"Aggiornamento pronto": "Update ready",

	"MineSync %s è stato scaricato. Riavvio adesso per applicarlo?\n\nSe stai per giocare scegli «Non ora»: l'aggiornamento resta pronto e puoi riavviare quando vuoi.": "MineSync %s has been downloaded. Restart now to apply it?\n\nIf you're about to play, choose “Not now”: the update stays ready and you can restart whenever you like.",

	"Riavvia": "Restart",

	"Non ora": "Not now",

	"✔ connesso a %s come %s": "✔ connected to %s as %s",

	"✔ client aggiornato alla v%s — riavvia per applicare": "✔ client updated to v%s — restart to apply",

	"avvio…": "starting…",

	"Allarga il terminale (minimo 70×20)": "Make the terminal larger (minimum 70×20)",

	"indietro": "back",

	"aiuto": "help",

	"Comandi": "Keys",

	"un tasto qualsiasi per chiudere": "press any key to close",

	"  ⟳ riavvia per v%s": "  ⟳ restart for v%s",

	"✔ lingua: italiano": "✔ language: English",

	"lingua → English": "language → Italiano",

	"mai": "never",

	"%ds fa": "%ds ago",

	"%dm fa": "%dm ago",

	"%dh fa": "%dh ago",

	"invio": "enter",

	"annulla": "cancel",

	"esci": "quit",

	"carico…": "loading…",

	"scegli": "choose",

	"conferma": "confirm",

	"Conferma %s di 2.": "Confirmation %s of 2.",

	"1ª": "1",

	"2ª": "2",

	"ULTIMA CHIAMATA: l'azione è irreversibile.": "LAST CALL: this action cannot be undone.",

	"Annulla": "Cancel",

	// --- TUI: home, connessione, nuovo server ---
	"server": "servers",

	"naviga": "navigate",

	"apri": "open",

	"nuovo server": "new server",

	"cambia hub": "change hub",

	"aggiorna": "refresh",

	"Nessun server.": "No servers.",

	"Premi 'n' per crearne uno.": "Press 'n' to create one.",

	"in gioco · %s": "in game · %s",

	" ⇣ pre-scarico %d%%": " ⇣ prefetching %d%%",

	"server (%d)": "servers (%d)",

	"nessuna attività": "no activity",

	"attività": "activity",

	"connessione": "connection",

	"connetti": "connect",

	"inserisci l'indirizzo dell'hub": "enter the hub address",

	"il mondo condiviso, sempre aggiornato": "the shared world, always up to date",

	"INDIRIZZO HUB": "HUB ADDRESS",

	"connessione…": "connecting…",

	"es. MioMondo": "e.g. MyWorld",

	"crea": "create",

	"dai un nome al server": "give the server a name",

	"✔ server creato": "✔ server created",

	"NOME DEL SERVER": "SERVER NAME",

	"creo…": "creating…",

	// --- TUI: dashboard dello spazio ---
	"es. C:\\Minecraft\\MioMondo oppure /home/tu/miomondo": "e.g. C:\\Minecraft\\MyWorld or /home/you/myworld",

	"collega": "link",

	"GIOCA": "PLAY",

	"verifica": "verify",

	"cartella": "folder",

	"storia": "history",

	"forza sblocco": "force unlock",

	"Lock stale di %s rimpiazzato.": "Stale lock of %s replaced.",

	"%s sta giocando (ultimo heartbeat %s): aspetta che chiuda la sessione": "%s is playing (last heartbeat %s): wait for them to close the session",

	"%s ha una sessione attiva (ultimo heartbeat %s).\n\nForzando il rilascio mentre gioca, i progressi non ancora salvati andranno persi.": "%s has an active session (last heartbeat %s).\n\nForcing the release while they play will lose any progress not yet saved.",

	"Sessione in corso": "Session in progress",

	"Forza e gioca": "Force and play",

	"✔ cartella collegata": "✔ folder linked",

	"Il lock di %s è attivo: se sta giocando, perderà i progressi non salvati.": "%s's lock is active: if they are playing, they will lose unsaved progress.",

	"Il lock di %s è scaduto (heartbeat fermo da %s). Il rilascio è sicuro.": "%s's lock has expired (heartbeat stopped %s). Releasing it is safe.",

	"Forzare il rilascio?": "Force the release?",

	"Rilascia": "Release",

	"push manuale di %s": "manual push by %s",

	"pull: generazione #%d, %d file": "pull: generation #%d, %d files",

	"push: nessuna modifica": "push: no changes",

	"push: generazione #%d (%s)": "push: generation #%d (%s)",

	"push non possibile: %s ha il lock (sta giocando)": "can't push: %s holds the lock (they're playing)",

	"✔ integrità: %d region controllati, tutti sani": "✔ integrity: %d regions checked, all healthy",

	"✗ %d region danneggiati (es. %s) — ripristina dalla web UI": "✗ %d damaged regions (e.g. %s) — restore from the web UI",

	"libero — nessuno in gioco": "free — nobody playing",

	"STALE di %s (fermo %s)": "STALE by %s (stopped %s)",

	"in gioco: %s (da %s)": "in game: %s (started %s)",

	"generazione  ": "generation   ",

	"ultimo push  ": "last push    ",

	"ENTRA IN GIOCO SU": "JOIN THE GAME AT",

	"(indirizzo fisso, uguale per tutti)": "(fixed address, the same for everyone)",

	"stato hub": "hub status",

	"Nessuna cartella collegata. Con G verrà usata:": "No folder linked. G will use:",

	"(premi 'l' per sceglierne un'altra)": "(press 'l' to pick another one)",

	"cartella  ": "folder    ",

	"non so come avviarlo": "don't know how to start it",

	"PERCORSO": "PATH",

	"copia locale": "local copy",

	"rilevo java…": "detecting java…",

	"mancante! (premi j)": "missing! (press j)",

	"java del modpack (verificato al Play)": "modpack java (checked at Play)",

	"java %s ⚠ serve %d (premi j)": "java %s ⚠ needs %d (press j)",

	"salvataggio": "save",

	"Ancora nessuna generazione: fai il primo push (u).": "No generations yet: do the first push (u).",

	"storia recente": "recent history",

	"%s in corso — fase: ": "%s in progress — phase: ",

	"trasferiti": "transferred",

	"trasferimento": "transfer",

	// --- TUI: sessione di gioco ---
	"comando console (es. list, say ciao)…": "console command (e.g. list, say hi)…",

	"dal modpack": "from modpack",

	"sessione": "session",

	"chiudi": "close",

	"applica ricerca": "apply search",

	"chiudi ricerca": "close search",

	"comando": "command",

	"cronologia": "history",

	"salva": "save",

	"filtro": "filter",

	"cerca": "search",

	"Arresto richiesto: salvataggio finale e chiusura in corso.": "Stop requested: final save and shutdown in progress.",

	"Arresto automatico disattivato.": "Automatic stop disabled.",

	"Arresto automatico attivo: dopo 30 minuti senza giocatori.": "Automatic stop on: after 30 minutes without players.",

	"Sessione terminata. Stato salvato sull'hub.": "Session finished. State saved to the hub.",

	"versione  ": "version   ",

	"salvato   ": "saved     ",

	"tra %s": "in %s",

	"%dm se vuoto": "%dm if empty",

	"%d/%d file · %s": "%d/%d files · %s",

	"%s  %s / %s   %s   %d/%d file": "%s  %s / %s   %s   %d/%d files",

	"\r[%s] %d/%d file  %s / %s  %s/s        ": "\r[%s] %d/%d files  %s / %s  %s/s        ",

	"⚠ in affanno (%d avvisi/2m)": "⚠ struggling (%d warnings/2m)",

	"mancante!": "missing!",

	"porta     ": "port      ",

	"test porta in corso…": "port test running…",

	"● porta raggiungibile": "● port reachable",

	"✗ porta bloccata (firewall)": "✗ port blocked (firewall)",

	"indirizzo per i giocatori": "address for players",

	"giocatori (%d)": "players (%d)",

	"avvisi": "alerts",

	"sessione terminata — premi esc per tornare indietro": "session finished — press esc to go back",

	"La copia locale ha modifiche mai salvate sull'hub: %d file cambiati, %d eliminati (base: generazione #%d, hub ora a #%d).\n\nScartandole, il Play riparte dalla versione dell'hub. I file locali toccati vengono prima copiati in:\n%s\n\nAnnulla per lasciare tutto com'è.": "The local copy has changes never saved to the hub: %d files changed, %d deleted (base: generation #%d, hub now at #%d).\n\nIf you discard them, Play restarts from the hub's version. The affected local files are first copied to:\n%s\n\nCancel to leave everything as it is.",

	"Modifiche locali non salvate": "Unsaved local changes",

	"Scarta le modifiche locali": "Discard local changes",

	"solo avvisi+errori": "warnings+errors only",

	"solo errori": "errors only",

	"▲ scroll — End per tornare live": "▲ scroll — End to go back live",

	// --- TUI: storia ---
	"ripristina": "restore",

	"✔ generazione ripristinata": "✔ generation restored",

	"il ripristino è riservato all'admin": "restoring is reserved to the admin",

	"è già la generazione corrente": "it's already the current generation",

	"Verrà creata una nuova generazione con il contenuto di #%d (%s, %s).\n\nNessun dato viene perso: la storia resta. Al prossimo avvio tutti scaricheranno questa versione.": "A new generation will be created with the contents of #%d (%s, %s).\n\nNo data is lost: the history stays. On their next start everyone will download this version.",

	"Ripristinare #%d?": "Restore #%d?",

	"Ripristina": "Restore",

	"Nessuna generazione.": "No generations.",

	"%d generazioni · %s totali (HEAD)": "%d generations · %s total (HEAD)",

	"storia di %s": "history of %s",

	// --- TUI: runtime Java ---
	"ririleva": "re-detect",

	"runtime: automatico (dal modpack)": "runtime: automatic (from the modpack)",

	"runtime fissato per %s": "runtime pinned for %s",

	"Java consigliato: sconosciuto (versione di Minecraft non rilevata)": "Recommended Java: unknown (Minecraft version not detected)",

	"Java consigliato per questo modpack: ": "Recommended Java for this modpack: ",

	"rilevo i runtime installati…": "detecting installed runtimes…",

	"Automatico": "Automatic",

	"Nessun runtime trovato sul sistema.": "No runtime found on the system.",

	"Installa il Java richiesto (es. Adoptium/Temurin) e premi r.": "Install the required Java (e.g. Adoptium/Temurin) and press r.",

	"runtime java per %s": "java runtime for %s",

	"✓ consigliato": "✓ recommended",

	"usa il runtime compatibile col modpack": "use the runtime that matches the modpack",

	"→ userebbe ": "→ would use ",

	"⚠ nessun Java %d installato": "⚠ no Java %d installed",
}
