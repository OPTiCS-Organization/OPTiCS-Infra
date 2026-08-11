#!/bin/bash

echo "[OPTiCS Uninstaller] Stopping and removing containers..."

docker stop optics-agent-optics-agent-dashboard-1 2>/dev/null
docker rm optics-agent-optics-agent-dashboard-1 2>/dev/null
echo "[OPTiCS Uninstaller] Dashboard container removed."

docker stop optics-agent-optics-agent-1 2>/dev/null
docker rm optics-agent-optics-agent-1 2>/dev/null
echo "[OPTiCS Uninstaller] Agent container removed."

read -p "[OPTiCS Uninstaller] Remove Docker images? (y/N): " answer
if [ "$answer" = "Y" ] || [ "$answer" = "y" ]; then
  docker rmi optics-agent 2>/dev/null
  docker rmi optics-agent-dashboard 2>/dev/null
  echo "[OPTiCS Uninstaller] Images removed."
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

read -p "[OPTiCS Uninstaller] Remove 'optics-build' folder? (y/N): " answer
if [ "$answer" = "Y" ] || [ "$answer" = "y" ]; then
  INSTALL_DIR="$(pwd)/optics-build"
  rm -rf "$INSTALL_DIR"
  echo "[OPTiCS Uninstaller] optics-build folder removed."
fi

echo "[OPTiCS Uninstaller] Uninstallation complete."
exit 0
