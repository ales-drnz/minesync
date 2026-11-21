#!/usr/bin/env bash
# Spike SHA-256: compila in AOT, esegue correttezza + benchmark + criteri.
# Exit 0 solo se tutti i criteri passano.
#   HASH_SPIKE_DATA=dir   dove generare i ~3,3 GiB di dati (default .tmp/data;
#                         meglio un tmpfs per non misurare il disco)
#   HASH_SPIKE_QUICK=1    fallback puri misurati su 256 MiB invece di 1 GiB
#   HASH_SPIKE_DOCKER=1   prova anche il binario in debian:stable-slim
#                         (nativo) e debian:bookworm (senza libcrypto -> fallback)
set -euo pipefail
cd "$(dirname "$0")"
DATA="${HASH_SPIKE_DATA:-.tmp/data}"
mkdir -p .tmp
dart pub get >/dev/null
dart analyze --fatal-infos
dart compile exe bin/bench.dart -o .tmp/bench >/dev/null
ARGS=(all --data "$DATA")
[[ "${HASH_SPIKE_QUICK:-0}" == 1 ]] && ARGS+=(--quick)
rc=0
.tmp/bench "${ARGS[@]}" || rc=1
if [[ "${HASH_SPIKE_DOCKER:-0}" == 1 ]]; then
  B="$PWD/.tmp/bench"
  echo "== docker debian:stable-slim (atteso: backend openssl)"
  out=$(docker run --rm -v "$B:/bench:ro" debian:stable-slim /bench correctness --data /tmp/d/data 2>&1) || rc=1
  echo "$out"; grep -q 'backend=openssl' <<<"$out" || rc=1
  echo "== docker debian:bookworm (senza libcrypto, atteso: fallback crypto)"
  out=$(docker run --rm -v "$B:/bench:ro" debian:bookworm /bench correctness --data /tmp/d/data 2>&1) || rc=1
  echo "$out"; grep -q 'backend=crypto native=false' <<<"$out" || rc=1
fi
exit $rc
