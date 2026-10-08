#!/bin/bash
# Set up the trashcan from scratch: every app in its own locked-down macOS account, run by launchd.
#
#   sudo ./setup.sh [--dry-run] [--yes] [--backup DIR] [--allow-deploy] <step ...>
#   sudo ./setup.sh status          shows which account owns every listening port
#
# steps (in this order when you say "all"):
#   base       folders, Node.js, helper commands, the status page's permission to restart services
#   status     the status page                     (code: this repo,                 data: backup)
#   llmgate    the login for llm.eliastrana.no     (code: this repo,                 data: backup)
#   chatbot    the chat page                       (code: chatbot-ollama + our patch)
#   hitster    Ikke-Hitster, web and game server   (code: GitHub,                    keys: backup)
#   arena      arcade.eliastrana.no                (code: GitHub)
#   mcpack     Minecraft resource packs            (code and data: backup)
#   minecraft  the Minecraft server (+ BlueMap)    (Java: downloaded,                world: backup)
#   caddy      the web front door, last            (binary: downloaded, Caddyfile: this repo, certificates: backup)
#
# --dry-run        print every command, change nothing (works without sudo)
# --backup DIR     a folder made by backup.sh; apps restore their saved data from DIR/<app>.tar.gz
# --yes            do not ask before restarting Minecraft or overwriting things
# --allow-deploy   let your admin account update Hitster with scripts/deploy.sh without typing the sudo password
#
# Safe to run again: an app that already exists is updated and restarted, not duplicated.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
APPS=/opt/apps
NODE=/opt/node
LABEL_PREFIX=com.eliastrana.svc
DRY=0; YES=0; ALLOW_DEPLOY=0; BACKUP=; LAST_LOG=; LAST_LABEL=
ALL=(base status llmgate chatbot hitster arena mcpack minecraft caddy)

# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=config/versions.conf
. "$HERE/config/versions.conf"

STEPS=()
while [ $# -gt 0 ]; do
  case $1 in
    --dry-run) DRY=1;;
    --yes) YES=1;;
    --allow-deploy) ALLOW_DEPLOY=1;;
    --backup) shift; BACKUP=${1:-}; [ -d "$BACKUP" ] || die "--backup needs a folder that exists";;
    -h|--help) sed -n '2,24p' "$0"; exit 0;;
    *) STEPS+=("$1");;
  esac
  shift
done
[ ${#STEPS[@]} -gt 0 ] || { sed -n '2,24p' "$0"; exit 1; }
[ "$DRY" = 1 ] || [ "$(id -u)" = 0 ] || die "run with sudo (or add --dry-run to just print what would happen)"
[ -z "$BACKUP" ] || BACKUP=$(cd "$BACKUP" && pwd)

# The admin account that ran sudo: it may edit the Caddyfile and (with --allow-deploy) update Hitster.
ADMIN_USER=${SUDO_USER:-$(id -un)}
ADMIN_HOME=$(dscl . -read "/Users/$ADMIN_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
ADMIN_HOME=${ADMIN_HOME:-/Users/$ADMIN_USER}

# Write a root-owned file whose content comes on stdin.
put_file() {   # put_file <mode> <dest>
  if [ "$DRY" = 1 ]; then echo "   + write $2 (mode $1)"; cat > /dev/null; else install -m "$1" -o root -g wheel /dev/stdin "$2"; fi
}

# ================================================================ base
ensure_node() {
  if [ -x "$NODE/bin/node" ]; then say "node is already in $NODE ($("$NODE/bin/node" -v))"; return; fi
  local tarball="node-$NODE_VERSION-$NODE_ARCH.tar.gz" base="https://nodejs.org/dist/$NODE_VERSION" tmp
  say "installing Node.js $NODE_VERSION into $NODE (one copy, owned by root, shared by every service)"
  tmp=$(mktemp -d)
  download "$base/$tarball" "$tmp/$tarball"
  if [ "$DRY" = 1 ]; then echo "   + check the checksum against $base/SHASUMS256.txt"; else
    local want; want=$(curl -fsSL "$base/SHASUMS256.txt" | awk -v f="$tarball" '$2 == f {print $1}')
    [ -n "$want" ] || die "could not find the checksum for $tarball"
    check_sha "$tmp/$tarball" "$want"
  fi
  run mkdir -p "$NODE"
  run tar -xzf "$tmp/$tarball" -C "$NODE" --strip-components=1
  run chown -R root:wheel "$NODE"
  run chmod -R go-w "$NODE"
  rm -rf "$tmp"
}

step_base() {
  say "folders"
  run mkdir -p "$APPS/bin"
  run chown root:wheel "$APPS" "$APPS/bin"; run chmod 755 "$APPS" "$APPS/bin"
  ensure_node

  say "helper commands in $APPS/bin (root-owned, so a hacked app cannot change them)"
  run install -m 755 -o root -g wheel "$HERE/bin/svc-control" "$APPS/bin/svc-control"
  sed "s#^SRC=.*#SRC=$ADMIN_HOME/deploy/hitster#" "$HERE/bin/deploy-hitster" | put_file 755 "$APPS/bin/deploy-hitster"
  put_file 755 "$APPS/bin/caddy-reload" <<EOF
#!/bin/sh
exec sudo -u $(user_of caddy) $APPS/caddy/caddy reload --config $APPS/caddy/Caddyfile --address unix/$APPS/caddy/admin.sock
EOF
  put_file 755 "$APPS/bin/mc-cmd" <<EOF
#!/bin/sh
# usage: mc-cmd say hello      (sends a command to the Minecraft console)
echo "\$*" | sudo tee -a $APPS/minecraft/console.in >/dev/null
EOF
  put_file 755 "$APPS/bin/mc-restart" <<EOF
#!/bin/sh
# Graceful restart: SIGTERM makes Paper save the world and exit, launchd then starts it again.
exec sudo launchctl kill SIGTERM system/$(label_of minecraft)
EOF

  say "letting the status account run svc-control for these exact id/action pairs, and nothing else"
  local tmp pair; tmp=$(mktemp)
  {
    echo "# written by setup.sh: the status page may run these commands as root, and nothing else"
    for pair in "caddy restart" \
                "arena stop" "arena start" "arena restart" \
                "hitweb stop" "hitweb start" "hitweb restart" \
                "hitws stop" "hitws start" "hitws restart" \
                "mcpack stop" "mcpack start" "mcpack restart" \
                "minecraft stop" "minecraft start" "minecraft restart"; do
      echo "$(user_of status) ALL=(root) NOPASSWD: $APPS/bin/svc-control $pair"
    done
  } > "$tmp"
  if [ "$DRY" = 1 ]; then echo "   + validate with visudo, install as /etc/sudoers.d/status-control"; else
    visudo -cf "$tmp" >/dev/null || die "the sudoers file did not validate; nothing was installed"
    install -m 440 -o root -g wheel "$tmp" /etc/sudoers.d/status-control
  fi
  rm -f "$tmp"

  if [ "$ALLOW_DEPLOY" = 1 ]; then
    say "allowing $ADMIN_USER to run exactly one command as root without a password: $APPS/bin/deploy-hitster"
    echo "$ADMIN_USER ALL=(root) NOPASSWD: $APPS/bin/deploy-hitster" | put_file 440 /etc/sudoers.d/deploy-hitster
    [ "$DRY" = 1 ] || visudo -cf /etc/sudoers.d/deploy-hitster >/dev/null
  fi
}

# ================================================================ small node apps from this repo
ensure_password() {   # ensure_password <app>
  local a=$1 d; d=$(dir_of "$1")
  if [ "$DRY" = 1 ]; then echo "   + ask for the $a password, unless $d/data/password.json came back with the backup"; return; fi
  [ -f "$d/data/password.json" ] && { say "the $a password is already set (restored from the backup)"; return; }
  if [ -t 0 ]; then
    say "choose the password for $a (at least 12 characters)"
    sudo -u "$(user_of "$a")" env DATA_DIR="$d/data" "$NODE/bin/node" "$d/set-password.js" || warn "no password was set; run it later (see README)"
  else
    warn "no password set yet. Run: sudo -u $(user_of "$a") env DATA_DIR=$d/data $NODE/bin/node $d/set-password.js"
  fi
}

step_status() {
  local a=status d; d=$(dir_of status)
  create_account $a
  sync_in "$HERE/status" "$d" --exclude data
  run mkdir -p "$d/data" "$d/logs"
  restore_state $a || true
  lock_dir $a
  ENVV=(HOME="$d" DATA_DIR="$d/data"); ARGV=("$NODE/bin/node" "$d/server.js")
  plist "$(label_of $a)" $a "$d" "$d/logs/status.log"
  daemon_up "$(label_of $a)"
  wait_for "status page (port 3020)" http_ok http://127.0.0.1:3020/login || die "the status page did not start"
  ensure_password $a
}

step_llmgate() {
  local a=llmgate d; d=$(dir_of llmgate)
  create_account $a
  sync_in "$HERE/llm-gate" "$d" --exclude data
  run mkdir -p "$d/data" "$d/logs"
  restore_state $a || true
  lock_dir $a
  ENVV=(HOME="$d" DATA_DIR="$d/data"); ARGV=("$NODE/bin/node" "$d/server.js")
  plist "$(label_of $a)" $a "$d" "$d/logs/llmgate.log"
  daemon_up "$(label_of $a)"
  wait_for "llm login gate (port 3040)" http_ok http://127.0.0.1:3040/login || die "the login gate did not start"
  ensure_password $a
}

# ================================================================ chat page
step_chatbot() {
  local a=chatbot d tmp; d=$(dir_of chatbot)
  command -v git >/dev/null || die "git is missing (install the Xcode command line tools: xcode-select --install)"
  create_account $a
  say "fetching chatbot-ollama at $CHATBOT_COMMIT and applying our changes (chatbot/chatbot.patch)"
  tmp=$(mktemp -d)
  run git clone -q "$CHATBOT_GIT" "$tmp/src"
  run git -C "$tmp/src" checkout -q "$CHATBOT_COMMIT"
  run git -C "$tmp/src" apply "$HERE/chatbot/chatbot.patch"
  sync_in "$tmp/src" "$d" --exclude .git
  run mkdir -p "$d/logs"
  lock_dir $a
  say "installing dependencies and building, as $(user_of $a) (takes a few minutes)"
  as_app $a "$d" "npm ci --silent && npx next build >/dev/null"
  ENVV=(HOME="$d" NODE_ENV=production OLLAMA_HOST=http://127.0.0.1:11434 DEFAULT_MODEL="$CHATBOT_MODEL")
  ARGV=("$NODE/bin/node" "$d/node_modules/next/dist/bin/next" start -p 3030 -H 127.0.0.1)
  plist "$(label_of $a)" $a "$d" "$d/logs/chatbot.log"
  daemon_up "$(label_of $a)"
  wait_for "chat page (port 3030)" http_ok http://127.0.0.1:3030/ || die "the chat page did not start"
  rm -rf "$tmp"
  port_open 11434 || warn "Ollama is not answering on 127.0.0.1:11434. Install it from https://ollama.com and pull: $OLLAMA_MODELS"
}

# ================================================================ Hitster
step_hitster() {
  local a=hitster d tmp; d=$(dir_of hitster)
  command -v git >/dev/null || die "git is missing (install the Xcode command line tools: xcode-select --install)"
  create_account $a
  say "fetching Hitster ($HITSTER_GIT, branch $HITSTER_BRANCH)"
  tmp=$(mktemp -d)
  run git clone -q --depth 1 --branch "$HITSTER_BRANCH" "$HITSTER_GIT" "$tmp/src"
  sync_in "$tmp/src" "$d/web" --exclude .git --exclude server --exclude node_modules --exclude .next --exclude .env.local
  sync_in "$tmp/src/server" "$d/server" --exclude node_modules --exclude dist
  run mkdir -p "$d/logs"
  restore_state $a || true                                   # brings back web/.env.local (Spotify keys)
  if [ "$DRY" != 1 ] && [ ! -f "$d/web/.env.local" ]; then
    die "Hitster needs $d/web/.env.local (SPOTIFY_CLIENT_ID, SPOTIFY_CLIENT_SECRET, NEXTAUTH_SECRET, NEXTAUTH_URL, NEXT_PUBLIC_MP_URL). Restore it with --backup, or create it and run again."
  fi
  lock_dir $a
  say "building as $(user_of $a) (takes a few minutes)"
  as_app $a "$d/web" "npm ci --silent && npm run build:server >/dev/null && npx next build >/dev/null"
  as_app $a "$d" "rm -rf server/dist && cp -R web/server/dist server/dist && rm -rf web/server"
  as_app $a "$d/server" "npm install --omit=dev --silent"
  ENVV=(HOME="$d" PORT=3002);           ARGV=("$NODE/bin/node" "$d/server/index.js")
  plist "$(label_of $a)" $a "$d/server" "$d/logs/server.log"
  ENVV=(HOME="$d" NODE_ENV=production); ARGV=("$NODE/bin/node" "$d/web/node_modules/next/dist/bin/next" start -p 3010 -H 127.0.0.1)
  plist "$(label_of $a web)" $a "$d/web" "$d/logs/web.log"
  daemon_up "$(label_of $a)"; daemon_up "$(label_of $a web)"
  wait_for "hitster game server (port 3002)" http_ok http://127.0.0.1:3002/health || die "the Hitster game server did not start"
  wait_for "hitster web (port 3010)" http_ok http://127.0.0.1:3010/ || die "the Hitster web app did not start"
  rm -rf "$tmp"
}

# ================================================================ apps that only exist on this machine (restored from the backup)
step_arena() {
  local a=arena d tmp; d=$(dir_of arena)
  command -v git >/dev/null || die "git is missing (install the Xcode command line tools: xcode-select --install)"
  create_account $a
  say "fetching the arcade ($ARENA_GIT, branch $ARENA_BRANCH)"
  tmp=$(mktemp -d)
  run git clone -q --depth 1 --branch "$ARENA_BRANCH" "$ARENA_GIT" "$tmp/src"
  sync_in "$tmp/src" "$d" --exclude .git
  restore_state arena-music || warn "no saved menu music (arena-music.tar.gz): the game plays its built-in tune instead"
  run mkdir -p "$d/logs"; lock_dir $a
  as_app $a "$d" "npm ci --omit=dev --silent"
  ENVV=(HOME="$d"); ARGV=("$NODE/bin/node" "$d/server/index.js")
  plist "$(label_of $a)" $a "$d" "$d/logs/arena.log"
  daemon_up "$(label_of $a)"
  wait_for "arena (port 3001)" http_ok http://127.0.0.1:3001/ || die "arena did not start"
  rm -rf "$tmp"
}

step_mcpack() {
  local a=mcpack d; d=$(dir_of mcpack)
  create_account $a
  need_state $a "the resource packs and serve.py"
  run mkdir -p "$d/logs"; lock_dir $a
  # /usr/bin/python3 is a developer-tools shim; make sure the new account can really run it
  [ "$DRY" = 1 ] || sudo -u "$(user_of $a)" /usr/bin/python3 --version >/dev/null || die "python3 does not work for $(user_of $a) (run xcode-select --install)"
  ENVV=(HOME="$d"); ARGV=(/usr/bin/python3 "$d/mc-packs/serve.py")
  plist "$(label_of $a)" $a "$d/mc-packs" "$d/logs/mcpack.log"
  daemon_up "$(label_of $a)"
  wait_for "mc-packs (port 8090)" http_ok http://127.0.0.1:8090/ || die "mcpack did not start"
}

step_minecraft() {
  local a=minecraft d s java; d=$(dir_of minecraft); s=$d/server
  java="$d/jdk/$JDK_VERSION/Contents/Home/bin/java"
  create_account $a
  need_state $a "the world, plugins and paper.jar"
  if [ ! -x "$java" ]; then
    say "downloading Java ($JDK_VERSION) from Adoptium"
    local tmp; tmp=$(mktemp -d)
    download "https://api.adoptium.net/v3/binary/version/$JDK_VERSION/mac/$JDK_ARCH/jdk/hotspot/normal/eclipse" "$tmp/jdk.tar.gz"
    run mkdir -p "$d/jdk"
    run tar -xzf "$tmp/jdk.tar.gz" -C "$d/jdk"
    rm -rf "$tmp"
  fi
  run mkdir -p "$d/logs"; lock_dir $a
  say "preflight: can $(user_of $a) run Java and open the console pipe?"
  if [ "$DRY" = 1 ]; then echo "   + sudo -u $(user_of $a) java -version, and mkfifo console.in"; else
    sudo -u "$(user_of $a)" env HOME="$d" "$java" -version >/dev/null 2>&1 || die "$java does not run as $(user_of $a)"
    (cd / && sudo -u "$(user_of $a)" sh -c "rm -f '$d/console.in' && mkfifo -m 600 '$d/console.in'") || die "cannot create the console pipe in $d"
  fi
  # launchd services have no terminal and "screen" needs one, so Java runs directly. Its input is a named pipe that this
  # script keeps open, so commands can be typed into it later (mc-cmd) and Java never sees end-of-file.
  # SIGTERM from launchd makes Paper save the world and stop.
  put_file 700 "$d/run.sh" <<EOF
#!/bin/sh
cd $s
[ -p $d/console.in ] || mkfifo -m 600 $d/console.in
exec 3<>$d/console.in
exec $java -Xms8G -Xmx8G -XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 -XX:+UnlockExperimentalVMOptions -XX:+DisableExplicitGC -XX:+AlwaysPreTouch -XX:G1NewSizePercent=30 -XX:G1MaxNewSizePercent=40 -XX:G1HeapRegionSize=8M -XX:G1ReservePercent=20 -XX:G1HeapWastePercent=5 -XX:G1MixedGCCountTarget=4 -XX:InitiatingHeapOccupancyPercent=15 -XX:G1MixedGCLiveThresholdPercent=90 -XX:SurvivorRatio=32 -XX:+PerfDisableSharedMem -XX:MaxTenuringThreshold=1 -jar paper.jar nogui <&3
EOF
  run chown "$(user_of $a):$(user_of $a)" "$d/run.sh"
  ENVV=(HOME="$d"); ARGV=(/bin/sh "$d/run.sh")
  PLIST_EXTRA='<key>ExitTimeOut</key><integer>120</integer>'
  plist "$(label_of $a)" $a "$s" "$d/logs/minecraft.log"
  PLIST_EXTRA=
  wait_port_clear 25565
  daemon_up "$(label_of $a)"
  WAIT_TRIES=90 wait_for "minecraft (port 25565)" port_open 25565 || die "Minecraft did not come up; read $d/logs/minecraft.log"
  say "commands: $APPS/bin/mc-cmd <command>    restart: $APPS/bin/mc-restart    log: sudo tail -f $s/logs/latest.log"
}

# ================================================================ Caddy
step_caddy() {
  local a=caddy d tmp base tarball sums want; d=$(dir_of caddy)
  tarball="caddy_${CADDY_VERSION}_${CADDY_ARCH}.tar.gz"
  base="https://github.com/caddyserver/caddy/releases/download/v$CADDY_VERSION"
  create_account $a
  say "downloading Caddy $CADDY_VERSION"
  tmp=$(mktemp -d)
  download "$base/$tarball" "$tmp/$tarball"
  if [ "$DRY" = 1 ]; then echo "   + check the checksum against $base/caddy_${CADDY_VERSION}_checksums.txt"; else
    sums=$(curl -fsSL "$base/caddy_${CADDY_VERSION}_checksums.txt") || die "could not download the Caddy checksums"
    want=$(printf '%s\n' "$sums" | awk -v f="$tarball" '$2 == f {print $1}')
    [ -n "$want" ] || die "no checksum listed for $tarball"
    check_sha "$tmp/$tarball" "$want"
  fi
  run mkdir -p "$d/data" "$d/config" "$d/logs"
  run tar -xzf "$tmp/$tarball" -C "$d" caddy
  rm -rf "$tmp"
  run install -m 664 "$HERE/config/Caddyfile" "$d/Caddyfile"
  restore_state $a || warn "no saved certificates: Caddy will ask Let's Encrypt for new ones (needs DNS and the router's port forwards to be in place)"
  lock_dir $a
  run chown "root:admin" "$d/Caddyfile"; run chmod 664 "$d/Caddyfile"     # admins edit it without sudo, caddy only reads it
  run chmod 751 "$d"                                                      # admins can reach the Caddyfile, nobody can list the folder
  say "checking the Caddyfile"
  run sudo -u "$(user_of $a)" env HOME="$d" XDG_DATA_HOME="$d/data" XDG_CONFIG_HOME="$d/config" "$d/caddy" validate --config "$d/Caddyfile"
  ENVV=(HOME="$d" XDG_DATA_HOME="$d/data" XDG_CONFIG_HOME="$d/config"); ARGV=("$d/caddy" run --config "$d/Caddyfile")
  plist "$(label_of $a)" $a "$d" "$d/logs/caddy.log"
  daemon_up "$(label_of $a)"
  wait_for "caddy (port 8443)" port_open 8443 || die "Caddy did not start"
}

# ================================================================ run
status_cmd() {
  say "who is listening where (root can see every user's sockets)"
  lsof -nP -iTCP -sTCP:LISTEN | awk 'NR>1 && $9 !~ /^127\.0\.0\.1:(5|6)[0-9]{4}$/ {printf "%-14s %-18s %s\n", $3, $1, $9}' | sort -u
}

if [ "${STEPS[0]}" = status ] && [ ${#STEPS[@]} -eq 1 ]; then status_cmd; exit 0; fi
if [ "${STEPS[0]}" = all ]; then STEPS=("${ALL[@]}"); fi
for s in "${STEPS[@]}"; do printf '%s\n' "${ALL[@]}" | grep -qx "$s" || die "unknown step '$s' (steps: ${ALL[*]} all, or: status)"; done
[ "$DRY" = 1 ] || [ "$(uname -m)" = x86_64 ] || warn "this was written for the Intel Mac Pro; change NODE_ARCH, CADDY_ARCH and JDK_ARCH in config/versions.conf for $(uname -m)"
for s in "${STEPS[@]}"; do
  say "==================== $s ===================="
  "step_$s"
done
say "done. Next: check https://status.eliastrana.no (or run: sudo ./setup.sh status)"
