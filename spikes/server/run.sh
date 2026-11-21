#!/usr/bin/env bash
# Spike server: build delle immagini e prove misurabili. Exit 0 solo se i
# criteri passano. Richiede: dart (PATH o FLUTTER_ROOT), docker, curl, dig,
# sha256sum, python3. Dati temporanei in .tmp/ (~17 GiB su disco).
#
#   ./run.sh                    tutto
#   THROUGHPUT_MODE=dart ./run.sh   criterio di throughput con package:crypto
#
# Variabili: CPUS=2 MEM=1g (limiti del container, "NAS"), THROUGHPUT_MODE
# (dart|openssl|none: modalità di hash su cui si valuta il criterio dei
# 200 MB/s; default openssl, vedi README), KEEP=1 non cancella i dati.
set -uo pipefail
cd "$(dirname "$0")"
export PATH="${FLUTTER_ROOT:-/home/alex0/development/flutter}/bin:$PATH"
CPUS=${CPUS:-2} MEM=${MEM:-1g} THROUGHPUT_MODE=${THROUGHPUT_MODE:-openssl}
T=$PWD/.tmp
PORT=18084 DNSPORT=15353
mkdir -p "$T" build
RES=$T/results.txt; : > "$RES"
FAIL=0
log() { echo "$*" | tee -a "$RES"; }
check() { # check <nome> <condizione python> <valore>
  if python3 -c "import sys; v=$3; sys.exit(0 if ($2) else 1)"; then log "  PASS $1 ($3)"; else log "  FAIL $1 ($3)"; FAIL=1; fi
}
jq_() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)"; }
MiB=$((1024*1024))

cleanup() { docker rm -f -v spike-hub spike-arm64 >/dev/null 2>&1 || true; jobs -p | xargs -r kill 2>/dev/null || true; }
trap cleanup EXIT

# ---------- build ----------
log "== build"
dart pub get >/dev/null
dart compile exe tool/bench.dart -o build/bench >/dev/null || exit 1
DOCKER_BUILDKIT=0 docker build -q -t spike-hub:amd64 -f deploy/Dockerfile . >/dev/null || exit 1
DOCKER_BUILDKIT=0 docker build -q --build-arg TARGETARCH=arm64 --build-arg TARGETPLATFORM=linux/arm64 \
  -t spike-hub:arm64 -f deploy/Dockerfile . >/dev/null || exit 1
for a in amd64 arm64; do
  sz=$(docker image inspect spike-hub:$a -f '{{.Size}}')
  arch=$(docker image inspect spike-hub:$a -f '{{.Architecture}} {{.Config.User}}')
  check "immagine $a < 80 MB [$arch]" "v < 80e6" "$sz"
done
docker rm -f spike-arm64 >/dev/null 2>&1
out=$(docker run -d --name spike-arm64 --platform linux/arm64 -p 18090:8084 -e HUB_DNS_PORT=0 spike-hub:arm64 2>&1)
sleep 3
if curl -sf localhost:18090/healthz >/dev/null; then
  log "  arm64: VERIFICATO sotto emulazione (healthz ok)"
else
  log "  arm64: NON VERIFICATO su questo host ($(docker logs spike-arm64 2>&1 | tail -1))"
fi
docker rm -f -v spike-arm64 >/dev/null 2>&1

# ---------- dati di prova ----------
log "== dati di prova"
gen() { [ -s "$1" ] || head -c $(($2*MiB)) /dev/urandom > "$1"; }
gen "$T/big.bin" 4096
for i in $(seq -w 1 16); do gen "$T/m$i.bin" 256; done
gen "$T/small.bin" 0; [ -s "$T/small.bin" ] || head -c 4096 /dev/urandom > "$T/small.bin"
[ -s "$T/sums" ] || (cd "$T" && sha256sum big.bin m*.bin small.bin > sums)
h() { awk -v f="$1" '$2==f{print $1}' "$T/sums"; }

# ---------- avvio del container ----------
start() { # start <datadir> <hash> [extra env...]
  docker rm -f -v spike-hub >/dev/null 2>&1
  mkdir -p "$1"
  docker run -d --name spike-hub --cpus="$CPUS" --memory="$MEM" --user "$(id -u):$(id -g)" \
    -v "$1:/data" -p $PORT:8084 -p $DNSPORT:53/udp -e HUB_HASH="$2" \
    -e HUB_DNS_RECORDS=alpha=192.0.2.10:25565,beta=192.0.2.20:25570,gamma= "${@:3}" \
    spike-hub:amd64 >/dev/null
  for _ in $(seq 50); do curl -sf localhost:$PORT/healthz >/dev/null && return 0; sleep 0.1; done
  echo "hub non partito"; docker logs spike-hub; exit 1
}
stats() { curl -s localhost:$PORT/debug/stats; }
hwm() { stats | jq_ "['hwmKb']"; }
put() { curl -s -o /dev/null -H 'Expect:' -w '%{http_code} %{time_total}\n' -T "$T/$1" "localhost:$PORT/blobs/$(h "$1")"; }
hubpid() { docker inspect -f '{{.State.Pid}}' spike-hub; }
cputicks() { awk '{print $14+$15}' /proc/"$(hubpid)"/stat; }

# ---------- 4 GiB: upload/download, per modalità di hash ----------
for mode in none openssl dart; do
  log "== 4 GiB upload/download (HUB_HASH=$mode, --cpus=$CPUS --memory=$MEM)"
  rm -rf "$T/d-$mode"; start "$T/d-$mode" $mode
  read -r code t < <(put big.bin)
  up=$(python3 -c "print(round(4096/$t,1))")
  log "  upload: HTTP $code, ${t}s, $up MiB/s"
  [ "$code" = 201 ] || { log "  FAIL upload $code"; FAIL=1; }
  s0=$(date +%s.%N)
  got=$(curl -s "localhost:$PORT/blobs/$(h big.bin)" | sha256sum | cut -d' ' -f1)
  dt=$(python3 -c "print(round($(date +%s.%N)-$s0,2))")
  down=$(python3 -c "print(round(4096/$dt,1))")
  log "  download+sha256sum: ${dt}s, $down MiB/s, hash $( [ "$got" = "$(h big.bin)" ] && echo OK || echo DIVERSO)"
  [ "$got" = "$(h big.bin)" ] || FAIL=1
  m=$(hwm); log "  RSS massimo (VmHWM): $((m/1024)) MiB"
  check "RSS < 150 MB ($mode, 4 GiB)" "v < 150*1000" "$m"
  if [ "$mode" = "$THROUGHPUT_MODE" ]; then
    check "upload 4 GiB >= 200 MB/s ($mode)" "v*1.048576 >= 200" "$up"
    check "download 4 GiB >= 200 MB/s" "v*1.048576 >= 200" "$down"
  fi
  [ "$mode" = dart ] || rm -rf "$T/d-$mode"
done

log "== 4 GiB upload a velocità di rete 1 GbE (curl --limit-rate 112M, HUB_HASH=dart)"
rm -rf "$T/d-net"; start "$T/d-net" dart
t=$(curl -s -o /dev/null -H 'Expect:' --limit-rate 112M -w '%{time_total}' -T "$T/big.bin" "localhost:$PORT/blobs/$(h big.bin)")
m=$(hwm); log "  ${t}s, $(python3 -c "print(round(4096/$t,1))") MiB/s, RSS massimo $((m/1024)) MiB"
check "RSS < 150 MB (4 GiB a 1 GbE)" "v < 150*1000" "$m"
rm -rf "$T/d-net"; start "$T/d-dart" dart

# Le prove seguenti girano con l'hash di package:crypto (quello dello spike).
D=$T/d-dart
log "== Range (HUB_HASH=dart)"
./build/bench range "http://localhost:$PORT" "$(h big.bin)" "$T/big.bin" | sed 's/^/  /' | tee -a "$RES"
[ "${PIPESTATUS[0]}" = 0 ] || FAIL=1
# hash sbagliato -> 422 e nessun file
code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Expect:' -T "$T/small.bin" "localhost:$PORT/blobs/$(printf '0%.0s' $(seq 64))")
check "hash sbagliato -> 422" "v == 422" "$code"
put small.bin >/dev/null

log "== latenza GET piccola senza carico"
base=$(./build/bench latency "http://localhost:$PORT" "$(h small.bin)" 5)
log "  $base"
log "== 16 upload concorrenti da 256 MiB + GET piccola in parallelo"
s0=$(date +%s.%N); pids=()
for i in $(seq -w 1 16); do put "m$i.bin" > "$T/put$i" & pids+=($!); done
wait "${pids[@]}"
dt=$(python3 -c "print(round($(date +%s.%N)-$s0,2))")
ok16=$(cat "$T"/put* | grep -c '^201'); rm -f "$T"/put*
log "  errori lato hub: $(stats | jq_ "['errors']")"
log "  16 x 256 MiB: ${dt}s, $(python3 -c "print(round(4096/$dt,1))") MiB/s aggregati, $ok16/16 HTTP 201"
check "16 upload completati" "v == 16" "$ok16"
m=$(hwm); log "  RSS massimo: $((m/1024)) MiB"; check "RSS < 150 MB (16 upload)" "v < 150*1000" "$m"

log "== latenza GET durante 16 upload (rifatti su un data dir vuoto)"
start "$T/d-lat" dart; put small.bin >/dev/null
DUR=$(python3 -c "import math; print(max(5, math.floor($dt)-2))")
./build/bench latency "http://localhost:$PORT" "$(h small.bin)" "$DUR" > "$T/lat.json" &
LAT=$!; pids=()
for i in $(seq -w 1 16); do put "m$i.bin" >/dev/null & pids+=($!); done
wait $LAT; lat=$(cat "$T/lat.json"); wait "${pids[@]}"
log "  sotto carico: $lat"
check "GET piccola p99 < 100 ms sotto carico" "v < 100" "$(echo "$lat" | jq_ "['p99ms']")"
m=$(hwm); check "RSS < 150 MB (16 upload + GET)" "v < 150*1000" "$m"
rm -rf "$T/d-lat"; start "$D" dart

log "== 200 client SSE (keepalive 25 s, 60 s di osservazione)"
r0=$(stats | jq_ "['rssKb']")
./build/bench sse "http://localhost:$PORT" 200 60 > "$T/sse.json" 2>/dev/null &
SSE=$!; sleep 5
c0=$(cputicks); n=$(stats | jq_ "['sseClients']"); r1=$(stats | jq_ "['rssKb']")
./build/bench commit "http://localhost:$PORT" "$(h small.bin)" >/dev/null
wait $SSE; c1=$(cputicks)
sse=$(cat "$T/sse.json")
log "  client registrati sull'hub: $n; RSS prima $((r0/1024)) MiB, con 200 client $((r1/1024)) MiB"
log "  CPU dell'hub in ~55 s con 200 client: $(( (c1-c0)*10 )) ms totali"
log "  $sse"
check "200 client SSE aperti" "v == 200" "$n"
check "keepalive ricevuti (>= 2 per client)" "v >= 400" "$(echo "$sse" | jq_ "['keepalives']")"
check "evento commit a tutti" "v == 200" "$(echo "$sse" | jq_ "['events']")"
m=$(hwm); check "RSS < 150 MB (SSE)" "v < 150*1000" "$m"

log "== client che cade a metà upload"
FAKE=$(printf 'ab%.0s' $(seq 32))
./build/bench abort "http://localhost:$PORT" "$FAKE" $((512*MiB)) $((100*MiB)) >/dev/null
sleep 1
left=$(ls -A "$D/tmp" | wc -l)
check "temporaneo ripulito" "v == 0" "$left"
check "nessun blob parziale" "v == 0" "$( [ -e "$D/blobs/ab/$FAKE" ] && echo 1 || echo 0)"
check "hub ancora vivo" "v == 200" "$(curl -s -o /dev/null -w '%{http_code}' localhost:$PORT/healthz)"

log "== DNS (dig, porta alta fuori -> :53/udp nel container, utente non root)"
d() { dig @127.0.0.1 -p $DNSPORT "$@" +time=2 +tries=1; }
a=$(d zerotier.alpha.internal A +short)
srv=$(d _minecraft._tcp.zerotier.beta.internal SRV +noall +answer +additional | tr -s ' \t' ' ')
log "  A alpha: $a"; log "  SRV beta: $(echo "$srv" | tr '\n' '|')"
check "A corretto" "v == '192.0.2.10'" "'$a'"
check "SRV + glue A" "'SRV 0 0 25570 zerotier.beta.internal.' in v and 'zerotier.beta.internal. 5 IN A 192.0.2.20' in v" "'$(echo "$srv" | tr '\n' ' ')'"
check "TTL 5" "v.split()[1] == '5'" "'$(d zerotier.alpha.internal A +noall +answer | tr -s ' \t' ' ')'"
check "NXDOMAIN + SOA" "'NXDOMAIN' in v and 'SOA' in v" "'''$(d zerotier.nope.internal A | tr '\n' ' ')'''"
check "fuori zona REFUSED" "'REFUSED' in v" "'$(d example.com A | grep status)'"
check "spazio senza host: NOERROR vuoto" "'NOERROR' in v and 'ANSWER: 0' in v" "'''$(d zerotier.gamma.internal A | grep -E 'status|ANSWER:' | tr '\n' ' ')'''"
check "utente del processo non root" "v != '0'" "'$(awk '/^Uid/{print $2}' /proc/"$(hubpid)"/status)'"
check "CapEff vuoto (nessuna capability)" "v == '0000000000000000'" "'$(awk '/^CapEff/{print $2}' /proc/"$(hubpid)"/status)'"

log "== kill -9 durante le scritture (5 round, docker kill -s KILL)"
K=$T/d-kill; rm -rf "$K"; KFAIL=0
# due flussi che caricano i 16 file in sequenza: a ogni round alcuni blob sono
# già completi (si saltano), altri a metà -> il kill cade su scritture,
# fsync e rename in punti diversi; i blob completati si accumulano.
for delay in 2 5 9 14 20; do
  start "$K" dart
  pids=()
  (for i in 01 03 05 07 09 11 13 15; do put "m$i.bin" >/dev/null 2>&1; done) & pids+=($!)
  (for i in 02 04 06 08 10 12 14 16; do put "m$i.bin" >/dev/null 2>&1; done) & pids+=($!)
  sleep $delay
  docker kill -s KILL spike-hub >/dev/null
  wait "${pids[@]}" 2>/dev/null
  partial=$(ls -A "$K/tmp" | wc -l)
  start "$K" dart
  cleaned=$(docker logs spike-hub 2>&1 | grep -o 'avvio: [0-9]*' | cut -d' ' -f2)
  bad=0; n=0
  while IFS= read -r f; do
    n=$((n+1)); [ "$(sha256sum "$f" | cut -d' ' -f1)" = "$(basename "$f")" ] || bad=$((bad+1))
  done < <(find "$K/blobs" -type f)
  log "  kill dopo ${delay}s: temporanei lasciati $partial, ripuliti all'avvio $cleaned, blob $n, corrotti $bad, tmp ora $(ls -A "$K/tmp" | wc -l)"
  [ "$bad" = 0 ] && [ "$(ls -A "$K/tmp" | wc -l)" = 0 ] || KFAIL=1
done
check "kill -9: nessun blob corrotto, tmp ripulito" "v == 0" "$KFAIL"

docker rm -f -v spike-hub >/dev/null
[ "${KEEP:-0}" = 1 ] || rm -rf "$D" "$K"
log "== esito: $([ $FAIL = 0 ] && echo PASS || echo FAIL)"
exit $FAIL
