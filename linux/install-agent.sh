#!/bin/bash
echo "Welcome to OPTiCS Linux Installer v0.2.0!"

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

echo "[OPTiCS Installer] Starting clone from github..."
mkdir OPTiCS
cd OPTiCS
git clone https://github.com/OPTiCS-Organization/OPTiCS-Agent OPTiCS-Agent
git clone https://github.com/OPTiCS-Organization/OPTiCS-Agent-Dashboard OPTiCS-Agent-Dashboard

echo "[OPTiCS Installer] Creating directory 'optics-build'..."
mkdir -p "$INSTALL_DIR"
echo "[OPTiCS Installer] Copying files..."
cp -r ./OPTiCS-Agent "$INSTALL_DIR"
cp -r ./OPTiCS-Agent-Dashboard "$INSTALL_DIR"
cd ..
echo "[OPTiCS Installer] Cleaning up..."
rm -rf ./OPTiCS
echo "[OPTiCS Installer] Repository clone successful."
sleep 1

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
