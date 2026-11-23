# Ambiente di build Linux con glibc 2.31 (Ubuntu 20.04): quello che si
# compila qui (runner GTK e plugin dell'app) gira su ogni distribuzione con
# glibc >= 2.31. L'engine Flutter e i binari Dart AOT chiedono già solo
# GLIBC_2.18. Lo usa tools/package/linux/container.sh, non va pubblicato.
FROM ubuntu:20.04

ARG FLUTTER_VERSION
ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8

# Strumenti della build Linux di Flutter (clang, cmake, ninja, GTK 3) e
# librerie dei plugin: libayatana-appindicator3 (tray_manager), libnotify
# (local_notifier). binutils per il controllo della glibc con objdump.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git unzip xz-utils zip file binutils \
      clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libstdc++-10-dev \
      libayatana-appindicator3-dev libnotify-dev \
    && rm -rf /var/lib/apt/lists/*

# Flutter dal tag git (lo stesso che usa la CI anche per Linux arm64).
# L'SDK resta scrivibile da tutti: il container gira con l'utente del runner.
RUN test -n "$FLUTTER_VERSION" \
    && git clone --depth 1 -b "$FLUTTER_VERSION" https://github.com/flutter/flutter.git /opt/flutter \
    && git config --system --add safe.directory '*' \
    && /opt/flutter/bin/flutter config --no-analytics --no-cli-animations \
    && /opt/flutter/bin/flutter precache --linux --no-android --no-ios --no-web \
    && /opt/flutter/bin/flutter --version \
    && chmod -R a+rwX /opt/flutter
ENV PATH=/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin:$PATH
