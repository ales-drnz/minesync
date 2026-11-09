# syntax=docker/dockerfile:1
# minesync-hub: hub + client per ogni OS (serviti su /dl, così gli amici li
# scaricano dalla pagina web e si aggiornano da soli).
#
#   docker build -f deploy/Dockerfile -t minesync-hub .
#
# Opzionali:
#   --build-arg MINESYNC_DEFAULT_SERVER=http://<ip-hub>:8084
#       indirizzo precompilato nei client
#   --secret id=minesync_sign_key,src=minesync-sign.key
#       firma SHA256SUMS e incorpora la chiave pubblica nei client
#       (senza, gli aggiornamenti sono verificati solo col checksum)
ARG BUILDPLATFORM

# --- client: identici per ogni architettura dell'immagine, compilati una volta ---
FROM --platform=$BUILDPLATFORM golang:1.26-alpine AS clients
WORKDIR /src
COPY VERSION ./
COPY scripts/build.sh scripts/build.sh
COPY scripts/sign scripts/sign
COPY client/go.mod client/go.sum client/
RUN cd client && GOWORK=off go mod download
COPY client client
ARG MINESYNC_DEFAULT_SERVER=""
RUN --mount=type=secret,id=minesync_sign_key \
    if [ -s /run/secrets/minesync_sign_key ]; then export MINESYNC_SIGN_KEY=/run/secrets/minesync_sign_key; fi; \
    OUT=/out HUB_TARGETS="" MINESYNC_DEFAULT_SERVER="$MINESYNC_DEFAULT_SERVER" sh scripts/build.sh

# --- hub: cross-compilato per l'architettura di destinazione ---
FROM --platform=$BUILDPLATFORM golang:1.26-alpine AS hub
ARG TARGETOS=linux
ARG TARGETARCH=amd64
WORKDIR /src
COPY VERSION ./
COPY scripts/build.sh scripts/build.sh
COPY server server
RUN OUT=/out HUB_TARGETS="$TARGETOS/$TARGETARCH" CLIENT_TARGETS="" sh scripts/build.sh && \
    mv /out/minesync-hub-$TARGETOS-$TARGETARCH /out/minesync-hub

# --- runtime ---
FROM alpine:3.22
RUN apk add --no-cache ca-certificates tzdata
COPY --from=hub /out/minesync-hub /usr/local/bin/minesync-hub
# la :53 del DNS è privilegiata: la capability sul binario permette di aprirla
# anche senza root (serve che il container non abbia no-new-privileges)
RUN apk add --no-cache --virtual .cap libcap && \
    setcap cap_net_bind_service=+ep /usr/local/bin/minesync-hub && \
    apk del .cap
COPY --from=clients /out/dl /opt/dl
RUN mkdir -p /data && chown 65532:65532 /data
# utente non privilegiato; nel compose si può sostituire con `user:` (PUID:PGID)
USER 65532:65532
VOLUME /data
EXPOSE 8084 53/udp
ENV MINESYNC_DATA=/data MINESYNC_ADDR=:8084 MINESYNC_DL=/opt/dl
ENTRYPOINT ["minesync-hub"]
