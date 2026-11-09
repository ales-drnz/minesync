package mc

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Layout sintetici dei server pack che si incontrano davvero. Il requisito è
// uno solo: da ognuno di questi MineSync deve sapere come partire. Prima
// metà di questi casi finiva in "nessuno start script trovato".
func mk(t *testing.T, dir string, files map[string]string) string {
	t.Helper()
	for p, c := range files {
		full := filepath.Join(dir, filepath.FromSlash(p))
		os.MkdirAll(filepath.Dir(full), 0o755)
		os.WriteFile(full, []byte(c), 0o644)
	}
	return dir
}

func TestInspectSuLayoutReali(t *testing.T) {
	casi := []struct {
		nome     string
		mcAtteso string
		files    map[string]string
	}{
		{"forge 1.20.1 (server pack CurseForge, mai avviato)", "1.20.1", map[string]string{
			"run.sh":            "#!/usr/bin/env bash\njava @user_jvm_args.txt @libraries/net/minecraftforge/forge/1.20.1-47.3.0/unix_args.txt \"$@\"\n",
			"run.bat":           "java @user_jvm_args.txt @libraries/...\r\n",
			"user_jvm_args.txt": "-Xmx6G\n",
			"libraries/net/minecraftforge/forge/1.20.1-47.3.0/unix_args.txt": "-cp\nlibraries/...\n",
			"server.properties": "server-port=25565\n",
		}},
		{"neoforge 1.21.1", "1.21.1", map[string]string{
			"run.sh": "#!/usr/bin/env bash\njava @user_jvm_args.txt @libraries/net/neoforged/neoforge/21.1.79/unix_args.txt \"$@\"\n",
			"libraries/net/neoforged/neoforge/21.1.79/unix_args.txt": "-cp\n...\n",
			"server.properties": "server-port=25565\n",
		}},
		{"fabric senza script (solo launcher jar)", "", map[string]string{
			"fabric-server-launch.jar":          "PK",
			"fabric-server-launcher.properties": "serverJar=server.jar\n",
			"server.properties":                 "server-port=25565\n",
		}},
		{"fabric gia' avviato (librerie presenti)", "1.21.1", map[string]string{
			"fabric-server-launch.jar": "PK",
			"libraries/net/fabricmc/intermediary/1.21.1/intermediary-1.21.1.jar": "PK",
			"server.properties": "server-port=25565\n",
		}},
		{"forge 1.12.2 vecchio stile", "1.12.2", map[string]string{
			"ServerStart.sh":                "#!/bin/bash\njava -jar forge-1.12.2-14.23.5.2860.jar nogui\n",
			"ServerStart.bat":               "java -jar forge...\r\n",
			"settings.sh":                   "MAX_RAM=\"6G\"\n",
			"forge-1.12.2-14.23.5.2860.jar": "PK",
			"minecraft_server.1.12.2.jar":   "PK",
			"server.properties":             "server-port=25565\n",
		}},
		{"vanilla/paper: solo il jar", "", map[string]string{
			"server.jar":        "PK",
			"server.properties": "server-port=25565\n",
		}},
		{"pack preparato su windows, host linux", "", map[string]string{
			"start.bat":         "java -Xmx8G -jar server.jar nogui\r\npause\r\n",
			"server.jar":        "PK",
			"server.properties": "server-port=25565\n",
		}},
		{"piu' script candidati insieme", "", map[string]string{
			"run.sh":            "#!/bin/sh\njava @user_jvm_args.txt\n",
			"start.sh":          "#!/bin/sh\necho script sbagliato: e' un helper\n",
			"server.properties": "server-port=25565\n",
		}},
	}
	for _, c := range casi {
		dir := mk(t, t.TempDir(), c.files)
		info := Inspect(dir)
		avvio := "NON PARTE"
		if len(info.Launch) > 0 {
			avvio = strings.Join(info.Launch, " ")
		}
		req := RequiredMajor(info.MCVersion)
		if info.JavaMajor > 0 {
			req = info.JavaMajor
		}
		t.Logf("%-42s avvio=%-34s loader=%-8s mc=%-8s java=%d",
			c.nome, avvio, orQ(info.Loader), orQ(info.MCVersion), req)
		if len(info.Launch) == 0 {
			t.Errorf("%s: MineSync non saprebbe come avviarlo", c.nome)
		}
		if c.mcAtteso != "" && info.MCVersion != c.mcAtteso {
			t.Errorf("%s: versione Minecraft = %q, attesa %q (senza, il Java scelto è a caso)",
				c.nome, info.MCVersion, c.mcAtteso)
		}
	}
}

func orQ(s string) string {
	if s == "" {
		return "?"
	}
	return s
}

// Gli zip dei server pack avvolgono tutto in una cartella: estratti così,
// in radice non c'è niente da avviare.
func TestInspectScendeNellaSottocartella(t *testing.T) {
	root := t.TempDir()
	mk(t, root, map[string]string{
		"Modpack-Server/run.sh":            "#!/bin/sh\njava @user_jvm_args.txt\n",
		"Modpack-Server/server.properties": "server-port=25565\n",
	})
	info := Inspect(root)
	if len(info.Launch) == 0 {
		t.Fatal("server dentro una sottocartella: non trovato")
	}
	if filepath.Base(info.Dir) != "Modpack-Server" {
		t.Errorf("cartella di lavoro sbagliata: %s", info.Dir)
	}
}
