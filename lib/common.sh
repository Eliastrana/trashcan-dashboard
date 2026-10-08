#!/bin/bash
# Shared helpers for setup.sh. Sourced, never run on its own.
#
# Everything that changes the machine goes through run(), so --dry-run can print it instead of doing it.

say()  { printf '\033[1m==> [%s] %s\033[0m\n' "$(date +%T)" "$*"; }
warn() { printf '\033[33m!! [%s] %s\033[0m\n' "$(date +%T)" "$*" >&2; }
die()  { printf '\033[31mxx %s\033[0m\n' "$*" >&2; exit 1; }
run()  { if [ "$DRY" = 1 ]; then printf '   + %s\n' "$*"; else "$@"; fi; }

user_of()  { echo "_svc_$1"; }
label_of() { echo "$LABEL_PREFIX.$1${2:+-$2}"; }          # label_of hitster web -> com.eliastrana.svc.hitster-web
dir_of()   { echo "$APPS/$1"; }

# ---------------------------------------------------------------- accounts
next_id() {
  local id=450
  while dscl . -list /Users UniqueID | awk '{print $2}' | grep -qx "$id" \
     || dscl . -list /Groups PrimaryGroupID | awk '{print $2}' | grep -qx "$id"; do id=$((id + 1)); done
  echo "$id"
}

# A hidden account that cannot log in, has no home folder and owns exactly one app.
create_account() {
  local u; u=$(user_of "$1")
  if dscl . -read "/Users/$u" >/dev/null 2>&1; then say "account $u exists"; return; fi
  local id; id=$(next_id)
  say "creating hidden account $u (id $id)"
  run dscl . -create "/Groups/$u"
  run dscl . -create "/Groups/$u" PrimaryGroupID "$id"
  run dscl . -create "/Users/$u"
  run dscl . -create "/Users/$u" UserShell /usr/bin/false
  run dscl . -create "/Users/$u" RealName "service $1"
  run dscl . -create "/Users/$u" UniqueID "$id"
  run dscl . -create "/Users/$u" PrimaryGroupID "$id"
  run dscl . -create "/Users/$u" NFSHomeDirectory /var/empty
  run dscl . -create "/Users/$u" Password '*'
  run dscl . -create "/Users/$u" IsHidden 1
}

# Owned by the service account, closed to everyone else.
lock_dir() {
  local u; u=$(user_of "$1")
  run chown -R "$u:$u" "$(dir_of "$1")"
  run chmod -R go-rwx "$(dir_of "$1")"
  run chmod 750 "$(dir_of "$1")"
}

# Copy a folder in, keep symlinks that stay inside it and never follow one out.
sync_in() {    # sync_in <src> <dest> [rsync flags...]
  local src=$1 dest=$2; shift 2
  run mkdir -p "$dest"
  run rsync -a --safe-links "$@" "$src/" "$dest/"
}

# ---------------------------------------------------------------- launchd
# plist <label> <app> <workdir> <logfile>      reads ENVV[] (KEY=value) and ARGV[], and optionally PLIST_EXTRA
plist() {
  local label=$1 app=$2 wd=$3 log=$4 out arg kv
  LAST_LOG=$log; LAST_LABEL=$label
  if [ "$DRY" = 1 ]; then out=$(mktemp -d)/$label.plist; else out=/Library/LaunchDaemons/$label.plist; fi
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0"><dict>'
    echo "  <key>Label</key><string>$label</string>"
    echo "  <key>UserName</key><string>$(user_of "$app")</string>"
    echo "  <key>GroupName</key><string>$(user_of "$app")</string>"
    echo "  <key>WorkingDirectory</key><string>$wd</string>"
    echo '  <key>ProgramArguments</key><array>'
    for arg in "${ARGV[@]}"; do echo "    <string>$arg</string>"; done
    echo '  </array>'
    echo '  <key>EnvironmentVariables</key><dict>'
    for kv in "${ENVV[@]}"; do echo "    <key>${kv%%=*}</key><string>${kv#*=}</string>"; done
    echo '  </dict>'
    echo '  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>10</integer>'
    [ -z "${PLIST_EXTRA:-}" ] || echo "  $PLIST_EXTRA"
    echo "  <key>StandardOutPath</key><string>$log</string><key>StandardErrorPath</key><string>$log</string>"
    echo '</dict></plist>'
  } > "$out"
  if [ "$DRY" = 1 ]; then plutil -lint "$out" | sed 's/^/   /'; else
    chown root:wheel "$out"; chmod 644 "$out"; plutil -lint "$out" >/dev/null
  fi
}

# Start a daemon. If it is already loaded (setup.sh run twice) it is restarted so it picks up the new files.
daemon_up() {
  if [ "$DRY" != 1 ] && launchctl print "system/$1" >/dev/null 2>&1; then run launchctl bootout "system/$1"; fi
  run launchctl bootstrap system "/Library/LaunchDaemons/$1.plist"
}

# ---------------------------------------------------------------- waiting and checking
# macOS keeps a port blocked while old connections linger half-closed (FIN_WAIT, CLOSE_WAIT ...). Starting a server
# on it too early makes the server crash and retry, so wait for the port to be clean first (TIME_WAIT is harmless).
wait_port_clear() {   # wait_port_clear <port> [max seconds]
  local port=$1 max=${2:-360} waited=0 n
  [ "$DRY" = 1 ] && { echo "   + wait until no lingering connections remain on port $port"; return 0; }
  while :; do
    n=$(netstat -anp tcp | awk -v p=".$port" '$4 ~ (p "$") && $6 != "TIME_WAIT" {c++} END {print c+0}')
    [ "$n" = 0 ] && return 0
    [ "$waited" -ge "$max" ] && { warn "port $port still has $n lingering connection(s) after $max s; continuing anyway"; return 0; }
    sleep 5; waited=$((waited + 5))
  done
}

wait_for() {   # wait_for <description> <command...>      WAIT_TRIES=n checks (default 30), 2 s apart
  [ "$DRY" = 1 ] && { echo "   + wait until: $1"; return 0; }
  local d=$1 tries=${WAIT_TRIES:-30} i; shift
  for i in $(seq 1 "$tries"); do "$@" >/dev/null 2>&1 && { say "$d: ok after ~$((i * 2)) s"; return 0; }; sleep 2; done
  warn "$d: no answer after $((tries * 2)) s. What launchd says about $LAST_LABEL:"
  launchctl print "system/$LAST_LABEL" 2>&1 | grep -E "state =|pid =|runs =|last exit|exit code|spawn" | sed 's/^[[:space:]]*/     | /' >&2 || true
  warn "Last lines of the service log ($LAST_LOG):"
  [ -f "$LAST_LOG" ] && tail -n 40 "$LAST_LOG" | sed 's/^/     | /' >&2
  return 1
}
http_ok()   { curl -s -m 4 -o /dev/null -w '%{http_code}' "$1" | grep -qE '^[123]'; }
port_open() { nc -z -w 2 127.0.0.1 "$1"; }

# ---------------------------------------------------------------- downloads
# download <url> <file>   fails loudly on HTTP errors
download() { run curl -fL --retry 3 -o "$2" "$1"; }

# A file's checksum must equal the published one, or stop. The algorithm (256 or 512) follows the published sum's length.
check_sha() {   # check_sha <file> <expected>
  [ "$DRY" = 1 ] && { echo "   + check the checksum of $1"; return 0; }
  local bits=256 got
  [ "${#2}" = 128 ] && bits=512
  got=$(shasum -a "$bits" "$1" | awk '{print $1}')
  [ "$got" = "$2" ] || die "checksum mismatch for $1 (got $got, wanted $2); refusing to use it"
}

# ---------------------------------------------------------------- app state from a backup (made by backup.sh)
# The backup holds what git cannot: passwords, API keys, the Minecraft world, certificates. One archive per app.
restore_state() {   # restore_state <app>       returns 1 when there is no archive for it
  local app=$1 f="${BACKUP:-}/$1.tar.gz"
  [ -n "${BACKUP:-}" ] && [ -f "$f" ] || return 1
  say "restoring $app's saved data from $f"
  run tar -xzf "$f" -C "$APPS"
}
need_state() {      # need_state <app> <why>    a backup is mandatory for this app
  if [ "$DRY" = 1 ] && [ ! -f "${BACKUP:-/nonexistent}/$1.tar.gz" ]; then warn "(dry run) a real run needs $1.tar.gz in the --backup folder: $2"; return 0; fi
  restore_state "$1" || die "$1 needs its backup archive ($2). Run with: --backup <folder that contains $1.tar.gz>"
}

# Run a command as an app's account, with node on the path, inside its own folder.
as_app() {   # as_app <app> <dir> <shell command>
  local app=$1 dir=$2; shift 2
  run sudo -u "$(user_of "$app")" env HOME="$(dir_of "$app")" PATH="$NODE/bin:/usr/bin:/bin:/usr/sbin:/sbin" sh -c "cd '$dir' && $*"
}
