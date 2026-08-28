#!/bin/bash
#
# OPTiCS Agent Linux Uninstaller
#
# 0.6.0부터 설치는 "설치 디렉터리에 놓인 compose 파일"이 실체입니다.
# 컨테이너를 개별 이름으로 지우는 대신 그 디렉터리에서 compose로 내려야
# 네트워크와 볼륨까지 빠짐없이 정리됩니다.
set -uo pipefail

INSTALL_DIR="${OPTICS_INSTALL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/optics/agent}"
AGENT_IMAGE="ghcr.io/optics-organization/optics-agent"
DASHBOARD_IMAGE="ghcr.io/optics-organization/optics-agent-dashboard"

if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD="docker-compose"
else
  COMPOSE_CMD=""
fi

echo "[OPTiCS Uninstaller] Install directory: $INSTALL_DIR"
echo "[OPTiCS Uninstaller] Stopping and removing containers..."

if [ -f "$INSTALL_DIR/docker-compose.yml" ] && [ -n "$COMPOSE_CMD" ]; then
  (cd "$INSTALL_DIR" && $COMPOSE_CMD down --remove-orphans)
  echo "[OPTiCS Uninstaller] Containers removed."
else
  # compose 파일이나 compose 명령이 없으면 컨테이너 이름으로 직접 지운다.
  # 프로젝트 이름이 compose 파일에 optics-agent로 고정되어 있어 이름을 예측할 수 있다.
  echo "[OPTiCS Uninstaller] Compose definition not found. Falling back to container names..."
  docker rm -f optics-agent-optics-agent-dashboard-1 2>/dev/null
  docker rm -f optics-agent-optics-agent-1 2>/dev/null
  docker network rm optics-agent_service-network 2>/dev/null
  echo "[OPTiCS Uninstaller] Containers removed."
fi

read -p "[OPTiCS Uninstaller] Remove downloaded Docker images? (y/N): " answer
if [ "$answer" = "Y" ] || [ "$answer" = "y" ]; then
  # 태그를 고정해 쓰는 경우가 있어 이미지 이름으로 걸린 것을 모두 지운다.
  docker images --format '{{.Repository}}:{{.Tag}}' \
    | grep -E "^($AGENT_IMAGE|$DASHBOARD_IMAGE):" \
    | xargs -r docker rmi 2>/dev/null
  echo "[OPTiCS Uninstaller] Images removed."
fi

# 볼륨에는 Agent의 로컬 DB(UUID·서명 비밀 포함)가 들어 있다. 지우면 재설치 시
# 완전히 새로운 Agent로 등록되고, Hub에 남은 기존 Agent와 그 서비스는 끊긴 상태가 된다.
read -p "[OPTiCS Uninstaller] Remove Agent data volumes? This unregisters this machine from OPTiCS Hub. (y/N): " answer
if [ "$answer" = "Y" ] || [ "$answer" = "y" ]; then
  docker volume rm optics-agent_optics-data 2>/dev/null
  docker volume rm optics-build 2>/dev/null
  echo "[OPTiCS Uninstaller] Volumes removed."
fi

SSH_KEY_MARKER="optics-agent-web-terminal"
SSH_TARGET_USER="${OPTICS_SSH_USER:-${SUDO_USER:-$(id -un)}}"
if [ "$SSH_TARGET_USER" != "root" ] && id "$SSH_TARGET_USER" >/dev/null 2>&1; then
  SSH_TARGET_HOME=$(getent passwd "$SSH_TARGET_USER" | cut -d: -f6)
  SSH_AUTHORIZED_KEYS="$SSH_TARGET_HOME/.ssh/authorized_keys"
  SSH_STATE_DIR="$SSH_TARGET_HOME/.local/share/optics/ssh"

  if [ -f "$SSH_AUTHORIZED_KEYS" ]; then
    if [ "$(id -un)" = "$SSH_TARGET_USER" ]; then
      sed -i "/ ${SSH_KEY_MARKER}$/d" "$SSH_AUTHORIZED_KEYS"
    else
      sudo -u "$SSH_TARGET_USER" sed -i "/ ${SSH_KEY_MARKER}$/d" "$SSH_AUTHORIZED_KEYS"
    fi
  fi

  if [ -d "$SSH_STATE_DIR" ]; then
    if [ "$(id -un)" = "$SSH_TARGET_USER" ]; then
      rm -rf "$SSH_STATE_DIR"
    else
      sudo -u "$SSH_TARGET_USER" rm -rf "$SSH_STATE_DIR"
    fi
  fi
  echo "[OPTiCS Uninstaller] Agent SSH key removed."
fi

read -p "[OPTiCS Uninstaller] Remove install directory ($INSTALL_DIR)? (y/N): " answer
if [ "$answer" = "Y" ] || [ "$answer" = "y" ]; then
  rm -rf "$INSTALL_DIR"
  echo "[OPTiCS Uninstaller] Install directory removed."
fi

echo "[OPTiCS Uninstaller] Uninstallation complete."
exit 0
