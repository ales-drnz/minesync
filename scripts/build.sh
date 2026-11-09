#!/bin/sh
# Compila hub e client. Unico punto di verità per versione e ldflags:
# lo usano a mano, il Dockerfile e la CI.
#
#   scripts/build.sh            → hub + tutti i client in ./dist
#
# Variabili (tutte opzionali):
#   OUT                      cartella di output (default ./dist)
#   HUB_TARGETS              es. "linux/amd64 linux/arm64" ("" = niente hub)
#   CLIENT_TARGETS           es. "windows/amd64 linux/amd64" ("" = niente client)
#   MINESYNC_DEFAULT_SERVER  indirizzo hub precompilato nei client (es. http://10.0.0.1:8084)
#   MINESYNC_SIGN_KEY        file .key (vedi scripts/sign): firma SHA256SUMS e
#                            incorpora la chiave pubblica nei client
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
out="${OUT:-$root/dist}"
version="$(tr -d ' \r\n' < "$root/VERSION")"
hub_targets="${HUB_TARGETS-linux/amd64 linux/arm64}"
client_targets="${CLIENT_TARGETS-windows/amd64 linux/amd64 linux/arm64 darwin/arm64 darwin/amd64}"

export CGO_ENABLED=0 GOWORK=off GOFLAGS="${GOFLAGS:-} -trimpath -buildvcs=false"
mkdir -p "$out/dl"

signtool=""
pubkey=""
if [ -n "${MINESYNC_SIGN_KEY:-}" ]; then
	signtool="$out/.sign-tool"
	(cd "$root/scripts/sign" && GOOS= GOARCH= go build -o "$signtool" .)
	pubkey="$("$signtool" pubkey "$MINESYNC_SIGN_KEY")"
fi

for t in $hub_targets; do
	os="${t%/*}" arch="${t#*/}"
	echo "==> hub $os/$arch ($version)"
	(cd "$root/server" && GOOS=$os GOARCH=$arch go build \
		-ldflags="-s -w -X minesync/server/internal/api.Version=$version" \
		-o "$out/minesync-hub-$os-$arch" .)
done

client_ldflags="-s -w -X minesync/client/internal/version.Client=$version"
client_ldflags="$client_ldflags -X minesync/client/internal/config.DefaultServer=${MINESYNC_DEFAULT_SERVER:-}"
client_ldflags="$client_ldflags -X minesync/client/internal/selfupdate.PublicKey=$pubkey"
for t in $client_targets; do
	os="${t%/*}" arch="${t#*/}"
	ext=""
	[ "$os" = windows ] && ext=".exe"
	echo "==> client $os/$arch ($version)"
	(cd "$root/client" && GOOS=$os GOARCH=$arch go build -ldflags="$client_ldflags" \
		-o "$out/dl/minesync-$os-$arch$ext" .)
done

if [ -n "$client_targets" ]; then
	if [ -z "$signtool" ]; then
		signtool="$out/.sign-tool"
		(cd "$root/scripts/sign" && GOOS= GOARCH= go build -o "$signtool" .)
	fi
	"$signtool" sums "$out/dl"
	if [ -n "${MINESYNC_SIGN_KEY:-}" ]; then
		"$signtool" sign "$MINESYNC_SIGN_KEY" "$out/dl/SHA256SUMS"
		echo "==> SHA256SUMS firmato"
	else
		echo "==> SHA256SUMS NON firmato (MINESYNC_SIGN_KEY non impostata)"
	fi
fi
rm -f "$out/.sign-tool"
echo "Fatto: $out"
