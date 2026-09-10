#!/bin/bash
#
# limpiar_retencion.sh - agregado el 4/9/2026, portado de LSD-Tector1.1
# el mismo dia: acota tanto el almacenamiento LOCAL como el de DRIVE por
# tamaño, borrando carpetas de fecha ENTERAS (Detecciones/<fecha>/ en
# Drive, By_Date/<fecha>/ local -- ambas con todas las especies de ese
# dia adentro) empezando por la mas vieja -- nunca archivos sueltos de
# un dia a medias, para que sea predecible ("o esta el dia completo, o
# no esta"). Llamado desde cierre_amanecer.sh/cierre_atardecer.sh,
# DESPUES de que el rclone copy de esa corrida haya salido bien (si
# Drive no esta disponible en ese momento, no se toca nada, se
# reintenta en el proximo cierre).
#
# RETENCION_AUDIO_LOCAL_MB / RETENCION_DRIVE_MB en config/config_general.txt.

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BASE_PATH="$(dirname "$SCRIPT_DIR")"

REAL_USER="${SUDO_USER:-$(whoami)}"
USER_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
export RCLONE_CONFIG="$USER_HOME/.config/rclone/rclone.conf"

CONFIG_GENERAL="$BASE_PATH/config/config_general.txt"
DRIVE_PATH=$(awk -F'=' '/^DRIVE_PATH=/{print $2}' "$CONFIG_GENERAL" | tr -d '\r')
RETENCION_LOCAL_MB=$(awk -F'=' '/^RETENCION_AUDIO_LOCAL_MB=/{print $2}' "$CONFIG_GENERAL" | tr -d ' \r')
RETENCION_DRIVE_MB=$(awk -F'=' '/^RETENCION_DRIVE_MB=/{print $2}' "$CONFIG_GENERAL" | tr -d ' \r')

# --- Local: du por carpeta de fecha (mas nueva primero), acumular
# tamaño, borrar carpetas enteras una vez superado el limite. ---
if [ -n "$RETENCION_LOCAL_MB" ]; then
	CAP_BYTES=$((RETENCION_LOCAL_MB * 1024 * 1024))
	find "$USER_HOME/BirdSongs/Extracted/By_Date" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null \
		| sort -r \
		| while IFS= read -r FECHA; do
			echo "$(du -sb "$USER_HOME/BirdSongs/Extracted/By_Date/$FECHA" 2>/dev/null | cut -f1) $FECHA"
		done \
		| awk -v cap="$CAP_BYTES" '{ acumulado += $1; if (acumulado > cap) print $2 }' \
		| while IFS= read -r FECHA; do
			rm -rf "$USER_HOME/BirdSongs/Extracted/By_Date/$FECHA"
		done
fi

# --- Drive: un solo listado recursivo con tamaños (rclone lsjson -R),
# agrupado por carpeta de fecha en Python (mas eficiente que un
# "rclone size" por fecha, que seria una llamada de red por dia). Best
# effort: si el listado falla (sin red, Drive caido), no se borra nada.
# ---
if [ -n "$RETENCION_DRIVE_MB" ] && [ -n "$DRIVE_PATH" ]; then
	CAP_BYTES=$((RETENCION_DRIVE_MB * 1024 * 1024))
	timeout 60 rclone lsjson -R "gdrive:$DRIVE_PATH/Detecciones" --files-only 2>/dev/null \
		| python3 -c "
import sys, json

try:
    items = json.load(sys.stdin)
except Exception:
    sys.exit(0)

por_fecha = {}
for it in items:
    partes = it.get('Path', '').split('/')
    if not partes or not partes[0]:
        continue
    fecha = partes[0]
    por_fecha[fecha] = por_fecha.get(fecha, 0) + it.get('Size', 0)

acumulado = 0
cap = $CAP_BYTES
for fecha in sorted(por_fecha, reverse=True):
    acumulado += por_fecha[fecha]
    if acumulado > cap:
        print(fecha)
" \
		| while IFS= read -r FECHA; do
			timeout 60 rclone purge "gdrive:$DRIVE_PATH/Detecciones/$FECHA" 2>/dev/null
		done
fi
