<img width="1032" height="2272" alt="Screenshot_20261127_171016_001" src="https://github.com/user-attachments/assets/52220bfb-4e61-4703-bdcb-43e8d0bbfc10" />

# Bionic Remote

A Sailfish OS application.

Watch [LM Studio Bionic](https://lmstudio.ai/) agent sessions from your Jolla
phone: browse projects, follow live agent progress, and read transcripts.

## How it works

A small zero-dependency bridge daemon (`bridge/bridge.mjs`, Node ≥ 22) runs on
the machine where Bionic runs. It exposes Bionic's on-disk session stores over
a token-authenticated HTTP API (default port `8443`, source-IP allowlist) and
is read-only with respect to Bionic's data.

This app is the client:

- **Projects** — every Bionic project with session count, last activity and
  an active indicator (auto-refreshes every 5 s).
- **Sessions** — per-project session list with live "agent active" and
  "awaiting approval" indicators (auto-refreshes every 4 s).
- **Session** — the rolling transcript (user / Bionic / tool calls / results,
  thinking collapsed) plus a banner when an approval is pending (M1 is
  read-only; approve/deny happens in the Bionic desktop app).

## Screenshots

<img height="500" alt="Screenshot_20261125_210443_001" src="https://github.com/user-attachments/assets/c0aee282-8b5c-4325-942f-d7f1b0822014" />
<img height="500" alt="Screenshot_20261125_210502_001" src="https://github.com/user-attachments/assets/2bd44832-0799-4f00-917c-0f945015b71e" />
<img width="500" height="2272" alt="Screenshot_20261127_171016_001" src="https://github.com/user-attachments/assets/048c0412-526b-4003-9623-830302f584f1" />

## Getting started

### 1. Bridge on the PC (the machine running Bionic)

Requirements: Node.js ≥ 22 (uses `node:sqlite`), nothing else.

```sh
# a) place the bridge where the service will run
mkdir -p ~/.local/share/bionic-remote
cp bridge.mjs ~/.local/share/bionic-remote/     # from this repo's bridge/ dir

# b) create the shared token (192-bit random)
mkdir -p ~/.config/bionic-remote
openssl rand -hex 24 > ~/.config/bionic-remote/token
chmod 600 ~/.config/bionic-remote/token

# c) run it — foreground for a test, or as a systemd user service (below)
node ~/.local/share/bionic-remote/bridge.mjs
```

Install as a systemd **user** service (survives reboots, starts on login):

```sh
cat > ~/.config/systemd/user/bionic-remote.service <<'EOF'
[Unit]
Description=bionic-remote bridge (Bionic session API for phone app)
After=network.target

[Service]
Environment=BRIDGE_PORT=8443
Environment=BRIDGE_TOKEN_FILE=%h/.config/bionic-remote/token
ExecStart=/usr/bin/node --no-warnings %h/.local/share/bionic-remote/bridge.mjs
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now bionic-remote
systemctl --user status bionic-remote
```

Verify (replace `TOKEN` with the contents of your token file):

```sh
curl -s -H "Authorization: Bearer $(cat ~/.config/bionic-remote/token)" \
     http://127.0.0.1:8443/v1/health
# -> {"ok":true,"name":"bionic-remote-bridge",...}
```

Bridge environment variables:

| Variable               | Default                          | Purpose                                                        |
| ---------------------- | -------------------------------- | -------------------------------------------------------------- |
| `BRIDGE_PORT`          | `8443`                           | TCP port                                                        |
| `BRIDGE_TOKEN_FILE`    | `~/.config/bionic-remote/token`  | File containing the token                                       |
| `BRIDGE_TOKEN`         | —                                | Inline token (overrides the file; avoid, visible in `ps`)       |
| `BIONIC_HOME`          | `~/.lmstudio`                    | Where Bionic keeps its data                                     |
| `BRIDGE_BIND`          | `0.0.0.0`                        | Listen address — set to your Tailscale IP to serve tailnet-only |
| `BRIDGE_ALLOWED_CIDRS` | permissive private ranges        | Strict source allowlist, e.g. `loopback,tailscale-v6,100.64.0.0/10` |

### 2. App on the phone

Download the latest `harbour-bionic-remote-0.1.0-N.aarch64.rpm` from the
[releases](https://github.com/ozzi-/bionic-remote/releases) page (or copy it
from `repo/dist/` on the build machine), then:

```sh
# from the PC (replace <PHONE_IP> / <user> with your phone's)
scp harbour-bionic-remote-0.1.0-10.aarch64.rpm <user>@<PHONE_IP>:~/

# on the phone (terminal app, or ssh)
devel-su rpm -Uvh ~/harbour-bionic-remote-0.1.0-10.aarch64.rpm
```

`rpm -Uvh` upgrades over a previous version; use `rpm -ivh` for a first install.

### 3. Connect the app to the bridge

**Easiest:** open the app → pull down → **Settings** → enter the bridge URL
(e.g. `http://<bridge-host>:8443` — the PC's LAN IP, or its Tailscale IP if
you use Tailscale) and the token (from step 1b), then *Test connection*.

**Programmatically** (sets both values at once). Close the app first —
QSettings rewrites the file on exit and would clobber your values:

```sh
# on the phone, as your normal user. The token is taken from a file you
# scp'd over first:  scp ~/.config/bionic-remote/token <user>@<PHONE_IP>:~/bionic-token
# EDIT: replace <bridge-host> with the PC's LAN IP or Tailscale IP.
mkdir -p ~/.config/ozzi
printf '[General]\nserverUrl=http://<bridge-host>:8443\ntoken=%s\n' \
    "$(cat ~/bionic-token)" > ~/.config/ozzi/harbour-bionic-remote.conf
chmod 700 ~/.config/ozzi
chmod 600 ~/.config/ozzi/harbour-bionic-remote.conf
rm ~/bionic-token
```

## Security notes

- **How the app learns the IP and token:** it doesn't have them built in.
  Both live in the app's QSettings file
  `~/.config/ozzi/harbour-bionic-remote.conf` on the phone
  (org `ozzi`, app `harbour-bionic-remote`, INI `[General]` section with
  `serverUrl` and `token` keys) — written by the Settings page or the
  terminal command above. Nothing sensitive is in the app binary or the
  repository.
- **The bridge** reads its token from `~/.config/bionic-remote/token`
  (keep it `600`); it compares tokens in constant time and rejects unknown
  source IPs.
- **Transport is plain HTTP.** On a trusted home network the 192-bit random
  token is the main protection. For anything stronger, install Tailscale on
  the PC and the phone, point the app at the PC's `100.x` Tailscale IP, and
  harden the bridge:

  ```sh
  # in bionic-remote.service
  Environment=BRIDGE_BIND=<PC_TAILSCALE_IP>
  Environment=BRIDGE_ALLOWED_CIDRS=loopback,tailscale-v6
  ```

  then the bridge listens only on the encrypted tailnet and only accepts
  tailnet sources.
- The bridge is **read-only** against Bionic's data (opens SQLite stores
  `readOnly`, all queries parameterized, project/session IDs must match the
  registry — no path traversal).
- The token is stored in **plaintext** on the phone (file mode `600`).
  Acceptable for a personal device; SFOS secure storage (libkey) would be
  the next step if this ever matters to you.

## License

MIT — see [LICENSE](LICENSE).
