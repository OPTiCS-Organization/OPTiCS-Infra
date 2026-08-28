#!/bin/bash
#
# OPTiCS Agent Linux Installer
#
# 0.6.0부터 Agent와 Dashboard는 소스를 빌드하지 않고 GHCR에 게시된 이미지를 받아 씁니다.
# 그래서 이 스크립트가 내려받는 것은 docker-compose.yml과 .env.example 두 개뿐이고,
# Node.js도 git도 필요하지 않습니다.
#
# 설치 디렉터리는 지워지지 않고 남습니다. compose 파일이 곧 이 설치의 실체이므로,
# 지우면 이후에 컨테이너를 멈추거나 업데이트할 방법이 사라집니다.
set -uo pipefail

INSTALLER_VERSION="0.4.0"
echo "Welcome to OPTiCS Linux Installer v${INSTALLER_VERSION}!"

AGENT_REPO_RAW="https://raw.githubusercontent.com/OPTiCS-Organization/OPTiCS-Agent/main"
INSTALL_DIR="${OPTICS_INSTALL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/optics/agent}"
SSH_KEY_MARKER="optics-agent-web-terminal"
SSH_CONFIGURED=0
SSH_PRIVATE_KEY=""

# ---------------------------------------------------------------------------
# OS 판별
# ---------------------------------------------------------------------------

OS=$(uname -s)
DISTRO=""
# 패키지 관리자로 갈래를 나눈다. 배포판 이름을 하나하나 나열하면 파생 배포판이 나올 때마다 늘어난다.
PKG=""

case "$OS" in
  Linux*)
    if [ -r /etc/os-release ]; then
      DISTRO=$(. /etc/os-release && echo "$ID")
      DISTRO_LIKE=$(. /etc/os-release && echo "${ID_LIKE:-}")
    fi
    echo "[OPTiCS Installer] Detected OS: Linux (${DISTRO:-unknown})"

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
      echo "[OPTiCS Installer] Unsupported Linux distro: ${DISTRO:-unknown}"
      echo "[OPTiCS Installer] Supported: Arch-based (pacman), Ubuntu/Debian-based (apt)"
      echo "[OPTiCS Installer] Install Docker and the Compose plugin manually, then run this script again."
      exit 1
    fi
    echo "[OPTiCS Installer] Package manager: $PKG"
    ;;
  *)
    echo "[OPTiCS Installer] Detected OS: $OS (Unsupported)"
    echo "[Notice] OPTiCS will not get any responsibility about your PC when script got fail."
    read -p "[OPTiCS Installer] $OS is unsupported OS in this script. Continue installation anyway? (y/N): " answer
    if [ "$answer" = "Y" ] || [ "$answer" = "y" ]; then
      echo "[OPTiCS Installer] Continuing installation process..."
    else
      echo "[OPTiCS Installer] Aborting installation process..."
      exit 1
    fi
    ;;
esac

sleep 1

# ---------------------------------------------------------------------------
# 의존성
# ---------------------------------------------------------------------------

# curl은 compose 파일을 받는 데 쓴다. 없으면 아무것도 시작할 수 없다.
if ! command -v curl >/dev/null 2>&1; then
  echo "[OPTiCS Installer] Installing curl..."
  case "$PKG" in
    pacman) sudo pacman -S --needed --noconfirm curl ;;
    apt)    sudo apt-get update && sudo apt-get install -y curl ;;
  esac
  if ! command -v curl >/dev/null 2>&1; then
    echo "[OPTiCS Installer] curl is required. Aborting..."
    exit 1
  fi
fi

install_docker() {
  case "$PKG" in
    pacman)
      sudo pacman -S --needed --noconfirm docker docker-compose || return 1
      ;;
    apt)
      # Ubuntu/Debian 기본 저장소의 docker.io는 Compose 플러그인을 함께 주지 않는 판이 있어,
      # 버전에 상관없이 동일하게 동작하는 Docker 공식 저장소를 쓴다.
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

      # 파생 배포판은 자기 코드네임을 쓰므로 upstream 코드네임(UBUNTU_CODENAME)을 우선한다.
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
  echo "[OPTiCS Installer] Docker installed. You may need to re-login for group changes to take effect."
  return 0
}

echo "[OPTiCS Installer] Checking Docker version..."
DOCKER_VER=$(docker --version 2>/dev/null)
if [ -z "$DOCKER_VER" ]; then
  read -p "[OPTiCS Installer] Docker is not installed. Do you want to install it? (Y/n): " answer
  if [ -z "$answer" ] || [ "$answer" = "Y" ] || [ "$answer" = "y" ]; then
    echo "[OPTiCS Installer] Installing Docker..."
    if ! install_docker; then
      echo "[OPTiCS Installer] Docker installation failed. Please install it manually."
      exit 1
    fi
  else
    echo "[OPTiCS Installer] Docker is required. Aborting..."
    exit 1
  fi
else
  echo "[OPTiCS Installer] Docker detected: $DOCKER_VER"
fi

echo "[OPTiCS Installer] Checking Docker Compose version..."
# 플러그인형(docker compose)을 먼저 본다. 독립 실행형 docker-compose는 v1일 수 있고,
# v1은 compose 파일의 일부 문법을 해석하지 못한다.
if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
  echo "[OPTiCS Installer] docker compose (plugin) detected: $(docker compose version)"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD="docker-compose"
  echo "[OPTiCS Installer] docker-compose detected: $(docker-compose --version)"
else
  read -p "[OPTiCS Installer] Docker Compose is not installed. Do you want to install it? (Y/n): " answer
  if [ -z "$answer" ] || [ "$answer" = "Y" ] || [ "$answer" = "y" ]; then
    echo "[OPTiCS Installer] Installing Docker Compose..."
    case "$PKG" in
      pacman) sudo pacman -S --needed --noconfirm docker-compose ;;
      apt)    sudo apt-get update && sudo apt-get install -y docker-compose-plugin ;;
    esac

    if docker compose version >/dev/null 2>&1; then
      COMPOSE_CMD="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
      COMPOSE_CMD="docker-compose"
    else
      echo "[OPTiCS Installer] Docker Compose installation failed. Please install it manually."
      exit 1
    fi
  else
    echo "[OPTiCS Installer] Docker Compose is required. Aborting..."
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# 헬퍼
# ---------------------------------------------------------------------------

run_as_ssh_user() {
  if [ "$(id -un)" = "$SSH_TARGET_USER" ]; then
    "$@"
  else
    sudo -u "$SSH_TARGET_USER" "$@"
  fi
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

configure_host_ssh() {
  echo "[OPTiCS Installer] Configuring Agent host SSH access..."

  if ! command -v ssh-keygen >/dev/null 2>&1 || ! command -v sshd >/dev/null 2>&1; then
    echo "[OPTiCS Installer] Installing OpenSSH..."
    case "$PKG" in
      pacman) sudo pacman -S --needed --noconfirm openssh || return 1 ;;
      apt)    sudo apt-get install -y openssh-server openssh-client || return 1 ;;
    esac
  fi

  if command -v systemctl >/dev/null 2>&1 && ! pgrep -x sshd >/dev/null 2>&1; then
    # 유닛 이름이 배포판마다 다르다. Arch는 sshd, Debian 계열은 ssh.
    if systemctl list-unit-files sshd.service --no-legend 2>/dev/null | grep -q sshd.service; then
      sudo systemctl enable --now sshd || return 1
    elif systemctl list-unit-files ssh.service --no-legend 2>/dev/null | grep -q ssh.service; then
      sudo systemctl enable --now ssh || return 1
    fi
  fi

  if ! pgrep -x sshd >/dev/null 2>&1; then
    echo "[OPTiCS Installer] sshd is not running. SSH terminal setup was skipped."
    return 1
  fi

  SSH_TARGET_USER="${OPTICS_SSH_USER:-${SUDO_USER:-$(id -un)}}"
  if [ "$SSH_TARGET_USER" = "root" ]; then
    echo "[OPTiCS Installer] Refusing to configure a root SSH shell. Set OPTICS_SSH_USER to a non-root local user."
    return 1
  fi
  if ! id "$SSH_TARGET_USER" >/dev/null 2>&1; then
    echo "[OPTiCS Installer] SSH target user does not exist: $SSH_TARGET_USER"
    return 1
  fi

  SSH_TARGET_HOME=$(getent passwd "$SSH_TARGET_USER" | cut -d: -f6)
  if [ -z "$SSH_TARGET_HOME" ] || [ ! -d "$SSH_TARGET_HOME" ]; then
    echo "[OPTiCS Installer] Unable to find home directory for $SSH_TARGET_USER."
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
    echo "[OPTiCS Installer] Ed25519 SSH host key is unavailable. SSH terminal setup was skipped."
    return 1
  fi
  SSH_HOST_KEY_BODY=$(awk 'NR == 1 { print $2 }' "$SSH_HOST_KEY_FILE")
  SSH_HOST_HASH=$(printf "%s" "$SSH_HOST_KEY_BODY" | base64 -d | sha256sum | awk '{print $1}')
  if [ -z "$SSH_HOST_HASH" ]; then
    echo "[OPTiCS Installer] Unable to calculate SSH host key hash."
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

  echo "[OPTiCS Installer] SSH access configured for local user: $SSH_TARGET_USER"
  return 0
}

fetch() {
  local url="$1"
  local dest="$2"
  if ! curl -fsSL "$url" -o "$dest"; then
    echo "[OPTiCS Installer] Failed to download: $url"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 설치 파일 준비
# ---------------------------------------------------------------------------

echo "[OPTiCS Installer] Install directory: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

# 기존 설치 위에 덮어쓰는 경우, 먼저 컨테이너를 멈춰야 이미지 교체가 안전하다.
if [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
  echo "[OPTiCS Installer] Existing installation found. Checking for running containers..."
  if (cd "$INSTALL_DIR" && $COMPOSE_CMD ps -q 2>/dev/null | grep -q .); then
    echo "[OPTiCS Installer] Stopping existing OPTiCS Agent containers..."
    (cd "$INSTALL_DIR" && $COMPOSE_CMD down)
  fi
fi

echo "[OPTiCS Installer] Downloading compose definition..."
fetch "$AGENT_REPO_RAW/docker-compose.yml" "$INSTALL_DIR/docker-compose.yml" || exit 1

# .env는 비밀값과 사용자 설정을 담으므로 이미 있으면 덮어쓰지 않는다.
# 재설치할 때마다 초기화되면 SSH 설정과 Hub 주소가 매번 날아간다.
if [ -f "$INSTALL_DIR/.env" ]; then
  echo "[OPTiCS Installer] Existing .env found. Keeping it."
else
  echo "[OPTiCS Installer] Downloading .env.example..."
  fetch "$AGENT_REPO_RAW/.env.example" "$INSTALL_DIR/.env" || exit 1
  echo "[OPTiCS Installer] Created .env from .env.example."
fi

sleep 1

read -p "[OPTiCS Installer] Enable Web SSH terminal access? This configures sshd, generates a dedicated key, and adds it to authorized_keys. (y/N): " sshAnswer
if [ "$sshAnswer" = "Y" ] || [ "$sshAnswer" = "y" ]; then
  if configure_host_ssh; then
    SSH_CONFIGURED=1
  else
    echo "[OPTiCS Installer] Web SSH terminal setup failed. Agent installation will continue without it."
  fi
else
  echo "[OPTiCS Installer] Skipping Web SSH terminal setup (declined)."
fi

# ---------------------------------------------------------------------------
# 포트
# ---------------------------------------------------------------------------

check_port() {
  local port=$1
  if command -v ss >/dev/null 2>&1; then
    ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE "(^|:)${port}$"
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tln 2>/dev/null | awk '{print $4}' | grep -qE "(^|:)${port}$"
  else
    # 확인할 수단이 없으면 사용 중이 아니라고 본다. 실제로 겹치면 compose가 알려준다.
    return 1
  fi
}

echo "[OPTiCS Installer] Checking ports..."

AGENT_PORT=5230
while check_port "$AGENT_PORT"; do
  echo "[OPTiCS Installer] Port $AGENT_PORT is already in use."
  read -p "[OPTiCS Installer] Enter a different port for optics-agent: " input </dev/tty
  if [ -n "$input" ]; then
    AGENT_PORT=$input
  fi
done

DASHBOARD_PORT=5240
while check_port "$DASHBOARD_PORT"; do
  echo "[OPTiCS Installer] Port $DASHBOARD_PORT is already in use (optics-agent-dashboard)."
  read -p "[OPTiCS Installer] Enter a different port for optics-agent-dashboard: " input </dev/tty
  if [ -n "$input" ]; then
    DASHBOARD_PORT=$input
  fi
done

echo "[OPTiCS Installer] Using ports: agent=$AGENT_PORT, dashboard=$DASHBOARD_PORT"

# 포트를 .env에 적어 둔다. compose가 프로젝트 디렉터리의 .env를 자동으로 읽으므로,
# 나중에 사용자가 그냥 `docker compose up -d`만 해도 같은 설정으로 뜬다.
set_agent_env "AGENT_PORT" "$AGENT_PORT"
set_agent_env "DASHBOARD_PORT" "$DASHBOARD_PORT"

# ---------------------------------------------------------------------------
# 이미지 수신 및 기동
# ---------------------------------------------------------------------------

cd "$INSTALL_DIR" || exit 1

# AGENT_IMAGE_TAG를 지정하지 않으면 compose가 latest를 쓴다.
# latest는 릴리스 워크플로가 정식 릴리스(prerelease 아님)에만 붙이므로 최신 안정판을 가리킨다.
IMAGE_TAG="${OPTICS_AGENT_TAG:-latest}"
if [ "$IMAGE_TAG" != "latest" ]; then
  set_agent_env "AGENT_IMAGE_TAG" "$IMAGE_TAG"
  set_agent_env "DASHBOARD_IMAGE_TAG" "$IMAGE_TAG"
  echo "[OPTiCS Installer] Pinned image tag: $IMAGE_TAG"
fi

echo "[OPTiCS Installer] Pulling images from GHCR (tag: $IMAGE_TAG)..."
if ! $COMPOSE_CMD pull; then
  echo "[OPTiCS Installer] Failed to pull images from GHCR."
  echo "[OPTiCS Installer] Check your network connection and try again."
  exit 1
fi

echo "[OPTiCS Installer] Starting containers..."
if ! $COMPOSE_CMD up -d; then
  echo "[OPTiCS Installer] Failed to start containers. Check logs with:"
  echo "    cd $INSTALL_DIR && $COMPOSE_CMD logs"
  exit 1
fi

echo "[OPTiCS Installer] OPTiCS Agent installment finished."
echo ""
echo "    Dashboard   : http://localhost:$DASHBOARD_PORT/"
echo "    Install dir : $INSTALL_DIR"
echo ""
echo "    Update      : cd $INSTALL_DIR && $COMPOSE_CMD pull && $COMPOSE_CMD up -d"
echo "    Stop        : cd $INSTALL_DIR && $COMPOSE_CMD down"
echo "    Logs        : cd $INSTALL_DIR && $COMPOSE_CMD logs -f"
echo ""

read -p "[OPTiCS Installer] Do you want to enter Agent console after finish? (y/N): " answer
if [ "$answer" = "Y" ] || [ "$answer" = "y" ]; then
  if $COMPOSE_CMD ps --status running | grep -q optics-agent; then
    $COMPOSE_CMD exec optics-agent sh
  else
    echo "[OPTiCS Installer] Agent container is not running. Check logs with: $COMPOSE_CMD logs optics-agent"
  fi
fi

exit 0
