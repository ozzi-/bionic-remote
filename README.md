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
  thinking collapsed). When a session is awaiting an approval (tool or
  directory access), an interactive card shows the request with the
  **Approve / Deny** choice buttons. Tapping one drives Bionic's own approval
  UI over Chrome DevTools Protocol (CDP), so the decision goes through
  Bionic's real code path rather than a raw write to its database.

## Approve / deny from the phone

To approve or deny a tool / directory-access request from the phone, the
bridge has to drive Bionic's UI, which it does over **Chrome DevTools
Protocol** (CDP). That requires one thing on the PC: **Bionic must be running
with a remote-debugging port.**

> Bionic's debug port is bound to **127.0.0.1 only**, so it is not reachable
> from the LAN or the tailnet — the bridge talks to it locally on the same
> machine. This is the safe configuration; keep it that way.

**Bionic relaunch command** (run this *on the PC, in your own terminal* — the
agent must not relaunch Bionic for you, because the agent is running *inside*
Bionic and would kill itself):

```sh
# fully quit Bionic first, then relaunch with the local debug port:
/app-bionic --remote-debugging-port=9222 --remote-debugging-address=127.0.0.1
```

> The exact AppImage path varies (`~/.local/share/lm-studio/app-bionic@*`,
> or your installed `bionic` binary). Adjust the path to wherever your Bionic
> AppImage/binary lives. After relaunching, open the session you want to
> control so its approval buttons are on screen.

Then point the bridge at it (it already defaults to this, shown here for
clarity — add to `bionic-remote.service` if you changed them):

```sh
Environment=CDP_HOST=127.0.0.1
Environment=CDP_PORT=9222
Environment=CDP_TIMEOUT_MS=8000
```

**How it works end-to-end:** the app shows the pending request's choice labels
as buttons; tapping one POSTs the choice *value* to the bridge
(`POST /v1/projects/<id>/sessions/<id>/approve`); the bridge maps the value to
its label and instructs Bionic (via CDP `Runtime.evaluate`) to click the button
whose visible text matches that label. You'll see "Sent to Bionic." in the app.

If Bionic isn't running with the debug port, the approve action returns an error
(reading projects / sessions / transcripts still works — only approve/deny needs
CDP).

## Screenshots

<img height="500" alt="Screenshot_20261125_210443_001" src="https://github.com/user-attachments/assets/c0aee282-8b5c-4325-942f-d7f1b0822014" />
<img height="500" alt="Screenshot_20261125_210502_001" src="https://github.com/user-attachments/assets/2bd44832-0799-4f00-917c-0f945015b71e" />
<img height="500" alt="Screenshot_20261127_171016_001" src="https://github.com/user-attachments/assets/048c0412-526b-4003-9623-830302f584f1" />

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
# Serve only on the Tailscale network. Get the PC's tailnet IP with: tailscale ip -4
# (Remove the two BRIDGE_BIND / BRIDGE_ALLOWED_CIDRS lines to serve on the LAN instead.)
Environment=BRIDGE_BIND=<PC_TAILSCALE_IP>
Environment=BRIDGE_ALLOWED_CIDRS=loopback,100.64.0.0/10,tailscale-v6
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
# NOTE: with the Tailscale-only bind above, use the PC's tailnet IP, not 127.0.0.1.
curl -s -H "Authorization: Bearer $(cat ~/.config/bionic-remote/token)" \
     http://<PC_TAILSCALE_IP>:8443/v1/health
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
| `CDP_HOST`             | `127.0.0.1`                    | Bionic's CDP endpoint host (keep on loopback for security)         |
| `CDP_PORT`             | `9222`                         | Bionic's `--remote-debugging-port` (needed for approve/deny only)  |
| `CDP_TIMEOUT_MS`       | `8000`                         | CDP call timeout in milliseconds                                    |

### 2. App on the phone

Download the latest `harbour-bionic-remote-0.1.0-N.aarch64.rpm` from the
[releases](https://github.com/ozzi-/bionic-remote/releases) page (or copy it
from `repo/dist/` on the build machine), then:

```sh
# from the PC (replace <PHONE_IP> / <user> with your phone's)
scp harbour-bionic-remote-0.1.0-12.aarch64.rpm <user>@<PHONE_IP>:~/

# on the phone (terminal app, or ssh)
devel-su rpm -Uvh ~/harbour-bionic-remote-0.1.0-12.aarch64.rpm
```

`rpm -Uvh` upgrades over a previous version; use `rpm -ivh` for a first install.

### 3. Connect the app to the bridge

**Easiest:** open the app → pull down → **Settings** → enter the bridge URL
(`http://<PC_TAILSCALE_IP>:8443` — your PC's Tailscale IP from `tailscale ip -4`,
which is the address the bridge is bound to) and the token (from step 1b),
then *Test connection*. (If you served the bridge on the LAN instead, use the
PC's LAN IP here.)

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
- **Transport: Tailscale (recommended).** The API is plain HTTP, so the
  192-bit token is the wire protection. The recommended setup installs Tailscale
  on the PC and the phone, binds the bridge to the PC's tailnet IP, and
  allowlists only tailnet sources — the phone then talks to the bridge over the
  encrypted tailnet and the LAN port is not exposed:

  ```sh
  # in bionic-remote.service  (PC tailnet IP from: tailscale ip -4)
  Environment=BRIDGE_BIND=<PC_TAILSCALE_IP>
  Environment=BRIDGE_ALLOWED_CIDRS=loopback,100.64.0.0/10,tailscale-v6
  ```

  `100.64.0.0/10` covers Tailscale v4 (your phone's `100.x` peer),
  `tailscale-v6` covers `fd7a::/8`, and `loopback` is for local testing. The
  bridge listens only on the encrypted tailnet and only accepts tailnet
  sources.
- The bridge is **read-only** against Bionic's *data* (opens SQLite stores
  `readOnly`, all queries parameterized, project/session IDs must match the
  registry — no path traversal). The only action that changes Bionic state is
  approve/deny, and it does so by **driving Bionic's own UI over CDP on
  loopback** — never by writing to Bionic's database directly. The CDP port is
  bound to `127.0.0.1`, so only the bridge on the same machine can reach it.
- The token is stored in **plaintext** on the phone (file mode `600`).
  Acceptable for a personal device; SFOS secure storage (libkey) would be
  the next step if this ever matters to you.

## License

MIT — see [LICENSE](LICENSE).
