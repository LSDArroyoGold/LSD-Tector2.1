#!/bin/bash
#
# publicar_estado.sh - Genera estado.json y lo sube a Drive.
#
# Es lo que hace que un Tector aparezca "vivo" en la app. Se llama en tres
# momentos: al abrir una ventana (inicio_*.sh), al cerrarla (cierre_*.sh) y
# al terminar la configuracion inicial (hotspot.sh).
#
# Best-effort a proposito: si falla, no rompe nada de lo que estaba pasando
# alrededor. Un estado.json viejo en Drive es exactamente lo que la app
# espera ver mientras el equipo duerme -- perder una actualizacion no es
# peor que eso, y nunca justifica abortar una ventana de grabacion.

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BASE_PATH="$(dirname "$SCRIPT_DIR")"

REAL_USER="${SUDO_USER:-$(whoami)}"
USER_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

export RCLONE_CONFIG="$USER_HOME/.config/rclone/rclone.conf"
export HOME="$USER_HOME"

CONFIG_GENERAL="$BASE_PATH/config/config_general.txt"
DRIVE_PATH=$(awk -F'=' '/^DRIVE_PATH=/{print $2}' "$CONFIG_GENERAL" | tr -d '\r')

python3 "$BASE_PATH/python/generar_estado.py" || exit 0

rclone copy "$BASE_PATH/estado.json" "gdrive:$DRIVE_PATH/" 2>/dev/null || exit 0
