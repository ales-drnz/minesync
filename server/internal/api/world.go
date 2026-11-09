package api

import (
	"container/list"
	"errors"
	"io"
	"net/http"
	"sort"
	"strings"
	"sync"

	"minesync/server/internal/i18n"
	"minesync/server/internal/mcmeta"
	"minesync/server/internal/store"
)

// I dati del mondo (info, giocatori, mod) sono ricavati dai file che l'hub
// conserva come blob nella generazione HEAD. Risultati in cache per numero di
// generazione: si ricalcolano solo quando qualcuno pusha.

type cachedGen struct {
	gen  int
	data any
}

// cachedGen serve un valore calcolato da HEAD, riusando la cache finché HEAD
// non avanza.
func (s *Server) cachedFor(id, kind string, build func() (any, error)) (any, error) {
	head, err := s.Store.Head(id)
	if err != nil {
		return nil, err
	}
	key := id + "|" + kind
	if v, ok := s.worldCache.Load(key); ok {
		if e := v.(*cachedGen); e.gen == head {
			return e.data, nil
		}
	}
	data, err := build()
	if err != nil {
		return nil, err
	}
	s.worldCache.Store(key, &cachedGen{gen: head, data: data})
	return data, nil
}

// readPath legge un intero file da HEAD (nil se assente).
func (s *Server) readPath(id, path string) ([]byte, error) {
	rc, ok, err := s.Store.OpenPath(id, path)
	if err != nil || !ok {
		return nil, err
	}
	defer rc.Close()
	b, err := io.ReadAll(io.LimitReader(rc, maxReadBytes+1))
	if err == nil && len(b) > maxReadBytes {
		return nil, i18n.Errorf("%w: %s troppo grande", store.ErrBadRequest, path)
	}
	return b, err
}

// --- /world: info del mondo + config del server ---

func (s *Server) handleWorld(_ http.ResponseWriter, r *http.Request, _ Identity) (any, error) {
	id := r.PathValue("id")
	return s.cachedFor(id, "world", func() (any, error) {
		out := map[string]any{}
		// level.dat può stare in <level-name>/level.dat; "world" è il default
		levelPath := "world/level.dat"
		if props, _ := s.readPath(id, "server.properties"); props != nil {
			si := mcmeta.ParseServer(strings.NewReader(string(props)))
			out["server"] = si
			if si.LevelName != "" {
				levelPath = si.LevelName + "/level.dat"
			}
		}
		rc, ok, err := s.Store.OpenPath(id, levelPath)
		if err == nil && !ok {
			rc, ok, err = s.Store.OpenPath(id, "world/level.dat")
		}
		if err == nil && ok {
			li, perr := mcmeta.ParseLevel(rc)
			rc.Close()
			if perr == nil {
				out["level"] = li
			}
		}
		return out, nil
	})
}

// --- /players: statistiche e ruoli ---

type playerView struct {
	UUID      string `json:"uuid"`
	Name      string `json:"name"`
	Op        bool   `json:"op,omitempty"`
	Whitelist bool   `json:"whitelist,omitempty"`
	mcmeta.PlayerStats
}

func (s *Server) handlePlayers(_ http.ResponseWriter, r *http.Request, _ Identity) (any, error) {
	id := r.PathValue("id")
	return s.cachedFor(id, "players", func() (any, error) {
		head, err := s.Store.Head(id)
		if err != nil {
			return nil, err
		}
		man, err := s.Store.ManifestAt(id, head)
		if err != nil {
			return nil, err
		}
		// nomi da usercache/whitelist; ruoli da whitelist/ops
		names := map[string]string{}
		for _, f := range []string{"usercache.json", "whitelist.json"} {
			if b, _ := s.readPath(id, f); b != nil {
				for u, n := range mcmeta.ParseNameMap(strings.NewReader(string(b))) {
					names[u] = n
				}
			}
		}
		wl, ops := map[string]bool{}, map[string]bool{}
		if b, _ := s.readPath(id, "whitelist.json"); b != nil {
			wl = mcmeta.ParseUUIDSet(strings.NewReader(string(b)))
		}
		if b, _ := s.readPath(id, "ops.json"); b != nil {
			ops = mcmeta.ParseUUIDSet(strings.NewReader(string(b)))
		}

		var players []playerView
		for path := range man {
			if !strings.Contains(path, "/stats/") || !strings.HasSuffix(path, ".json") {
				continue
			}
			rawUUID := strings.TrimSuffix(path[strings.LastIndex(path, "/")+1:], ".json")
			u := mcmeta.NormUUID(rawUUID)
			b, _ := s.readPath(id, path)
			if b == nil {
				continue
			}
			st, err := mcmeta.ParsePlayerStats(strings.NewReader(string(b)))
			if err != nil {
				continue
			}
			name := names[u]
			if name == "" {
				name = shortUUID(rawUUID)
			}
			players = append(players, playerView{
				UUID: rawUUID, Name: name, Op: ops[u], Whitelist: wl[u], PlayerStats: st,
			})
		}
		// ordine: più ore in cima
		sort.Slice(players, func(i, j int) bool {
			if players[i].PlayTimeTicks != players[j].PlayTimeTicks {
				return players[i].PlayTimeTicks > players[j].PlayTimeTicks
			}
			return players[i].Name < players[j].Name
		})
		if players == nil {
			players = []playerView{}
		}
		return players, nil
	})
}

func shortUUID(u string) string {
	if len(u) >= 8 {
		return u[:8]
	}
	return u
}

// --- /mods: elenco + dettaglio + icona ---

type modListItem struct {
	File string `json:"file"`
	Name string `json:"name"` // dal nome-file, per la lista (gratis)
	Size int64  `json:"size"`
}

func (s *Server) handleMods(_ http.ResponseWriter, r *http.Request, _ Identity) (any, error) {
	id := r.PathValue("id")
	return s.cachedFor(id, "mods", func() (any, error) {
		head, err := s.Store.Head(id)
		if err != nil {
			return nil, err
		}
		man, err := s.Store.ManifestAt(id, head)
		if err != nil {
			return nil, err
		}
		var mods []modListItem
		var total int64
		for path, fm := range man {
			rest, ok := strings.CutPrefix(path, "mods/")
			if !ok || strings.Contains(rest, "/") || !strings.HasSuffix(rest, ".jar") {
				continue
			}
			mods = append(mods, modListItem{File: rest, Name: prettyModName(rest), Size: fm.Size})
			total += fm.Size
		}
		sort.Slice(mods, func(i, j int) bool { return strings.ToLower(mods[i].Name) < strings.ToLower(mods[j].Name) })
		if mods == nil {
			mods = []modListItem{}
		}
		return map[string]any{"mods": mods, "count": len(mods), "totalBytes": total}, nil
	})
}

func (s *Server) handleModDetail(_ http.ResponseWriter, r *http.Request, _ Identity) (any, error) {
	id, file := r.PathValue("id"), r.PathValue("file")
	if !safeJarName(file) {
		return nil, i18n.Errorf("%w: nome jar non valido", store.ErrBadRequest)
	}
	return s.cachedFor(id, "mod:"+file, func() (any, error) {
		info, _, err := s.modInfo(id, file)
		if errors.Is(err, store.ErrNotFound) {
			return nil, err
		}
		if err != nil {
			// jar senza metadati (libreria, coremod): almeno il nome-file
			return map[string]any{"name": prettyModName(file), "hasIcon": false}, nil
		}
		return map[string]any{
			"id": info.ID, "name": info.Name, "version": info.Version,
			"description": info.Description, "authors": info.Authors,
			"homepage": info.Homepage, "license": info.License,
			"loader": info.Loader, "hasIcon": info.HasIcon(),
		}, nil
	})
}

func (s *Server) handleModIcon(w http.ResponseWriter, r *http.Request, _ Identity) {
	id, file := r.PathValue("id"), r.PathValue("file")
	if !safeJarName(file) {
		jsonError(w, r, http.StatusBadRequest, "nome jar non valido")
		return
	}
	fm, ok, err := s.Store.HeadFile(id, "mods/"+file)
	if err != nil || !ok {
		jsonError(w, r, http.StatusNotFound, "mod non trovata")
		return
	}
	// cache per hash del jar: la stessa mod in più generazioni/spazi si
	// estrae una volta sola
	ic, hit := s.icons.get(fm.Hash)
	if !hit {
		ic = s.extractIcon(id, fm)
		s.icons.put(fm.Hash, ic)
	}
	if ic.data == nil {
		jsonError(w, r, http.StatusNotFound, "nessuna icona")
		return
	}
	w.Header().Set("Content-Type", ic.ct)
	w.Header().Set("Cache-Control", "max-age=86400")
	w.Write(ic.data)
}

// modInfo legge i metadati di un jar di HEAD senza caricarlo in RAM.
func (s *Server) modInfo(id, file string) (mcmeta.ModInfo, store.FileMeta, error) {
	fm, ok, err := s.Store.HeadFile(id, "mods/"+file)
	if err != nil {
		return mcmeta.ModInfo{}, fm, err
	}
	if !ok {
		return mcmeta.ModInfo{}, fm, store.ErrNotFound
	}
	ra, err := s.Store.OpenFileAt(id, fm, maxJarBytes)
	if err != nil {
		return mcmeta.ModInfo{}, fm, err
	}
	defer ra.Close()
	info, err := mcmeta.ReadModJarAt(ra, ra.Size())
	return info, fm, err
}

// extractIcon estrae il logo di un jar (data nil = nessuna icona).
func (s *Server) extractIcon(id string, fm store.FileMeta) iconEntry {
	ra, err := s.Store.OpenFileAt(id, fm, maxJarBytes)
	if err != nil {
		return iconEntry{}
	}
	defer ra.Close()
	info, err := mcmeta.ReadModJarAt(ra, ra.Size())
	if err != nil || !info.HasIcon() {
		return iconEntry{}
	}
	data, ct, err := mcmeta.ExtractModIconAt(ra, ra.Size(), info.IconPath())
	if err != nil {
		return iconEntry{}
	}
	return iconEntry{data: data, ct: ct}
}

// --- cache LRU delle icone delle mod ---

const (
	iconCacheEntries = 256
	iconCacheBytes   = 16 << 20
)

type iconEntry struct {
	data []byte // nil = il jar non ha icona (si memorizza anche l'assenza)
	ct   string
}

type iconCache struct {
	mu    sync.Mutex
	ll    *list.List // fronte = più recente; valori *iconItem
	items map[string]*list.Element
	bytes int
}

type iconItem struct {
	key string
	val iconEntry
}

func (c *iconCache) get(key string) (iconEntry, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if el, ok := c.items[key]; ok {
		c.ll.MoveToFront(el)
		return el.Value.(*iconItem).val, true
	}
	return iconEntry{}, false
}

func (c *iconCache) put(key string, v iconEntry) {
	if len(v.data) > iconCacheBytes/4 {
		return // troppo grande per valere la cache
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.items == nil {
		c.items, c.ll = map[string]*list.Element{}, list.New()
	}
	if el, ok := c.items[key]; ok {
		c.bytes -= len(el.Value.(*iconItem).val.data)
		c.ll.Remove(el)
		delete(c.items, key)
	}
	c.items[key] = c.ll.PushFront(&iconItem{key: key, val: v})
	c.bytes += len(v.data)
	for c.ll.Len() > iconCacheEntries || c.bytes > iconCacheBytes {
		el := c.ll.Back()
		it := el.Value.(*iconItem)
		c.ll.Remove(el)
		delete(c.items, it.key)
		c.bytes -= len(it.val.data)
	}
}

// prettyModName ricava un nome leggibile dal nome del jar: toglie estensione
// e coda di versione, sostituisce separatori.
func prettyModName(file string) string {
	name := strings.TrimSuffix(file, ".jar")
	// taglia dalla prima parte che sembra una versione (inizia con una cifra)
	parts := strings.FieldsFunc(name, func(r rune) bool { return r == '-' || r == '_' || r == '+' })
	var keep []string
	for _, p := range parts {
		if p != "" && p[0] >= '0' && p[0] <= '9' {
			break
		}
		keep = append(keep, p)
	}
	if len(keep) == 0 {
		return name
	}
	return strings.Join(keep, " ")
}

func safeJarName(f string) bool {
	return f != "" && strings.HasSuffix(f, ".jar") &&
		!strings.ContainsAny(f, "/\\") && !strings.Contains(f, "..")
}
