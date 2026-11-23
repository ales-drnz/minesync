#!/usr/bin/env bash
# Controlla che la chiave privata di firma degli aggiornamenti (base64 del
# seme ed25519 di 32 byte, KEY) e la pubblica (base64, PUB) siano una coppia:
# firma un messaggio con la prima e lo verifica con la seconda. Non stampa
# mai la chiave privata. Uso: KEY=... PUB=... tools/check_keys.sh
set -euo pipefail
: "${KEY:?manca KEY}" "${PUB:?manca PUB}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
umask 077
printf '%s' "$KEY" | base64 -d >"$tmp/seed" 2>/dev/null || { echo "chiave privata: base64 non valido" >&2; exit 1; }
printf '%s' "$PUB" | base64 -d >"$tmp/pub" 2>/dev/null || { echo "chiave pubblica: base64 non valido" >&2; exit 1; }
[ "$(wc -c <"$tmp/seed")" -eq 32 ] || { echo "chiave privata: attesi 32 byte" >&2; exit 1; }
[ "$(wc -c <"$tmp/pub")" -eq 32 ] || { echo "chiave pubblica: attesi 32 byte" >&2; exit 1; }
# PKCS#8 e SubjectPublicKeyInfo ed25519 attorno ai 32 byte
{ printf '302e020100300506032b657004220420' | xxd -r -p; cat "$tmp/seed"; } >"$tmp/key.der"
{ printf '302a300506032b6570032100' | xxd -r -p; cat "$tmp/pub"; } >"$tmp/pub.der"
openssl pkey -inform DER -in "$tmp/key.der" -out "$tmp/key.pem" 2>/dev/null
openssl pkey -pubin -inform DER -in "$tmp/pub.der" -out "$tmp/pub.pem" 2>/dev/null
printf 'minesync: prova della coppia di chiavi\n' >"$tmp/msg"
openssl pkeyutl -sign -inkey "$tmp/key.pem" -rawin -in "$tmp/msg" -out "$tmp/sig"
if openssl pkeyutl -verify -pubin -inkey "$tmp/pub.pem" -rawin -in "$tmp/msg" -sigfile "$tmp/sig" >/dev/null 2>&1; then
	echo "chiavi di firma: la privata e la pubblica sono una coppia"
else
	echo "chiavi di firma: la privata NON corrisponde alla pubblica" >&2
	exit 1
fi
