# Spike: hub Dart AOT in un'immagine minima, multi-arch (linux/amd64, linux/arm64).
#
# Con buildx (CI):   docker buildx build --platform linux/amd64,linux/arm64 -f deploy/Dockerfile .
# Senza buildx (builder classico, come su questo host):
#   DOCKER_BUILDKIT=0 docker build --build-arg TARGETARCH=arm64 \
#     --build-arg TARGETPLATFORM=linux/arm64 -f deploy/Dockerfile .
#   (NON passare --platform al builder classico: lo applicherebbe anche allo
#   stage di build e fallirebbe)
#
# Lo stage di build gira SEMPRE sull'architettura dell'host ($BUILDPLATFORM) e
# cross-compila con `dart compile exe --target-arch`: niente emulazione qemu
# durante la build. Lo stage finale non ha istruzioni RUN, quindi anche
# l'immagine arm64 si assembla senza binfmt.
ARG BUILDPLATFORM=linux/amd64
ARG TARGETPLATFORM=linux/amd64
FROM --platform=$BUILDPLATFORM dart:3.13.4 AS build
ARG TARGETARCH=amd64
WORKDIR /src
COPY pubspec.yaml ./
RUN dart pub get
COPY bin bin
COPY lib lib
RUN set -eu; case "$TARGETARCH" in amd64) A=x64;; arm64) A=arm64;; *) echo "arch $TARGETARCH"; exit 1;; esac; \
    mkdir -p /out/data && \
    dart compile exe --target-os linux --target-arch "$A" bin/hub.dart -o /out/hub && \
    chown 65532:65532 /out/data

# distroless/cc: glibc + libgcc + libssl3/libcrypto (per HUB_HASH=openssl),
# nessuna shell; utente nonroot = 65532. Il binario Dart AOT è dinamico su glibc.
FROM --platform=$TARGETPLATFORM gcr.io/distroless/cc-debian12:nonroot
COPY --from=build /out/hub /usr/local/bin/hub
COPY --from=build --chown=65532:65532 /out/data /data
USER 65532:65532
VOLUME /data
# Nella rete bridge di Docker (>= 20.10) net.ipv4.ip_unprivileged_port_start
# vale 0 nel namespace del container: la :53 si apre anche da non root, senza
# capability. Con --network host vale la soglia dell'host (1024): una file
# capability (setcap) non sopravvive al COPY del builder classico (misurato) e
# qui non c'è RUN; si usa `--user 0 --cap-drop ALL --cap-add NET_BIND_SERVICE`.
EXPOSE 8084 53/udp
ENV HUB_DATA=/data HUB_HTTP_PORT=8084 HUB_DNS_PORT=53 HUB_DNS_ZONE=internal \
    HUB_MAX_UPLOADS=4
# Tetto dell'heap Dart (old space, MB): dart:io legge dal socket fino a ~4-6 MiB
# per evento e quei pezzi stanno nell'old space finché il mark-sweep non passa;
# senza tetto il picco di RSS segue il throughput (~180-230 MB a 500+ MiB/s).
# Col tetto il GC scatta prima. Misure e rischio (OOM per connessione) nel README.
ENV DART_VM_OPTIONS=--old_gen_heap_size=128
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD ["/usr/local/bin/hub", "healthcheck"]
ENTRYPOINT ["/usr/local/bin/hub"]
