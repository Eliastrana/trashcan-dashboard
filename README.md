# trashcan-dashboard

The status page for the trashcan (the Mac Pro), plus the scripts that set the whole machine up again from scratch if it
is ever reset. Every app runs in its **own locked-down macOS account**, started by launchd, behind Caddy.

| App | Account | Port | Code comes from |
|---|---|---|---|
| status page (`status/`) | `_svc_status` | 3020 | this repo |
| llm login gate (`llm-gate/`) | `_svc_llmgate` | 3040 | this repo |
| chat page for Ollama | `_svc_chatbot` | 3030 | [chatbot-ollama](https://github.com/ivanfioravanti/chatbot-ollama) + `chatbot/chatbot.patch` |
| Ikke-Hitster (web, game server) | `_svc_hitster` | 3010, 3002 | [ikke_hitster](https://github.com/Eliastrana/ikke_hitster) |
| arena (arcade.eliastrana.no) | `_svc_arena` | 3001 | [arcade](https://github.com/Eliastrana/arcade) |
| Minecraft resource packs | `_svc_mcpack` | 8090 | the backup (no git repo) |
| Minecraft server + BlueMap | `_svc_minecraft` | 25565, 8100 | Java is downloaded, the world is in the backup |
| Caddy (front door, TLS) | `_svc_caddy` | 80, 8443 | binary is downloaded, `config/Caddyfile` is in this repo |

An account like `_svc_hitster` is hidden, cannot log in and has no home folder. Its files are in `/opt/apps/<app>`, readable
by nobody else. If one app is hacked, the attacker only gets what that one account can see.

**Not covered** (set up by hand, see the end): Plex, Ollama itself, the goal notifier, the mac listener, the SSH portfolio
(already its own account `elias`, port 2222), the router's port forwards and the DNS records.

## If the trashcan was reset

You need: the macOS admin account, internet, this repo, and **your latest backup folder** (see "Backups" below: without it
the Minecraft world, and every password are gone).

1. Install macOS, make the admin account, turn on Remote Login (SSH) if you want to do this remotely.
2. Install the command line tools (gives `git` and `python3`):
   ```bash
   xcode-select --install
   ```
3. Get this repo and plug in the drive with the backup:
   ```bash
   git clone https://github.com/Eliastrana/trashcan-dashboard.git
   cd trashcan-dashboard
   ```
4. Look first, change nothing:
   ```bash
   sudo ./setup.sh --dry-run --backup /Volumes/YourDrive/trashcan-backup-2026XXXX-XXXXXX all
   ```
5. Do it for real. It asks for your admin password through `sudo`, and for the status and llm passwords if the backup does not have them:
   ```bash
   sudo ./setup.sh --backup /Volumes/YourDrive/trashcan-backup-2026XXXX-XXXXXX all
   ```
   Add `--allow-deploy` to let your admin account update Hitster with `scripts/deploy.sh` without typing the password every time.
6. Do the by-hand parts below (router, DNS, Ollama), then open https://status.eliastrana.no.

You can also run one piece at a time, in any order except that `base` must come first and `caddy` last:

```bash
sudo ./setup.sh base
sudo ./setup.sh status llmgate
sudo ./setup.sh hitster --backup <folder>
sudo ./setup.sh status          # lists which account owns every listening port
```

Each app is checked after it starts (it must answer on its port), and the script stops with the service's log if it does not.
Running it again is safe: an app that exists is updated and restarted, not duplicated.

## Backups

Git holds the code. It does **not** hold passwords, Spotify keys, the Minecraft world
or Caddy's certificates. `backup.sh` saves those, one archive per app:

```bash
sudo ./backup.sh /Volumes/YourDrive/trashcan-backup-$(date +%Y%m%d)
```

- Run it regularly and **keep the folder on another drive or computer**. A backup on the trashcan's own disk is lost with it.
- The Minecraft world is saved safely while the server runs (saving is paused, flushed, archived, resumed).
- The archives contain secrets. They are `.gitignore`d. Never push them anywhere.
- It also copies the live Caddyfile and warns if it differs from `config/Caddyfile`. Commit the difference so the repo stays the truth.

## The parts by hand

- **Router**: forward external 443 to the trashcan's port 8443, and 80 to 80 (Caddy asks Let's Encrypt for certificates through them). Minecraft needs 25565.
- **DNS**: `A` records for `arcade`, `hitster`, `status`, `llm`, `minecraftmap` (and `canvas`) pointing at your public IP.
- **Ollama**: install from https://ollama.com, then `ollama pull gemma` and `ollama pull llama3.2:1b`. It listens on `127.0.0.1:11434`.
- **Hitster keys**: they live in `/opt/apps/hitster/web/.env.local` and come back with the backup. If you start over without a backup you need
  `SPOTIFY_CLIENT_ID`, `SPOTIFY_CLIENT_SECRET`, `NEXTAUTH_SECRET`, `NEXTAUTH_URL=https://hitster.eliastrana.no` and `NEXT_PUBLIC_MP_URL=wss://hitster.eliastrana.no`
  (the Spotify redirect URI `https://hitster.eliastrana.no/api/auth/callback/spotify` must be in the Spotify dashboard).
- **Passwords**: change one later with
  `sudo -u _svc_status env DATA_DIR=/opt/apps/status/data /opt/node/bin/node /opt/apps/status/set-password.js` (same for `llmgate`).

## What is where

```
setup.sh            the restore script (above)
backup.sh           saves what git cannot
lib/common.sh       accounts, launchd, waiting, checking: shared by setup.sh
config/Caddyfile    every site, and which port it goes to
config/versions.conf  the versions and git sources setup.sh downloads (edit here)
bin/                svc-control (start/stop/restart for the status page's buttons), deploy-hitster
status/             the status page (zero dependencies, Node)
llm-gate/           the login page and gate for llm.eliastrana.no
chatbot/            the patch applied on top of chatbot-ollama
migrate/            harden.sh and friends: the one-time move from the old "everything runs as trashcan" layout
```

Day to day:
- **Edit the Caddyfile** at `/opt/apps/caddy/Caddyfile` (admins can write it), run `/opt/apps/bin/caddy-reload`, then copy it into `config/Caddyfile` here and commit.
- **Update the status page**: change `status/`, run `sudo ./setup.sh status` (it keeps its data and password).
- **Minecraft**: `/opt/apps/bin/mc-cmd say hello`, `/opt/apps/bin/mc-restart`, log in `/opt/apps/minecraft/server/logs/latest.log`.
- **Hitster deploys**: `scripts/deploy.sh` in the Hitster repo.

## The status page's buttons

The page can start, stop and restart some services. It does this through `/opt/apps/bin/svc-control`, which is root-owned and which
only the status account may run through `sudo`, for a fixed list of id/action pairs (written by `setup.sh base` into
`/etc/sudoers.d/status-control`). Anything else is refused, and no argument is ever used to build a command or path.

## Honest limits

- This is **not a virtual machine**. It stops a hacked app from reading the others, your files or your SSH settings. A flaw in macOS itself could still let an attacker out, and all apps share the same network. Keep Next.js and the other dependencies updated.
- `setup.sh` was tested with `--dry-run`, and the downloads, checksums and the Caddyfile were checked, but **it has not yet been run on a wiped machine**. The first real restore may need a fix or two. Try `--dry-run` first, and do one app at a time the first time.
- The Mac Pro is Intel. On Apple silicon change `NODE_ARCH`, `CADDY_ARCH` and `JDK_ARCH` in `config/versions.conf`.
- macOS 12 no longer gets security updates. Consider moving the apps to a machine that does.
- Hitster is restored from the branch named in `config/versions.conf` (`HITSTER_BRANCH`). Make sure the branch you actually deploy from is pushed to GitHub.
