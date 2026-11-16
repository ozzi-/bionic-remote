# Bionic Remote

A Sailfish OS application.

Watch [LM Studio Bionic](https://lmstudio.ai/) agent sessions from your Jolla
phone: browse projects, follow live agent progress, and read transcripts.

## How it works

A small zero-dependency bridge daemon (`bridge/bridge.mjs`, Node ≥ 22) runs on
the machine where Bionic runs. It exposes Bionic's on-disk session stores over
a token-authenticated HTTP API (default `http://<bridge-host>:8443`, with a
LAN/tailscale source-IP allowlist) and is read-only with respect to Bionic's
data.

This app is the client:

- **Projects** — every Bionic project with session count, last activity and
  an active indicator (auto-refreshes every 5 s).
- **Sessions** — per-project session list with live "agent active" and
  "awaiting approval" indicators (auto-refreshes every 4 s).
- **Session** — the rolling transcript (user / Bionic / tool calls / results)
  plus a banner when an approval is pending (M1 is read-only; approve/deny
  happens in the Bionic desktop app).

## Bridge daemon setup

On the machine running Bionic:

```sh
mkdir -p ~/.config/bionic-remote
openssl rand -hex 24 > ~/.config/bionic-remote/token
node bridge/bridge.mjs          # or install as a systemd user service
```

Environment: `BRIDGE_PORT` (default 8443), `BRIDGE_TOKEN_FILE` or
`BRIDGE_TOKEN`, `BIONIC_HOME` (default `~/.lmstudio`).

## Configuration

In the app: Settings → bridge server URL + token (pre-filled with
`http://192.168.178.32:8443`), then *Test connection*.

## License

MIT — see [LICENSE](LICENSE).
