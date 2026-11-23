# minesync_hub_web

The hub's web UI (Flutter web): overview, servers, players, mods, history,
downloads and the Admin area. The hub serves the output of
`flutter build web --wasm --release --no-web-resources-cdn --no-source-maps --base-href /`
from `MINESYNC_WEB`.

Test with `flutter test` (TZ=UTC); goldens are under `test/goldens/`.
