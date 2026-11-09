package version

import "testing"

func TestCompare(t *testing.T) {
	cases := []struct {
		a, b string
		want int
		ok   bool
	}{
		{"1.2.3", "1.2.3", 0, true},
		{"v1.2.3", "1.2.3", 0, true},
		{"1.2.4", "1.2.3", 1, true},
		{"1.10.0", "1.9.9", 1, true}, // numerico, non lessicografico
		{"2.0.0", "10.0.0", -1, true},
		{"3.0.0-rc.1", "3.0.0", -1, true},
		{"3.0.0", "3.0.0-rc.1", 1, true},
		{"3.0.0-rc.2", "3.0.0-rc.10", -1, true},
		{"3.0.0-alpha", "3.0.0-alpha.1", -1, true},
		{"3.0.0-1", "3.0.0-alpha", -1, true},
		{"1.2.3+build.5", "1.2.3", 0, true},
		{"dev", "1.0.0", 0, false},
		{"1.0.0", "dev", 0, false},
		{"1.2", "1.2.0", 0, false},
		{"01.2.3", "1.2.3", 0, false},
		{"1.2.3-", "1.2.3", 0, false},
		{"", "1.2.3", 0, false},
	}
	for _, c := range cases {
		got, ok := Compare(c.a, c.b)
		if got != c.want || ok != c.ok {
			t.Errorf("Compare(%q,%q) = %d,%v; atteso %d,%v", c.a, c.b, got, ok, c.want, c.ok)
		}
	}
}

func TestNewer(t *testing.T) {
	if !Newer("3.0.1", "3.0.0") {
		t.Error("3.0.1 deve essere più nuova di 3.0.0")
	}
	if Newer("2.9.0", "3.0.0") {
		t.Error("mai downgrade")
	}
	if Newer("3.0.0", "3.0.0") {
		t.Error("stessa versione: niente update")
	}
	if Newer("9.9.9", "dev") || Newer("dev", "1.0.0") {
		t.Error("le build dev non si aggiornano e non sono un target")
	}
}

func TestDisplay(t *testing.T) {
	old := Client
	defer func() { Client = old }()
	Client = "dev"
	if Display() != "dev" {
		t.Errorf("Display dev = %q", Display())
	}
	Client = "3.0.0"
	if Display() != "v3.0.0" {
		t.Errorf("Display = %q", Display())
	}
	Client = "v3.0.0"
	if Display() != "v3.0.0" {
		t.Errorf("Display con prefisso = %q", Display())
	}
}
