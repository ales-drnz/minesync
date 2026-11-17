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
}
