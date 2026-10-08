#!/bin/bash
# One-time install of the status page's start/stop/restart buttons, plus the newest status page files.
#   sudo ./install-control.sh
# It does four things:
#   1. installs the root-owned helper /opt/apps/bin/svc-control
#   2. lets ONLY the status account (_svc_status) run that helper, for a fixed list of id/action pairs, without a password
#   3. copies the staged status page from ~trashcan/deploy/status into /opt/apps/status
#   4. restarts the status page
# To undo the permission: sudo rm /etc/sudoers.d/status-control
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
STAGE=/Users/trashcan/deploy/status
U=_svc_status
APP=/opt/apps/status

[ -f "$HERE/bin/svc-control" ] || { echo "missing $HERE/bin/svc-control" >&2; exit 1; }
[ -f "$STAGE/server.js" ] || { echo "nothing staged in $STAGE" >&2; exit 1; }

echo "==> installing /opt/apps/bin/svc-control (root-owned)"
install -m 755 -o root -g wheel "$HERE/bin/svc-control" /opt/apps/bin/svc-control

echo "==> allowing $U to run it, for these exact commands only"
tmp=$(mktemp)
{
  echo "# written by install-control.sh: the status page may run these commands as root, and nothing else"
  for pair in "caddy restart" \
              "arena stop" "arena start" "arena restart" \
              "hitweb stop" "hitweb start" "hitweb restart" \
              "hitws stop" "hitws start" "hitws restart" \
              "mcpack stop" "mcpack start" "mcpack restart" \
              "minecraft stop" "minecraft start" "minecraft restart"; do
    echo "$U ALL=(root) NOPASSWD: /opt/apps/bin/svc-control $pair"
  done
} > "$tmp"
visudo -cf "$tmp" >/dev/null || { echo "the sudoers file did not validate; nothing was installed" >&2; rm -f "$tmp"; exit 1; }
install -m 440 -o root -g wheel "$tmp" /etc/sudoers.d/status-control
rm -f "$tmp"

echo "==> updating the status page files from $STAGE"
rsync -rlpt --safe-links --delete --exclude data "$STAGE/" "$APP/"
chown -R "$U:$U" "$APP"
chmod -R go-rwx "$APP"

echo "==> restarting the status page"
launchctl kickstart -k system/com.eliastrana.svc.status
sleep 3
curl -s -m5 -o /dev/null -w "status page answers: %{http_code}\n" http://127.0.0.1:3020/login
echo "done. Buttons appear on https://status.eliastrana.no after a refresh."
