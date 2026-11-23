# syntax=docker/dockerfile:1
# Immagine dell'hub MineSync: hub (Dart AOT), interfaccia web (hub_web) e
# download dei client (/dl), multi-arch linux/amd64 e linux/arm64.
#
# Dalla radice del repository, con BuildKit (buildx):
#   docker buildx build --platform linux/amd64,linux/arm64 \
#     --build-arg VERSION=$(cat VERSION) -f deploy/Dockerfile .
#   docker build --build-arg VERSION=$(cat VERSION) -t minesync-hub -f deploy/Dockerfile .
# Col builder classico (Docker senza buildx, per esempio su un NAS) gli
# argomenti di piattaforma non arrivano da soli: vanno passati quelli
# dell'host e NON va passato --platform (varrebbe anche per gli stage di build):
#   DOCKER_BUILDKIT=0 docker build --build-arg BUILDPLATFORM=linux/arm64 \
#     --build-arg TARGETARCH=arm64 -t minesync-hub -f deploy/Dockerfile .
#
# Gli stage di build girano SEMPRE sull'architettura di chi compila
# ($BUILDPLATFORM): l'interfaccia web si compila una volta sola per entrambe le
# architetture e l'hub si cross-compila con
# `dart compile exe --target-os linux --target-arch`. Niente emulazione qemu:
# lo stage finale non ha istruzioni RUN.
#
# deploy/dl/ (download desktop + update/) lo riempie la CI di release; vuota
# per le build locali, e l'hub mostra allora una pagina dei download vuota.

# Valori per il builder classico; con BuildKit li sovrascrive lui.
ARG BUILDPLATFORM=linux/amd64
# Flutter fissato alla stessa versione della CI (ci.yml) e verificato sul
# commit del tag. Il workspace pub contiene pacchetti Flutter: anche l'hub,
# che è Dart puro, si risolve con `flutter pub get` e il Dart di Flutter.
ARG FLUTTER_VERSION=3.47.5
ARG FLUTTER_COMMIT=6a19cca56475dbfba1478ee68d7bd0c2ef891da1
ARG DEBIAN_IMAGE=debian:12-slim
ARG RUNTIME_IMAGE=gcr.io/distroless/cc-debian12:nonroot

# --- SDK: Debian + Flutter (con il suo Dart) ---------------------------------
FROM --platform=$BUILDPLATFORM ${DEBIAN_IMAGE} AS sdk
ARG FLUTTER_VERSION
ARG FLUTTER_COMMIT
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git unzip xz-utils brotli \
 && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch "$FLUTTER_VERSION" https://github.com/flutter/flutter.git /opt/flutter \
 && test "$(git -C /opt/flutter rev-parse HEAD)" = "$FLUTTER_COMMIT"
ENV PATH=/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin:$PATH \
    CI=true FLUTTER_SUPPRESS_ANALYTICS=true PUB_CACHE=/opt/pub-cache
# Dart SDK e artefatti web scaricati una volta, in questo strato
RUN flutter config --no-analytics --no-cli-animations \
 && flutter precache --web --no-android --no-ios --no-linux --no-macos --no-windows --no-fuchsia \
 && dart --disable-analytics \
 && flutter --version

# --- Sorgenti e dipendenze del workspace -------------------------------------
FROM sdk AS src
WORKDIR /src
# prima solo i pubspec: le dipendenze restano in cache finché non cambiano
COPY pubspec.yaml pubspec.lock analysis_options.yaml ./
COPY packages/ms_protocol/pubspec.yaml packages/ms_protocol/
COPY packages/ms_core/pubspec.yaml packages/ms_core/
COPY packages/ms_minecraft/pubspec.yaml packages/ms_minecraft/
COPY packages/ms_session/pubspec.yaml packages/ms_session/
COPY packages/ms_l10n/pubspec.yaml packages/ms_l10n/
COPY packages/ms_ui/pubspec.yaml packages/ms_ui/
COPY packages/ms_modpack/pubspec.yaml packages/ms_modpack/
COPY apps/hub/pubspec.yaml apps/hub/
COPY apps/hub_web/pubspec.yaml apps/hub_web/
COPY apps/desktop/pubspec.yaml apps/desktop/
COPY apps/cli/pubspec.yaml apps/cli/
COPY apps/guard/pubspec.yaml apps/guard/
COPY apps/launcher/pubspec.yaml apps/launcher/
RUN flutter pub get --enforce-lockfile
COPY VERSION ./
COPY packages packages
COPY apps apps
RUN flutter pub get --enforce-lockfile --offline

# --- Interfaccia web (indipendente dall'architettura) -----------------------
FROM src AS web
# 1 = file .br accanto a .js/.mjs/.wasm/.json/.ttf/.otf (l'hub li serve a chi
# accetta brotli); 0 = build più veloce, solo gzip calcolato dall'hub.
ARG BROTLI=1
WORKDIR /src/apps/hub_web
RUN flutter build web --wasm --release --no-web-resources-cdn --no-source-maps --base-href / \
 && cd build/web \
 && find . \( -name '*.symbols' -o -name '*.map' -o -name '*.gz' \) -type f -delete \
 && if [ "$BROTLI" = 1 ]; then \
      find . -type f \( -name '*.js' -o -name '*.mjs' -o -name '*.wasm' -o -name '*.json' \
        -o -name '*.ttf' -o -name '*.otf' \) -exec brotli -k -q 11 {} + ; \
    fi \
 && mv /src/apps/hub_web/build/web /out-web

# --- Hub, cross-compilato per l'architettura di destinazione -----------------
FROM src AS hub
ARG TARGETARCH=amd64
# Se passata (CI), deve coincidere con VERSION: l'etichetta dell'immagine e la
# versione che l'hub dichiara non possono divergere.
ARG VERSION=
RUN set -eu; \
    if [ -n "$VERSION" ] && [ "$VERSION" != "$(cat VERSION)" ]; then \
      echo "VERSION=$VERSION ma il file VERSION dice $(cat VERSION)"; exit 1; fi; \
    case "$TARGETARCH" in amd64) A=x64;; arm64) A=arm64;; *) echo "arch $TARGETARCH non supportata"; exit 1;; esac; \
    mkdir -p /out && \
    dart compile exe --target-os linux --target-arch "$A" apps/hub/bin/hub.dart -o /out/hub

# --- Download, cartella dati --------------------------------------------------
FROM --platform=$BUILDPLATFORM ${DEBIAN_IMAGE} AS files
COPY deploy/dl/ /out/dl/
# niente file nascosti (.gitkeep) in /dl; /data dell'utente nonroot (65532)
RUN find /out/dl -mindepth 1 -name '.*' -prune -exec rm -rf {} + \
 && chmod -R a+rX,go-w /out/dl \
 && mkdir -p /out/data && chown 65532:65532 /out/data

# --- Immagine finale -------------------------------------------------------
# distroless/cc: glibc + libgcc + libssl, tzdata, certificati; nessuna shell.
# Utente nonroot = 65532. Il binario Dart AOT è dinamico su glibc.
FROM ${RUNTIME_IMAGE}
ARG VERSION=
ARG REVISION=
ARG SOURCE=
LABEL org.opencontainers.image.title="MineSync hub" \
      org.opencontainers.image.description="Self-hosted hub that syncs Minecraft server worlds between friends over a private ZeroTier network" \
      org.opencontainers.image.licenses="BSD-3-Clause" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.source="${SOURCE}"
COPY LICENSE /app/LICENSE
COPY --from=hub /out/hub /app/hub
COPY --from=web /out-web /app/web
COPY --from=files /out/dl /app/dl
COPY --from=files --chown=65532:65532 /out/data /data
USER 65532:65532
WORKDIR /data
VOLUME /data
# 8084: HTTP (API, web UI, /dl). 53/udp+tcp: DNS integrato, solo con
# MINESYNC_DNS_ZONE. Con `network_mode: service:zerotier` le porte non si
# pubblicano: sono quelle dello spazio di rete del container ZeroTier.
# In uno spazio di rete proprio (bridge, Docker >= 20.10)
# net.ipv4.ip_unprivileged_port_start vale 0: la :53 si apre anche da nonroot.
EXPOSE 8084/tcp 53/udp 53/tcp
ENV MINESYNC_DATA=/data \
    MINESYNC_ADDR=:8084 \
    MINESYNC_WEB=/app/web \
    MINESYNC_DL=/app/dl
# Tetto dell'heap Dart (old space, MB): dart:io legge dal socket fino a ~4-6
# MiB per evento e quei pezzi stanno nell'old space finché il mark-sweep non
# passa; senza tetto il picco di RSS segue il throughput (misurato). Col
# tetto il GC scatta prima.
ENV DART_VM_OPTIONS=--old_gen_heap_size=128
# Nessuna shell: è l'hub stesso a interrogarsi (GET / su MINESYNC_ADDR).
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --start-interval=2s --retries=3 \
    CMD ["/app/hub", "healthcheck"]
STOPSIGNAL SIGTERM
ENTRYPOINT ["/app/hub"]
