#!/usr/bin/env bash
# MCU stack container entrypoint.
#
# The base image's CMD is /hermeswebui_init.bash, which sets up the WebUI and
# then runs it in the foreground as PID 1's child. That image has no s6 and no
# post-start hook, so there is no supported seam to add a second service.
# This wrapper is that seam: start the background services, then exec the
# original init so its behaviour (and PID-1 signal semantics) are unchanged.
#
# WHY THE DASHBOARD: Hermes Desktop's "Remote gateway" connection talks to the
# `hermes dashboard` backend (default 9119) — NOT the WebUI on 8787 and NOT the
# OpenAI-compatible api_server on 8642.
#
# WHY PER-PROFILE GATEWAYS: `hermes gateway start` REFUSES to run here —
#   "Service start is not applicable inside a Docker container.
#    The gateway runs as the container's main process."
# That guard (hermes_cli/gateway.py) assumes the container's main process IS
# the gateway, which is true for the official Hermes image but NOT for this
# one (our PID 1 is the WebUI init). The supported escape hatch, named in that
# same message, is the foreground `hermes gateway run`, which is what we use.
set -uo pipefail

HERMES_BIN="/app/venv/bin/hermes"
DASH_HOST="${MCU_DASHBOARD_HOST:-0.0.0.0}"
DASH_PORT="${MCU_DASHBOARD_PORT:-9119}"
RUN_AS="${MCU_DASHBOARD_USER:-hermeswebui}"
RUN_HOME="${MCU_DASHBOARD_HOME:-/home/hermeswebui}"
LOG_DIR="${RUN_HOME}/.hermes/logs"
LOG="${LOG_DIR}/dashboard.log"
WAIT_S="${MCU_DASHBOARD_WAIT_S:-600}"

# phil-coulson FIRST: it owns Photon (the only profile with an inbound
# platform) and it should also win the singleton kanban dispatcher lock.
# The other four have no platform enabled — their gateway still earns its
# keep by hosting that profile's in-process cron scheduler (routines) and by
# being reachable for Bot Mode delegation.
# NOTE `${VAR-default}` (single dash), NOT `${VAR:-default}`: an EMPTY value
# must mean "start no gateways", which is what a first deploy sets before the
# bots exist. `:-` would treat empty as unset and start all five against
# profiles that do not exist yet, producing an endless restart loop.
MCU_GATEWAY_PROFILES="${MCU_GATEWAY_PROFILES-phil-coulson nick-fury tony-stark daisy-johnson peter-parker}"

log() { echo "[start-mcu] $*"; }

# Drop to the service user with a CORRECT environment.
#
# MUST run as hermeswebui (uid 1000), never root: anything root creates under
# the bind-mounted home becomes unreadable to the service (mode 0700 root) and
# to the host user. That failure mode cost us five unusable profiles once, and
# later broke `photon status` on phil-coulson.
#
# HOME/USER/LOGNAME must be set EXPLICITLY. setpriv drops privileges but does
# NOT touch the environment, so the child would inherit root's HOME=/root while
# running as uid 1000 — every user-level path then resolves under /root (mode
# 0700) and fails with
#   PermissionError: [Errno 13] Permission denied: '/root/.local/bin'
# (su -l would fix HOME but also spawns a login shell and re-reads profile
# scripts; env -i is overkill. Setting the three vars is the minimal fix.)
#
# PATH must include /app/venv/bin. tools/bot_mode_dm.py execs a BARE "hermes"
# for local teammate delivery, so message_agent dies with
#   FileNotFoundError: [Errno 2] No such file or directory: 'hermes'
# if the venv bin dir is absent. (The image also ships a /usr/local/bin/hermes
# symlink for subprocesses whose PATH gets scrubbed by su/login.defs.)
as_service_user() {
  setpriv --reuid="$RUN_AS" --regid="$RUN_AS" --init-groups \
    env HOME="$RUN_HOME" USER="$RUN_AS" LOGNAME="$RUN_AS" \
        PATH="/app/venv/bin:${RUN_HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin" \
    "$@"
}

# ORDERING: /app/venv is created by /hermeswebui_init.bash, which runs AFTER
# this wrapper. So $HERMES_BIN does not exist yet — polling for it is required;
# checking once always loses the race.
wait_for_venv() {
  for _ in $(seq 1 "$WAIT_S"); do
    [[ -x "$HERMES_BIN" ]] && return 0
    sleep 1
  done
  return 1
}

start_dashboard() {
  # Auth is MANDATORY for a non-loopback bind. --insecure has been a no-op
  # since the June 2026 hardening, so without a provider the dashboard exits
  # rather than serving unauthenticated. Fail loudly here instead of leaving a
  # silently dead port for Desktop to time out against.
  if [[ -z "${HERMES_DASHBOARD_BASIC_AUTH_PASSWORD:-}" ]]; then
    log "WARNING: HERMES_DASHBOARD_BASIC_AUTH_PASSWORD is unset."
    log "WARNING: a ${DASH_HOST} bind requires an auth provider — skipping dashboard."
    return 0
  fi

  (
    if ! wait_for_venv; then
      log "WARNING: $HERMES_BIN never appeared — dashboard not started."
      exit 0
    fi
    log "venv ready — starting dashboard on ${DASH_HOST}:${DASH_PORT} as ${RUN_AS}"
    as_service_user "$HERMES_BIN" dashboard \
      --host "$DASH_HOST" --port "$DASH_PORT" \
      --no-open --skip-build \
      >>"$LOG" 2>&1
    log "dashboard exited (rc=$?) — see $LOG"
  ) &

  log "dashboard supervisor pid $! (waiting for venv; log: $LOG)"
}

start_gateways() {
  # An empty list is a legitimate state, not an error: on a FIRST deploy no
  # profiles exist yet (bots are created in Hermes Desktop afterwards), and
  # `gateway run` refuses an unknown profile. Say so explicitly — a silent
  # no-op looks identical to a supervisor that crashed.
  if [[ -z "${MCU_GATEWAY_PROFILES// /}" ]]; then
    log "no gateway profiles configured — starting 0 gateways (set MCU_GATEWAY_PROFILES once the bots exist)"
    return 0
  fi
  for profile in $MCU_GATEWAY_PROFILES; do
    local glog="${LOG_DIR}/gateway-${profile}.log"
    # Pre-create the log as the service user. The `>>"$glog"` redirect below is
    # opened by THIS shell (still root) before setpriv drops privileges, so
    # without this the file is created root-owned inside the bind-mounted home
    # — the exact ownership class that has broken this stack repeatedly.
    # (Harmless for the log itself, but the tripwire should stay clean so a
    # real ownership fault is never lost in the noise.)
    touch "$glog" 2>/dev/null || true
    chown "$RUN_AS":"$RUN_AS" "$glog" 2>/dev/null || true
    (
      if ! wait_for_venv; then
        log "WARNING: $HERMES_BIN never appeared — gateway ${profile} not started."
        exit 0
      fi

      # Stagger: five gateways warming their tool machinery at once is a CPU
      # spike on boot, and phil-coulson should settle first so it takes the
      # kanban dispatcher lock rather than racing for it.
      sleep "${MCU_GATEWAY_STAGGER_S:-8}"

      # Restart loop: `gateway run` deliberately exits non-zero on a
      # signal-initiated shutdown "so systemd Restart=on-failure can revive
      # the gateway" — there is no such supervisor here, so this is it.
      local backoff=5
      while :; do
        log "starting gateway for ${profile} (log: ${glog})"
        # --external-supervisor: tells Hermes an external process manager owns
        # this foreground gateway, so in-chat restarts/updates exit back to us
        # instead of spawning a detached replacement we would not be tracking.
        # --replace: the home is a persistent bind mount, so a stale pidfile
        # from the previous container can survive a restart and block startup.
        as_service_user "$HERMES_BIN" -p "$profile" gateway run \
          --external-supervisor --replace \
          >>"$glog" 2>&1
        local rc=$?

        # Clean exit, or the container is going down — do not respawn.
        if [[ $rc -eq 0 ]]; then
          log "gateway ${profile} exited cleanly — not restarting"
          break
        fi
        [[ -f /run/mcu-shutdown ]] && { log "gateway ${profile}: shutdown in progress"; break; }

        log "gateway ${profile} exited rc=${rc} — restarting in ${backoff}s"
        sleep "$backoff"
        # Cap the backoff so a permanently broken profile does not spin hot.
        (( backoff < 120 )) && backoff=$(( backoff * 2 ))
      done
    ) &
    log "gateway supervisor pid $! for ${profile}"
  done
}

# WHY HERE AND NOT systemd: the extension ships
# sidecar/profile-avatars-sidecar.service and its README says
#   systemctl --user enable --now profile-avatars-sidecar
# There is no systemd in this image (`systemctl` is not installed), so that
# unit is unusable. This function is the equivalent seam.
#
# WHY INSIDE THE CONTAINER: the extension's README warns that "a
# bridge-networked WebUI container cannot reach a host-run sidecar's
# 127.0.0.1:17798 (loopback is namespace-local). Sidecars work only where core
# and the sidecar share a network namespace and the state dir." Running it here
# satisfies both — the WebUI proxy reaches it over loopback, and the state dir
# is the same bind-mounted path.
#
# NOT wait_for_venv: unlike the dashboard and gateways, the sidecar is
# stdlib-only (http.server + sqlite3) and runs under /usr/bin/python3 -S with
# NO site-packages, exactly as its unit file does. Gating it on $HERMES_BIN
# would delay it for no reason.
start_ext_sidecars() {
  local state_dir="${HERMES_WEBUI_STATE_DIR:-${RUN_HOME}/.hermes/webui}"
  local ext_root="${state_dir}/extensions"

  [[ -d "$ext_root" ]] || { log "no extensions dir (${ext_root}) — no sidecars"; return 0; }

  local cfg
  for cfg in "$ext_root"/*/sidecar/sidecar.json; do
    [[ -f "$cfg" ]] || continue

    local sdir ext_id port
    sdir="$(dirname "$cfg")"
    ext_id="$(basename "$(dirname "$sdir")")"

    # id/port come from the extension's own sidecar.json (the repo's contract:
    # {id, port, proxy_auth}). Parsed with python3 rather than grep/sed so a
    # reformatted file cannot silently yield a wrong port.
    port="$(/usr/bin/python3 -c 'import json,sys
try:
    print(int(json.load(open(sys.argv[1])).get("port") or 0))
except Exception:
    print(0)' "$cfg" 2>/dev/null)"
    [[ "$port" =~ ^[0-9]+$ ]] && (( port > 0 )) || {
      log "WARNING: ${ext_id}: no usable port in sidecar.json — skipping"
      continue
    }

    # Respect the WebUI's own toggle. Settings -> Extensions writes
    # extension-overrides.json; a disabled extension must not get a sidecar.
    if /usr/bin/python3 -c 'import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
sys.exit(0 if sys.argv[2] in (d.get("disabled_extensions") or []) else 1)' \
        "${state_dir}/extension-overrides.json" "$ext_id" 2>/dev/null; then
      log "extension ${ext_id} is disabled in WebUI settings — not starting its sidecar"
      continue
    fi

    [[ -f "${sdir}/sidecar.py" ]] || {
      log "WARNING: ${ext_id}: sidecar.py missing — skipping"
      continue
    }

    local slog="${LOG_DIR}/sidecar-${ext_id}.log"
    # Same root-ownership trap as the gateway logs: this `>>` redirect is
    # opened by THIS shell (still root) before setpriv drops privileges.
    touch "$slog" 2>/dev/null || true
    chown "$RUN_AS":"$RUN_AS" "$slog" 2>/dev/null || true

    (
      # BOOT RACE: this wrapper runs BEFORE /hermeswebui_init.bash, which is
      # what normalises ownership of the bind-mounted home to WANTED_UID
      # (observed: "uid: 0 / WANTED_UID: 1000" then a re-exec as hermeswebui).
      # Until that pass completes, sidecar.py can be unreadable to the service
      # user and python exits rc=2:
      #   can't open file '.../sidecar.py': [Errno 13] Permission denied
      # The restart loop below recovers on the next tick, but waiting here
      # keeps a spurious failure out of the log and off the tripwire.
      for _ in $(seq 1 "${MCU_SIDECAR_WAIT_S:-120}"); do
        as_service_user test -r "${sdir}/sidecar.py" && break
        sleep 1
      done

      local backoff=5
      while :; do
        log "starting sidecar ${ext_id} on 127.0.0.1:${port} (log: ${slog})"
        # cd first: sidecar.py does `from sidecar_base import Sidecar` and
        # `import routes_impl`, both resolved relative to its own directory
        # (the unit file sets WorkingDirectory for the same reason).
        cd "$sdir" || { log "sidecar ${ext_id}: cannot cd ${sdir}"; break; }
        as_service_user /usr/bin/python3 -S -u sidecar.py >>"$slog" 2>&1
        local rc=$?

        if [[ $rc -eq 0 ]]; then
          log "sidecar ${ext_id} exited cleanly — not restarting"
          break
        fi
        [[ -f /run/mcu-shutdown ]] && { log "sidecar ${ext_id}: shutdown in progress"; break; }

        log "sidecar ${ext_id} exited rc=${rc} — restarting in ${backoff}s"
        sleep "$backoff"
        (( backoff < 120 )) && backoff=$(( backoff * 2 ))
      done
    ) &
    log "sidecar supervisor pid $! for ${ext_id}"
  done
}

# ACP relays: one Unix-socket listener per profile on the shared /acp mount,
# so the openvscode-server sidecar container can speak ACP to these agents.
#
# WHY A SOCKET AND NOT A PORT: `hermes acp` is stdio-only — there is no
# listener anywhere in acp_adapter/, and the adapter's own threat model says
# "ACP is stdio-only, local-trust". socat bridges that stdio stream onto a UDS.
# A UDS on a bind mount is the same inode inside and outside the container, so
# the IDE container connects to the same file. Verified end-to-end before this
# was written: a real ACP `initialize` handshake crossed the boundary and
# returned agentInfo={"name":"hermes-agent","version":"0.21.0"}.
#
# THE SOCKET IS A CREDENTIAL: connecting to it yields an agent with `terminal`
# and `execute_code`. There is no auth in the ACP channel itself, so access
# control is filesystem-only — hence mode=0600 here and mode 700 on the /acp
# directory. Both must hold.
start_acp_relays() {
  local dir="${MCU_ACP_SOCKET_DIR:-}"
  if [[ -z "$dir" ]]; then
    log "acp-relay: MCU_ACP_SOCKET_DIR unset — no relays started"
    return 0
  fi
  if ! command -v socat >/dev/null 2>&1; then
    log "WARNING: acp-relay: socat not installed — no relays started"
    return 0
  fi
  if [[ ! -d "$dir" ]]; then
    log "WARNING: acp-relay: ${dir} is not a directory — no relays started"
    return 0
  fi

  local profile
  # Same reasoning as start_gateways: no profiles configured is a valid
  # first-deploy state. Binding sockets for profiles that do not exist would
  # be actively misleading, because socat creates the listener BEFORE
  # `hermes acp` ever runs — the socket would look healthy and fail on use.
  if [[ -z "${MCU_GATEWAY_PROFILES// /}" ]]; then
    log "acp-relay: no gateway profiles configured — no relays started"
    return 0
  fi
  for profile in $MCU_GATEWAY_PROFILES; do
    local rlog="${LOG_DIR}/acp-relay-${profile}.log"
    # Same root-ownership trap as the gateway/sidecar logs: this `>>` redirect
    # is opened by THIS shell (still root) before setpriv drops privileges.
    touch "$rlog" 2>/dev/null || true
    chown "$RUN_AS":"$RUN_AS" "$rlog" 2>/dev/null || true

    (
      # Unlike the extension sidecars (stdlib-only python), this one EXECs
      # $HERMES_BIN, so it must wait for the venv exactly like the gateways do.
      if ! wait_for_venv; then
        log "WARNING: $HERMES_BIN never appeared — acp-relay ${profile} not started."
        exit 0
      fi

      local sock="${dir}/${profile}.sock"
      local backoff=5
      while :; do
        [[ -f /run/mcu-shutdown ]] && { log "acp-relay ${profile}: shutdown in progress"; break; }
        log "starting acp-relay for ${profile} on ${sock}"

        # fork         : a fresh `hermes acp` per connection, so reconnects work
        # unlink-early : clear a stale socket left by an unclean shutdown
        # mode=0600    : only uid 1000 may connect (see the credential note above)
        # max-children : cap runaway agent spawns from a reconnect loop
        #
        # --pass-session-id is a GLOBAL flag and must precede the `acp`
        # subcommand; after it, argparse errors out. Verified:
        #   hermes --pass-session-id -p tony-stark acp --version -> 0.21.0
        # It puts the session id in the system prompt so the bot can
        # session_search its own Bot Chat history.
        # ,pipes is REQUIRED, not cosmetic. Without it socat connects the
        # child over a bidirectional SOCKETPAIR on fd 0/1. `initialize` still
        # answers, but the SECOND request (session/list) never gets a reply,
        # so the ACP panel hangs forever on "Loading sessions".
        #
        # Proven by A/B on 2026-09-03, identical but for this one option:
        #   default  -> session/list NEVER answered
        #   ,pipes   -> session/list -> {"sessions": []} in 2.5s
        # Direct stdio (subprocess pipes, no socat) also answers in 2.5s,
        # which is what pins the fault on the socketpair rather than Hermes.
        #
        # Hermes' stdio reader expects a real pipe on stdin; a socketpair
        # changes the read/EOF semantics it relies on. `,pipes` gives the
        # child ordinary unidirectional pipes, exactly like a normal parent
        # process would. Do not remove it.
        as_service_user socat \
          "UNIX-LISTEN:${sock},fork,unlink-early,mode=0600,max-children=4" \
          "EXEC:${HERMES_BIN} --pass-session-id -p ${profile} acp,pipes" \
          >>"$rlog" 2>&1
        rc=$?

        [[ -f /run/mcu-shutdown ]] && { log "acp-relay ${profile}: shutdown in progress"; break; }
        log "acp-relay ${profile} exited rc=${rc} — restarting in ${backoff}s"
        sleep "$backoff"
        (( backoff < 120 )) && backoff=$(( backoff * 2 ))
      done
    ) &
    log "acp-relay supervisor pid $! for ${profile}"
  done
}

# Mark shutdown so the restart loops above stand down instead of respawning
# gateways while the container is terminating.
trap 'touch /run/mcu-shutdown 2>/dev/null || true' TERM INT
mkdir -p "$LOG_DIR" 2>/dev/null || true
chown "$RUN_AS":"$RUN_AS" "$LOG_DIR" 2>/dev/null || true
rm -f /run/mcu-shutdown 2>/dev/null || true

start_dashboard
start_gateways
start_ext_sidecars
start_acp_relays

log "handing off to /hermeswebui_init.bash"
exec /hermeswebui_init.bash "$@"
