package i18n

// Traduzioni inglesi dello stream EDGES (TUI, CLI, lockbeat): file separato
// per non toccare catalog_en.go in parallelo. Stesse regole di catalogEN; le
// voci si fondono nello stesso catalogo all'avvio.
func init() {
	for id, en := range catalogENEdges {
		catalogEN[id] = en
	}
}

var catalogENEdges = map[string]string{

	"lock perso durante il push (forzato da un altro o scaduto): push annullato, i file locali sono intatti": "lock lost during the push (forced by someone else or expired): push cancelled, local files are untouched",

	"lo spazio non esiste più sull'hub: push annullato, i file locali sono intatti": "the space no longer exists on the hub: push cancelled, local files are untouched",

	// --- TUI: sessione di gioco ---
	"sull'hub  ": "on hub    ",

	"in caricamento… %d%%": "uploading… %d%%",

	"attenzione": "warning",

	"spazio sparito": "space gone",

	"hub pieno": "hub full",

	"Un altro ha preso lo spazio (o il lock è scaduto): il server è stato fermato e il mondo è salvato solo su questo PC.": "Someone else took the space (or the lock expired): the server was stopped and the world is saved only on this PC.",

	"Lo spazio non esiste più sull'hub: il mondo è salvato solo su questo PC.": "The space no longer exists on the hub: the world is saved only on this PC.",

	"L'hub ha il disco pieno: i salvataggi non arrivano all'hub. Libera spazio sull'hub; il mondo resta su questo PC.": "The hub's disk is full: saves are not reaching the hub. Free up space on the hub; the world stays on this PC.",

	// --- TUI: dashboard ---
	"⚠ hub quasi pieno: liberi %s su %s (%.1f%%). Oltre la soglia l'hub rifiuta i salvataggi.": "⚠ hub almost full: %s free of %s (%.1f%%). Past the threshold the hub refuses saves.",
}
