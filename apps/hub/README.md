# minesync_hub

The MineSync hub: a `dart:io` server with API v1, SSE events, the
content-addressed store, the lock, Admin settings, DNS, the Telegram bot,
`/dl` and the static web UI. Entry point `bin/hub.dart`, configured by
environment variables (see [docs/guide/hub.md](../../docs/guide/hub.md)).

Test with `dart test` (TZ=UTC); `dart run bin/hub.dart` starts a local hub.
