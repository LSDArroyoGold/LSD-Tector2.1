#!/bin/bash
#
# aplicar_config_remota.sh - Baja de Drive la configuracion que dejo la app y
# la instala donde la lee cada componente.
#
# Por ahora hace una sola cosa: el token de BirdWeather.
#
# POR QUE ESTE SCRIPT EXISTE
# --------------------------
# config_horarios.txt lo bajan inicio_*.sh y cierre_*.sh directo, porque vive
# en este mismo repo. config_birdweather.txt no: lo lee TectorNET-Pi, que es
# otro repositorio, con su propia carpeta y su propio rclone. Sin este puente,
# activar BirdWeather desde la app era imposible --habia que entrar por SSH.
#
# La alternativa era tocar TectorNET-Pi para que se bajara su propia
# configuracion. Se descarto: TectorNET-Pi es el motor de deteccion, y
# meterle logica de sincronizacion con Drive lo ata a como esta armado el
# resto del sistema. Este repo ya es el que orquesta el ciclo y ya habla con
# Drive, asi que el puente va aca.
#
# LAS COORDENADAS NO VIAJAN POR DRIVE
# -----------------------------------
# config_birdweather.txt necesita LATITUDE y LONGITUDE ademas del token. Esas
# no las manda la app: las detecta el propio dispositivo en hotspot.sh (via
# ipinfo.io) y viven en config_general.txt. Este script las inyecta al
# instalar, asi que la app solo tiene que mandar el token y no puede dejar a
# una estacion publicada en el lugar equivocado.

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BASE_PATH="$(dirname "$SCRIPT_DIR")"

REAL_USER="${SUDO_USER:-$(whoami)}"
USER_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

export RCLONE_CONFIG="$USER_HOME/.config/rclone/rclone.conf"
export HOME="$USER_HOME"

CONFIG_GENERAL="$BASE_PATH/config/config_general.txt"
DRIVE_PATH=$(awk -F'=' '/^DRIVE_PATH=/{print $2}' "$CONFIG_GENERAL" | tr -d '\r')

log() {
	python3 "$BASE_PATH/python/log_sistema.py" MSG "$1"
}

# Donde vive el motor. Se contemplan los dos nombres porque la migracion de
# birdnet-lsd a TectorNET-Pi (7/9/2026) puede no haber corrido todavia en
# todos los dispositivos.
for CANDIDATO in "$USER_HOME/TectorNET-Pi" "$USER_HOME/birdnet-lsd"; do
	if [ -d "$CANDIDATO" ]; then
		MOTOR_DIR="$CANDIDATO"
		break
	fi
done

if [ -z "$MOTOR_DIR" ]; then
	# Sin motor propio instalado no hay nada que configurar. No es un error:
	# es un dispositivo que todavia corre BirdNET-Pi a secas.
	exit 0
fi

DESTINO="$MOTOR_DIR/config/config_birdweather.txt"
TMP="$BASE_PATH/.config_birdweather_remota"

# Best-effort: si no hay nada en Drive, no hay nada que hacer. Es el caso
# normal de una estacion que nunca activo BirdWeather.
if ! rclone copyto "gdrive:$DRIVE_PATH/config_birdweather.txt" "$TMP" 2>/dev/null; then
	rm -f "$TMP"
	exit 0
fi

TOKEN=$(awk -F'=' '/^BIRDWEATHER_ID[ ]*=/{print $2}' "$TMP" | tr -d ' \r')
rm -f "$TMP"

LAT=$(awk -F'=' '/^LAT=/{print $2}' "$CONFIG_GENERAL" | tr -d ' \r')
LON=$(awk -F'=' '/^LON=/{print $2}' "$CONFIG_GENERAL" | tr -d ' \r')

# Token vacio = la app pidio desconectar. birdweather.py de TectorNet
# interpreta BIRDWEATHER_ID vacio como "estacion no conectada" y no postea
# nada, que es exactamente el comportamiento que queremos.
mkdir -p "$MOTOR_DIR/config"
NUEVO=$(printf '# Escrito por aplicar_config_remota.sh desde lo que dejo la app en Drive.\n# Las coordenadas las pone el dispositivo, no la app.\nBIRDWEATHER_ID = %s\nLATITUDE = %s\nLONGITUDE = %s\n' "$TOKEN" "$LAT" "$LON")

# Solo escribir y reiniciar si algo cambio: esto corre en cada apertura de
# ventana, y reiniciar el motor sin motivo perderia el buffer de audio en
# curso.
if [ -f "$DESTINO" ] && [ "$NUEVO" = "$(cat "$DESTINO")" ]; then
	exit 0
fi

echo "$NUEVO" > "$DESTINO"
chown "$REAL_USER:$REAL_USER" "$DESTINO" 2>/dev/null

if [ -n "$TOKEN" ]; then
	log "BirdWeather configurado desde la app (estacion ${TOKEN:0:4}...)."
else
	log "BirdWeather desconectado desde la app."
fi

for UNIDAD in TectorNET-Pi.service birdnet-lsd.service; do
	if systemctl list-unit-files "$UNIDAD" &>/dev/null; then
		sudo systemctl restart "$UNIDAD" 2>/dev/null
		break
	fi
done
