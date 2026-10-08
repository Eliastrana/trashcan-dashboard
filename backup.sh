#!/bin/bash
# Save everything that git cannot bring back: passwords, API keys, the Minecraft world, certificates.
#
#   sudo ./backup.sh [destination-folder]        default: ./trashcan-backup-<date>
#
# Makes one archive per app (status.tar.gz, hitster.tar.gz, ...). setup.sh --backup <folder> puts them back.
# Put the folder on an EXTERNAL drive or another computer. A backup on the trashcan's own disk is lost with the trashcan.
# The archives contain passwords and secret keys: never upload them to GitHub or any public place.
set -euo pipefail
APPS=/opt/apps
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
DEST=${1:-$HERE/trashcan-backup-$(date +%Y%m%d-%H%M%S)}
say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
mkdir -p "$DEST"; chmod 700 "$DEST"; DEST=$(cd "$DEST" && pwd)

pack() {   # pack <app> <tar flags and paths relative to /opt/apps...>
  local app=$1; shift
  say "$app"
  tar -czf "$DEST/$app.tar.gz" -C "$APPS" "$@"
  chmod 600 "$DEST/$app.tar.gz"
}

[ -d "$APPS/status/data" ]   && pack status  status/data
[ -d "$APPS/llmgate/data" ]  && pack llmgate llmgate/data
[ -f "$APPS/hitster/web/.env.local" ] && pack hitster hitster/web/.env.local
[ -d "$APPS/mcpack/mc-packs" ] && pack mcpack mcpack/mc-packs
[ -d "$APPS/caddy/data" ]    && pack caddy   caddy/data

if [ -d "$APPS/minecraft/server" ]; then
  # Ask the running server to write the world to disk and pause saving while the archive is made, then turn saving back on.
  live=0; [ -p "$APPS/minecraft/console.in" ] && live=1
  if [ $live = 1 ]; then
    trap '"$APPS/bin/mc-cmd" save-on >/dev/null 2>&1 || true' EXIT
    "$APPS/bin/mc-cmd" save-off; "$APPS/bin/mc-cmd" "save-all flush"; sleep 15
  fi
  pack minecraft --exclude minecraft/server/logs --exclude minecraft/server/cache --exclude minecraft/server/crash-reports minecraft/server
  if [ $live = 1 ]; then "$APPS/bin/mc-cmd" save-on; trap - EXIT; fi
fi

# The live Caddyfile, to compare with config/Caddyfile in the repo (commit any difference so the repo stays the truth).
if [ -f "$APPS/caddy/Caddyfile" ]; then
  cp "$APPS/caddy/Caddyfile" "$DEST/Caddyfile.live"
  diff -q "$APPS/caddy/Caddyfile" "$HERE/config/Caddyfile" >/dev/null || echo "!! the live Caddyfile differs from config/Caddyfile in the repo. Copy it over and commit."
fi

chown -R root:wheel "$DEST"
say "saved to $DEST"; ls -lh "$DEST"
echo "Copy this folder to an external drive now."
