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

read -p "[OPTiCS Uninstaller] Remove 'optics-build' folder? (y/N): " answer
if [ "$answer" = "Y" ] || [ "$answer" = "y" ]; then
  INSTALL_DIR="$(pwd)/optics-build"
  rm -rf "$INSTALL_DIR"
  echo "[OPTiCS Uninstaller] optics-build folder removed."
fi

echo "[OPTiCS Uninstaller] Uninstallation complete."
exit 0
