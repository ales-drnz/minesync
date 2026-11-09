package mcmeta

import (
	"archive/zip"
	"bytes"
	"testing"
)

func makeJar(t *testing.T, entries map[string][]byte) []byte {
	t.Helper()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	for name, body := range entries {
		w, err := zw.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		w.Write(body)
	}
	zw.Close()
	return buf.Bytes()
}

func TestReadForgeMod(t *testing.T) {
	toml := `
modLoader="javafml"
license="MIT"
logoFile="create.png"
[[mods]]
modId="gearworks"
version="0.5.1.f"
displayName="Gearworks"
displayURL="https://example.com/mods/gearworks"
authors="simibubi"
description='''
Automazione e macchine.
Multi-riga.
'''
[[dependencies.create]]
modId="forge"
`
	jar := makeJar(t, map[string][]byte{
		"META-INF/mods.toml": []byte(toml),
		"create.png":         []byte("PNGDATA"),
	})
	m, err := ReadModJar(jar)
	if err != nil {
		t.Fatal(err)
	}
	if m.Name != "Gearworks" || m.Version != "0.5.1.f" || m.ID != "gearworks" {
		t.Fatalf("campi base: %+v", m)
	}
	if m.Homepage == "" || m.Authors != "simibubi" || m.License != "MIT" {
		t.Fatalf("homepage/autori/licenza: %+v", m)
	}
	if !contains(m.Description, "Automazione") || !contains(m.Description, "Multi-riga") {
		t.Fatalf("descrizione multi-riga: %q", m.Description)
	}
	if !m.HasIcon() {
		t.Fatal("icona non rilevata")
	}
	icon, ct, err := ExtractModIcon(jar, m.iconPath)
	if err != nil || string(icon) != "PNGDATA" || ct != "image/png" {
		t.Fatalf("estrazione icona: %q %q %v", icon, ct, err)
	}
}

func TestReadFabricMod(t *testing.T) {
	js := `{
	  "id":"fastrender","name":"Fast Render","version":"0.5.3",
	  "description":"Ottimizza il rendering.",
	  "license":"LGPL-3.0",
	  "authors":["JellySquid",{"name":"Contributor"}],
	  "contact":{"homepage":"https://example.com/mods/fastrender"},
	  "icon":"assets/fastrender/icon.png"
	}`
	jar := makeJar(t, map[string][]byte{
		"fabric.mod.json":            []byte(js),
		"assets/fastrender/icon.png": []byte("ICON"),
	})
	m, err := ReadModJar(jar)
	if err != nil {
		t.Fatal(err)
	}
	if m.Name != "Fast Render" || m.Version != "0.5.3" || m.Loader != "fabric" {
		t.Fatalf("campi base: %+v", m)
	}
	if m.Homepage == "" || m.Authors != "JellySquid, Contributor" {
		t.Fatalf("homepage/autori: %+v", m)
	}
	if _, _, err := ExtractModIcon(jar, m.iconPath); err != nil {
		t.Fatalf("icona fabric: %v", err)
	}
}

func contains(s, sub string) bool { return bytes.Contains([]byte(s), []byte(sub)) }
