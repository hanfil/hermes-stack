#!/usr/bin/env bash
# Entrypoint for the openvscode-server sidecar.
#
# Seeds user settings, the multi-root workspace file, and extensions on FIRST
# boot only, then execs the server. Compose passes `--connection-token ...` as
# `command:`, which arrives here as "$@" and is appended to the server's argv.
set -euo pipefail

DATA_DIR=/home/openvscode-server/data
EXT_DIR=/home/openvscode-server/extensions

mkdir -p "${DATA_DIR}/User" "${EXT_DIR}"

# Seed extensions only when the volume is empty — never clobber extensions the
# user installed himself from the Extensions view.
if [ -z "$(ls -A "$EXT_DIR" 2>/dev/null)" ]; then
  echo "[ide] seeding extensions from image staging"
  cp -a /home/openvscode-server/.ovsc-staging/. "$EXT_DIR"/
fi

# Same rule for settings and the workspace file: defaults, not overwrites.
#
# IDE_RESEED_SETTINGS=1 forces the image's template back over the live copy.
# Without it, editing ide/settings.json on the host and rebuilding does NOTHING
# to a container whose volume already has the file — a trap that cost real time
# during the initial rollout. With it:
#
#   IDE_RESEED_SETTINGS=1 docker compose up -d --force-recreate vscode-ide
#
# A timestamped backup is kept so a forced reseed can never silently destroy
# settings changed in the IDE UI. Deliberately opt-in and per-boot: it must not
# fire on an ordinary restart.
RESEED="${IDE_RESEED_SETTINGS:-0}"

seed_file() {
  # $1 = template under /opt/ide-defaults, $2 = live destination
  if [ ! -f "$2" ]; then
    cp "$1" "$2"
    echo "[ide] seeded $(basename "$2") (was absent)"
  elif [ "$RESEED" = "1" ]; then
    if cmp -s "$1" "$2"; then
      echo "[ide] $(basename "$2") already matches template — nothing to do"
    else
      cp -p "$2" "$2.bak.$(date +%Y%m%dT%H%M%S)"
      cp "$1" "$2"
      echo "[ide] RESEEDED $(basename "$2") from template (backup kept)"
    fi
  fi
}

seed_file /opt/ide-defaults/settings.json      "${DATA_DIR}/User/settings.json"
seed_file /opt/ide-defaults/mcu.code-workspace "${DATA_DIR}/mcu.code-workspace"

# Refuse to start without a connection token. openvscode-server with no token
# is UNAUTHENTICATED, and this instance exposes a shell, a GitHub token with
# push rights to private repos, and five agents with terminal + execute_code.
# Fail closed rather than come up wide open.
case " $* " in
  *" --connection-token "*) : ;;
  *)
    echo "[ide] FATAL: no --connection-token supplied by compose 'command:'" >&2
    exit 78   # EX_CONFIG
    ;;
esac

# "$@" LAST so compose stays authoritative for the token.
#
# --host 0.0.0.0 is safe ONLY because compose publishes to 127.0.0.1:8080 and
# cloudflared reaches this container over the internal network; the container's
# own interface is not the exposure boundary.
exec "${OPENVSCODE_SERVER_ROOT}/bin/openvscode-server" \
  --host 0.0.0.0 \
  --port 3000 \
  --user-data-dir "$DATA_DIR" \
  --extensions-dir "$EXT_DIR" \
  --default-workspace "${DATA_DIR}/mcu.code-workspace" \
  "$@"
