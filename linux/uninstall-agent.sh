#!/bin/bash
#
# OPTiCS Agent Linux Uninstaller
#
# Since 0.6.0 the installation IS the compose file in the install directory. Tearing it
# down through compose from that directory also clears the network and volumes, which
# removing containers by name would leave behind.
#
# Same flow as the installer: ask everything, confirm, then act.
#   Phase 1  ask    - choose what to remove; nothing is deleted
#   Phase 2  review - show what goes and what stays; any item can be revised by number
#   Phase 3  apply  - deletion happens here
# Deletion cannot be undone, so aborting at phase 2 leaves everything in place.
set -uo pipefail

UNINSTALLER_VERSION="0.5.0"

INSTALL_DIR="${OPTICS_INSTALL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/optics/agent}"
AGENT_IMAGE="ghcr.io/optics-organization/optics-agent"
DASHBOARD_IMAGE="ghcr.io/optics-organization/optics-agent-dashboard"
SSH_KEY_MARKER="optics-agent-web-terminal"

# Collected in phase 1. Nothing is deleted until phase 3.
PLAN_CONTAINERS="no"
PLAN_IMAGES="no"
PLAN_DATA="no"
PLAN_SSH="no"
PLAN_INSTALL_DIR="no"

# Current state found during phase 1, used to describe what the review will remove.
CONTAINERS_FOUND="no"
CONTAINER_NOTE=""
IMAGES_FOUND=""
DATA_DIR=""
BUILD_DIR=""
SSH_FOUND="no"
SSH_NOTE=""
COMPOSE_CMD=""

# What phase 3 actually removed, for the closing summary.
DONE_CONTAINERS=""
DONE_IMAGES=""
DONE_DATA=""
DONE_SSH=""
DONE_INSTALL_DIR=""

# Progress through phase 3.
STEP_TOTAL=5
STEP_NUM=0
step() {
  STEP_NUM=$((STEP_NUM + 1))
  echo ""
  echo "[${STEP_NUM}/${STEP_TOTAL}] $1"
}

# Phase 1 uses fixed numbers, not a counter: the review lets you jump back to an item,
# so "[3/4] Agent data" must keep matching review entry 3.
ASK_TOTAL=4
ask_step() {
  echo ""
  echo "[$1/${ASK_TOTAL}] $2"
}

# A per-line prefix eats width and buries the step structure; indent content instead.
say()  { echo "  $1"; }
warn() { echo "  ! $1"; }
ask()  { printf '  %s' "$1" >&2; }

# Pause on a step that had nothing to ask, so the reason for skipping is readable
# before the next prompt scrolls past. Pointless when nobody is watching.
SKIP_PAUSE="${OPTICS_SKIP_PAUSE:-1.5}"
pause_skip() {
  say "$1"
  if [ -t 0 ] && [ -t 1 ]; then
    sleep "$SKIP_PAUSE"
  fi
}

# Last chance to Ctrl+C before anything is deleted.
COUNTDOWN_FROM="${OPTICS_COUNTDOWN:-3}"
countdown() {
  if [ ! -t 0 ] || [ ! -t 1 ] || [ "$COUNTDOWN_FROM" -le 0 ] 2>/dev/null; then
    return 0
  fi

  echo ""
  printf '  Removal starts in '
  local i=$COUNTDOWN_FROM
  local dot
  while [ "$i" -gt 0 ]; do
    printf '%s' "$i"
    # One dot at a time so the seconds are visible.
    for dot in 1 2 3 4 5; do
      sleep 0.2
      printf '.'
    done
    i=$((i - 1))
  done
  echo ""
}

# One-line y/N. The default is always the safe answer: keep.
ask_yes_no() {
  local prompt="$1"
  local answer
  ask "$prompt (y/N): "
  read -r answer </dev/tty
  case "$answer" in
    Y|y) return 0 ;;
    *)   return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

probe_compose() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
  fi
}

env_value() {
  [ -f "$INSTALL_DIR/.env" ] || return 0
  grep -E "^$1=" "$INSTALL_DIR/.env" 2>/dev/null | tail -n 1 | cut -d= -f2-
}

# Last guard before rm -rf. Even a value read from .env is rejected if it is empty,
# relative, or root, so a single typo cannot wipe a home directory.
safe_to_remove() {
  local dir="$1"
  [ -n "$dir" ] || return 1
  case "$dir" in
    /) return 1 ;;
    /*) ;;
    *) return 1 ;;
  esac
  return 0
}

# Read-only. The review needs to know what will be stopped before asking.
detect_containers() {
  CONTAINERS_FOUND="no"
  CONTAINER_NOTE=""

  command -v docker >/dev/null 2>&1 || {
    CONTAINER_NOTE="Docker is not installed"
    return 0
  }

  local names
  # The compose project name is pinned to optics-agent, so the label finds the same
  # containers even when the compose file is gone.
  names=$(docker ps -a --filter "label=com.docker.compose.project=optics-agent" \
    --format '{{.Names}}' 2>/dev/null | sort)

  if [ -z "$names" ]; then
    names=$(docker ps -a --format '{{.Names}}' 2>/dev/null \
      | grep -E '^optics-agent-optics-agent(-dashboard)?-1$' | sort)
  fi

  if [ -n "$names" ]; then
    CONTAINERS_FOUND="yes"
    CONTAINER_NOTE=$(printf '%s' "$names" | tr '\n' ' ' | sed 's/ $//')
  fi
  return 0
}

detect_images() {
  IMAGES_FOUND=""
  command -v docker >/dev/null 2>&1 || return 0

  # Match on repository name to catch pinned tags too.
  IMAGES_FOUND=$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
    | grep -E "^($AGENT_IMAGE|$DASHBOARD_IMAGE):" | sort)
  return 0
}

# Since 0.7.0 both volumes bind-mount host directories named in .env, so removing the
# volumes alone leaves the real data behind. Those paths must be read first.
detect_data() {
  DATA_DIR=$(env_value OPTICS_DATA_DIR)
  BUILD_DIR=$(env_value OPTICS_BUILD_DIR)
}

detect_ssh() {
  SSH_FOUND="no"
  SSH_NOTE=""

  SSH_TARGET_USER="${OPTICS_SSH_USER:-${SUDO_USER:-$(id -un)}}"
  if [ "$SSH_TARGET_USER" = "root" ] || ! id "$SSH_TARGET_USER" >/dev/null 2>&1; then
    SSH_NOTE="no target user"
    return 0
  fi

  SSH_TARGET_HOME=$(getent passwd "$SSH_TARGET_USER" | cut -d: -f6)
  if [ -z "$SSH_TARGET_HOME" ]; then
    SSH_NOTE="no home directory"
    return 0
  fi

  SSH_AUTHORIZED_KEYS="$SSH_TARGET_HOME/.ssh/authorized_keys"
  SSH_STATE_DIR="$SSH_TARGET_HOME/.local/share/optics/ssh"

  # Something to remove if the marker is in authorized_keys or the key dir exists.
  if grep -q " ${SSH_KEY_MARKER}\$" "$SSH_AUTHORIZED_KEYS" 2>/dev/null; then
    SSH_FOUND="yes"
  elif [ -d "$SSH_STATE_DIR" ]; then
    SSH_FOUND="yes"
  fi

  if [ "$SSH_FOUND" = "yes" ]; then
    SSH_NOTE="$SSH_TARGET_USER"
  else
    SSH_NOTE="nothing to remove"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Phase 1: ask
# ---------------------------------------------------------------------------
# Functions here only decide values: no containers stopped, no files removed.

ask_containers() {
  ask_step 1 "Containers"

  if [ "$CONTAINERS_FOUND" != "yes" ]; then
    PLAN_CONTAINERS="no"
    pause_skip "No OPTiCS containers found${CONTAINER_NOTE:+ ($CONTAINER_NOTE)}"
    return 0
  fi

  say "Found: $CONTAINER_NOTE"
  say "Stops and removes them along with the compose network."
  # Leaving containers behind pins both the images and the data, so this is the one
  # question that defaults to Yes.
  local answer
  ask "Stop and remove containers? (Y/n): "
  read -r answer </dev/tty
  case "$answer" in
    N|n) PLAN_CONTAINERS="no" ;;
    *)   PLAN_CONTAINERS="yes" ;;
  esac
}

ask_images() {
  ask_step 2 "Images"

  if [ -z "$IMAGES_FOUND" ]; then
    PLAN_IMAGES="no"
    pause_skip "No OPTiCS images found"
    return 0
  fi

  say "Downloaded Agent and Dashboard images:"
  local line
  echo "$IMAGES_FOUND" | while read -r line; do
    echo "    $line"
  done
  say "Reinstalling later will download them again."

  if ask_yes_no "Remove downloaded images?"; then
    PLAN_IMAGES="yes"
  else
    PLAN_IMAGES="no"
  fi
}

ask_data() {
  ask_step 3 "Agent data"

  # The local DB holds this Agent\'s UUID and signing secret. Removing it registers a
  # brand-new Agent on reinstall and orphans the old one and its services on the Hub.
  say "Removing this unregisters the machine from OPTiCS Hub."
  say "Reinstalling registers a new Agent; services on the old one stay orphaned."

  if [ -n "$DATA_DIR" ] || [ -n "$BUILD_DIR" ]; then
    say "Data : ${DATA_DIR:-unknown}"
    say "Build: ${BUILD_DIR:-unknown}"
  else
    # Without .env the target is unknown. Guessing a path could destroy an unrelated
    # directory, so say it is unknown instead.
    warn ".env not found, so the data directories are unknown."
    say "Docker volumes can still be removed; host directories cannot."
  fi

  if ask_yes_no "Remove Agent data?"; then
    PLAN_DATA="yes"
  else
    PLAN_DATA="no"
  fi
}

ask_ssh() {
  ask_step 4 "SSH key"

  if [ "$SSH_FOUND" != "yes" ]; then
    PLAN_SSH="no"
    pause_skip "No Web SSH terminal key found${SSH_NOTE:+ ($SSH_NOTE)}"
    return 0
  fi

  say "The installer added a key to ${SSH_NOTE}'s authorized_keys."
  say "Removing it closes the console's shell access to this host."

  if ask_yes_no "Remove the Web SSH terminal key?"; then
    PLAN_SSH="yes"
  else
    PLAN_SSH="no"
  fi
}

# Asked just before the final confirmation rather than as a review item. The compose
# file is the installation, so removing it only makes sense once the containers are
# going away too.
ask_install_dir() {
  PLAN_INSTALL_DIR="no"
  [ -d "$INSTALL_DIR" ] || return 0

  if ask_yes_no "Also remove the install directory ($INSTALL_DIR)?"; then
    PLAN_INSTALL_DIR="yes"
  fi
}

# ---------------------------------------------------------------------------
# Phase 2: review
# ---------------------------------------------------------------------------

print_review() {
  local containers_line images_line data_line ssh_line

  if [ "$PLAN_CONTAINERS" = "yes" ]; then
    containers_line="remove  ($CONTAINER_NOTE)"
  elif [ "$CONTAINERS_FOUND" = "yes" ]; then
    containers_line="keep    (still running: $CONTAINER_NOTE)"
  else
    containers_line="none found"
  fi

  if [ "$PLAN_IMAGES" = "yes" ]; then
    images_line="remove  ($(echo "$IMAGES_FOUND" | grep -c .) image(s))"
  elif [ -n "$IMAGES_FOUND" ]; then
    images_line="keep    ($(echo "$IMAGES_FOUND" | grep -c .) image(s))"
  else
    images_line="none found"
  fi

  if [ "$PLAN_DATA" = "yes" ]; then
    data_line="remove  (unregisters this machine from OPTiCS Hub)"
  else
    data_line="keep"
  fi

  if [ "$PLAN_SSH" = "yes" ]; then
    ssh_line="remove  ($SSH_NOTE)"
  elif [ "$SSH_FOUND" = "yes" ]; then
    ssh_line="keep    ($SSH_NOTE)"
  else
    ssh_line="none found"
  fi

  echo ""
  echo "Review"
  echo ""
  echo "    1  Containers   $containers_line"
  echo "    2  Images       $images_line"
  echo "    3  Agent data   $data_line"
  echo "    4  SSH key      $ssh_line"
  echo ""
  echo "    Install dir    $INSTALL_DIR"

  # Show the exact paths once more: anything headed for rm -rf deserves a second look.
  if [ "$PLAN_DATA" = "yes" ]; then
    if [ -n "$DATA_DIR" ] || [ -n "$BUILD_DIR" ]; then
      [ -n "$DATA_DIR" ]  && echo "    Will delete    $DATA_DIR"
      [ -n "$BUILD_DIR" ] && echo "    Will delete    $BUILD_DIR"
    else
      echo "    Data directories are unknown (.env missing); only volumes are removed"
    fi
  elif [ -n "$DATA_DIR" ] || [ -n "$BUILD_DIR" ]; then
    echo "    Data kept at   ${DATA_DIR:-?} , ${BUILD_DIR:-?}"
  fi

  if [ "$PLAN_CONTAINERS" = "yes" ]; then
    echo "    The Agent stops serving this host once containers are removed"
  fi
  echo ""
}

# Declining here ends the run with nothing removed.
confirm_plan() {
  local answer
  while true; do
    print_review
    ask "Proceed? (Y/n, or a number to change): "
    read -r answer </dev/tty
    answer=$(printf '%s' "$answer" | tr -d '[:space:]')

    case "$answer" in
      ""|Y|y)
        return 0
        ;;
      N|n)
        say "Nothing was changed."
        exit 0
        ;;
      1) ask_containers ;;
      2) ask_images ;;
      3) ask_data ;;
      4) ask_ssh ;;
      *)
        warn "Enter Y, n, or 1-4."
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Phase 3: apply
# ---------------------------------------------------------------------------

apply_containers() {
  step "Removing containers"

  if [ "$PLAN_CONTAINERS" != "yes" ]; then
    pause_skip "Skipped"
    return 0
  fi

  if [ -f "$INSTALL_DIR/docker-compose.yml" ] && [ -n "$COMPOSE_CMD" ]; then
    say "Stopping via compose in $INSTALL_DIR..."
    (cd "$INSTALL_DIR" && $COMPOSE_CMD down --remove-orphans)
  else
    # Without the compose file or command, fall back to names: the pinned project name
    # makes them predictable.
    say "Compose definition not found. Falling back to container names..."
    docker rm -f optics-agent-optics-agent-dashboard-1 >/dev/null 2>&1
    docker rm -f optics-agent-optics-agent-1 >/dev/null 2>&1
    docker network rm optics-agent_service-network >/dev/null 2>&1
  fi

  DONE_CONTAINERS="removed"
  say "Containers removed."
}

apply_images() {
  step "Removing images"

  if [ "$PLAN_IMAGES" != "yes" ]; then
    pause_skip "Skipped"
    return 0
  fi

  echo "$IMAGES_FOUND" | xargs -r docker rmi >/dev/null 2>&1
  DONE_IMAGES="removed"
  say "Images removed."
}

apply_data() {
  step "Removing Agent data"

  if [ "$PLAN_DATA" != "yes" ]; then
    pause_skip "Skipped"
    return 0
  fi

  docker volume rm optics-agent_optics-data >/dev/null 2>&1
  docker volume rm optics-build >/dev/null 2>&1
  say "Docker volumes removed."

  # Only paths read from .env, and only when absolute and not root.
  local dir removed_any="no"
  for dir in "$DATA_DIR" "$BUILD_DIR"; do
    [ -n "$dir" ] || continue
    if ! safe_to_remove "$dir"; then
      warn "Refusing to remove an unsafe path: $dir"
      continue
    fi
    if [ -d "$dir" ]; then
      say "Removing $dir"
      rm -rf "$dir"
      removed_any="yes"
    fi
  done

  if [ -z "$DATA_DIR" ] && [ -z "$BUILD_DIR" ]; then
    warn "Data directories are unknown (.env not found)."
    say "Remove them manually if you know where they are."
    DONE_DATA="volumes only"
  elif [ "$removed_any" = "yes" ]; then
    DONE_DATA="removed"
  else
    DONE_DATA="volumes only"
  fi

  say "Agent data removed. This machine is no longer registered with OPTiCS Hub."
}

apply_ssh() {
  step "Removing SSH key"

  if [ "$PLAN_SSH" != "yes" ]; then
    pause_skip "Skipped"
    return 0
  fi

  # Only lines carrying the installer\'s marker; other keys are the user\'s.
  if [ -f "$SSH_AUTHORIZED_KEYS" ]; then
    if [ "$(id -un)" = "$SSH_TARGET_USER" ]; then
      sed -i "/ ${SSH_KEY_MARKER}\$/d" "$SSH_AUTHORIZED_KEYS"
    else
      sudo -u "$SSH_TARGET_USER" sed -i "/ ${SSH_KEY_MARKER}\$/d" "$SSH_AUTHORIZED_KEYS"
    fi
  fi

  if [ -d "$SSH_STATE_DIR" ] && safe_to_remove "$SSH_STATE_DIR"; then
    if [ "$(id -un)" = "$SSH_TARGET_USER" ]; then
      rm -rf "$SSH_STATE_DIR"
    else
      sudo -u "$SSH_TARGET_USER" rm -rf "$SSH_STATE_DIR"
    fi
  fi

  DONE_SSH="removed"
  say "Web SSH terminal key removed ($SSH_TARGET_USER)."
}

apply_install_dir() {
  step "Removing install directory"

  if [ "$PLAN_INSTALL_DIR" != "yes" ]; then
    pause_skip "Kept at $INSTALL_DIR"
    return 0
  fi

  if ! safe_to_remove "$INSTALL_DIR"; then
    warn "Refusing to remove an unsafe path: $INSTALL_DIR"
    return 0
  fi

  rm -rf "$INSTALL_DIR"
  DONE_INSTALL_DIR="removed"
  say "Install directory removed."
}

apply_plan() {
  apply_containers
  apply_images
  apply_data
  apply_ssh
  apply_install_dir
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

echo ""
echo "OPTiCS Agent Uninstaller v${UNINSTALLER_VERSION}"
say "Install dir: $INSTALL_DIR"
# Time to read what is starting.
if [ -t 0 ] && [ -t 1 ]; then
  sleep "${OPTICS_WELCOME_PAUSE:-2}"
fi

probe_compose

# All read-only: the questions depend on knowing what exists.
detect_containers
detect_images
detect_data
detect_ssh

ask_containers
ask_images
ask_data
ask_ssh

confirm_plan
# Asked after the review: losing the compose file also loses the means to undo, so it
# is decided last.
echo ""
ask_install_dir

countdown
apply_plan

echo ""
echo ""
echo "Done."
echo ""

# One place stating what went and what stayed, so nobody has to go looking for the
# answer after an irreversible operation.
echo "    Containers   ${DONE_CONTAINERS:-kept}"
echo "    Images       ${DONE_IMAGES:-kept}"
echo "    Agent data   ${DONE_DATA:-kept}"
echo "    SSH key      ${DONE_SSH:-kept}"
echo "    Install dir  ${DONE_INSTALL_DIR:-kept}"
echo ""

if [ "$PLAN_DATA" != "yes" ] && { [ -n "$DATA_DIR" ] || [ -n "$BUILD_DIR" ]; }; then
  echo "    Agent data is still at:"
  [ -n "$DATA_DIR" ]  && echo "      $DATA_DIR"
  [ -n "$BUILD_DIR" ] && echo "      $BUILD_DIR"
  echo ""
fi

if [ "$PLAN_INSTALL_DIR" != "yes" ] && [ -d "$INSTALL_DIR" ]; then
  echo "    Reinstall or restart from: $INSTALL_DIR"
  echo ""
fi

exit 0
