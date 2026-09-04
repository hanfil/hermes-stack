# hermes-stack

A containerised, multi-persona [Hermes Agent](https://hermes-agent.nousresearch.com)
deployment: five agent profiles, each with its own gateway, sharing one image;
a browser IDE wired to the agents over the Agent Client Protocol (ACP); a
memory sidecar; and an optional Cloudflare tunnel.

This repo holds the **recipe** — Dockerfiles, compose, supervision script,
config templates. It deliberately does **not** hold state: `hermes-home/`,
`workspace/` and `wiki/` are gitignored because they are your data, not the
deployment.

---

## Table of contents

- [What gets deployed](#what-gets-deployed)
- [Prerequisites](#prerequisites)
- [Deployment phases](#deployment-phases)
- [Creating the bots (manual, in Hermes Desktop)](#creating-the-bots-manual-in-hermes-desktop)
- [Connecting Hermes Desktop to the remote gateway](#connecting-hermes-desktop-to-the-remote-gateway)
- [Managing agents in the IDE (add / remove / update)](#managing-agents-in-the-ide-add--remove--update)
- [Environment variables](#environment-variables)
- [Optional packages in the hermes-mcu image](#optional-packages-in-the-hermes-mcu-image)
- [Day-two operations](#day-two-operations)
- [Security notes](#security-notes)
- [Troubleshooting](#troubleshooting)

---

## What gets deployed

Four containers on one internal Docker network:

| Service | Container | Ports (host) | Purpose |
|---|---|---|---|
| `hermes-mcu-core` | `hermes_mcu_core` | `127.0.0.1:8787` (WebUI), `127.0.0.1:9119` (dashboard backend) | All five agent profiles, their gateways, and the ACP relays |
| `vscode-ide` | `hermes_vscode_ide` | `127.0.0.1:8080` → 3000 | openvscode-server in the browser, with the ACP panel |
| `hindsight` | `hermes_hindsight_sidecar` | `127.0.0.1:9999` | Long-term memory provider |
| `cloudflared` | `hermes_cloudflare_tunnel` | — | Optional public ingress |

Every published port binds **127.0.0.1**. Nothing is exposed to the network
except through the Cloudflare tunnel, which you configure deliberately.

### How the IDE talks to the agents

`hermes acp` speaks JSON-RPC over **stdin/stdout only** — there is no network
listener anywhere in the ACP adapter. The bridge is therefore a filesystem
socket, not a port:

```
hermes_mcu_core                          hermes_vscode_ide
  socat UNIX-LISTEN:/acp/<p>.sock   <-->   socat - UNIX-CONNECT:/acp/<p>.sock
    EXEC: hermes -p <p> acp,pipes            (spawned by the ACP extension)
                        \                   /
                    shared bind mount:  ./acp-ipc  ->  /acp
```

A Unix socket on a bind mount is the same inode on both sides of the container
boundary. No `docker.sock`, no TCP port, no privilege escalation.

`/workspace` and `/wiki` are mounted at **identical paths** in both containers.
That is a hard ACP requirement: when an agent says it edited
`/workspace/app/main.py`, the editor must find that exact path.

---

## Prerequisites

- Docker Engine with the Compose plugin
- A user with uid/gid `1000` (or adjust `UID`/`GID` in `.env`)
- ~8 GB free disk for images (Chromium and the Go toolchain are not small)
- Optional: a Cloudflare account with a tunnel, for public access

---

## Deployment phases

> **Working with an AI agent?** Phases 1–4 are fully scriptable and safe to
> delegate. Phase 5 (creating bots) is **manual on purpose** — see the
> reasoning in that section. Phase 6 is verification.

### Phase 1 — Clone and configure

```bash
git clone <this-repo> hermes-stack && cd hermes-stack

cp .env.example .env
chmod 600 .env
```

Edit `.env` and fill in every REQUIRED value. Generators:

```bash
id -u; id -g                 # UID / GID
openssl rand -base64 24      # HERMES_WEBUI_PASSWORD, dashboard password
openssl rand -base64 32      # HERMES_DASHBOARD_BASIC_AUTH_SECRET
openssl rand -hex 16         # MCU_IDE_TOKEN  (hex only — charset is enforced)
```

Set the four `MCU_*` paths to **absolute** paths under your checkout.

### Phase 2 — Pre-create the bind mounts

Do this **before** the first `up`. Docker creates missing bind-mount targets
as **root**, and the container runs as uid 1000 — it then cannot write to its
own state directory and dies in a restart loop.

```bash
mkdir -p hermes-home workspace wiki acp-ipc
chmod 700 acp-ipc          # sockets only; not world-readable
chmod 755 hermes-home workspace wiki
```

### Phase 3 — Build and start the platform (no bots yet)

On a **fresh** deployment there are no profiles, and `hermes gateway run`
refuses an unknown one:

```
Error: Profile 'tony-stark' does not exist. Create it with: hermes profile create tony-stark
```

The supervisor would then retry each of the five forever with exponential
backoff. So the first boot deliberately starts **zero** gateways. In `.env`:

```bash
MCU_GATEWAY_PROFILES=""      # empty on a first deploy — bots do not exist yet
```

Then:

```bash
docker compose build                 # hermes-mcu + vscode-ide images
docker compose up -d
```

First boot takes a few minutes: the core image creates its Python venv at
runtime, and the supervisor waits for it before starting anything.

Build assertions fail loudly if a dependency is missing, so a green build
genuinely means node, ffmpeg, gh, Go, socat and a **rendering** Chromium are
all present.

### Phase 4 — Verify the platform

Do **not** check for gateways here — there are none yet, by design. What must
be true at this point:

```bash
# All four containers up, core healthy
docker ps --format '{{.Names}}\t{{.Status}}'

# The supervisor started and found no profiles to run (expected on a fresh deploy)
docker logs hermes_mcu_core 2>&1 | grep -E 'start-mcu|no gateway profiles'

# The WebUI answers (302/200 = up)
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8787/

# IDE responds and demands its token (403 = correct)
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/
```

Open the IDE at `http://127.0.0.1:8080/?tkn=<MCU_IDE_TOKEN>`.

### Phase 5 — Authenticate

Log in to your LLM provider **once, at the root profile** (no `-p` flag),
before creating any bots — new profiles then inherit a working credential:

```bash
docker exec -it -u hermeswebui hermes_mcu_core /app/venv/bin/hermes auth login
```

> **Do not copy credentials between profiles.** OAuth refresh tokens are
> single-use: two profiles sharing one credential will revoke each other on
> refresh. Authenticate at the root and leave the per-profile credential
> stores empty; reads fall back to the root store.

### Phase 6 — Create the bots

Manual, in Hermes Desktop — see [Creating the bots](#creating-the-bots-manual-in-hermes-desktop).
This is the phase that makes the profiles exist. Nothing before it can start a
gateway.

Verify they landed on the container's filesystem:

```bash
docker exec -u hermeswebui hermes_mcu_core /app/venv/bin/hermes profile list
```

### Phase 7 — Enable the gateways and ACP sockets

Now that the profiles exist, name them in `.env`:

```bash
MCU_GATEWAY_PROFILES="phil-coulson nick-fury tony-stark daisy-johnson peter-parker"
```

Apply and verify — **this** is where the gateway count is meaningful:

```bash
docker compose up -d --force-recreate hermes-mcu-core

# One "starting gateway" line per profile you listed
docker logs hermes_mcu_core 2>&1 | grep -c 'starting gateway'

# One socket per profile, mode srw------- owned by uid 1000
ls -l acp-ipc/
```

> A socket file appearing is **not** proof the agent works: `socat` binds the
> listener before `hermes acp` is ever executed, so a socket exists even for a
> misspelled profile. The real check is a live handshake — connect the agent
> from the IDE's ACP panel and send one message.

### Phase 8 — Wire the IDE to the bots

Add one entry per bot to `ide/settings.json`, then rebuild and reseed — see
[Managing agents in the IDE](#managing-agents-in-the-ide-add--remove--update).

---

## Creating the bots (manual, in Hermes Desktop)

**Bots are created in the Hermes Desktop app, not by this repo.** That is a
deliberate design decision, not a missing feature:

1. **A bot is more than a directory.** Creating one through Desktop registers
   the profile with the backend, provisions its session database and memory
   bank, and wires its Bot Chat routing. A hand-made `profiles/<name>/`
   directory gets none of that and produces an agent that looks present but
   cannot be messaged.
2. **Bot Chat rooms are Desktop-side state.** The roster, display names and
   room membership live with the app, so the app has to be the one to create
   them.
3. **Identity should be a human decision.** Each bot gets a persona, tool
   permissions and a memory bank of its own. Those are judgement calls, and
   scripting them tends to produce five identical agents with different names.

Once the backend is reachable (next section), create each bot with
**New Agent → Create on → \<your remote connection\>**. The profile is created
on the *backend's* filesystem — inside the container, under
`hermes-home/profiles/<name>/` — so it persists across rebuilds.

After creating them, tell the supervisor which profiles get a gateway and an
ACP socket by setting `MCU_GATEWAY_PROFILES` in `.env` (Phase 7), then
recreating the core container. The value is passed through
`docker-compose.yml`; the default baked into `start-mcu.bash` is the
five-persona list, used only when the variable is absent entirely.

Persona files for the five bots in this deployment are in `souls/`. Paste the
contents into each bot's SOUL/system prompt in Desktop.

---

## Connecting Hermes Desktop to the remote gateway

The stack publishes the **dashboard backend** on `127.0.0.1:9119`. This is
what Desktop's *Remote gateway* connection talks to — it is not the WebUI on
8787.

**1. The backend must actually be running.** Publishing the port does not
start it. Inside the container:

```bash
docker exec -d -u hermeswebui hermes_mcu_core \
  /app/venv/bin/hermes serve --host 0.0.0.0 --port 9119
```

The `0.0.0.0` bind is required so Docker can forward the port. A non-loopback
bind **always** engages the auth gate, which is why the three
`HERMES_DASHBOARD_BASIC_AUTH_*` variables are mandatory — without them the
backend refuses to serve.

**2. Reach it from your workstation.** If Desktop runs on the same machine,
`http://127.0.0.1:9119` works directly. From elsewhere, prefer an SSH tunnel
over publishing the port:

```bash
ssh -N -L 9119:127.0.0.1:9119 user@your-server
```

**3. Add the connection in Desktop:** *Settings → Connections → Add →
Remote gateway*, URL `http://127.0.0.1:9119`, then the username and password
from `.env`.

> Set `HERMES_DASHBOARD_BASIC_AUTH_SECRET` to a fixed value. Without it a new
> signing key is generated on every boot and Desktop is logged out after each
> restart.

With the connection registered, the New Agent dialog gains a **Create on**
picker — choose the remote and the bot is created inside the container.

---

## Managing agents in the IDE (add / remove / update)

> **This section is written for an AI agent doing the edit.** Every agent
> entry is one JSON object; the rules below are the non-obvious parts.

Agents shown in the IDE's ACP panel come from **`ide/settings.json`**, key
`acp.agents`. One entry per bot:

```json
"Hermes — Tony Stark": {
  "command": "socat",
  "args": ["-", "UNIX-CONNECT:/acp/tony-stark.sock"],
  "env": {}
}
```

The profile is selected **by socket path**, not by a `-p` flag. There is no
`hermes` binary in the IDE container by design; `socat` connects to the
listener that the core container already runs for that profile.

### To ADD an agent

1. Create the bot in Desktop (see above) — the profile must exist first, or
   its gateway will fail with `Profile '<name>' does not exist`.
2. Add it to `MCU_GATEWAY_PROFILES` in `.env`, then
   `docker compose up -d --force-recreate hermes-mcu-core` so the core
   container opens a socket for it.
3. Add an entry to `ide/settings.json` following the pattern above. The
   socket filename is exactly the profile name plus `.sock`.
4. Apply:
   ```bash
   docker compose build vscode-ide
   IDE_RESEED_SETTINGS=1 docker compose up -d --force-recreate vscode-ide
   ```

### To REMOVE an agent

Delete its entry from `ide/settings.json` and remove it from
`MCU_GATEWAY_PROFILES`, then apply as above. Removing the panel entry does not
delete the profile or its history — do that in Desktop.

### To UPDATE settings

Edit `ide/settings.json`, then:

```bash
docker compose build vscode-ide
IDE_RESEED_SETTINGS=1 docker compose up -d --force-recreate vscode-ide
```

**Both steps are required.** `ide/` is baked into the image, not bind-mounted,
and the entrypoint seeds settings only when the file is **absent** — so a
rebuild alone changes nothing in a container whose volume already has one.
`IDE_RESEED_SETTINGS=1` forces the template over the live copy and keeps a
timestamped `.bak`. Without the flag, an ordinary restart leaves settings you
changed in the IDE UI untouched.

### Pitfalls worth knowing

- **The extension's built-in agents are stripped at build time.** `acp-client`
  ships eleven defaults (including one named `Hermes Agent` that runs a bare
  `hermes` binary and always fails here). VS Code *deep-merges* a
  configuration default object with the user value, so removing them via
  settings — or via `ACP: Remove Agent` — does not stick; they return on
  refresh. `Dockerfile.ide` rewrites the manifest default to `{}` instead. To
  re-add a real one (Claude Code, Codex CLI…), add an explicit entry to
  `ide/settings.json`.
- **Session lists are scoped by working directory.** The ACP panel lists
  sessions for `workspaceFolders[0]` only. In `ide/mcu.code-workspace`,
  `/workspace` is deliberately first — putting `/wiki` first makes every agent
  session start in the wiki. The extension's `acp.defaultWorkingDirectory`
  setting is **declared but never read**; folder order is the only lever.
- **A session appears in the list only after it has at least one message.**
  Connecting alone creates an empty session that is filtered out.
- **Changing `ide/settings.json` requires a rebuild + reseed** (above).

---

## Environment variables

Every variable this deployment reads. Full annotated copy in `.env.example`.

### Required

| Variable | Used by | Purpose |
|---|---|---|
| `UID` / `GID` | compose, `start-mcu.bash` | Remaps the in-image user (uid 1024) to your host user so bind-mounted files stay host-owned. Wrong values ⇒ permission errors on first boot. |
| `MCU_HERMES_HOME` | compose | Host path for all persistent agent state: profiles, session DBs, memory, credentials. **Back this up.** |
| `MCU_WORKSPACE` | compose | Host path for the agents' git checkouts. Mounted at `/workspace` in **both** containers at the same path (ACP requirement). |
| `MCU_WIKI` | compose | Host path for the Obsidian knowledge base, mounted at `/wiki` in both. |
| `MCU_ACP_IPC` | compose | Host path holding one Unix socket per profile, mounted at `/acp`. Mode 700. Its own mount so socket files never appear inside a git repo. |
| `HERMES_WEBUI_PASSWORD` | compose | Login for the WebUI on 8787 — the surface the Cloudflare tunnel fronts. |
| `MCU_IDE_TOKEN` | compose | openvscode-server connection token. **Charset enforced: `0-9 a-z A-Z -` only.** Without it the entrypoint exits 78 rather than starting unauthenticated. |

### Required for Hermes Desktop

| Variable | Purpose |
|---|---|
| `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` | Dashboard backend login (port 9119). |
| `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD` | Dashboard backend password. Mandatory because a non-loopback bind always engages the auth gate. |
| `HERMES_DASHBOARD_BASIC_AUTH_SECRET` | Stable session-signing key. Omit it and a random key per boot logs Desktop out on every restart. |

### Optional

| Variable | Default | Purpose |
|---|---|---|
| `IDE_RESEED_SETTINGS` | `0` | Set to `1` for one boot to force `ide/settings.json` and `ide/mcu.code-workspace` over the live copies (a `.bak` is kept). |
| `CLOUDFLARE_TUNNEL_TOKEN` | — | Token-based tunnel. Omit the `cloudflared` service for a LAN-only install. Ingress hostnames are set in the Cloudflare dashboard. |
| `HERMES_CUSTOM_BAMSE_API_KEY` | — | API key for a custom OpenAI-compatible endpoint. Unnecessary when agents use an Anthropic/OpenAI subscription. |
| `MCU_GATEWAY_PROFILES` | the five personas | Space-separated profiles that get a gateway **and** an ACP socket. **Set it to `""` on a first deploy** — the profiles do not exist yet and `gateway run` refuses an unknown one. Fill it in after Phase 6. This is also the list to edit when adding or removing a bot. |
| `MCU_GATEWAY_STAGGER_S` | `8` | Seconds between gateway starts, to avoid a thundering herd at boot. |

---

## Optional packages in the hermes-mcu image

The base image (`ghcr.io/nesquena/hermes-webui`) ships none of these. They are
added in `Dockerfile` **for agent convenience** — the stack runs without any
of them, but the corresponding capability disappears. Nothing installs at
runtime: `/usr/local` and `/opt` are read-only to the agent user and container
recreation wipes runtime installs, so the image is the only durable seam.

| Package | Version here | What breaks without it |
|---|---|---|
| `ffmpeg` | 7.1.5 | Audio/video conversion; TTS output post-processing |
| `nodejs` (22.x, NodeSource) | 22.23.2 | Any JS/TS work, `npx`, and `agent-browser` below. Node **≥ 22 is required** by the agent's own engine constraint |
| `edge-tts` (pip) | 7.2.7 | Text-to-speech. Pure Python — no torch, no system speech libs. Needs `--break-system-packages` (Debian 13 is PEP 668) |
| `gh` (GitHub CLI) | 2.98.0 | Authenticated git over HTTPS, PR/issue workflows. Also wires the git credential helper |
| `golang-go` | 1.24.4 | Building Go projects. **No gcc in the image**, so cgo will not work — pure-Go builds only |
| `make` | 4.4.1 | Projects driven through a Makefile |
| `socat` | 1.8.x | **Not optional in practice** — it is the ACP transport. Remove it and the IDE cannot reach any agent |
| `chromium` + fonts | 152.0.7977.75 | Rendering web pages, taking screenshots, and iterating on generated UI. Fonts (`liberation`, `dejavu`, `noto-color-emoji`) prevent tofu boxes in every screenshot |
| `agent-browser` (npm, global) | latest | The CLI Hermes drives Chromium through. Installed globally because the lazy `npx` path would re-fetch into an ephemeral HOME on every container recreate |

To slim the image, delete the layer you do not need and remove its matching
build assertion — the assertions are there so a missing tool fails the build
instead of surfacing at 2am. Keep `socat`.

**Chromium runs `--no-sandbox`.** The setuid sandbox needs privileges this
container does not have. The renderer — the process that parses untrusted
HTML/JS — is contained only by the container boundary. Fine for previewing the
agents' own generated pages; do not treat it as a safe way to browse hostile
sites.

---

## Day-two operations

```bash
# Rebuild the core image and restart (REQUIRED after editing start-mcu.bash,
# which is COPY'd into the image)
./mcu-update.bash --force

# Restart without touching images
./mcu-update.bash --no-build

# Update the IDE settings template
docker compose build vscode-ide
IDE_RESEED_SETTINGS=1 docker compose up -d --force-recreate vscode-ide

# Logs
docker logs -f hermes_mcu_core
docker exec -u hermeswebui hermes_mcu_core sh -c 'tail -f ~/.hermes/logs/gateway-tony-stark.log'
```

**Always run `bash -n start-mcu.bash` before rebuilding.** A syntax error there
takes down all five gateways at once.

**Any `docker exec` touching the Hermes home must use `-u hermeswebui`.**
Running as root creates root-owned files in the agent's own state directory,
which then fails in confusing ways later.

### Backups

`hermes-home/` is the whole deployment's memory — profiles, conversation
history, credentials. `workspace/` and `wiki/` are your content. All three are
gitignored; back them up separately. The images can always be rebuilt.

---

## Security notes

- Every port binds `127.0.0.1`. The Cloudflare tunnel is the only intended
  public path.
- **Put a Cloudflare Access policy in front of any published hostname.** The
  WebUI password and IDE token have no rate limiting, no lockout and no MFA.
- Anyone reaching the IDE gets a terminal in the container, a GitHub token
  with push rights to whatever `gh` is authenticated for, and five agents with
  execution tools. Treat that URL as root access.
- `acp.autoApprovePermissions` is pinned to `"ask"` in `ide/settings.json` so
  agents prompt before acting. Changing it to `"allowAll"` removes the last
  human checkpoint.
- `.env` is mode 600 and gitignored. Rotating `MCU_IDE_TOKEN` or
  `HERMES_WEBUI_PASSWORD` requires restarting the affected container.

---

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Container restart-loops with `Permission denied` on first boot | Bind-mount target created by Docker as root. Stop the stack, `chown -R 1000:1000` the directory, pre-create mounts next time (Phase 2). |
| IDE exits immediately, `exit 78` | `MCU_IDE_TOKEN` missing from `.env`. |
| IDE exits with `connection token ... does not adhere to the characters` | Token contains characters outside `0-9 a-z A-Z -`. Regenerate with `openssl rand -hex 16`. |
| ACP panel hangs on *Loading sessions* | The relay lost `,pipes` in its `socat EXEC:` address. Without it socat uses a socketpair: `initialize` answers, the next request never does. |
| ACP agent fails instantly with `write EPIPE` | You clicked a built-in entry rather than a `Hermes — <name>` one. Rebuild the IDE image if the built-ins are back. |
| Agent sessions all start in the wrong folder | `workspaceFolders[0]` in `ide/mcu.code-workspace`. Reorder it. |
| Edits to `ide/settings.json` have no effect | Rebuild **and** reseed: `IDE_RESEED_SETTINGS=1 docker compose up -d --force-recreate vscode-ide`. |
| `Chrome crashed` / `target closed` on real pages | `/dev/shm` too small. `shm_size: 1gb` is set on `hermes-mcu-core`; add it to any service that drives Chromium. |
| Desktop logs out on every restart | `HERMES_DASHBOARD_BASIC_AUTH_SECRET` unset — a random key is generated each boot. |
| Gateway restart-loops with `Profile 'x' does not exist` | The profile is named in `MCU_GATEWAY_PROFILES` but was never created in Desktop. Create it (Phase 6), or remove it from the list. |
| Gateways never start | The venv is created at runtime on first boot; the supervisor waits for it. Check `docker logs hermes_mcu_core` for `never appeared`. If it says `no gateway profiles configured`, that is a first deploy behaving correctly — see Phase 7. |
| Build fails with `File has unexpected size` from a Debian/Ubuntu mirror | Transient mirror sync. Re-run the build. |

---

## Repository layout

```
├── Dockerfile              # hermes-mcu core image (agents, gateways, tools)
├── Dockerfile.ide          # openvscode-server sidecar
├── docker-compose.yml      # the four services
├── start-mcu.bash          # supervisor: dashboard, gateways, sidecars, ACP relays
├── mcu-update.bash         # rebuild + restart helper
├── ide/
│   ├── entrypoint.sh       # seeds settings, enforces the connection token
│   ├── settings.json       # ACP agent list + editor settings (template)
│   └── mcu.code-workspace  # multi-root workspace; folder order matters
├── souls/                  # persona files for the five bots
├── .env.example            # every variable, documented
├── .dockerignore           # keeps the build context ~20 kB
└── .gitignore              # excludes .env and all state directories
```

Gitignored, created at deploy time: `hermes-home/`, `workspace/`, `wiki/`,
`acp-ipc/`.
