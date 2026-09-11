#!/bin/bash
#
# limpiar_retencion.sh - agregado el 4/9/2026, portado de LSD-Tector1.1
# el mismo dia. Borra audio viejo, por tiempo o por tamaño, en carpetas
# de fecha ENTERAS (Detecciones/<fecha>/ en Drive, By_Date/<fecha>/
# local -- ambas con todas las especies de ese dia adentro) empezando
# por la mas vieja -- nunca archivos sueltos de un dia a medias, para
# que sea predecible ("o esta el dia completo, o no esta"). Llamado
# desde cierre_amanecer.sh/cierre_atardecer.sh, DESPUES de que el
# rclone copy de esa corrida haya salido bien (si Drive no esta
# disponible en ese momento, no se toca nada, se reintenta en el
# proximo cierre).
#
# QUE HACE HOY, 11/9/2026
# -----------------------
# En Drive, NADA: las dos claves que lo gobiernan estan apagadas por
# decision del laboratorio. Lo que sube a Drive se queda hasta que
# alguien lo borre a mano. Ver la explicacion larga en
# config/config_general.txt.
#
# Lo unico activo es el tope LOCAL (RETENCION_AUDIO_LOCAL_MB), que NO es
# una politica de datos sino la proteccion de la microSD: si la tarjeta
# se llena el equipo deja de grabar. Lo local es una copia de trabajo,
# el original ya esta en Drive.
#
# SI ALGUNA VEZ SE VUELVE A ENCENDER: solo se borra AUDIO. El resumen de
# cada dia (resumenes/, y Resumenes/ en Drive) no se toca nunca: es una
# fila por deteccion, ~5 KB contra ~50 MB del audio del mismo dia, y de
# ahi salen las estadisticas.
#
# TODO borrado deja una linea en log_sistema.txt. Cuesta nada y evita la
# pregunta "¿y esto quien se lo llevo?" seis meses despues.

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BASE_PATH="$(dirname "$SCRIPT_DIR")"

REAL_USER="${SUDO_USER:-$(whoami)}"
USER_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
export RCLONE_CONFIG="$USER_HOME/.config/rclone/rclone.conf"

CONFIG_GENERAL="$BASE_PATH/config/config_general.txt"
DRIVE_PATH=$(awk -F'=' '/^DRIVE_PATH=/{print $2}' "$CONFIG_GENERAL" | tr -d '\r')
RETENCION_LOCAL_MB=$(awk -F'=' '/^RETENCION_AUDIO_LOCAL_MB=/{print $2}' "$CONFIG_GENERAL" | tr -d ' \r')
RETENCION_DRIVE_MB=$(awk -F'=' '/^RETENCION_DRIVE_MB=/{print $2}' "$CONFIG_GENERAL" | tr -d ' \r')
RETENCION_DIAS=$(awk -F'=' '/^RETENCION_DIAS=/{print $2}' "$CONFIG_GENERAL" | tr -d ' \r')

registrar() {
	python3 "$BASE_PATH/python/log_sistema.py" MSG "$1" 2>/dev/null
}

# --- Por TIEMPO. Apagado con RETENCION_DIAS=0 (que es como esta). ---
if [ -n "$RETENCION_DIAS" ] && [ "$RETENCION_DIAS" -gt 0 ] 2>/dev/null; then
	CORTE=$(date -d "$RETENCION_DIAS days ago" +%Y-%m-%d)

	# Las carpetas de fecha son nombres ISO, asi que comparar como texto es
	# comparar como fecha. No se usa `find -mtime` a proposito: la fecha del
	# NOMBRE es la del dato, y la de modificacion cambia sola cuando algo
	# toca el archivo.
	find "$USER_HOME/BirdSongs/Extracted/By_Date" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null \
		| while IFS= read -r FECHA; do
			case "$FECHA" in
				[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
				*) continue ;;
			esac
			if [ "$FECHA" \< "$CORTE" ]; then
				rm -rf "$USER_HOME/BirdSongs/Extracted/By_Date/$FECHA"
				registrar "RETENCION: borrado audio local de $FECHA (mas de $RETENCION_DIAS dias)"
			fi
		done

	if [ -n "$DRIVE_PATH" ]; then
		timeout 60 rclone lsf --dirs-only "gdrive:$DRIVE_PATH/Detecciones" 2>/dev/null \
			| tr -d '/' \
			| while IFS= read -r FECHA; do
				case "$FECHA" in
					[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
					*) continue ;;
				esac
				if [ "$FECHA" \< "$CORTE" ]; then
					if timeout 120 rclone purge "gdrive:$DRIVE_PATH/Detecciones/$FECHA" 2>/dev/null; then
						registrar "RETENCION: borrado de DRIVE el dia $FECHA (mas de $RETENCION_DIAS dias)"
					fi
				fi
			done
	fi
fi

# --- Tope LOCAL por tamaño: proteccion de la microSD, queda activo. ---
# du por carpeta de fecha (mas nueva primero), acumular tamaño, borrar
# carpetas enteras una vez superado el limite.
if [ -n "$RETENCION_LOCAL_MB" ] && [ "$RETENCION_LOCAL_MB" -gt 0 ] 2>/dev/null; then
	CAP_BYTES=$((RETENCION_LOCAL_MB * 1024 * 1024))
	find "$USER_HOME/BirdSongs/Extracted/By_Date" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null \
		| sort -r \
		| while IFS= read -r FECHA; do
			echo "$(du -sb "$USER_HOME/BirdSongs/Extracted/By_Date/$FECHA" 2>/dev/null | cut -f1) $FECHA"
		done \
		| awk -v cap="$CAP_BYTES" '{ acumulado += $1; if (acumulado > cap) print $2 }' \
		| while IFS= read -r FECHA; do
			rm -rf "$USER_HOME/BirdSongs/Extracted/By_Date/$FECHA"
			registrar "RETENCION: borrado audio local de $FECHA (la SD paso los $RETENCION_LOCAL_MB MB; la copia de Drive sigue)"
		done
fi

# --- Tope de DRIVE por tamaño. APAGADO (RETENCION_DRIVE_MB vacio). ---
# Estuvo ACTIVO en 4096 MB entre el 4/9 y el 11/9/2026, o sea que pudo
# haber borrado dias de Drive en esa semana; buscar "RETENCION:" en
# log_sistema.txt no sirve para ese periodo porque el logueo se agrego
# recien ahora.
#
# Un solo listado recursivo con tamaños (rclone lsjson -R), agrupado por
# carpeta de fecha en Python: mas eficiente que un "rclone size" por
# fecha, que seria una llamada de red por dia. Best effort: si el listado
# falla (sin red, Drive caido), no se borra nada.
if [ -n "$RETENCION_DRIVE_MB" ] && [ "$RETENCION_DRIVE_MB" -gt 0 ] 2>/dev/null && [ -n "$DRIVE_PATH" ]; then
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
			if timeout 60 rclone purge "gdrive:$DRIVE_PATH/Detecciones/$FECHA" 2>/dev/null; then
				registrar "RETENCION: borrado de DRIVE el dia $FECHA (Drive paso los $RETENCION_DRIVE_MB MB)"
			fi
		done
fi
