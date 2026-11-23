#!/usr/bin/env bash
# Prova di fumo dell'immagine dell'hub: la avvia con un volume /data
# temporaneo e controlla API, web UI, /b/<buildId>/…, /dl e l'healthcheck.
#
#   deploy/smoke-test.sh <immagine> [--expect-dl]
#
# L'hub gira con --network host ma ascolta solo su 127.0.0.1: le richieste
# arrivano dal loopback, l'unico indirizzo che MINESYNC_DEV_USER riconosce
# (DevResolver), quindi l'identità di prova non è raggiungibile da fuori.
# --expect-dl: /dl deve contenere download firmati e update/ (immagine di
# release).
set -euo pipefail
cd "$(dirname "$0")/.."

image=${1:?uso: deploy/smoke-test.sh <immagine> [--expect-dl]}
expect_dl=0
[ "${2:-}" = --expect-dl ] && expect_dl=1
version=$(cat VERSION)
port=${SMOKE_PORT:-18084}
name=minesync-smoke-$$
vol=minesync-smoke-$$
base=http://127.0.0.1:$port
tmp=$(mktemp -d)

cleanup() {
	status=$?
	if [ $status -ne 0 ]; then
		echo "== log dell'hub"
		docker logs "$name" 2>&1 | tail -50 || true
	fi
	docker rm -f "$name" >/dev/null 2>&1 || true
	docker volume rm "$vol" >/dev/null 2>&1 || true
	rm -rf "$tmp"
	exit $status
}
trap cleanup EXIT

fail() {
	echo "FALLITO: $*" >&2
	exit 1
}

# get <percorso> <file>: stampa lo stato HTTP, corpo in <file>, intestazioni in <file>.h
get() {
	curl -sS --compressed -o "$2" -D "$2.h" -w '%{http_code}' "$base$1"
}

header() { grep -i "^$1:" "$2" | head -1 | cut -d: -f2- | tr -d '\r' | sed 's/^ *//'; }

echo "== avvio di $image"
docker volume create "$vol" >/dev/null
docker run -d --name "$name" --network host \
	-e MINESYNC_ADDR="127.0.0.1:$port" \
	-e MINESYNC_DEV_USER=alice \
	-v "$vol:/data" \
	"$image" >/dev/null

user=$(docker inspect --format '{{.Config.User}}' "$name")
[ "$user" = 65532:65532 ] || fail "utente dell'immagine $user, atteso 65532:65532"

ok=0
for _ in $(seq 1 60); do
	if curl -fsS -o /dev/null "$base/api/v1/hub" 2>/dev/null; then
		ok=1
		break
	fi
	[ "$(docker inspect --format '{{.State.Running}}' "$name")" = true ] || fail "il container si è fermato"
	sleep 1
done
[ $ok = 1 ] || fail "l'hub non risponde su $base"

echo "== GET /api/v1/hub"
code=$(get /api/v1/hub "$tmp/hub.json")
[ "$code" = 200 ] || fail "/api/v1/hub: HTTP $code"
grep -q "\"version\":\"$version\"" "$tmp/hub.json" || fail "/api/v1/hub senza version $version: $(cat "$tmp/hub.json")"
cat "$tmp/hub.json"
echo

echo "== GET /"
code=$(get / "$tmp/index.html")
[ "$code" = 200 ] || fail "/: HTTP $code (manca la web UI?)"
case "$(header content-type "$tmp/index.html.h")" in text/html*) ;; *) fail "/: content-type sbagliato" ;; esac
id=$(sed -n 's/.*<meta name="minesync-build" content="\([0-9a-f]*\)".*/\1/p' "$tmp/index.html" | head -1)
[ -n "$id" ] || fail "/: build id non sostituito"
grep -q __BUILD__ "$tmp/index.html" && fail "/: segnaposto __BUILD__ rimasto"
echo "build id $id"

echo "== GET /server/x (rotta della SPA)"
code=$(get /server/x "$tmp/spa.html")
[ "$code" = 200 ] || fail "/server/x: HTTP $code"

for f in flutter_bootstrap.js main.dart.wasm main.dart.mjs main.dart.js; do
	echo "== GET /b/$id/$f"
	code=$(get "/b/$id/$f" "$tmp/asset")
	[ "$code" = 200 ] || fail "/b/$id/$f: HTTP $code"
	header cache-control "$tmp/asset.h" | grep -q immutable || fail "/b/$id/$f: non immutabile"
done
code=$(get "/b/$id/main.dart.wasm" "$tmp/wasm")
header content-type "$tmp/wasm.h" | grep -q application/wasm || fail "main.dart.wasm: content-type sbagliato"
enc=$(header content-encoding "$tmp/wasm.h")
echo "main.dart.wasm: content-encoding ${enc:-nessuno}"

echo "== GET /api/v1/dl"
code=$(get /api/v1/dl "$tmp/dl.json")
[ "$code" = 200 ] || fail "/api/v1/dl: HTTP $code"
cat "$tmp/dl.json"
echo
if [ $expect_dl = 1 ]; then
	grep -q '"signedSums":true' "$tmp/dl.json" || fail "/api/v1/dl: SHA256SUMS non firmato"
	grep -q '"signed":true' "$tmp/dl.json" || fail "/api/v1/dl: nessun aggiornamento firmato"
	code=$(get /dl/SHA256SUMS "$tmp/sums")
	[ "$code" = 200 ] || fail "/dl/SHA256SUMS: HTTP $code"
	plat=$(sed -n 's/.*"platform":"\([a-z0-9-]*\)".*/\1/p' "$tmp/dl.json" | head -1)
	[ -n "$plat" ] || fail "/api/v1/dl: nessuna piattaforma negli aggiornamenti"
	code=$(get "/dl/update/$plat/manifest.json" "$tmp/manifest")
	[ "$code" = 200 ] || fail "/dl/update/$plat/manifest.json: HTTP $code"
	code=$(get "/dl/update/$plat/manifest.json.sig" "$tmp/manifest.sig")
	[ "$code" = 200 ] || fail "/dl/update/$plat/manifest.json.sig: HTTP $code"
fi

echo "== healthcheck"
docker exec "$name" /app/hub healthcheck || fail "hub healthcheck fallito"
health=
for _ in $(seq 1 30); do
	health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$name")
	[ "$health" = healthy ] && break
	sleep 1
done
[ "$health" = healthy ] || fail "stato di salute di Docker: ${health:-assente}"

echo "== arresto (SIGTERM)"
docker stop -t 15 "$name" >/dev/null
code=$(docker inspect --format '{{.State.ExitCode}}' "$name")
[ "$code" = 0 ] || fail "uscita $code dopo SIGTERM"

echo "OK: $image"
