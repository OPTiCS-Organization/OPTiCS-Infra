#!/bin/bash
#
# OPTiCS Agent Linux Installer
#
# Since 0.6.0 the Agent and Dashboard run from images published on GHCR rather than
# being built from source, so this script only downloads docker-compose.yml and
# .env.example. Neither Node.js nor git is required.
#
# The install directory is left behind on purpose: the compose file IS the installation,
# and removing it leaves no way to stop or update the containers.
#
# Flow: ask everything, confirm, then act.
#   Phase 1  ask    - collect settings only; nothing on the system changes
#   Phase 2  review - show what was collected; any item can be revised by number
#   Phase 3  apply  - the first real changes happen here, Docker install included
# Aborting at phase 2 therefore leaves the machine untouched.
set -uo pipefail

INSTALLER_VERSION="0.5.0"

AGENT_REPO_RAW="https://raw.githubusercontent.com/OPTiCS-Organization/OPTiCS-Agent/main"
INSTALL_DIR="${OPTICS_INSTALL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/optics/agent}"
# Kept separate from the install dir: that holds two small files, while this grows
# without bound as the build workspace accumulates.
DATA_ROOT_DEFAULT="${XDG_DATA_HOME:-$HOME/.local/share}/optics/data"
DATA_ROOT="${OPTICS_DATA_ROOT:-}"
SSH_KEY_MARKER="optics-agent-web-terminal"

# Collected in phase 1. Nothing reads these until phase 3.
PLAN_DATA_ROOT=""
PLAN_IMAGE_TAG=""
PLAN_AGENT_PORT=""
PLAN_DASHBOARD_PORT=""
PLAN_SSH_ENABLE="no"
PLAN_SSH_NOTE=""
PLAN_STOP_CONTAINERS="no"
PLAN_DOCKER="present"
PLAN_COMPOSE="present"

SSH_CONFIGURED=0
SSH_PRIVATE_KEY=""
SSH_READY_USER=""
COMPOSE_CMD=""

# Progress through phase 3.
STEP_TOTAL=6
STEP_NUM=0
step() {
  STEP_NUM=$((STEP_NUM + 1))
  echo ""
  echo "[${STEP_NUM}/${STEP_TOTAL}] $1"
}

# Phase 1 uses fixed numbers, not a counter: the review lets you jump back to an item,
# so "[3/5] Ports" must keep matching review entry 3.
ASK_TOTAL=5
ask_step() {
  echo ""
  echo "[$1/${ASK_TOTAL}] $2"
}

# Pause on a step that had nothing to ask, so the reason for skipping is readable
# before the next prompt scrolls past. Pointless when nobody is watching.
SKIP_PAUSE="${OPTICS_SKIP_PAUSE:-1.5}"
pause_skip() {
  say "$1"
  if [ -t 0 ] && [ -t 1 ]; then
    sleep "$SKIP_PAUSE"
  fi
}

# Last chance to Ctrl+C before anything changes.
COUNTDOWN_FROM="${OPTICS_COUNTDOWN:-3}"
countdown() {
  if [ ! -t 0 ] || [ ! -t 1 ] || [ "$COUNTDOWN_FROM" -le 0 ] 2>/dev/null; then
    return 0
  fi

  echo ""
  printf '  Installation starts in '
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

# A per-line prefix eats width and buries the step structure; indent content instead.
say()  { echo "  $1"; }
warn() { echo "  ! $1"; }

cleanup() {
  [ -n "${TAGS_CACHE_FILE:-}" ] && rm -f "$TAGS_CACHE_FILE"
  [ -n "${ENV_BACKUP:-}" ] && rm -f "$ENV_BACKUP"
  return 0
}
trap cleanup EXIT
ask()  { printf '  %s' "$1" >&2; }

# ---------------------------------------------------------------------------
# OS detection
# ---------------------------------------------------------------------------
# Read-only. Checked before the questions because Docker cannot be installed later
# without knowing the package manager.

OS=$(uname -s)
DISTRO=""
DISTRO_LIKE=""
# Branch on the package manager; listing distro names grows with every derivative.
PKG=""

detect_os() {
  case "$OS" in
    Linux*)
      if [ -r /etc/os-release ]; then
        DISTRO=$(. /etc/os-release && echo "$ID")
        DISTRO_LIKE=$(. /etc/os-release && echo "${ID_LIKE:-}")
      fi
      OS_LABEL="Linux (${DISTRO:-unknown})"

      case " $DISTRO $DISTRO_LIKE " in
        *" arch "*)   PKG="pacman" ;;
        *" debian "*|*" ubuntu "*) PKG="apt" ;;
      esac

      if [ -z "$PKG" ]; then
        case "$DISTRO" in
          arch|manjaro|endeavouros|garuda) PKG="pacman" ;;
          ubuntu|debian|linuxmint|pop|elementary) PKG="apt" ;;
        esac
      fi

      if [ -z "$PKG" ]; then
        say "Unsupported Linux distro: ${DISTRO:-unknown}"
        say "Supported: Arch-based (pacman), Ubuntu/Debian-based (apt)"
        say "Install Docker and the Compose plugin manually, then run this script again."
        exit 1
      fi
      say "$OS_LABEL, package manager: $PKG"
      ;;
    *)
      say "Detected OS: $OS (Unsupported)"
      echo "[Notice] OPTiCS will not get any responsibility about your PC when script got fail."
      ask "$OS is unsupported OS in this script. Continue installation anyway? (y/N): "
      read -r answer </dev/tty
      if [ "$answer" = "Y" ] || [ "$answer" = "y" ]; then
        say "Continuing installation process..."
      else
        say "Aborting installation process..."
        exit 1
      fi
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Needed during phase 1 for the version list, so this one dependency comes early.
ensure_curl() {
  command -v curl >/dev/null 2>&1 && return 0

  say "Installing curl..."
  case "$PKG" in
    pacman) sudo pacman -S --needed --noconfirm curl ;;
    apt)    sudo apt-get update && sudo apt-get install -y curl ;;
  esac

  if ! command -v curl >/dev/null 2>&1; then
    say "curl is required. Aborting..."
    exit 1
  fi
}

install_docker() {
  case "$PKG" in
    pacman)
      sudo pacman -S --needed --noconfirm docker docker-compose || return 1
      ;;
    apt)
      # Some Ubuntu/Debian docker.io builds ship without the Compose plugin; the official
      # repository behaves the same across versions.
      sudo apt-get update || return 1
      sudo apt-get install -y ca-certificates curl gnupg || return 1
      sudo install -m 0755 -d /etc/apt/keyrings || return 1

      local repo_id="$DISTRO"
      case " $DISTRO $DISTRO_LIKE " in
        *" ubuntu "*) repo_id="ubuntu" ;;
        *" debian "*) repo_id="debian" ;;
      esac
      [ "$DISTRO" = "ubuntu" ] && repo_id="ubuntu"
      [ "$DISTRO" = "debian" ] && repo_id="debian"

      curl -fsSL "https://download.docker.com/linux/${repo_id}/gpg" \
        | sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg || return 1
      sudo chmod a+r /etc/apt/keyrings/docker.gpg

      # Derivatives use their own codename, so prefer the upstream one.
      local codename
      codename=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-${DEBIAN_CODENAME:-$VERSION_CODENAME}}")
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${repo_id} ${codename} stable" \
        | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null || return 1

      sudo apt-get update || return 1
      sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return 1
      ;;
  esac

  sudo systemctl enable --now docker || return 1
  sudo usermod -aG docker "$USER"
  say "Docker installed. Re-login may be needed for group changes."
  return 0
}

fetch() {
  local url="$1"
  local dest="$2"
  if ! curl -fsSL "$url" -o "$dest"; then
    warn "Failed to download: $url"
    return 1
  fi
  return 0
}

set_agent_env() {
  local key="$1"
  local value="$2"
  local env_file="$INSTALL_DIR/.env"

  if grep -q "^${key}=" "$env_file" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$env_file"
  else
    printf "%s=%s\n" "$key" "$value" >> "$env_file"
  fi
}

# Settings are written in step 3 but the pull happens in step 5; on failure .env would
# point at an image that does not exist, so a later `docker compose up` would fail too.
#
# Restored key by key rather than wholesale: step 4 may have generated an SSH key and
# edited authorized_keys, and rolling those .env values back would contradict the host.
ENV_BACKUP=""
ENV_BACKUP_KEYS="OPTICS_DATA_DIR OPTICS_BUILD_DIR AGENT_PORT DASHBOARD_PORT AGENT_IMAGE_TAG DASHBOARD_IMAGE_TAG"

backup_env() {
  [ -f "$INSTALL_DIR/.env" ] || return 0
  ENV_BACKUP=$(mktemp 2>/dev/null) || return 0

  local key line
  for key in $ENV_BACKUP_KEYS; do
    line=$(grep -E "^${key}=" "$INSTALL_DIR/.env" 2>/dev/null | tail -n 1)
    # Keys absent beforehand are marked for deletion.
    if [ -n "$line" ]; then
      printf '%s\n' "$line" >> "$ENV_BACKUP"
    else
      printf '#absent %s\n' "$key" >> "$ENV_BACKUP"
    fi
  done
}

restore_env() {
  [ -n "$ENV_BACKUP" ] && [ -f "$ENV_BACKUP" ] || return 0
  [ -f "$INSTALL_DIR/.env" ] || return 0

  local line key
  while IFS= read -r line; do
    case "$line" in
      "#absent "*)
        key=${line#\#absent }
        sed -i "/^${key}=/d" "$INSTALL_DIR/.env"
        ;;
      *=*)
        key=${line%%=*}
        set_agent_env "$key" "${line#*=}"
        ;;
    esac
  done < "$ENV_BACKUP"

  say "Reverted .env to the previous settings."
}

run_as_ssh_user() {
  if [ "$(id -un)" = "$SSH_TARGET_USER" ]; then
    "$@"
  else
    sudo -u "$SSH_TARGET_USER" "$@"
  fi
}

free_space_of() {
  local dir="$1"
  while [ -n "$dir" ] && [ ! -d "$dir" ]; do
    local parent
    parent=$(dirname "$dir")
    [ "$parent" = "$dir" ] && break
    dir="$parent"
  done
  df -h "$dir" 2>/dev/null | awk 'NR == 2 { print $4 " free on " $1 " (" $6 ")" }'
}

prepare_data_root() {
  local dir="$1"

  case "$dir" in
    /*) ;;
    *)
      warn "Must be an absolute path: $dir"
      return 1
      ;;
  esac

  if ! mkdir -p "$dir/agent" "$dir/build" 2>/dev/null; then
    warn "Cannot create: $dir"
    say "Check that the drive is mounted and writable."
    return 1
  fi

  if ! touch "$dir/.optics-write-test" 2>/dev/null; then
    warn "Not writable: $dir"
    return 1
  fi
  rm -f "$dir/.optics-write-test"

  return 0
}

# Two round trips (token, then list), roughly 2s. The timeout matters because falling
# back to latest beats stalling forever on an unresponsive network.
GHCR_TIMEOUT="${OPTICS_GHCR_TIMEOUT:-8}"

list_image_tags() {
  local token
  token=$(curl -fsSL --max-time "$GHCR_TIMEOUT" \
    "https://ghcr.io/token?scope=repository:optics-organization/optics-agent:pull&service=ghcr.io" 2>/dev/null \
    | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
  [ -n "$token" ] || return 1

  curl -fsSL --max-time "$GHCR_TIMEOUT" -H "Authorization: Bearer $token" \
    "https://ghcr.io/v2/optics-organization/optics-agent/tags/list" 2>/dev/null \
    | tr ',' '\n' | sed -n 's/.*"\([0-9][0-9.]*\)".*/\1/p' | sort -Vr
}

# Fetched while the data directory is being asked, so the wait overlaps with typing.
TAGS_CACHE_FILE=""
prefetch_image_tags() {
  TAGS_CACHE_FILE=$(mktemp 2>/dev/null) || return 0
  list_image_tags > "$TAGS_CACHE_FILE" 2>/dev/null &
  PREFETCH_PID=$!
}

# Wait for the prefetch if it is still running; fetch now if it never started.
cached_image_tags() {
  if [ -n "${PREFETCH_PID:-}" ]; then
    wait "$PREFETCH_PID" 2>/dev/null
    PREFETCH_PID=""
  fi

  if [ -n "$TAGS_CACHE_FILE" ] && [ -s "$TAGS_CACHE_FILE" ]; then
    cat "$TAGS_CACHE_FILE"
    return 0
  fi

  list_image_tags
}

installed_agent_version() {
  # No tag in .env means nothing was installed here; unrelated images left on the host
  # must not be mistaken for this installation.
  local tag
  tag=$(grep -E '^AGENT_IMAGE_TAG=' "$INSTALL_DIR/.env" 2>/dev/null | tail -n 1 | cut -d= -f2-)
  [ -n "$tag" ] || return 1

  command -v docker >/dev/null 2>&1 || return 1

  local version
  version=$(docker image inspect "ghcr.io/optics-organization/optics-agent:$tag" \
    --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null)

  # Older images carry no label, in which case the tag is the version. "latest" is not
  # a version, so treat it as unknown.
  if [ -z "$version" ] || [ "$version" = "<no value>" ]; then
    [ "$tag" = "latest" ] && return 1
    version="$tag"
  fi

  printf '%s' "$version"
}

is_downgrade() {
  local target="$1"
  local current="$2"

  [ -n "$target" ] && [ -n "$current" ] || return 1
  [ "$target" = "$current" ] && return 1

  local lowest
  lowest=$(printf '%s\n%s\n' "$target" "$current" | sort -V | head -n 1)
  [ "$lowest" = "$target" ]
}

check_port() {
  local port=$1
  if command -v ss >/dev/null 2>&1; then
    ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE "(^|:)${port}$"
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tln 2>/dev/null | awk '{print $4}' | grep -qE "(^|:)${port}$"
  else
    # With no way to check, assume free; compose reports a real conflict anyway.
    return 1
  fi
}

port_owned_by_agent() {
  local port=$1
  [ -f "$INSTALL_DIR/docker-compose.yml" ] || return 1
  command -v docker >/dev/null 2>&1 || return 1

  local ids
  ids=$(cd "$INSTALL_DIR" && $COMPOSE_CMD ps -q 2>/dev/null)
  [ -n "$ids" ] || return 1

  # A published port matching this number belongs to this installation.
  echo "$ids" | xargs -r docker port 2>/dev/null | grep -qE "(^|:)${port}(\s|$|->)" && return 0

  docker inspect --format '{{range $p, $conf := .HostConfig.PortBindings}}{{range $conf}}{{.HostPort}} {{end}}{{end}}' $ids 2>/dev/null \
    | tr ' ' '\n' | grep -qx "$port"
}

port_available() {
  local port=$1
  check_port "$port" || return 0
  port_owned_by_agent "$port"
}

host_ssh_ready() {
  local env_file="$INSTALL_DIR/.env"
  [ -f "$env_file" ] || return 1

  pgrep -x sshd >/dev/null 2>&1 || return 1

  local ssh_user key_file host_hash
  ssh_user=$(grep -E '^HOST_SSH_USERNAME=' "$env_file" 2>/dev/null | tail -n 1 | cut -d= -f2-)
  key_file=$(grep -E '^HOST_SSH_PRIVATE_KEY_FILE=' "$env_file" 2>/dev/null | tail -n 1 | cut -d= -f2-)
  host_hash=$(grep -E '^HOST_SSH_HOST_HASH=' "$env_file" 2>/dev/null | tail -n 1 | cut -d= -f2-)

  [ -n "$ssh_user" ] && [ -n "$key_file" ] && [ -n "$host_hash" ] || return 1
  id "$ssh_user" >/dev/null 2>&1 || return 1
  [ -f "$key_file" ] && [ -f "$key_file.pub" ] || return 1

  # The public key must actually be in that user\'s authorized_keys to connect.
  local target_home auth_keys pub_body
  target_home=$(getent passwd "$ssh_user" | cut -d: -f6)
  [ -n "$target_home" ] || return 1
  auth_keys="$target_home/.ssh/authorized_keys"
  [ -r "$auth_keys" ] || return 1
  pub_body=$(awk '{print $2}' "$key_file.pub" 2>/dev/null)
  [ -n "$pub_body" ] || return 1
  grep -Fq "$pub_body" "$auth_keys" || return 1

  # A changed host key makes the Agent refuse to connect, so it must be reconfigured.
  local host_key_file actual
  host_key_file="/etc/ssh/ssh_host_ed25519_key.pub"
  [ -r "$host_key_file" ] || return 1
  actual=$(awk 'NR == 1 { print $2 }' "$host_key_file" | base64 -d 2>/dev/null | sha256sum | awk '{print $1}')
  [ "$actual" = "$host_hash" ] || return 1

  SSH_READY_USER="$ssh_user"
  return 0
}

configure_host_ssh() {
  say "Configuring host SSH access..."

  if ! command -v ssh-keygen >/dev/null 2>&1 || ! command -v sshd >/dev/null 2>&1; then
    say "Installing OpenSSH..."
    case "$PKG" in
      pacman) sudo pacman -S --needed --noconfirm openssh || return 1 ;;
      apt)    sudo apt-get install -y openssh-server openssh-client || return 1 ;;
    esac
  fi

  if command -v systemctl >/dev/null 2>&1 && ! pgrep -x sshd >/dev/null 2>&1; then
    # Unit name differs: sshd on Arch, ssh on Debian derivatives.
    if systemctl list-unit-files sshd.service --no-legend 2>/dev/null | grep -q sshd.service; then
      sudo systemctl enable --now sshd || return 1
    elif systemctl list-unit-files ssh.service --no-legend 2>/dev/null | grep -q ssh.service; then
      sudo systemctl enable --now ssh || return 1
    fi
  fi

  if ! pgrep -x sshd >/dev/null 2>&1; then
    warn "sshd is not running. Skipped."
    return 1
  fi

  SSH_TARGET_USER="${OPTICS_SSH_USER:-${SUDO_USER:-$(id -un)}}"
  if [ "$SSH_TARGET_USER" = "root" ]; then
    warn "Refusing a root SSH shell. Set OPTICS_SSH_USER to a non-root user."
    return 1
  fi
  if ! id "$SSH_TARGET_USER" >/dev/null 2>&1; then
    warn "No such user: $SSH_TARGET_USER"
    return 1
  fi

  SSH_TARGET_HOME=$(getent passwd "$SSH_TARGET_USER" | cut -d: -f6)
  if [ -z "$SSH_TARGET_HOME" ] || [ ! -d "$SSH_TARGET_HOME" ]; then
    warn "No home directory for $SSH_TARGET_USER."
    return 1
  fi

  SSH_STATE_DIR="$SSH_TARGET_HOME/.local/share/optics/ssh"
  SSH_PRIVATE_KEY="$SSH_STATE_DIR/agent_host_ed25519"
  SSH_AUTHORIZED_KEYS="$SSH_TARGET_HOME/.ssh/authorized_keys"

  run_as_ssh_user install -d -m 700 "$SSH_STATE_DIR" "$SSH_TARGET_HOME/.ssh" || return 1
  if [ ! -f "$SSH_PRIVATE_KEY" ]; then
    run_as_ssh_user ssh-keygen -q -t ed25519 -N "" -C "$SSH_KEY_MARKER" -f "$SSH_PRIVATE_KEY" || return 1
  fi
  run_as_ssh_user chmod 600 "$SSH_PRIVATE_KEY"
  run_as_ssh_user chmod 644 "$SSH_PRIVATE_KEY.pub"

  SSH_HOST_KEY_FILE="/etc/ssh/ssh_host_ed25519_key.pub"
  if [ ! -r "$SSH_HOST_KEY_FILE" ]; then
    warn "Ed25519 host key unavailable. Skipped."
    return 1
  fi
  SSH_HOST_KEY_BODY=$(awk 'NR == 1 { print $2 }' "$SSH_HOST_KEY_FILE")
  SSH_HOST_HASH=$(printf "%s" "$SSH_HOST_KEY_BODY" | base64 -d | sha256sum | awk '{print $1}')
  if [ -z "$SSH_HOST_HASH" ]; then
    warn "Cannot calculate the host key hash."
    return 1
  fi

  run_as_ssh_user touch "$SSH_AUTHORIZED_KEYS"
  run_as_ssh_user chmod 600 "$SSH_AUTHORIZED_KEYS"

  SSH_PUBLIC_KEY=$(cat "$SSH_PRIVATE_KEY.pub")
  SSH_PUBLIC_KEY_BODY=$(printf "%s" "$SSH_PUBLIC_KEY" | awk '{print $2}')
  if ! grep -Fq " $SSH_PUBLIC_KEY_BODY " "$SSH_AUTHORIZED_KEYS"; then
    SSH_AUTHORIZED_ENTRY="restrict,pty $SSH_PUBLIC_KEY"
    if [ "$(id -un)" = "$SSH_TARGET_USER" ]; then
      printf "%s\n" "$SSH_AUTHORIZED_ENTRY" >> "$SSH_AUTHORIZED_KEYS"
    else
      printf "%s\n" "$SSH_AUTHORIZED_ENTRY" | sudo -u "$SSH_TARGET_USER" tee -a "$SSH_AUTHORIZED_KEYS" >/dev/null
    fi
  fi

  set_agent_env "HOST_SSH_HOST" "host.docker.internal"
  set_agent_env "HOST_SSH_PORT" "22"
  set_agent_env "HOST_SSH_USERNAME" "$SSH_TARGET_USER"
  set_agent_env "HOST_SSH_PRIVATE_KEY_FILE" "$SSH_PRIVATE_KEY"
  set_agent_env "HOST_SSH_PRIVATE_KEY_PATH" "/run/secrets/host_ssh_key"
  set_agent_env "HOST_SSH_HOST_HASH" "$SSH_HOST_HASH"

  say "Configured for user: $SSH_TARGET_USER"
  return 0
}

# Phase 3 only. Phase 1 works without Docker, so nothing is installed before consent.
ensure_docker() {
  local docker_ver
  docker_ver=$(docker --version 2>/dev/null)

  if [ -z "$docker_ver" ]; then
    say "Installing Docker..."
    if ! install_docker; then
      warn "Docker installation failed. Install it manually and retry."
      exit 1
    fi
  else
    say "Docker ${docker_ver#Docker version }"
  fi

  # Prefer the plugin: standalone docker-compose may be v1, which cannot parse parts
  # of this compose file.
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
    return 0
  fi

  if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
    return 0
  fi

  say "Installing Docker Compose..."
  case "$PKG" in
    pacman) sudo pacman -S --needed --noconfirm docker-compose ;;
    apt)    sudo apt-get update && sudo apt-get install -y docker-compose-plugin ;;
  esac

  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
  else
    warn "Docker Compose installation failed. Install it manually and retry."
    exit 1
  fi
}

# Phase 1 variant: fill COMPOSE_CMD if present, stay quiet otherwise. Its absence
# also implies there is no prior installation to inspect.
probe_compose() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
  fi
}

# Presence check only; the install itself waits for consent in phase 3.
detect_docker_state() {
  if command -v docker >/dev/null 2>&1; then
    PLAN_DOCKER="present"
  else
    PLAN_DOCKER="install"
  fi

  if [ -n "$COMPOSE_CMD" ]; then
    PLAN_COMPOSE="present"
  else
    PLAN_COMPOSE="install"
  fi
}

# ---------------------------------------------------------------------------
# Phase 1: ask
# ---------------------------------------------------------------------------
# Functions here only decide values: no file writes, no sudo. The one exception is
# creating the data directory, which is the only way to prove it is writable, and an
# empty directory left behind is harmless.

ask_data_root() {
  if [ -n "$DATA_ROOT" ]; then
    ask_step 1 "Data directory"
    pause_skip "From OPTICS_DATA_ROOT: $DATA_ROOT"
    if prepare_data_root "$DATA_ROOT"; then
      PLAN_DATA_ROOT="$DATA_ROOT"
      return 0
    fi
    say "OPTICS_DATA_ROOT is unusable. Aborting..."
    exit 1
  fi

  # On reinstall, default to what .env already says so the chosen drive is not retyped.
  local default="$DATA_ROOT_DEFAULT"
  local existing
  existing=$(grep -E '^OPTICS_DATA_DIR=' "$INSTALL_DIR/.env" 2>/dev/null | tail -n 1 | cut -d= -f2-)
  if [ -n "$existing" ]; then
    default=$(dirname "$existing")
  fi

  ask_step 1 "Data directory"
  say "Build workspace and local database live here, and this grows over time."
  say "Default: $default ($(free_space_of "$default"))"

  local input candidate
  while true; do
    ask "Data directory [$default]: "
    read -r input </dev/tty
    candidate="${input:-$default}"
    # read does not expand a leading ~.
    case "$candidate" in
      "~"|"~/"*) candidate="$HOME${candidate#\~}" ;;
    esac

    if prepare_data_root "$candidate"; then
      PLAN_DATA_ROOT="$candidate"
      return 0
    fi
    say "Please enter a different path."
  done
}

ask_image_tag() {
  if [ -n "${OPTICS_AGENT_TAG:-}" ]; then
    ask_step 2 "Agent version"
    pause_skip "From OPTICS_AGENT_TAG: $OPTICS_AGENT_TAG"
    PLAN_IMAGE_TAG="$OPTICS_AGENT_TAG"
    return 0
  fi

  local tags
  tags=$(cached_image_tags)

  if [ -z "$tags" ]; then
    # A missing list must not block the install.
    ask_step 2 "Agent version"
    pause_skip "Could not fetch the version list. Using latest."
    PLAN_IMAGE_TAG="latest"
    return 0
  fi

  local current
  current=$(installed_agent_version)

  ask_step 2 "Agent version"
  say "Available Agent versions:"
  echo "    latest (recommended)"
  # Mark the running version so an older one is not picked unknowingly.
  local line
  echo "$tags" | head -n 8 | while read -r line; do
    if [ -n "$current" ] && [ "$line" = "$current" ]; then
      echo "    $line  <- currently installed"
    else
      echo "    $line"
    fi
  done

  local input confirm
  while true; do
    ask "Agent version to install [latest]: "
    read -r input </dev/tty
    input=$(printf '%s' "${input:-latest}" | tr -d '[:space:]')

    if [ "$input" = "latest" ]; then
      PLAN_IMAGE_TAG="latest"
      return 0
    fi

    # An unlisted tag would only fail at pull time; reject it here instead.
    if ! echo "$tags" | grep -qx "$input"; then
      say "Unknown version: $input"
      continue
    fi

    # Downgrading can leave the Agent unable to start against a newer schema, and it is
    # hard to undo, so confirm once.
    if is_downgrade "$input" "$current"; then
      echo ""
      warn "$input is older than the installed $current."
      say "The local database was migrated by the newer version;"
      say "the Agent may fail to start."
      ask "Install $input anyway? (y/N): "
      read -r confirm </dev/tty
      if [ "$confirm" != "Y" ] && [ "$confirm" != "y" ]; then
        continue
      fi
    fi

    PLAN_IMAGE_TAG="$input"
    return 0
  done
}

# stdout is this function\'s return value, so every message goes to stderr.
ask_one_port() {
  local label="$1"
  local default="$2"
  local port="$3"

  # Default to the port in .env so a custom choice survives updates.
  [ -n "$port" ] || port="$default"

  local input
  while true; do
    ask "Port for $label [$port]: "
    read -r input </dev/tty
    input=$(printf '%s' "${input:-$port}" | tr -d '[:space:]')

    # Non-numeric or out-of-range values would only fail once compose starts.
    case "$input" in
      ''|*[!0-9]*)
        echo "  ! Enter a number between 1 and 65535." >&2
        continue
        ;;
    esac
    if [ "$input" -lt 1 ] || [ "$input" -gt 65535 ]; then
      echo "  ! Enter a number between 1 and 65535." >&2
      continue
    fi

    if ! port_available "$input"; then
      echo "  ! Port $input is in use." >&2
      port="$input"
      continue
    fi

    printf '%s' "$input"
    return 0
  done
}

ask_ports() {
  ask_step 3 "Ports"

  local existing_agent existing_dashboard
  existing_agent=$(grep -E '^AGENT_PORT=' "$INSTALL_DIR/.env" 2>/dev/null | tail -n 1 | cut -d= -f2-)
  existing_dashboard=$(grep -E '^DASHBOARD_PORT=' "$INSTALL_DIR/.env" 2>/dev/null | tail -n 1 | cut -d= -f2-)

  PLAN_AGENT_PORT=$(ask_one_port "optics-agent" 5230 "$existing_agent")
  PLAN_DASHBOARD_PORT=$(ask_one_port "optics-agent-dashboard" 5240 "$existing_dashboard")
}

ask_ssh() {
  # Skip the question when everything is already in place; reconfigure only on drift.
  if host_ssh_ready; then
    PLAN_SSH_ENABLE="skip"
    PLAN_SSH_NOTE="already configured ($SSH_READY_USER)"
    ask_step 4 "Web SSH terminal"
    pause_skip "Already configured ($SSH_READY_USER)"
    return 0
  fi

  local answer
  ask_step 4 "Web SSH terminal"
  say "Opens a shell on this host from the OPTiCS console."
  say "Configures sshd, generates a key, and adds it to authorized_keys."
  ask "Enable Web SSH terminal access? (y/N): "
  read -r answer </dev/tty
  if [ "$answer" = "Y" ] || [ "$answer" = "y" ]; then
    PLAN_SSH_ENABLE="yes"
    PLAN_SSH_NOTE="will be configured"
  else
    PLAN_SSH_ENABLE="no"
    PLAN_SSH_NOTE="disabled"
  fi
}

# Docker is a prerequisite, not a choice: the Agent runs as a container. Say so rather
# than pretending it can be declined.
ask_docker() {
  if [ "$PLAN_DOCKER" = "present" ] && [ "$PLAN_COMPOSE" = "present" ]; then
    ask_step 5 "Install Docker"
    pause_skip "Docker and Compose are already installed"
    return 0
  fi

  ask_step 5 "Install Docker"
  say "Required: the Agent runs as a container."
  if [ "$PLAN_DOCKER" = "install" ]; then
    say "Docker will be installed with $PKG."
  fi
  if [ "$PLAN_COMPOSE" = "install" ]; then
    say "The Compose plugin will be installed with $PKG."
  fi
  say "To use your own setup, abort and install Docker first."
}

# Recorded so the review can state what will be stopped.
detect_running_containers() {
  PLAN_STOP_CONTAINERS="no"
  [ -n "$COMPOSE_CMD" ] || return 0
  [ -f "$INSTALL_DIR/docker-compose.yml" ] || return 0

  if (cd "$INSTALL_DIR" && $COMPOSE_CMD ps -q 2>/dev/null | grep -q .); then
    PLAN_STOP_CONTAINERS="yes"
  fi
}

# ---------------------------------------------------------------------------
# Phase 2: review
# ---------------------------------------------------------------------------

print_review() {
  local ssh_line
  case "$PLAN_SSH_ENABLE" in
    skip) ssh_line="skip  ($PLAN_SSH_NOTE)" ;;
    yes)  ssh_line="yes   (sshd, key, authorized_keys)" ;;
    *)    ssh_line="no" ;;
  esac

  local version_line="$PLAN_IMAGE_TAG"
  local current
  current=$(installed_agent_version)
  # Only append the current version when it differs, to avoid printing it twice.
  if [ -n "$current" ] && [ "$current" != "$PLAN_IMAGE_TAG" ]; then
    version_line="$PLAN_IMAGE_TAG  (currently $current)"
  fi

  # Shown as one line: the question is whether containers can run, and either gap is
  # fixed the same way.
  local docker_line
  if [ "$PLAN_DOCKER" = "install" ] && [ "$PLAN_COMPOSE" = "install" ]; then
    docker_line="will install Docker + Compose"
  elif [ "$PLAN_DOCKER" = "install" ]; then
    docker_line="will install Docker"
  elif [ "$PLAN_COMPOSE" = "install" ]; then
    docker_line="will install Compose plugin"
  else
    docker_line="already installed"
  fi

  echo ""
  echo "Review"
  echo ""
  echo "    1  Data directory   $PLAN_DATA_ROOT  ($(free_space_of "$PLAN_DATA_ROOT"))"
  echo "    2  Agent version    $version_line"
  echo "    3  Ports            agent $PLAN_AGENT_PORT, dashboard $PLAN_DASHBOARD_PORT"
  echo "    4  Web SSH          $ssh_line"
  echo "    5  Docker           $docker_line"
  echo ""
  echo "    Install dir        $INSTALL_DIR"

  if [ "$PLAN_STOP_CONTAINERS" = "yes" ]; then
    echo "    Running containers will restart after images are pulled"
  fi
  echo ""
}

# Declining here ends the run with nothing changed.
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
      1) ask_data_root ;;
      2) ask_image_tag ;;
      3) ask_ports ;;
      4) ask_ssh ;;
      5) ask_docker ;;
      *)
        warn "Enter Y, n, or 1-5."
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Phase 3: apply
# ---------------------------------------------------------------------------

apply_plan() {
  if [ "$PLAN_DOCKER" = "install" ] || [ "$PLAN_COMPOSE" = "install" ]; then
    step "Installing Docker"
  else
    step "Checking Docker"
  fi
  ensure_docker

  step "Preparing install files"
  mkdir -p "$INSTALL_DIR"

  say "Downloading compose definition..."
  fetch "$AGENT_REPO_RAW/docker-compose.yml" "$INSTALL_DIR/docker-compose.yml" || exit 1

  # Never overwrite an existing .env: it holds secrets and user settings, and resetting
  # it on every reinstall would wipe the SSH config and Hub address.
  if [ -f "$INSTALL_DIR/.env" ]; then
    say "Keeping existing .env"
  else
    fetch "$AGENT_REPO_RAW/.env.example" "$INSTALL_DIR/.env" || exit 1
    say "Created .env from .env.example"
  fi

  step "Writing configuration"
  # .env changes start here; a failed pull rolls back to this point.
  backup_env
  set_agent_env "OPTICS_DATA_DIR" "$PLAN_DATA_ROOT/agent"
  set_agent_env "OPTICS_BUILD_DIR" "$PLAN_DATA_ROOT/build"
  set_agent_env "AGENT_PORT" "$PLAN_AGENT_PORT"
  set_agent_env "DASHBOARD_PORT" "$PLAN_DASHBOARD_PORT"

  # The chosen version applies to the Agent only. The Dashboard versions separately
  # (and will be merged into the Agent later), so reusing the tag would request one
  # that does not exist.
  set_agent_env "DASHBOARD_IMAGE_TAG" "latest"
  # Written unconditionally: a stale pin would otherwise survive choosing latest.
  set_agent_env "AGENT_IMAGE_TAG" "$PLAN_IMAGE_TAG"
  say "Saved to $INSTALL_DIR/.env"

  step "Setting up Web SSH terminal"
  case "$PLAN_SSH_ENABLE" in
    skip)
      SSH_CONFIGURED=1
      say "Already configured ($SSH_READY_USER)"
      ;;
    yes)
      if configure_host_ssh; then
        SSH_CONFIGURED=1
      else
        warn "Setup failed. Continuing without it."
      fi
      ;;
    *)
      say "Skipped"
      ;;
  esac

  cd "$INSTALL_DIR" || exit 1

  step "Pulling images"
  # Pull before tearing anything down. It is the slow step and the one that can fail
  # (network, missing tag), so doing it first keeps downtime to the container swap and
  # leaves the running Agent alone on failure.
  say "From GHCR (tag: $PLAN_IMAGE_TAG)"
  if ! $COMPOSE_CMD pull; then
    warn "Pull failed. Check the network or the version and retry."
    restore_env
    say "The running Agent was left untouched."
    exit 1
  fi

  step "Starting containers"
  # Downtime spans from here to up.
  if $COMPOSE_CMD ps -q 2>/dev/null | grep -q .; then
    say "Stopping current containers..."
    $COMPOSE_CMD down
  fi

  if ! $COMPOSE_CMD up -d; then
    warn "Failed to start. Check logs:"
    echo "    cd $INSTALL_DIR && $COMPOSE_CMD logs"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

echo ""
echo "OPTiCS Agent Installer v${INSTALLER_VERSION}"
# Time to read what is starting.
if [ -t 0 ] && [ -t 1 ]; then
  sleep "${OPTICS_WELCOME_PAUSE:-2}"
fi

detect_os
ensure_curl

# With Docker present an existing install can be inspected; without it this is a fresh
# install and there is nothing to inspect.
probe_compose
detect_docker_state

# Started early so the ~2s fetch overlaps with answering step 1.
prefetch_image_tags

ask_data_root
ask_image_tag
ask_ports
ask_ssh
ask_docker
detect_running_containers

confirm_plan
countdown
apply_plan

echo ""
echo ""
echo "Done."

# Read from the container that just started: "latest" says nothing about which version
# is actually running.
running_version() {
  local name="$1"
  docker inspect "$name" \
    --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null \
    | grep -v '^<no value>$'
}

AGENT_VERSION=$(running_version optics-agent-optics-agent-1)
DASHBOARD_VERSION=$(running_version optics-agent-optics-agent-dashboard-1)

AGENT_LINE="${AGENT_VERSION:-unknown}"
# Show both when the tag and the resolved version differ, as with latest.
if [ -n "$AGENT_VERSION" ] && [ "$PLAN_IMAGE_TAG" != "$AGENT_VERSION" ]; then
  AGENT_LINE="$AGENT_VERSION  (tag: $PLAN_IMAGE_TAG)"
fi

echo ""
echo "    Agent       : $AGENT_LINE"
echo "    Dashboard   : ${DASHBOARD_VERSION:-unknown}"
echo ""
echo "    Console     : http://localhost:$PLAN_DASHBOARD_PORT/"
echo "    Install dir : $INSTALL_DIR"
echo "    Data dir    : $PLAN_DATA_ROOT"
echo ""
# One cd keeps the rest short instead of repeating a long path three times.
echo "    cd $INSTALL_DIR"
echo "      update : $COMPOSE_CMD pull && $COMPOSE_CMD up -d"
echo "      stop   : $COMPOSE_CMD down"
echo "      logs   : $COMPOSE_CMD logs -f"
echo ""

# No /dev/tty (cron, CI, redirected) means nobody to ask; the install is already done.
answer=""
if [ -e /dev/tty ]; then
  ask "Open a shell in the Agent container? (y/N): "
  read -r answer </dev/tty 2>/dev/null || answer=""
fi
if [ "$answer" = "Y" ] || [ "$answer" = "y" ]; then
  if $COMPOSE_CMD ps --status running | grep -q optics-agent; then
    $COMPOSE_CMD exec optics-agent sh
  else
    warn "Agent is not running. Check: $COMPOSE_CMD logs optics-agent"
  fi
fi

exit 0
