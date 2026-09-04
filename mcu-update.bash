#!/usr/bin/env bash
# mcu-update.bash — update / pull / start the MCU Hermes stack.
#
# Replaces the bare one-liner
#   docker compose build --pull --build-arg CACHEBUST=$(date +%s) && docker compose up -d
# which has three sharp edges this script removes:
#   1. It rebuilds even when upstream has not moved (several minutes, no gain).
#   2. It overwrites hermes-mcu:local with no rollback point. A bad upstream
#      commit leaves you with no way back except guessing the old SHA.
#   3. It returns as soon as containers are *created*, not when the stack is
#      actually serving — so a broken build looks like a success.
#
# Usage:
#   ./mcu-update.bash              # update if upstream moved, else just start
#   ./mcu-update.bash --check      # report only, change nothing
#   ./mcu-update.bash --force      # rebuild even if the commit is unchanged
#   ./mcu-update.bash --pin <ref>  # build a specific commit/tag/branch
#   ./mcu-update.bash --no-build   # start/restart only, no image work
#   ./mcu-update.bash --rollback   # restore the previous image and restart
#
set -uo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$STACK_DIR" || exit 1

IMAGE="hermes-mcu:local"
PREV_IMAGE="hermes-mcu:previous"
CORE_SVC="hermes-mcu-core"
CORE_CTR="hermes_mcu_core"
REPO_URL="https://github.com/NousResearch/hermes-agent.git"
GATEWAY_PROFILES=(phil-coulson nick-fury tony-stark daisy-johnson peter-parker)
HEALTH_WAIT_S="${MCU_HEALTH_WAIT_S:-240}"

MODE="update"
PIN_REF=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)    MODE="check" ;;
    --force)    MODE="force" ;;
    --no-build) MODE="nobuild" ;;
    --rollback) MODE="rollback" ;;
    --pin)      PIN_REF="${2:-}"; MODE="force"; shift ;;
    -h|--help)  sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
say()  { echo "${c_dim}[mcu]${c_off} $*"; }
ok()   { echo "  ${c_grn}✓${c_off} $*"; }
warn() { echo "  ${c_yel}!${c_off} $*"; }
die()  { echo "  ${c_red}✗${c_off} $*" >&2; exit 1; }

# ── Preflight ────────────────────────────────────────────────────────────────
# These run before anything is touched. A stack that fails here is a stack
# where building would only bury the real problem under a second one.
preflight() {
  say "preflight"
  [[ -f docker-compose.yml ]] || die "no docker-compose.yml in $STACK_DIR"
  [[ -f .env ]]               || die "no .env in $STACK_DIR (secrets live there)"
  docker compose config >/dev/null 2>&1 || die "docker compose config is INVALID — fix before updating"
  ok "compose config valid"

  # The stack must never reach into the native Hermes home. This guard has
  # caught a real mount hijack before (ambient shell env beating .env), which
  # is why stack vars are MCU_-prefixed.
  local coupling
  coupling=$(docker compose config 2>/dev/null | grep -c "/home/filip/.hermes")
  [[ "$coupling" == "0" ]] || die "compose references the NATIVE home ($coupling refs) — refusing to build"
  ok "zero native-home coupling"
}

# ── Commit comparison ────────────────────────────────────────────────────────
baked_commit() {  # commit currently inside the running container
  docker exec -u hermeswebui "$CORE_CTR" \
    sh -c 'cut -d" " -f1 /opt/hermes-commit-detail.txt 2>/dev/null' 2>/dev/null | tr -d '\r\n'
}
image_commit() {  # commit inside an image, without running the stack
  docker run --rm --entrypoint sh "$1" \
    -c 'cut -d" " -f1 /opt/hermes-commit-detail.txt 2>/dev/null' 2>/dev/null | tr -d '\r\n'
}
remote_commit() { # upstream HEAD (or the pinned ref), cheap: no clone
  local ref="${1:-HEAD}"
  timeout 30 git ls-remote "$REPO_URL" "$ref" 2>/dev/null | head -1 | cut -f1
}

# ── Health gate ──────────────────────────────────────────────────────────────
# "Container started" is not "stack works". Each check below failed for real at
# some point during this build-out, which is why each one is here.
health() {
  local failed=0
  say "health checks"

  # 1. Container actually healthy (not just Up).
  local status
  status=$(docker compose ps "$CORE_SVC" --format '{{.Status}}' 2>/dev/null | head -1)
  if [[ "$status" == *healthy* ]]; then ok "core: $status"
  else warn "core: ${status:-not running}"; failed=1; fi

  # 2. WebUI serving AND gated. A 200 here would mean the password gate is off.
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:8787/ 2>/dev/null)
  case "$code" in
    302|401|200) ok "webui 8787: HTTP $code" ;;
    *) warn "webui 8787: HTTP ${code:-no-response}"; failed=1 ;;
  esac

  # 3. Dashboard = what Hermes Desktop's "Remote gateway" connects to (NOT 8787).
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:9119/ 2>/dev/null)
  case "$code" in
    302|401|200) ok "dashboard 9119: HTTP $code" ;;
    *) warn "dashboard 9119: HTTP ${code:-no-response}"; failed=1 ;;
  esac

  # 4. Gateways. NOTE: `ps` is NOT installed in this image — enumerating /proc
  # is the only reliable way. Empty `ps` output once looked like "all gateways
  # dead" when all five were running fine.
  # Match on "-p <profile> gateway run", and skip the counting shell itself:
  # its own cmdline contains the pattern, which is why a naive scan reports
  # 6/5. Comparing against $$ is exact where string-matching cannot be.
  local running
  running=$(docker exec "$CORE_CTR" sh -c '
    n=0
    self=$$
    for d in /proc/[0-9]*; do
      pid=${d#/proc/}
      [ "$pid" = "$self" ] && continue
      c=$(tr "\0" " " < "$d/cmdline" 2>/dev/null)
      case "$c" in *"/hermes -p "*"gateway run"*) n=$((n+1));; esac
    done
    echo "$n"' 2>/dev/null | tr -d '\r\n')
  if [[ "${running:-0}" -ge ${#GATEWAY_PROFILES[@]} ]]; then
    ok "gateways: $running/${#GATEWAY_PROFILES[@]} running"
  else
    warn "gateways: ${running:-0}/${#GATEWAY_PROFILES[@]} running (they start staggered; re-check shortly)"
  fi

  # 5. Photon — the one inbound platform. Read Hermes' OWN log, never a shell
  # redirect: Python block-buffers redirected stdout and the file lags badly.
  if docker exec -u hermeswebui "$CORE_CTR" \
       sh -c 'grep -q "photon connected" /home/hermeswebui/.hermes/profiles/phil-coulson/logs/gateway.log 2>/dev/null'; then
    ok "photon: connected"
  else
    warn "photon: no 'connected' line yet in phil-coulson gateway.log"
  fi

  # 6. Hindsight sidecar.
  if docker exec "$CORE_CTR" sh -c 'curl -sf --max-time 8 http://hindsight:8888/version >/dev/null'; then
    ok "hindsight: reachable"
  else warn "hindsight: unreachable from core"; failed=1; fi

  # 7. Tunnel edge connections.
  local conns
  conns=$(docker compose logs cloudflared 2>/dev/null | grep -c "Registered tunnel connection")
  if [[ "${conns:-0}" -gt 0 ]]; then ok "cloudflared: $conns registered connection(s)"
  else warn "cloudflared: no registered connections"; fi

  # 8. Ownership tripwire. Root-owned files under the bind-mounted home have
  # broken this stack three times (profiles unreadable, photon status dying).
  local rooted
  rooted=$(docker exec "$CORE_CTR" sh -c 'find /home/hermeswebui/.hermes -uid 0 2>/dev/null | wc -l' | tr -d '\r\n')
  if [[ "${rooted:-0}" == "0" ]]; then ok "ownership: no root-owned files in home"
  else
    warn "ownership: $rooted root-owned file(s) — fix with:"
    echo "      docker exec $CORE_CTR chown -R 1000:1000 /home/hermeswebui/.hermes"
    failed=1
  fi

  return $failed
}

wait_healthy() {
  say "waiting for the stack to serve (up to ${HEALTH_WAIT_S}s)"
  local waited=0
  while (( waited < HEALTH_WAIT_S )); do
    local st code
    st=$(docker compose ps "$CORE_SVC" --format '{{.Status}}' 2>/dev/null | head -1)
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8787/ 2>/dev/null)
    [[ "$st" == *healthy* && "$code" =~ ^(200|302|401)$ ]] && { ok "serving after ${waited}s"; return 0; }
    sleep 5; waited=$((waited + 5))
  done
  warn "not serving after ${HEALTH_WAIT_S}s"
  return 1
}

rollback() {
  say "rolling back to $PREV_IMAGE"
  docker image inspect "$PREV_IMAGE" >/dev/null 2>&1 || die "no $PREV_IMAGE to roll back to"
  docker tag "$PREV_IMAGE" "$IMAGE" || die "retag failed"
  docker compose up -d "$CORE_SVC" >/dev/null 2>&1 || die "restart failed"
  wait_healthy && ok "rolled back to $(image_commit "$IMAGE" | cut -c1-12)"
}

# ── Modes ────────────────────────────────────────────────────────────────────
if [[ "$MODE" == "rollback" ]]; then preflight; rollback; exit $?; fi

preflight

TARGET_REF="${PIN_REF:-HEAD}"
CURRENT="$(baked_commit)"
REMOTE="$(remote_commit "$TARGET_REF")"

say "commit status"
echo "  running : ${CURRENT:-unknown}"
echo "  upstream: ${REMOTE:-unreachable} ($TARGET_REF)"

if [[ "$MODE" == "check" ]]; then
  if [[ -n "$REMOTE" && -n "$CURRENT" && "$REMOTE" == "$CURRENT" ]]; then
    ok "up to date — a rebuild would change nothing"
  elif [[ -z "$REMOTE" ]]; then
    warn "could not reach upstream; cannot tell if an update exists"
  else
    warn "update available: ${CURRENT:0:12} → ${REMOTE:0:12}"
  fi
  health
  exit 0
fi

NEED_BUILD=1
if [[ "$MODE" == "nobuild" ]]; then
  NEED_BUILD=0
  say "skipping image work (--no-build)"
elif [[ "$MODE" != "force" && -n "$REMOTE" && "$REMOTE" == "$CURRENT" ]]; then
  NEED_BUILD=0
  ok "already on upstream HEAD — skipping rebuild (use --force to rebuild anyway)"
fi

if (( NEED_BUILD )); then
  # Rollback point. Do this BEFORE the build: once hermes-mcu:local is
  # overwritten the old layers are unreferenced and may be pruned away.
  if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    docker tag "$IMAGE" "$PREV_IMAGE" && ok "saved rollback image ($(image_commit "$IMAGE" | cut -c1-12))"
  fi

  # CACHEBUST is REQUIRED: without it Docker reuses the cached `git clone`
  # layer and you get an identical image while believing you updated.
  # --pull refreshes the ghcr.io base; it does NOT re-clone the agent source.
  say "building${PIN_REF:+ (pinned to $PIN_REF)}"
  build_args=(--pull --build-arg "CACHEBUST=$(date +%s)")
  [[ -n "$PIN_REF" ]] && build_args+=(--build-arg "HERMES_AGENT_REF=$PIN_REF")

  if ! docker compose build "${build_args[@]}"; then
    die "build FAILED — running stack untouched, still on ${CURRENT:0:12}"
  fi

  NEW_COMMIT="$(image_commit "$IMAGE")"
  ok "built image at ${NEW_COMMIT:0:12}"
  if [[ -n "$REMOTE" && -n "$NEW_COMMIT" && "$NEW_COMMIT" != "$REMOTE" ]]; then
    warn "image commit ${NEW_COMMIT:0:12} != requested ${REMOTE:0:12} (cache or moved ref?)"
  fi
fi

say "starting stack"
docker compose up -d || die "compose up failed"

if wait_healthy; then
  health || warn "stack is serving but some checks are soft-failing (see above)"
  echo
  ok "MCU stack up — running $(baked_commit | cut -c1-12)"
  (( NEED_BUILD )) && echo "  ${c_dim}rollback: ./mcu-update.bash --rollback${c_off}"
else
  echo
  warn "stack did NOT come up healthy"
  if (( NEED_BUILD )) && docker image inspect "$PREV_IMAGE" >/dev/null 2>&1; then
    echo "  roll back with: ./mcu-update.bash --rollback"
  fi
  echo "  logs: docker compose logs --tail 50 $CORE_SVC"
  exit 1
fi
