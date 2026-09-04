FROM ghcr.io/nesquena/hermes-webui:latest

USER root

# Node 22 for the Photon sidecar (sidecar/package.json requires >=18.17) and
# for the hermes-agent repo's own toolchain, whose root package.json demands
# node ^22.22.0 || ^24.11.0 || >=26.0.0 and npm <11.10.0 || >=11.17.0.
# Node 20 satisfied Photon but failed that engine check (EBADENGINE).
# ffmpeg transcodes Edge TTS MP3 -> Ogg/Opus for voice bubbles.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg ffmpeg git \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list \
    && apt-get update && apt-get install -y --no-install-recommends nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# GitHub CLI (gh) — official apt repo.
#
# WHY IN THE IMAGE rather than a runtime install into the Hermes home:
# at runtime /usr/local/bin and /opt are NOT writable (the agent is uid 1000,
# no sudo), so a runtime install has to land somewhere in ~/.hermes and then
# fight to get on PATH. That fight is unwinnable the obvious way:
# api/profiles.py::_reload_dotenv() assigns .env values LITERALLY (no shell
# expansion), so `PATH=/some/dir:$PATH` in a profile .env sets PATH to a string
# containing the characters "$PATH" and breaks every command in that profile.
# Installing here sidesteps all of it — apt puts gh in /usr/bin, which is
# already on the scrubbed su PATH (/usr/local/bin:/usr/bin:/bin:...), so gh
# just resolves. No PATH edits anywhere.
#
# NOTE: the published keyring is already a binary GPG keyring — do NOT pipe it
# through `gpg --dearmor` (that is only needed for the ASCII-armored nodesource
# key above); dearmoring an already-binary keyring produces an unusable file.
RUN mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Edge TTS — pure Python, no system speech libs, no torch.
# --break-system-packages required: base image is Debian 13 with a PEP 668
# externally-managed Python, which refuses a bare `pip install`.
RUN pip install --no-cache-dir --break-system-packages -U edge-tts

# ---------------------------------------------------------------------------
# hermes-agent source, baked into the image at /opt/hermes.
#
# WHY IN THE IMAGE: the source is then immutable and self-contained — no
# coupling to any host directory, so nothing on the host can change underneath
# the container. /opt/hermes is upstream's own second probe path
# (/hermeswebui_init.bash: _agent_paths), so this is a supported location.
#
# Left root-owned on purpose: the WebUI runs as hermeswebui and only ever
# READS this tree (it stages a writable copy to /app/hermes-agent-src for the
# editable install). Read-only source is upstream's documented defence-in-depth
# posture (docs/rfcs/agent-source-boundary.md).
#
# HERMES_AGENT_REF pins what gets built. Default `main` = latest.
#   Pin a known-good commit:  --build-arg HERMES_AGENT_REF=d95682cd0
#
# CACHEBUST exists because `docker compose build --pull` only refreshes the
# BASE image; if the base digest is unchanged, this RUN layer is served from
# cache and you silently rebuild the SAME agent commit. To genuinely re-clone:
#   docker compose build --pull --build-arg CACHEBUST=$(date +%s)
ARG HERMES_AGENT_REF=main
ARG CACHEBUST=0
RUN echo "cachebust=${CACHEBUST}" \
    && git clone --depth 1 --branch "${HERMES_AGENT_REF}" \
         https://github.com/NousResearch/hermes-agent.git /opt/hermes \
    || git clone https://github.com/NousResearch/hermes-agent.git /opt/hermes \
       && git -C /opt/hermes checkout --quiet "${HERMES_AGENT_REF}"

# Record the resolved commit so the running container can report exactly what
# it is on, even though the shallow .git is pruned to keep the image small.
RUN git -C /opt/hermes rev-parse HEAD > /opt/hermes-commit.txt \
    && git -C /opt/hermes log -1 --format='%H %cI %s' > /opt/hermes-commit-detail.txt \
    && rm -rf /opt/hermes/.git \
    && test -f /opt/hermes/pyproject.toml \
    && chmod -R go-w /opt/hermes

# Pre-build the dashboard web UI into the image.
#
# WHY: `hermes dashboard` builds the web UI on first launch if no dist exists.
# That needs npm at RUNTIME on every fresh container — slow, and a hard failure
# if the network is unavailable. Building here means the container starts the
# dashboard instantly and offline; `--skip-build` then always has a dist.
#
# NOTE the output path: vite emits to hermes_cli/web_dist/ (NOT web/dist) —
# verified from the build log. node_modules is dropped afterwards; only the
# built assets are needed at runtime.
RUN cd /opt/hermes/web \
    && npm ci --no-audit --no-fund \
    && npm run build \
    && rm -rf /opt/hermes/web/node_modules \
    && test -d /opt/hermes/hermes_cli/web_dist \
    && test -f /opt/hermes/hermes_cli/web_dist/index.html \
    && echo "dashboard dist built: $(ls /opt/hermes/hermes_cli/web_dist/assets | wc -l) assets"

# Go toolchain (Debian trixie: golang-go 2:1.24~2) + make.
#
# WHY IN THE IMAGE: at runtime the agent is uid 1000 with no sudo, and
# /usr/local, /usr/local/bin and /opt are all NOT writable (verified) — so a
# runtime `apt install` is impossible. Anything written into the container
# filesystem is also destroyed by the next `mcu-update.bash --force`, which
# recreates the container. Only image layers survive.
#
# apt (1.24) rather than the upstream tarball (1.27.1) is a deliberate choice:
# no version chase, security updates ride the distro. If a project's go.mod
# ever declares a newer `toolchain`, Go will try to auto-download it into
# GOMODCACHE — which works, because GOPATH/GOCACHE are shared and writable
# (see the Go env vars in docker-compose.yml).
#
# golang-go pulls the compiler, stdlib and `gofmt`; git is already present
# from the base image and is what `go get` shells out to.
#
# make: GNU Make 4.4.x — most Go projects drive build/test/lint through a
# Makefile rather than raw `go build`. Note this is make ALONE, not
# build-essential: no gcc, so cgo-dependent packages (CGO_ENABLED=1) will not
# compile. Pure-Go builds are unaffected.
#
# socat: the ACP transport for the openvscode-server sidecar. `hermes acp`
# speaks JSON-RPC over stdin/stdout only (no listener exists anywhere in
# acp_adapter/), so socat binds a Unix domain socket on the shared /acp mount
# and EXECs the agent per connection. The IDE container spawns its own socat
# as a local subprocess — which is exactly what an ACP client expects — and
# the two halves meet on the socket file.
#
# WHY THIS WORKS: a UDS on a bind mount is the same inode on both sides of the
# container boundary. Proven by experiment before this was written: a full ACP
# `initialize` handshake completed across containers, returning
# agentInfo={"name":"hermes-agent","version":"0.21.0"}. No docker.sock, no TCP
# port, no privilege escalation.
RUN apt-get update && apt-get install -y --no-install-recommends \
        golang-go make socat \
    && rm -rf /var/lib/apt/lists/*

# Chromium — so agents can run web code, screenshot it, and iterate on the
# result rather than writing HTML blind.
#
# WHAT HERMES ACTUALLY WANTS: `hermes_cli/browser_connect.py` probes for
# `/usr/bin/chromium` (and `chromium-browser`) on Linux, so the DISTRO package
# name is the one that matters — Debian trixie ships chromium 152.
#
# THE SECOND HALF IS NOT OPTIONAL: the browser toolset drives Chromium through
# the `agent-browser` CLI, which Hermes otherwise resolves lazily through
# `npx` at first use. On this stack that would mean a network fetch into a
# writable-but-ephemeral HOME on every container recreate, so it is installed
# globally here instead — the same reasoning that put node and gh in the image.
#
# --no-sandbox IS REQUIRED IN THIS CONTAINER and is a real trade-off. Chromium's
# setuid sandbox needs privileges this container does not have (no CAP_SYS_ADMIN,
# and user namespaces are unavailable to uid 1000 here), so the renderer runs
# unsandboxed. Renderers are the process that parses untrusted HTML/JS, so a
# renderer exploit is contained only by the container boundary. Acceptable for
# previewing the agents' OWN generated pages; do NOT treat this browser as a
# safe way to visit arbitrary hostile sites.
#
# Fonts matter more than they look: without a real font package every
# screenshot renders tofu boxes, which makes visual iteration worthless.
RUN apt-get update && apt-get install -y --no-install-recommends \
        chromium \
        fonts-liberation fonts-dejavu-core fonts-noto-color-emoji \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g agent-browser \
    && npm cache clean --force

# Wrapper CMD: start the dashboard, then hand off to the image's own init.
# The base image has no s6 and no post-start hook, so this is the seam.
COPY start-mcu.bash /usr/local/bin/start-mcu.bash
RUN chmod 0755 /usr/local/bin/start-mcu.bash

# Make `hermes` resolvable on a SCRUBBED PATH.
#
# The image's PID 1 is `su -s /bin/bash -c exec "/hermeswebui_init.bash" hermeswebui`.
# For a non-root target, su REPLACES PATH with ENV_PATH from /etc/login.defs:
#     /usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games
# so /app/venv/bin is stripped no matter what PATH the container env sets —
# a compose `PATH=` only reaches PID 1 (root), never the uid-1000 agent.
#
# tools/bot_mode_dm.py (lines 316/364) execs a BARE "hermes" for local
# teammate delivery — unlike bot_relay._hermes_cli() it never resolves the
# interpreter-sibling binary — so message_agent died with
#     FileNotFoundError: [Errno 2] No such file or directory: 'hermes'
# and A2A delegation silently never arrived.
#
# /usr/local/bin IS on the scrubbed PATH, so a symlink there is immune to how
# PATH gets reset. Dangling at build time (the venv is created at runtime by
# the init script) and resolves on first use — which is all exec needs.
RUN ln -sf /app/venv/bin/hermes /usr/local/bin/hermes \
    && echo "hermes shim -> $(readlink /usr/local/bin/hermes)"

# Build-time assertions: a missing dependency fails the build loudly
# instead of at 2am when Photon won't start. The node-major gate guards the
# repo engine requirement so a future base-image change can't silently
# regress to an unsupported runtime.
RUN node --version && npm --version && which ffmpeg \
    && node -e "const m=+process.versions.node.split('.')[0]; if(m<22){console.error('node major '+m+' < 22 — fails hermes-agent engines');process.exit(1)} console.log('node engine ok: '+process.versions.node)" \
    && python3 -c "import edge_tts; print('edge_tts ok')" \
    && gh --version | head -1 \
    && test "$(command -v gh)" = /usr/bin/gh \
    && go version \
    && test "$(command -v go)" = /usr/bin/go \
    && make --version | head -1 \
    && test "$(command -v make)" = /usr/bin/make \
    && socat -V | head -1 \
    && test "$(command -v socat)" = /usr/bin/socat \
    && test "$(command -v chromium)" = /usr/bin/chromium \
    && chromium --version \
    && test -n "$(command -v agent-browser)" \
    && chromium --headless --no-sandbox --disable-gpu --disable-dev-shm-usage \
         --virtual-time-budget=5000 --dump-dom about:blank > /tmp/_chk.html \
    && grep -q "</html>" /tmp/_chk.html \
    && rm -f /tmp/_chk.html \
    && echo "chromium headless render ok" \
    && echo "agent commit: $(cat /opt/hermes-commit.txt)"

CMD ["/usr/local/bin/start-mcu.bash"]
