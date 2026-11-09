package mcmeta

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/url"
	"strings"
)

// ModInfo sono i metadati di una mod estratti dal suo jar.
type ModInfo struct {
	ID          string `json:"id,omitempty"`
	Name        string `json:"name,omitempty"`
	Version     string `json:"version,omitempty"`
	Description string `json:"description,omitempty"`
	Authors     string `json:"authors,omitempty"`
	Homepage    string `json:"homepage,omitempty"` // sito ufficiale (dato non fidato)
	License     string `json:"license,omitempty"`
	Loader      string `json:"loader,omitempty"` // "forge" | "fabric" | "quilt"
	iconPath    string // percorso del logo dentro il jar ("" se assente)
}

// HasIcon riporta se il jar contiene un logo estraibile.
func (m ModInfo) HasIcon() bool { return m.iconPath != "" }

// IconPath è il percorso del logo dentro il jar (per ExtractModIcon).
func (m ModInfo) IconPath() string { return m.iconPath }

var maxModIcon = int64(4 << 20)

// ReadModJar legge i metadati di un jar in memoria (vedi ReadModJarAt).
func ReadModJar(data []byte) (ModInfo, error) {
	return ReadModJarAt(bytes.NewReader(data), int64(len(data)))
}

// ReadModJarAt apre un jar con accesso casuale e ne legge i metadati: prima
// Forge/NeoForge (mods.toml), poi Fabric/Quilt (json). Legge solo la
// directory centrale e le voci che servono, mai l'intero jar. L'icona non
// viene estratta qui — solo il suo percorso, per l'endpoint dedicato.
func ReadModJarAt(r io.ReaderAt, size int64) (ModInfo, error) {
	zr, err := zip.NewReader(r, size)
	if err != nil {
		return ModInfo{}, err
	}
	files := map[string]*zip.File{}
	for _, f := range zr.File {
		files[f.Name] = f
	}
	for _, name := range []string{"META-INF/mods.toml", "META-INF/neoforge.mods.toml"} {
		if f := files[name]; f != nil {
			if b, err := readZipEntry(f, 1<<20); err == nil {
				return parseModsToml(string(b)), nil
			}
		}
	}
	for _, name := range []string{"fabric.mod.json", "quilt.mod.json"} {
		if f := files[name]; f != nil {
			if b, err := readZipEntry(f, 1<<20); err == nil {
				return parseFabricJSON(b), nil
			}
		}
	}
	return ModInfo{}, errors.New("nessun metadato di mod nel jar")
}

// ExtractModIcon estrae il logo (percorso noto da ReadModJar) da un jar.
func ExtractModIcon(data []byte, iconPath string) ([]byte, string, error) {
	return ExtractModIconAt(bytes.NewReader(data), int64(len(data)), iconPath)
}

// ExtractModIconAt è ExtractModIcon con accesso casuale (legge solo il logo).
func ExtractModIconAt(r io.ReaderAt, size int64, iconPath string) ([]byte, string, error) {
	if iconPath == "" {
		return nil, "", errors.New("nessuna icona")
	}
	zr, err := zip.NewReader(r, size)
	if err != nil {
		return nil, "", err
	}
	for _, f := range zr.File {
		if strings.EqualFold(f.Name, iconPath) {
			b, err := readZipEntry(f, maxModIcon)
			return b, iconType(iconPath), err
		}
	}
	return nil, "", errors.New("icona non trovata nel jar")
}

func readZipEntry(f *zip.File, max int64) ([]byte, error) {
	rc, err := f.Open()
	if err != nil {
		return nil, err
	}
	defer rc.Close()
	return io.ReadAll(io.LimitReader(rc, max))
}

func iconType(path string) string {
	switch {
	case strings.HasSuffix(strings.ToLower(path), ".jpg"), strings.HasSuffix(strings.ToLower(path), ".jpeg"):
		return "image/jpeg"
	case strings.HasSuffix(strings.ToLower(path), ".gif"):
		return "image/gif"
	default:
		return "image/png"
	}
}

// --- Fabric / Quilt: JSON ---

func parseFabricJSON(b []byte) ModInfo {
	var raw struct {
		ID          string          `json:"id"`
		Name        string          `json:"name"`
		Version     string          `json:"version"`
		Description string          `json:"description"`
		License     json.RawMessage `json:"license"`
		Authors     json.RawMessage `json:"authors"`
		Icon        json.RawMessage `json:"icon"`
		Contact     struct {
			Homepage string `json:"homepage"`
		} `json:"contact"`
	}
	json.Unmarshal(b, &raw)
	m := ModInfo{
		ID: raw.ID, Name: raw.Name, Version: raw.Version,
		Description: raw.Description, Homepage: safeURL(raw.Contact.Homepage), Loader: "fabric",
	}
	if m.Name == "" {
		m.Name = raw.ID
	}
	m.License = firstString(raw.License)
	m.Authors = joinAuthors(raw.Authors)
	m.iconPath = fabricIcon(raw.Icon)
	return m
}

// fabricIcon: "icon" è una stringa, o un oggetto dimensione→percorso.
func fabricIcon(raw json.RawMessage) string {
	if s := firstString(raw); s != "" {
		return s
	}
	var obj map[string]string
	if json.Unmarshal(raw, &obj) == nil {
		best := ""
		for _, v := range obj {
			best = v // una qualsiasi va bene per l'anteprima
		}
		return best
	}
	return ""
}

func firstString(raw json.RawMessage) string {
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	return ""
}

// joinAuthors accetta ["A", {"name":"B"}] o una stringa singola.
func joinAuthors(raw json.RawMessage) string {
	var arr []json.RawMessage
	if json.Unmarshal(raw, &arr) != nil {
		return firstString(raw)
	}
	var names []string
	for _, e := range arr {
		if s := firstString(e); s != "" {
			names = append(names, s)
			continue
		}
		var obj struct {
			Name string `json:"name"`
		}
		if json.Unmarshal(e, &obj) == nil && obj.Name != "" {
			names = append(names, obj.Name)
		}
	}
	return strings.Join(names, ", ")
}

// --- Forge / NeoForge: mods.toml (sottoinsieme di TOML) ---
//
// Serve solo estrarre logoFile/license a livello file e i campi del primo
// blocco [[mods]]. Gestisce stringhe base ("..."), letterali ('...') e
// multi-riga (”'...”' / """..."""), ignorando le altre tabelle.
func parseModsToml(s string) ModInfo {
	var m ModInfo
	m.Loader = "forge"
	section := "" // "", "mods", "other"
	seenMod := false

	lines := strings.Split(s, "\n")
	for i := 0; i < len(lines); i++ {
		line := strings.TrimSpace(stripTomlComment(lines[i]))
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "[") {
			header := strings.Trim(line, "[]")
			switch {
			case header == "mods":
				if seenMod {
					section = "done" // prendiamo solo il primo mod
				} else {
					section, seenMod = "mods", true
				}
			default:
				if section == "mods" {
					section = "done"
				} else if section != "done" {
					section = "other"
				}
			}
			continue
		}
		key, rawVal, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		key = strings.TrimSpace(key)
		val, consumed := tomlValue(strings.TrimSpace(rawVal), lines, i)
		i += consumed
		switch section {
		case "": // proprietà a livello file
			switch key {
			case "logoFile":
				m.iconPath = val
			case "license":
				m.License = val
			}
		case "mods":
			switch key {
			case "modId":
				m.ID = val
			case "displayName":
				m.Name = val
			case "version":
				m.Version = val
			case "description":
				m.Description = val
			case "authors":
				m.Authors = val
			case "displayURL":
				m.Homepage = val
			}
		}
	}
	if m.Name == "" {
		m.Name = m.ID
	}
	m.Description = strings.TrimSpace(m.Description)
	m.Homepage = safeURL(m.Homepage)
	return m
}

// safeURL accetta solo link http/https assoluti: i metadati del jar non sono
// fidati e un "javascript:" finirebbe in un href della web UI.
func safeURL(s string) string {
	s = strings.TrimSpace(s)
	u, err := url.Parse(s)
	if err != nil || u.Host == "" || (u.Scheme != "http" && u.Scheme != "https") {
		return ""
	}
	return u.String()
}

// tomlValue estrae il valore stringa, gestendo i multi-riga. Ritorna anche
// quante righe extra ha consumato.
func tomlValue(v string, lines []string, i int) (string, int) {
	for _, q := range []string{"'''", `"""`} {
		if strings.HasPrefix(v, q) {
			rest := v[len(q):]
			if end := strings.Index(rest, q); end >= 0 {
				return rest[:end], 0
			}
			var sb strings.Builder
			sb.WriteString(strings.TrimPrefix(rest, "\n"))
			for j := i + 1; j < len(lines); j++ {
				if end := strings.Index(lines[j], q); end >= 0 {
					sb.WriteString("\n" + lines[j][:end])
					return strings.TrimSpace(sb.String()), j - i
				}
				sb.WriteString("\n" + lines[j])
			}
			return strings.TrimSpace(sb.String()), len(lines) - 1 - i
		}
	}
	if len(v) >= 2 && (v[0] == '"' || v[0] == '\'') {
		q := v[0]
		if end := strings.IndexByte(v[1:], q); end >= 0 {
			return v[1 : 1+end], 0
		}
	}
	return strings.Trim(v, `"'`), 0
}

// stripTomlComment toglie un commento # non dentro una stringa (euristica
// sufficiente per mods.toml, che non ha # dentro i valori che leggiamo).
func stripTomlComment(line string) string {
	inStr := byte(0)
	for i := 0; i < len(line); i++ {
		c := line[i]
		switch {
		case inStr != 0:
			if c == inStr {
				inStr = 0
			}
		case c == '"' || c == '\'':
			inStr = c
		case c == '#':
			return line[:i]
		}
	}
	return line
}
