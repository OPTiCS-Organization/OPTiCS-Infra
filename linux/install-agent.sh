#!/bin/bash
echo "Welcome to OPTiCS Linux Installer v0.3.1!"

# OS Detection
OS=$(uname -s)
CONTINUE_INSTALLATION=0
case "$OS" in
  Linux*)
    DISTRO=$(. /etc/os-release && echo "$ID")
    echo "[OPTiCS Installer] Detected OS: Linux ($DISTRO)"
    ;;
  *)
    echo "[OPTiCS Installer] Detected OS: $OS (Unsupported)"
    echo "[Notice] OPTiCS will not get any responsibility about your PC when script got fail."
    read -p "[OPTiCS Installer] $OS is unsupported OS in this script. Continue installation anyway? (y/N): " answer
    if [ "$answer" = "Y" ] || [ "$answer" = "y" ]; then
      echo "[OPTiCS Installer] Continuing installation process..."
    else
      echo "[OPTiCS Installer] Aborting installation process..."
      exit
    fi
    ;;
esac

sleep 3

# Docker Check
echo "[OPTiCS Installer] Checking Docker version..."
DOCKER_VER=$(docker --version 2>/dev/null)
if [ -z "$DOCKER_VER" ]; then
  read -p "[OPTiCS Installer] Docker is not installed. Do you want to install it? (Y/n): " answer
    if [ -z "$answer" ] || [ "$answer" = "Y" ] || [ "$answer" = "y" ]; then
    echo "[OPTiCS Installer] Installing Docker..."
    if [ "$OS" = "Linux" ]; then # :)
      if [ "$DISTRO" = "arch" ]; then
        sudo pacman -S --noconfirm docker
        sudo systemctl enable --now docker
        sudo usermod -aG docker "$USER"
        echo "[OPTiCS Installer] Docker installed. You may need to re-login for group changes to take effect."
      else
        echo "[OPTiCS Installer] Unsupported Linux distro: $DISTRO. Please install Docker manually."
        exit 1
      fi
    else
      echo "[OPTiCS Installer] Unsupported OS. Please install Docker manually."
      exit 1
    fi
  else
    echo "[OPTiCS Installer] Client install unavailable. Aborting..."
    exit 1
  fi
else
  echo "[OPTiCS Installer] Docker detected: $DOCKER_VER"
fi

# Docker Compose Check
echo "[OPTiCS Installer] Checking docker-compose version..."
if command -v docker-compose &>/dev/null; then
  COMPOSE_CMD="docker-compose"
  echo "[OPTiCS Installer] docker-compose detected: $(docker-compose --version)"
elif docker compose version &>/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
  echo "[OPTiCS Installer] docker compose (plugin) detected: $(docker compose version)"
else
  read -p "[OPTiCS Installer] docker-compose is not installed. Do you want to install it? (Y/n): " answer
    if [ -z "$answer" ] || [ "$answer" = "Y" ] || [ "$answer" = "y" ]; then
    echo "[OPTiCS Installer] Installing docker-compose..."
    if [ "$OS" = "Linux" ]; then
      if [ "$DISTRO" = "arch" ]; then
        sudo pacman -S --noconfirm docker-compose
      else
        echo "[OPTiCS Installer] Unsupported Linux distro: $DISTRO. Please install docker-compose manually."
        exit 1
      fi
    else
      echo "[OPTiCS Installer] Unsupported OS. Please install docker-compose manually."
      exit 1
    fi
  else
    echo "[OPTiCS Installer] Client install unavailable. Aborting..."
    exit 1
  fi
fi

INSTALL_DIR="$(pwd)/optics-build"
SSH_KEY_MARKER="optics-agent-web-terminal"
SSH_CONFIGURED=0
SSH_PRIVATE_KEY=""

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
  local env_file="$INSTALL_DIR/OPTiCS-Agent/.env"

  if grep -q "^${key}=" "$env_file" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$env_file"
  else
    printf "%s=%s\n" "$key" "$value" >> "$env_file"
  fi
}

configure_host_ssh() {
  echo "[OPTiCS Installer] Configuring Agent host SSH access..."

  if ! command -v ssh-keygen >/dev/null 2>&1 || ! command -v sshd >/dev/null 2>&1; then
    if [ "$DISTRO" = "arch" ]; then
      echo "[OPTiCS Installer] Installing OpenSSH..."
      sudo pacman -S --needed --noconfirm openssh || return 1
    else
      echo "[OPTiCS Installer] OpenSSH is required. Install and start sshd, then run the installer again."
      return 1
    fi
  fi

  if command -v systemctl >/dev/null 2>&1 && ! pgrep -x sshd >/dev/null 2>&1; then
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

echo "[OPTiCS Installer] Starting clone from github..."
echo "[OPTiCS Installer] Creating directory 'OPTiCS'..."
mkdir OPTiCS
cd OPTiCS
git clone https://github.com/OPTiCS-Organization/OPTiCS-Agent OPTiCS-Agent
git clone https://github.com/OPTiCS-Organization/OPTiCS-Agent-Dashboard OPTiCS-Agent-Dashboard

echo "[OPTiCS Installer] Creating directory 'OPTiCS/optics-build'..."
mkdir -p "$INSTALL_DIR"
echo "[OPTiCS Installer] Copying files..."
cp -r ./OPTiCS-Agent "$INSTALL_DIR"
cp -r ./OPTiCS-Agent-Dashboard "$INSTALL_DIR"
cd ..
echo "[OPTiCS Installer] Cleaning up..."
rm -rf ./OPTiCS
echo "[OPTiCS Installer] Repository clone successful."
sleep 1

# .env는 비밀값을 담을 수 있어 git에 커밋하지 않는다. 클론 직후엔 없는 게 정상이니 예시 파일로 채워준다.
if [ ! -f "$INSTALL_DIR/OPTiCS-Agent/.env" ]; then
  echo "[OPTiCS Installer] .env not found, creating from .env.example..."
  cp "$INSTALL_DIR/OPTiCS-Agent/.env.example" "$INSTALL_DIR/OPTiCS-Agent/.env"
fi

if configure_host_ssh; then
  SSH_CONFIGURED=1
else
  echo "[OPTiCS Installer] Agent installation will continue without Web SSH access."
fi

echo "[OPTiCS Installer] Docker-compose phase start in 3..."
sleep 1
echo "[OPTiCS Installer] Docker-compose phase start in 2..."
sleep 1
echo "[OPTiCS Installer] Docker-compose phase start in 1..."
sleep 1

# Port conflict check helper
check_port() {
  local port=$1
  ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE "(^|:)${port}$"
}

echo "[OPTiCS Installer] Checking optics agent process..."

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

echo "[OPTiCS Installer] Building agent client and dashboard..."
cd "$INSTALL_DIR/OPTiCS-Agent"
printf "AGENT_PORT=%s\nDASHBOARD_PORT=%s\n" "$AGENT_PORT" "$DASHBOARD_PORT" > .env.ports
if [ "$SSH_CONFIGURED" -eq 1 ]; then
  printf "HOST_SSH_PRIVATE_KEY_FILE=%s\n" "$SSH_PRIVATE_KEY" >> .env.ports
fi
AGENT_PORT="$AGENT_PORT" DASHBOARD_PORT="$DASHBOARD_PORT" docker compose --env-file .env.ports up --build -d
rm -f .env.ports

echo "[OPTiCS Installer] OPTiCS Agent installment finished."
echo ""
echo "    To access dashboard: http://localhost:$DASHBOARD_PORT/"
echo ""
read -p "[OPTiCS Installer] Do you want to enter Agent console after finish? (y/N): " answer
if [ "$answer" = "Y" ] || [ "$answer" = "y" ]; then
  if docker compose ps --status running | grep -q optics-agent; then
    docker compose exec optics-agent sh
  else
    echo "[OPTiCS Installer] Agent container is not running. Check logs with: docker compose logs optics-agent"
  fi
fi
read -p "[OPTiCS Installer] Do you want to remove 'optics-build' folder? (Y/n): " answer
if [ -z "$answer" ] || [ "$answer" = "Y" ] || [ "$answer" = "y" ]; then
  rm -rf "$INSTALL_DIR"
fi
exit 0
