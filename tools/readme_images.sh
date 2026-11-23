#!/usr/bin/env bash
# Copia in imgs/ le schermate del README dai golden dei test (disegnate
# dall'app stessa, in italiano). Dopo un cambio grafico:
#   (cd apps/desktop && TZ=UTC flutter test --update-goldens)
#   (cd apps/hub_web && TZ=UTC flutter test --update-goldens)
#   tools/readme_images.sh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p imgs

d=apps/desktop/test/goldens
w=apps/hub_web/test/goldens
s=apps/hub_web/test/server/goldens

pick() { # sorgente (cartella del golden), nome in imgs/
  local src=$1/dpr_1.50.png
  [ -f "$src" ] || src=$1/dpr_1.00.png
  cp "$src" "imgs/$2.png"
}

cp packages/ms_ui/assets/brand/minesync-256.png imgs/minesync.png
pick "$d/home" home
pick "$d/server_playing" server
pick "$d/session_running" session
pick "$d/modpack_mods" mods
pick "$d/modpack_dialog_detail" mod-detail
pick "$d/history" history
pick "$d/new_server_mods" new-server
pick "$d/home_offline_light" light
pick "$w/overview_admin" hub
pick "$s/server_overview_admin" hub-server
pick "$w/admin_general" hub-admin
pick "$w/download_phone" hub-phone
echo "imgs/ aggiornata"
