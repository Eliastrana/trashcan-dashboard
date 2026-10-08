#!/bin/bash
# Give each app on the trashcan its own unprivileged macOS account.
#
#   sudo ./harden.sh [--dry-run] [--yes] [--allow-deploy] install  <app|all>
#   sudo ./harden.sh                    rollback <app|all>
#   sudo ./harden.sh                    status
#
# apps: hitster arena mcpack status chatbot llmgate minecraft caddy      (portfolio already runs as its own user, "elias")
#
# What "install <app>" does, and why it is safe to run one app at a time:
#   1. creates a hidden account _svc_<app> (no login shell, no home folder, own group)
#   2. copies the app into /opt/apps/<app>, owned by that account, unreadable by everyone else
#   3. stops the old LaunchAgent (renamed to .disabled, never deleted), starts a system LaunchDaemon
#      that runs as the new account, and checks the app answers
#   4. if the check fails it rolls that app back by itself
# The original folders in /Users/trashcan are left untouched, so every step can be undone.
# Why: today everything runs as "trashcan", so one exploited app can read every other app's files and secrets.
# After this, an attacker who owns Hitster only gets what _svc_hitster can see.
set -euo pipefail

SRC_USER=trashcan
SRC_HOME=/Users/$SRC_USER
APPS=/opt/apps
NODE_VERSION=v20.20.2
NODE_SRC=$SRC_HOME/.nvm/versions/node/$NODE_VERSION
NODE=/opt/node
LABEL_PREFIX=com.eliastrana.svc
DRY=0; YES=0; ALLOW_DEPLOY=0; LAST_LOG=; LAST_LABEL=
HERE=$(cd "$(dirname "$0")" && pwd)

say()  { printf '\033[1m==> [%s] %s\033[0m\n' "$(date +%T)" "$*"; }
warn() { printf '\033[33m!! [%s] %s\033[0m\n' "$(date +%T)" "$*" >&2; }
die()  { printf '\033[31mxx %s\033[0m\n' "$*" >&2; exit 1; }
run()  { if [ $DRY = 1 ]; then printf '   + %s\n' "$*"; else "$@"; fi; }

ARGS=(); for a in "$@"; do case $a in --dry-run) DRY=1;; --yes) YES=1;; --allow-deploy) ALLOW_DEPLOY=1;; *) ARGS+=("$a");; esac; done
set -- "${ARGS[@]:-}"
CMD=${1:-}; TARGET=${2:-}
[ $DRY = 1 ] || [ "$(id -u)" = 0 ] || die "run with sudo (or add --dry-run to just print what would happen)"

user_of()  { echo "_svc_$1"; }
label_of() { echo "$LABEL_PREFIX.$1${2:+-$2}"; }          # label_of hitster web -> com.eliastrana.svc.hitster-web
dir_of()   { echo "$APPS/$1"; }
SRC_UID=$(id -u "$SRC_USER")

# ---------------------------------------------------------------- accounts
next_id() {
  local id=450
  while dscl . -list /Users UniqueID | awk '{print $2}' | grep -qx "$id" \
     || dscl . -list /Groups PrimaryGroupID | awk '{print $2}' | grep -qx "$id"; do id=$((id + 1)); done
  echo "$id"
}
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

# ---------------------------------------------------------------- shared pieces
ensure_node() {
  [ -x "$NODE/bin/node" ] && return
  [ -x "$NODE_SRC/bin/node" ] || die "node $NODE_VERSION not found at $NODE_SRC"
  say "installing node $NODE_VERSION system-wide in $NODE (read-only copy, root-owned)"
  run mkdir -p "$NODE"
  run rsync -a "$NODE_SRC/" "$NODE/"
  run chown -R root:wheel "$NODE"
  run chmod -R go-w "$NODE"
}
lock_dir() {   # lock_dir <app>  -> owned by the service account, closed to everyone else
  local u; u=$(user_of "$1")
  run chown -R "$u:$u" "$(dir_of "$1")"
  run chmod -R go-rwx "$(dir_of "$1")"
  run chmod 750 "$(dir_of "$1")"
}
sync_in() {    # sync_in <src> <dest> [rsync flags...]   copy, keep symlinks inside, never follow them out
  local src=$1 dest=$2; shift 2
  run mkdir -p "$dest"
  run rsync -a --safe-links "$@" "$src/" "$dest/"
}

# plist <label> <app> <workdir> <logfile> ; reads ENVV[] and ARGV[]
plist() {
  local label=$1 app=$2 wd=$3 log=$4 out arg kv
  LAST_LOG=$log; LAST_LABEL=$label
  if [ $DRY = 1 ]; then out=$(mktemp -d)/$label.plist; else out=/Library/LaunchDaemons/$label.plist; fi
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
  if [ $DRY = 1 ]; then plutil -lint "$out" | sed 's/^/   /'; else
    chown root:wheel "$out"; chmod 644 "$out"; plutil -lint "$out" >/dev/null
  fi
}
daemon_up()   { run launchctl bootstrap system "/Library/LaunchDaemons/$1.plist"; }
daemon_down() { run launchctl bootout "system/$1" 2>/dev/null || true; run rm -f "/Library/LaunchDaemons/$1.plist"; }
# Stop the old per-user LaunchAgent the way its owner would (root's launchctl can fail silently here),
# keep its plist as .disabled, and refuse to go on while the old process still holds a port.
agent_off() {   # agent_off <label> [port ...]
  local label=$1 f="$SRC_HOME/Library/LaunchAgents/$1.plist"; shift
  if [ -f "$f" ]; then
    run sudo -u "$SRC_USER" launchctl bootout "gui/$SRC_UID/$label" || warn "bootout of $label reported an error (checking the ports below)"
    run mv "$f" "$f.disabled"
  else
    warn "no old agent $label (fine if it was never one)"
  fi
  local port
  for port in "$@"; do
    [ $DRY = 1 ] && { echo "   + wait until port $port is free"; continue; }
    for _ in $(seq 1 15); do lsof -nP -iTCP:"$port" -sTCP:LISTEN -t >/dev/null 2>&1 || continue 2; sleep 1; done
    warn "the old process still holds port $port (pid $(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t | head -1)); putting $label back"
    agent_on "$label"; die "could not free port $port, nothing was switched"
  done
}
agent_on() {
  local f="$SRC_HOME/Library/LaunchAgents/$1.plist"
  [ -f "$f.disabled" ] && run mv "$f.disabled" "$f"
  if [ -f "$f" ]; then run sudo -u "$SRC_USER" launchctl bootstrap "gui/$SRC_UID" "$f" || true; fi
}
# After a server stops, connections from players and scanners can linger half-closed (FIN_WAIT, CLOSE_WAIT ...) for
# minutes, and macOS refuses to bind the port until they are gone. Starting the new server too early makes it crash
# and retry, so wait for the port to be clean first (TIME_WAIT is harmless).
wait_port_clear() {   # wait_port_clear <port> [max seconds]
  local port=$1 max=${2:-360} waited=0 n
  [ $DRY = 1 ] && { echo "   + wait until no lingering connections remain on port $port"; return 0; }
  while :; do
    n=$(netstat -anp tcp | awk -v p=".$port" '$4 ~ (p "$") && $6 != "TIME_WAIT" {c++} END {print c+0}')
    [ "$n" = 0 ] && { [ $waited = 0 ] || say "port $port is clear after $waited s"; return 0; }
    [ $waited -ge "$max" ] && { warn "port $port still has $n lingering connection(s) after $max s; continuing anyway"; return 0; }
    [ $((waited % 20)) = 0 ] && say "waiting for $n lingering connection(s) on port $port to clear (macOS keeps the port blocked meanwhile)..."
    sleep 5; waited=$((waited + 5))
  done
}
wait_for() {   # wait_for <description> <command...>   WAIT_TRIES=n (default 30) checks, 2 s apart
  [ $DRY = 1 ] && { echo "   + wait until: $1"; return 0; }
  local d=$1 tries=${WAIT_TRIES:-30} i; shift
  for i in $(seq 1 "$tries"); do "$@" >/dev/null 2>&1 && { say "$d: ok after ~$((i * 2)) s"; return 0; }; sleep 2; done
  warn "$d: no answer after $((tries * 2)) s. What launchd says about $LAST_LABEL:"
  launchctl print "system/$LAST_LABEL" 2>&1 | grep -E "state =|pid =|runs =|last exit|exit code|spawn" | sed 's/^[[:space:]]*/     | /' >&2
  warn "Last lines of the service log ($LAST_LOG):"
  [ -f "$LAST_LOG" ] && tail -n 40 "$LAST_LOG" | sed 's/^/     | /' >&2
  return 1
}
http_ok() { curl -s -m 4 -o /dev/null -w '%{http_code}' "$1" | grep -qE '^[123]'; }
port_open() { nc -z -w 2 127.0.0.1 "$1"; }

# ---------------------------------------------------------------- apps
# Each install_<app> prints what it does, switches over, health-checks, and rolls itself back on failure.
install_hitster() {
  local a=hitster d; d=$(dir_of $a)
  [ -d "$SRC_HOME/hitster/web" ] || die "no $SRC_HOME/hitster/web"
  create_account $a; ensure_node
  sync_in "$SRC_HOME/hitster/web"    "$d/web"    --exclude=.next/cache
  sync_in "$SRC_HOME/hitster/server" "$d/server"
  run mkdir -p "$d/logs"; lock_dir $a
  ENVV=(HOME="$d" PORT=3002);                         ARGV=("$NODE/bin/node" "$d/server/index.js"); plist "$(label_of $a)" $a "$d/server" "$d/logs/server.log"
  ENVV=(HOME="$d" NODE_ENV=production);               ARGV=("$NODE/bin/node" "$d/web/node_modules/next/dist/bin/next" start -p 3010 -H 127.0.0.1); plist "$(label_of $a web)" $a "$d/web" "$d/logs/web.log"
  run install -m 755 -o root -g wheel "$HERE/bin/deploy-hitster" "$APPS/bin/deploy-hitster"
  if [ $ALLOW_DEPLOY = 1 ]; then      # lets scripts/deploy.sh update Hitster without typing the sudo password every time
    say "allowing $SRC_USER to run exactly one command as root, without a password: /opt/apps/bin/deploy-hitster"
    run sh -c "echo '$SRC_USER ALL=(root) NOPASSWD: $APPS/bin/deploy-hitster' > /etc/sudoers.d/deploy-hitster && chmod 440 /etc/sudoers.d/deploy-hitster && visudo -cf /etc/sudoers.d/deploy-hitster"
  fi
  agent_off com.eliastrana.hitster 3002; agent_off com.eliastrana.hitster-web 3010
  daemon_up "$(label_of $a)"; daemon_up "$(label_of $a web)"
  wait_for "hitster game server" http_ok http://127.0.0.1:3002/health && wait_for "hitster web" http_ok http://127.0.0.1:3010/ || { rollback_hitster; die "hitster failed its health check; rolled back"; }
}
rollback_hitster() { daemon_down "$(label_of hitster)"; daemon_down "$(label_of hitster web)"; agent_on com.eliastrana.hitster; agent_on com.eliastrana.hitster-web; }

install_arena() {
  local a=arena d; d=$(dir_of $a)
  [ -d "$SRC_HOME/arena" ] || die "no $SRC_HOME/arena"
  create_account $a; ensure_node
  sync_in "$SRC_HOME/arena" "$d"; run mkdir -p "$d/logs"; lock_dir $a
  ENVV=(HOME="$d"); ARGV=("$NODE/bin/node" "$d/server/index.js"); plist "$(label_of $a)" $a "$d" "$d/logs/arena.log"
  agent_off com.eliastrana.arena 3001; daemon_up "$(label_of $a)"
  wait_for "arena" http_ok http://127.0.0.1:3001/ || { rollback_arena; die "arena failed its health check; rolled back"; }
}
rollback_arena() { daemon_down "$(label_of arena)"; agent_on com.eliastrana.arena; }

install_mcpack() {
  local a=mcpack d; d=$(dir_of $a)
  [ -d "$SRC_HOME/mc-packs" ] || die "no $SRC_HOME/mc-packs"
  create_account $a
  sync_in "$SRC_HOME/mc-packs" "$d/mc-packs"; run mkdir -p "$d/logs"; lock_dir $a
  # /usr/bin/python3 is a developer-tools shim; make sure the new account can actually run it
  [ $DRY = 1 ] || sudo -u "$(user_of $a)" /usr/bin/python3 --version >/dev/null || die "python3 does not work for $(user_of $a) (install the Xcode command line tools system-wide)"
  ENVV=(HOME="$d"); ARGV=(/usr/bin/python3 "$d/mc-packs/serve.py"); plist "$(label_of $a)" $a "$d/mc-packs" "$d/logs/mcpack.log"
  agent_off com.eliastrana.mcpack 8090; daemon_up "$(label_of $a)"
  wait_for "mc-packs" http_ok http://127.0.0.1:8090/ || { rollback_mcpack; die "mcpack failed its health check; rolled back"; }
}
rollback_mcpack() { daemon_down "$(label_of mcpack)"; agent_on com.eliastrana.mcpack; }

install_status() {
  local a=status d; d=$(dir_of $a)
  [ -d "$SRC_HOME/status" ] || die "no $SRC_HOME/status"
  create_account $a; ensure_node
  sync_in "$SRC_HOME/status" "$d"; run mkdir -p "$d/data" "$d/logs"; lock_dir $a
  ENVV=(HOME="$d" DATA_DIR="$d/data"); ARGV=("$NODE/bin/node" "$d/server.js"); plist "$(label_of $a)" $a "$d" "$d/logs/status.log"
  agent_off com.eliastrana.status 3020; daemon_up "$(label_of $a)"
  wait_for "status page" http_ok http://127.0.0.1:3020/login || { rollback_status; die "status failed its health check; rolled back"; }
  warn "change the password later with: sudo -u $(user_of $a) env DATA_DIR=$d/data $NODE/bin/node $d/set-password.js"
}
rollback_status() { daemon_down "$(label_of status)"; agent_on com.eliastrana.status; }

install_chatbot() {
  local a=chatbot d; d=$(dir_of $a)
  # Built and tested in the staging folder first (see ops/README.md); the original ~/chatbot-ollama is left alone.
  [ -d "$SRC_HOME/deploy/chatbot" ] || die "no $SRC_HOME/deploy/chatbot (the staged, built copy)"
  create_account $a; ensure_node
  sync_in "$SRC_HOME/deploy/chatbot" "$d"; run mkdir -p "$d/logs"; lock_dir $a
  # Ollama itself stays on 127.0.0.1:11434; this app is the only thing that talks to it, and Caddy puts a password in front.
  ENVV=(HOME="$d" NODE_ENV=production OLLAMA_HOST=http://127.0.0.1:11434 DEFAULT_MODEL=llama3.2:1b)
  ARGV=("$NODE/bin/node" "$d/node_modules/next/dist/bin/next" start -p 3030 -H 127.0.0.1)
  plist "$(label_of $a)" $a "$d" "$d/logs/chatbot.log"
  daemon_up "$(label_of $a)"
  wait_for "chatbot web (port 3030)" http_ok http://127.0.0.1:3030/ || { rollback_chatbot; die "chatbot failed its health check; removed again"; }
}
rollback_chatbot() { daemon_down "$(label_of chatbot)"; }

install_llmgate() {
  local a=llmgate d; d=$(dir_of $a)
  [ -d "$SRC_HOME/deploy/llmgate" ] || die "no $SRC_HOME/deploy/llmgate (the staged login gate)"
  create_account $a; ensure_node
  sync_in "$SRC_HOME/deploy/llmgate" "$d" --exclude data; run mkdir -p "$d/data" "$d/logs"; lock_dir $a
  ENVV=(HOME="$d" DATA_DIR="$d/data"); ARGV=("$NODE/bin/node" "$d/server.js")
  plist "$(label_of $a)" $a "$d" "$d/logs/llmgate.log"
  daemon_up "$(label_of $a)"
  wait_for "llm login gate (port 3040)" http_ok http://127.0.0.1:3040/login || { rollback_llmgate; die "llmgate failed its health check; removed again"; }
  warn "set the password:  sudo -u $(user_of $a) env DATA_DIR=$d/data $NODE/bin/node $d/set-password.js"
}
rollback_llmgate() { daemon_down "$(label_of llmgate)"; }

install_minecraft() {
  local a=minecraft d s java jh; d=$(dir_of $a); s=$d/server
  [ -d "$SRC_HOME/minecraft-server" ] || die "no $SRC_HOME/minecraft-server"
  say "Minecraft goes offline for a few minutes while the world is copied and the JVM pre-touches 8 GB."
  [ $YES = 1 ] || [ $DRY = 1 ] || { read -r -p "Is it OK to restart Minecraft now (nobody playing)? [y/N] " ok; [ "$ok" = y ] || die "cancelled"; }
  create_account $a
  jh=$(cat "$SRC_HOME/minecraft-server/.javahome"); java="${jh/#$SRC_HOME\/jdk/$d/jdk}/bin/java"
  run mkdir -p "$d"; run chown "$(user_of $a):$(user_of $a)" "$d"
  say "first copy while the server is still running (shortens the downtime)"
  sync_in "$SRC_HOME/jdk" "$d/jdk"; sync_in "$SRC_HOME/minecraft-server" "$s"; sync_in "$SRC_HOME/mc-backups" "$d/backups"
  run mkdir -p "$d/logs"; lock_dir $a      # rsync restored the old owner and modes; give it all to the service account first
  say "preflight: can $(user_of $a) run Java and open the console pipe? (checked before anything is stopped)"
  if [ $DRY = 1 ]; then echo "   + sudo -u $(user_of $a) java -version / mkfifo + open console.in"; else
    local out
    out=$(cd / && sudo -u "$(user_of $a)" env HOME="$d" "$java" -version 2>&1) || { printf '%s\n' "$out" | sed 's/^/     | /' >&2; ls -ld "$d" "$d/jdk" "$java" 2>&1 | sed 's/^/     | /' >&2; die "preflight: $java does not run as $(user_of $a); nothing was stopped"; }
    (cd / && sudo -u "$(user_of $a)" sh -c "cd '$d' && rm -f console.in && mkfifo -m 600 console.in && exec 3<>console.in") || die "preflight: cannot create the console pipe in $d; nothing was stopped"
  fi
  say "stopping the server gracefully so the world is saved"
  run sudo -u "$SRC_USER" "$SRC_HOME/minecraft-server/stop.sh"
  say "final copy (the world is consistent now)"
  sync_in "$SRC_HOME/minecraft-server" "$s" --delete
  run sh -c "echo '${jh/#$SRC_HOME\/jdk/$d/jdk}' > '$s/.javahome'"
  run mkdir -p "$d/logs"; lock_dir $a
  # launchd services have no terminal, and screen needs one (it exits with code 1 and says nothing), so Java runs
  # directly. Its stdin is a named pipe that this script holds open, so commands can be typed into it later and
  # Java never sees end-of-file. SIGTERM from launchd makes Paper save the world and stop.
  run sh -c "cat > '$d/run.sh' <<'RUNSH'
#!/bin/sh
cd $s
[ -p $d/console.in ] || mkfifo -m 600 $d/console.in
exec 3<>$d/console.in
exec $java -Xms8G -Xmx8G -XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 \\
  -XX:+UnlockExperimentalVMOptions -XX:+DisableExplicitGC -XX:+AlwaysPreTouch -XX:G1NewSizePercent=30 -XX:G1MaxNewSizePercent=40 \\
  -XX:G1HeapRegionSize=8M -XX:G1ReservePercent=20 -XX:G1HeapWastePercent=5 -XX:G1MixedGCCountTarget=4 \\
  -XX:InitiatingHeapOccupancyPercent=15 -XX:G1MixedGCLiveThresholdPercent=90 -XX:SurvivorRatio=32 -XX:+PerfDisableSharedMem \\
  -XX:MaxTenuringThreshold=1 -jar paper.jar nogui <&3
RUNSH"
  run chown "$(user_of $a):$(user_of $a)" "$d/run.sh"; run chmod 700 "$d/run.sh"
  ENVV=(HOME="$d"); ARGV=(/bin/sh "$d/run.sh")
  PLIST_EXTRA='<key>ExitTimeOut</key><integer>120</integer>'
  plist "$(label_of $a)" $a "$s" "$d/logs/minecraft.log"
  PLIST_EXTRA=
  # helpers for the admin account (they use sudo)
  run install -m 755 /dev/stdin "$APPS/bin/mc-cmd" <<MCCMD
#!/bin/sh
# usage: mc-cmd say hello      (sends a command to the Minecraft console)
echo "\$*" | sudo tee -a $d/console.in >/dev/null
MCCMD
  run install -m 755 /dev/stdin "$APPS/bin/mc-restart" <<MCRESTART
#!/bin/sh
# Graceful restart: SIGTERM makes Paper save the world and exit, launchd then starts it again.
exec sudo launchctl kill SIGTERM system/$(label_of $a)
MCRESTART
  wait_port_clear 25565
  daemon_up "$(label_of $a)"
  WAIT_TRIES=60 wait_for "minecraft (port 25565)" port_open 25565 || { rollback_minecraft; die "minecraft did not come up; rolled back to the old copy"; }
  say "commands: /opt/apps/bin/mc-cmd <command>     restart: /opt/apps/bin/mc-restart     log: sudo tail -f $s/logs/latest.log"
}
rollback_minecraft() {
  local d; d=$(dir_of minecraft)
  daemon_down "$(label_of minecraft)"
  [ $DRY = 1 ] || sleep 5
  # bring back anything written since the cutover, but never the new .javahome (it points into the locked-down folder)
  [ -d "$d/server" ] && run rsync -a --exclude .javahome "$d/server/" "$SRC_HOME/minecraft-server/"
  run chown -R "$SRC_USER:staff" "$SRC_HOME/minecraft-server"
  say "starting the old copy again so the server is back as soon as possible"
  run sudo -u "$SRC_USER" "$SRC_HOME/minecraft-server/start.sh"
}

install_caddy() {
  local a=caddy d; d=$(dir_of $a)
  [ -x "$SRC_HOME/caddy/caddy" ] || die "no caddy binary in $SRC_HOME/caddy"
  say "Caddy is the front door for every site; if it fails the script restores the old one at once."
  create_account $a
  run mkdir -p "$d/data" "$d/config"
  run cp "$SRC_HOME/caddy/caddy" "$d/caddy"
  run cp "$SRC_HOME/caddy/Caddyfile" "$d/Caddyfile"
  # keep the existing certificates and ACME account so nothing is re-issued
  [ -d "$SRC_HOME/Library/Application Support/Caddy" ] && sync_in "$SRC_HOME/Library/Application Support/Caddy" "$d/data/caddy"
  # the admin API on localhost:2019 has no password: any local process could re-route every site. Use a private socket.
  if ! grep -q '^[[:space:]]*admin ' "$SRC_HOME/caddy/Caddyfile"; then
    run sh -c "awk '{print} !done && /^\\{/ {print \"\\tadmin unix//opt/apps/caddy/admin.sock|0600\"; done=1}' '$d/Caddyfile' > '$d/Caddyfile.new' && mv '$d/Caddyfile.new' '$d/Caddyfile'"
  fi
  run mkdir -p "$d/logs"; lock_dir $a
  run chown root:admin "$d/Caddyfile"; run chmod 664 "$d/Caddyfile"       # admins edit it without sudo, caddy only reads it
  run chmod 751 "$d"                                                     # admins can reach the Caddyfile, nobody can list the folder
  ENVV=(HOME="$d" XDG_DATA_HOME="$d/data" XDG_CONFIG_HOME="$d/config"); ARGV=("$d/caddy" run --config "$d/Caddyfile"); plist "$(label_of $a)" $a "$d" "$d/logs/caddy.log"
  agent_off com.eliastrana.caddy 8443; daemon_up "$(label_of $a)"
  wait_for "caddy (port 8443)" port_open 8443 || { rollback_caddy; die "caddy failed; old caddy restored"; }
  run install -m 755 /dev/stdin "$APPS/bin/caddy-reload" <<RELOAD
#!/bin/sh
exec sudo -u $(user_of caddy) $d/caddy reload --config $d/Caddyfile --address unix/$d/admin.sock
RELOAD
}
rollback_caddy() { daemon_down "$(label_of caddy)"; agent_on com.eliastrana.caddy; }

install_fn()  { "install_$1"; }
rollback_fn() { "rollback_$1"; }

# ---------------------------------------------------------------- commands
ALL=(hitster arena mcpack status chatbot llmgate minecraft caddy)       # order: low risk first, the front door last
status_cmd() {
  say "who is listening where (root can see every user's sockets)"
  lsof -nP -iTCP -sTCP:LISTEN | awk 'NR>1 && $9 !~ /^127\.0\.0\.1:(5|6)[0-9]{4}$/ {printf "%-12s %-18s %s\n", $3, $1, $9}' | sort -u
}
for_apps() { local fn=$1 t=$2; if [ "$t" = all ]; then for x in "${ALL[@]}"; do "$fn" "$x"; done; else "$fn" "$t"; fi; }
valid_app() { [ "$1" = all ] || printf '%s\n' "${ALL[@]}" | grep -qx "$1"; }
run_app() { local mode=$1 x=$2; "${mode}_$x"; }

case "$CMD" in
  install)  valid_app "${TARGET:-}" || die "usage: harden.sh install <${ALL[*]}|all>"; mkdir -p "$APPS/bin" 2>/dev/null || true
            [ $DRY = 1 ] || { chown root:wheel "$APPS" "$APPS/bin"; chmod 755 "$APPS" "$APPS/bin"; }
            for_apps "install_fn" "$TARGET" ;;
  rollback) valid_app "${TARGET:-}" || die "usage: harden.sh rollback <${ALL[*]}|all>"; for_apps "rollback_fn" "$TARGET" ;;
  status)   status_cmd ;;
  *)        sed -n '2,19p' "$0"; exit 1 ;;
esac
