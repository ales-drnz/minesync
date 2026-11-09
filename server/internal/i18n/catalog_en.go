package i18n

// catalogEN: id italiano → inglese. I verbi di formato devono combaciare
// (stessi verbi, stesso ordine): lo verifica TestCatalogVerbs. Le voci non
// più usate le segnala TestCatalogCoverage.
//
// Nota: i messaggi di errore legati al lock contengono la parola "lock" anche
// in inglese (il client la usa per riconoscere un lock perso).
var catalogEN = map[string]string{

	// --- errori di base dello store (sentinelle) ---
	"non trovato": "not found",

	"conflitto": "conflict",

	"spazio lockato": "space locked",

	"richiesta non valida": "invalid request",

	// --- API: autenticazione, guard, risposte ---
	"non autenticato: connettiti alla rete ZeroTier": "not authenticated: connect to the ZeroTier network",

	"operazione riservata all'admin": "admin-only operation",

	"host non ammesso (aggiungilo a MINESYNC_HOSTS)": "host not allowed (add it to MINESYNC_HOSTS)",

	"richiesta cross-site rifiutata": "cross-site request rejected",

	"header X-MineSync mancante": "missing X-MineSync header",

	"corpo della richiesta troppo grande": "request body too large",

	"streaming non supportato": "streaming not supported",

	"nome non valido": "invalid name",

	"file non trovato": "file not found",

	"nome jar non valido": "invalid jar name",

	"mod non trovata": "mod not found",

	"nessuna icona": "no icon",

	"n non numerico": "n is not a number",

	"%w: body JSON non valido: %v": "%w: invalid JSON body: %v",

	"%w: gen non numerico": "%w: gen is not a number",

	"%w: limit non numerico": "%w: limit is not a number",

	"%w: n non numerico": "%w: n is not a number",

	"%w: keep deve essere un intero ≥ 1": "%w: keep must be an integer ≥ 1",

	"%w: nolock e allowMassDelete": "%w: nolock and allowMassDelete",

	"%w: forzare il rilascio di un lock attivo": "%w: force-releasing an active lock",

	"%w: nome jar non valido": "%w: invalid jar name",

	"%w: %s troppo grande": "%w: %s is too large",

	// --- store ---
	"il lock non è più tuo: riacquisiscilo prima di pushare": "the lock is no longer yours: acquire it again before pushing",

	"lockato da %s": "locked by %s",

	"il push eliminerebbe %d file su %d: rifiutato per sicurezza (un admin può forzarlo)": "the push would delete %d of %d files: rejected for safety (an admin can force it)",

	"%w: lock non tuo o già rilasciato": "%w: lock not yours or already released",

	"%w: il lock appartiene a %s": "%w: the lock belongs to %s",

	"%w: keep deve essere ≥ 1": "%w: keep must be ≥ 1",

	"%w: non puoi eliminare la versione corrente (HEAD)": "%w: you can't delete the current version (HEAD)",

	"generazione %d: %w": "generation %d: %w",

	"generazione %d illeggibile: %w": "generation %d is unreadable: %w",

	"GC annullato, nessun file eliminato: %w": "GC aborted, no files deleted: %w",

	"space %s: %w": "space %s: %w",

	"space %q: %w": "space %q: %w",

	"blob %s: %w": "blob %s: %w",

	"push %s: %w": "push %s: %w",

	"%w: %v": "%w: %v",

	"HEAD illeggibile (%q)": "unreadable HEAD (%q)",

	"HEAD=%d ma la generazione non è leggibile: %w": "HEAD=%d but the generation is unreadable: %w",

	"%w: nome mancante": "%w: missing name",

	"%w: hash non valido": "%w: invalid hash",

	"%w: hash non valido per %q": "%w: invalid hash for %q",

	"%w: hash non combacia (dichiarato %s, reale %s)": "%w: hash mismatch (declared %s, actual %s)",

	"%w: file troppo grande": "%w: file too large",

	"%w: file troppo grande (%d byte)": "%w: file too large (%d bytes)",

	"%w: gzip non valido: %v": "%w: invalid gzip: %v",

	"%w: blob %.12s non richiesto da questo push": "%w: blob %.12s was not requested by this push",

	"%w: parent %d ma HEAD è %d (qualcuno ha pushato prima di te: fai pull)": "%w: parent %d but HEAD is %d (someone pushed before you: pull first)",

	"%w: percorso non valido %q": "%w: invalid path %q",

	"%w: chunk non valido per %q": "%w: invalid chunk for %q",

	"%w: chunk di %q non coprono il file (%d ≠ %d)": "%w: chunks of %q don't cover the file (%d ≠ %d)",

	"%w: blob mancante per %q (%.12s)%s": "%w: missing blob for %q (%.12s)%s",

	"%w: HEAD avanzato durante il push": "%w: HEAD moved during the push",

	"%w: %q non è in HEAD": "%w: %q is not in HEAD",

	"%w: nessuna versione integra di %q nella storia": "%w: no intact version of %q in the history",

	"%w: %q non esiste nella generazione %d": "%w: %q does not exist in generation %d",

	// --- eventi (registro attività) ---
	"%s ha creato lo spazio «%s» (profilo %s)": "%s created the space “%s” (profile %s)",

	"%s ha aggiornato le impostazioni di «%s»": "%s updated the settings of “%s”",

	"%s ha eliminato lo spazio %s": "%s deleted the space %s",

	"%s ha eliminato la versione #%d": "%s deleted version #%d",

	"%s ha ripristinato la generazione %d (nuova: %d)": "%s restored generation %d (new: %d)",

	"%s ha ripristinato %s (versione integra, gen %d)": "%s restored %s (intact version, gen %d)",

	"GC: %d generazioni potate, %d blob eliminati (%s MB liberati)": "GC: %d generations pruned, %d blobs deleted (%s MB freed)",

	"%s ha pushato la generazione %d — %s (+%d ~%d −%d)": "%s pushed generation %d — %s (+%d ~%d −%d)",

	"%s ha pushato la generazione %d — salvataggio (+%d ~%d −%d)": "%s pushed generation %d — save (+%d ~%d −%d)",

	"%s ha preso il lock": "%s took the lock",

	"%s ha preso il lock (era stale di %s)": "%s took over the stale lock from %s",

	"%s ha rilasciato il lock": "%s released the lock",

	"⚠ %s ha FORZATO il rilascio del lock di %s": "⚠ %s FORCE-released %s's lock",

	"%s ha liberato il lock stale di %s": "%s cleared %s's stale lock",

	// --- pagina /dl ---
	"Scarica MineSync": "Download MineSync",

	"Scarica": "Download",

	"Nessun binario disponibile sull'hub.": "No binaries available on the hub.",

	"Il client per giocare ai server dell'hub.": "The client for playing on the hub's servers.",

	"Avvialo. Su Linux e macOS prima <code>chmod +x minesync</code>.": "Run it. On Linux and macOS, first <code>chmod +x minesync</code>.",

	"Conferma l'indirizzo dell'hub, scegli il server e premi <b>G</b>.": "Confirm the hub address, pick the server and press <b>G</b>.",

	"Requisiti: rete ZeroTier e Java nel PATH.": "Requirements: ZeroTier network and Java in your PATH.",

	// --- bot Telegram ---
	"📊 <b>Stato dei server</b>": "📊 <b>Server status</b>",

	"⚪ <b>%s</b> — chiuso": "⚪ <b>%s</b> — closed",

	"🟢 <b>%s</b> — hosta %s": "🟢 <b>%s</b> — hosted by %s",

	" da %s": " for %s",

	", nessuno in gioco": ", nobody playing",

	", in gioco: %s": ", playing: %s",

	", %d in gioco": ", %d playing",

	"Nessun server configurato.": "No servers configured.",

	"🟢 <b>%s</b> è aperto": "🟢 <b>%s</b> is open",

	"👤 hosta <b>%s</b>": "👤 hosted by <b>%s</b>",

	"🔴 <b>%s</b> è chiuso": "🔴 <b>%s</b> is closed",

	"⏱ sessione di %s": "⏱ session: %s",

	"il client di %s non risponde più": "%s's client stopped responding",

	"⚠️ <b>%s</b> è aperto ma non salva sull'hub da %s\n👤 host <b>%s</b>: i salvataggi automatici non arrivano, lo stato recente non è protetto": "⚠️ <b>%s</b> is open but hasn't saved to the hub for %s\n👤 host <b>%s</b>: autosaves aren't arriving, recent progress is not protected",

	"telegram ha risposto %s": "telegram replied %s",

	"telegram: coda piena, annuncio scartato": "telegram: queue full, announcement dropped",

	"telegram: annuncio non inviato: %v": "telegram: announcement not sent: %v",

	// --- log dell'hub ---
	"impossibile creare %s: %v": "cannot create %s: %v",

	"!!! ATTENZIONE: MODALITÀ SVILUPPO (MINESYNC_DEV_USER) — le richieste da loopback (127.0.0.1/::1) sono autenticate come admin. Non usarla mai in produzione !!!": "!!! WARNING: DEVELOPMENT MODE (MINESYNC_DEV_USER) — loopback requests (127.0.0.1/::1) are authenticated as admin. Never use it in production !!!",

	"!!! identità di sviluppo: «%s» (solo da loopback)": "!!! development identity: “%s” (loopback only)",

	"nessuno": "none",

	"auth ZeroTier attiva (ztnet: %s, admin: %s)": "ZeroTier auth enabled (ztnet: %s, admins: %s)",

	"configura ZTNET_URL, ZTNET_API_TOKEN e ZTNET_NETWORK_ID: l'autenticazione avviene tramite la rete ZeroTier (oppure MINESYNC_DEV_USER per sviluppo locale)": "set ZTNET_URL, ZTNET_API_TOKEN and ZTNET_NETWORK_ID: authentication goes through the ZeroTier network (or MINESYNC_DEV_USER for local development)",

	"retention: si conservano le ultime %d versioni per server (più quelle delle ultime 24h e una al giorno per 7 giorni)": "retention: keeping the last %d versions per server (plus those from the last 24h and one per day for 7 days)",

	"DNS interno su %s: zerotier.<spazio>.%s → chi hosta adesso": "internal DNS on %s: zerotier.<space>.%s → whoever is hosting now",

	"DNS interno NON attivo su %s: %v — l'hub continua; serve la porta 53 (vedi deploy)": "internal DNS NOT running on %s: %v — the hub keeps going; port 53 is required (see deploy)",

	"DNS interno disattivato": "internal DNS disabled",

	"bot Telegram attivo (chat %s)": "Telegram bot enabled (chat %s)",

	"bot Telegram non configurato (MINESYNC_TELEGRAM_TOKEN/CHAT)": "Telegram bot not configured (MINESYNC_TELEGRAM_TOKEN/CHAT)",

	"host ammessi oltre a IP/localhost/zona DNS: %s": "allowed hosts besides IP/localhost/DNS zone: %s",

	"minesync-hub %s in ascolto su %s (dati: %s)": "minesync-hub %s listening on %s (data: %s)",

	"arresto in corso (attendo fino a %s le richieste in corso)…": "shutting down (waiting up to %s for in-flight requests)…",

	"arresto HTTP incompleto: %v": "incomplete HTTP shutdown: %v",

	"DNS/bot non terminati in tempo": "DNS/bot did not stop in time",

	"minesync-hub arrestato": "minesync-hub stopped",

	"export %s gen %d interrotto: %v": "export %s gen %d aborted: %v",

	"ztauth: aggiornamento membri fallito: %v": "ztauth: member refresh failed: %v",

	"store: ATTENZIONE, %s non ha space.json: ignorata": "store: WARNING, %s has no space.json: ignored",

	"store: ATTENZIONE, spazio %s: %v → HEAD ricostruito a %d": "store: WARNING, space %s: %v → HEAD rebuilt at %d",

	"store: pulizia di %s incompleta: %v (riprovo al riavvio)": "store: cleanup of %s incomplete: %v (will retry on restart)",

	"store: retention di %s saltata: %v": "store: retention of %s skipped: %v",

	"store: GC di %s annullato: %v": "store: GC of %s aborted: %v",

	"store: statistiche di %s non salvate: %v": "store: stats of %s not saved: %v",
}
