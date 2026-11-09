package syncx

import "testing"

// R4: i pattern "x/**" devono accettare glob in ogni segmento, "**" deve
// valere a qualunque profondità, e su Windows il confronto ignora le
// maiuscole.
func TestMatcherGlobPerSegmento(t *testing.T) {
	defaults := []string{
		"logs/**", "crash-reports/**", "simplebackups/**",
		"session.lock", "**/session.lock", "*.lock",
		".minesync*", "tui/**",
		"world_backup*/**", "**/logs/**", "config/*.bak", "# commento", "",
	}
	cases := []struct {
		path string
		want bool
	}{
		{"world_backup_2024/region/r.0.0.mca", true},
		{"world_backup/level.dat", true},
		{"world_backup", true},
		{"world/region/r.0.0.mca", false},
		{"my_world_backup/x", false},
		{"logs/latest.log", true},
		{"mods/foo/logs/debug.log", true},
		{"a/b/c/logs/x/y.txt", true},
		{"logsx/file.txt", false},
		{"catalogs/x.txt", false},
		{"world/session.lock", true},
		{"session.lock", true},
		{"x.lock", true},
		{"config/ars.bak", true},
		{"config/sub/ars.bak", false},
		{"config/ars.toml", false},
		{".minesync-state", true},
		{"tui/bin/tool.exe", true},
		{"crash-reports/c.txt", true},
	}
	m := newMatcher(defaults, false)
	for _, c := range cases {
		if got := m.Match(c.path); got != c.want {
			t.Errorf("Match(%q) = %v, atteso %v", c.path, got, c.want)
		}
	}

	dirs := []struct {
		dir  string
		want bool
	}{
		{"world_backup_2024", true},
		{"world_backup_2024/region", true},
		{"logs", true},
		{"mods/foo/logs", true},
		{"world", false},
		{"config", false},
		{"x.lock", false}, // "*.lock" esclude file, non cartelle
	}
	for _, c := range dirs {
		if got := m.MatchDir(c.dir); got != c.want {
			t.Errorf("MatchDir(%q) = %v, atteso %v", c.dir, got, c.want)
		}
	}
}

func TestMatcherNomeEsattoPotaCartelle(t *testing.T) {
	m := newMatcher([]string{"node_modules", "**/cache"}, false)
	for _, p := range []string{"node_modules/a.js", "x/node_modules/b/c.js", "mods/cache/x.bin", "cache"} {
		if !m.Match(p) {
			t.Errorf("Match(%q) = false", p)
		}
	}
	if !m.MatchDir("x/node_modules") || !m.MatchDir("a/cache") {
		t.Error("MatchDir non pota i nomi esatti")
	}
}

func TestMatcherMaiuscoleWindows(t *testing.T) {
	win := newMatcher([]string{"Logs/**", "*.LOCK", "World_Backup*/**"}, true)
	unix := newMatcher([]string{"Logs/**", "*.LOCK", "World_Backup*/**"}, false)
	for _, p := range []string{"logs/latest.log", "LOGS/x", "session.lock", "world_backup_1/r.mca"} {
		if !win.Match(p) {
			t.Errorf("windows: Match(%q) = false", p)
		}
		if unix.Match(p) {
			t.Errorf("unix: Match(%q) = true (deve distinguere le maiuscole)", p)
		}
	}
	if !win.Match("Logs\\latest.log") {
		t.Error("windows: separatore \\ non normalizzato")
	}
}

func TestMatcherNil(t *testing.T) {
	var m *Matcher
	if m.Match("a") || m.MatchDir("a") {
		t.Error("un matcher nil non deve escludere niente")
	}
}

func TestValidRel(t *testing.T) {
	ok := []string{"a", "a/b.txt", "world/region/r.0.0.mca", ".minesync", "a..b/c"}
	bad := []string{"", "/a", "../a", "a/../../b", "a/./b", "./a", "a//b", "a/", "C:/x", "c:x", "a\\b", "a/\x00"}
	for _, p := range ok {
		if !validRel(p) {
			t.Errorf("validRel(%q) = false", p)
		}
	}
	for _, p := range bad {
		if validRel(p) {
			t.Errorf("validRel(%q) = true", p)
		}
	}
}
