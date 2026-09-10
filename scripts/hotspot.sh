#!/bin/bash

# Autodeteccion de rutas del proyecto
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BASE_PATH="$(dirname "$SCRIPT_DIR")"

# Deteccion robusta del usuario real y su home (incluso si el script corre con sudo)
REAL_USER="${SUDO_USER:-$(whoami)}"
USER_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

export RCLONE_CONFIG="$USER_HOME/.config/rclone/rclone.conf"
export HOME="$USER_HOME"

LOG_PATH="$BASE_PATH/log_sistema.txt"
CONFIG_PATH="$BASE_PATH/config/config_general.txt"
CONFIG_HORARIOS="$BASE_PATH/config/config_horarios.txt"

DRIVE_PATH=$(awk -F'=' '/^DRIVE_PATH=/{print $2}' "$CONFIG_PATH" | tr -d '\r')
# El SSID se arma con el numero de serie: cada dispositivo expone una red
# distinta y la app puede saber con cual esta hablando. Ver
# python/asignar_serie.py -- si por lo que sea todavia no hay serie asignado,
# asignar_serie.py lo crea aca mismo en vez de dejar el SSID en blanco.
SERIE=$(python3 "$BASE_PATH/python/asignar_serie.py")
HOTSPOT_SSID="Tector-${SERIE}-setup"

log() {
	python3 "$BASE_PATH/python/log_sistema.py" MSG "$1"
}

FIRST_START=$(awk -F'=' '/FIRST_START/{print $2}' "$CONFIG_PATH" | tr -d '\r')

# Siempre desbloquear el radio WiFi al arrancar, sin importar FIRST_START.
# cierre_amanecer.sh/cierre_atardecer.sh apagan el radio con
# `nmcli radio wifi off` al final de cada ventana para ahorrar batería, y
# ese estado queda persistido por systemd-rfkill entre reinicios. Si el
# equipo se reinicia (crash, corte de luz, lo que sea) mientras el radio
# estaba apagado, sin esto arranca sordo y se queda asi indefinidamente,
# porque el resto de este script no corre salvo que FIRST_START=TRUE o se
# apriete el boton.
sudo rfkill unblock wifi
sleep 2
sudo nmcli radio wifi on
sleep 2

sleep 15

# Chequear si fue activado por botón
BUTTON_FLAG=$(python3 -c "
import RPi.GPIO as GPIO
GPIO.setmode(GPIO.BCM)
GPIO.setwarnings(False)
GPIO.setup(24, GPIO.IN, pull_up_down=GPIO.PUD_DOWN)
val = GPIO.input(24)
GPIO.cleanup()
print(val)
")

if [ "$FIRST_START" != "TRUE" ] && [ "$BUTTON_FLAG" != "1" ]; then
	exit 0
fi

if [ "$BUTTON_FLAG" = "1" ]; then
python3 -c "
import RPi.GPIO as GPIO
GPIO.setmode(GPIO.BCM)
GPIO.setwarnings(False)
GPIO.setup(25, GPIO.OUT)
GPIO.output(25, GPIO.LOW)
import time; time.sleep(0.1)
GPIO.output(25, GPIO.HIGH)
GPIO.cleanup()
"
	sed -i 's/FIRST_START=.*/FIRST_START=TRUE/' "$CONFIG_PATH"
	FIRST_START="TRUE"
fi

if [ "$FIRST_START" != "TRUE" ]; then
	exit 0
fi

levantar_hotspot() {
	sudo ip addr flush dev wlan0
	sleep 1
	sudo pkill dnsmasq 2>/dev/null
	sleep 2

	# CAMBIO 2.1: red ABIERTA. No se puede usar "nmcli device wifi hotspot"
	# para esto -- ese atajo SIEMPRE pone seguridad: si no se le pasa
	# password, genera una al azar y la red queda protegida con una clave que
	# nadie conoce. Hay que armar el perfil a mano y no declarar ninguna
	# seccion 802-11-wireless-security, que es lo que deja el AP abierto.
	sudo nmcli connection delete Hotspot 2>/dev/null
	sudo nmcli connection add type wifi ifname wlan0 con-name Hotspot \
		autoconnect no \
		ssid "$HOTSPOT_SSID" \
		802-11-wireless.mode ap \
		802-11-wireless.band bg \
		ipv4.method shared \
		ipv4.addresses 192.168.4.1/24
	sleep 2
	sudo nmcli connection up Hotspot
}

levantar_hotspot
if [ $? -ne 0 ]; then
	log "Primer intento fallido. Reintentando hotspot..."
	sleep 5
	levantar_hotspot
	if [ $? -ne 0 ]; then
		log "Error: no se pudo levantar el hotspot después de dos intentos."
		exit 1
	fi
fi


sleep 5

IP_HOTSPOT=$(ip addr show wlan0 | grep -oP 'inet \K[\d.]+')
log "Hotspot activo: $HOTSPOT_SSID (IP: $IP_HOTSPOT)"

# Lanzar portal y capturar exit code
sudo python3 "$BASE_PATH/python/portal_configuracion.py"
EXIT_CODE=$?

if [ $EXIT_CODE -ne 0 ]; then
	log "Conexión fallida. Hotspot reactivado, esperando nuevas credenciales."
	exit 1
fi

# --- CONEXION EXITOSA ---

# Sincronizar hora
sudo systemctl restart systemd-timesyncd
sleep 5
python3 "$BASE_PATH/python/sync_rtc.py"

SSID_CONECTADA=$(nmcli -t -f active,ssid dev wifi | awk -F: '$1=="yes"{print $2; exit}')

UBICACION=$(curl -s ipinfo.io/json)
LAT=$(echo $UBICACION | python3 -c "import sys,json; coords=json.load(sys.stdin)['loc'].split(','); print(coords[0])")
LON=$(echo $UBICACION | python3 -c "import sys,json; coords=json.load(sys.stdin)['loc'].split(','); print(coords[1])")
sed -i "s/LAT=.*/LAT=$LAT/" "$CONFIG_PATH"
sed -i "s/LON=.*/LON=$LON/" "$CONFIG_PATH"

# Si BirdNET-Pi esta instalado, propagarle las mismas coordenadas: las usa
# su modelo de metadata geografica (LATITUDE/LONGITUDE) para priorizar
# especies plausibles para la region y la epoca del año, algo que refuerza
# justo lo que busca el modelo reentrenado. Son claves separadas de
# LAT/LON de este archivo, no la misma variable.
BIRDNET_CONF="$USER_HOME/BirdNET-Pi/birdnet.conf"
if [ -f "$BIRDNET_CONF" ]; then
	sudo sed -i "s/^LATITUDE=.*/LATITUDE=$LAT/" "$BIRDNET_CONF"
	sudo sed -i "s/^LONGITUDE=.*/LONGITUDE=$LON/" "$BIRDNET_CONF"
fi

# Marcar FIRST_START = FALSE
sed -i 's/FIRST_START=TRUE/FIRST_START=FALSE/' "$CONFIG_PATH"

# Registro contra el servidor de Tector Hub. Es el primer momento de la vida
# del dispositivo con internet, asi que es el primer momento en que se puede
# detectar si el numero de serie derivado del hardware ya lo tiene otro
# equipo. Si hay colision, este script reescribe config/serie.txt y el SSID
# de setup del proximo arranque ya sale con el numero nuevo.
#
# Nunca bloquea: sin SERVIDOR_URL configurado, o con el servidor caido, sale
# con codigo != 0 y el ciclo sigue igual.
python3 "$BASE_PATH/python/registrar_dispositivo.py" || true

bash "$BASE_PATH/scripts/aplicar_ajuste_regional.sh"

bash "$BASE_PATH/scripts/auto_sync_horarios.sh"
rclone copy "$CONFIG_HORARIOS" "gdrive:$DRIVE_PATH/"

# Calcular próxima ventana (la más cercana a futuro)
HORA_ACTUAL_MIN=$(date +%H%M | sed 's/^0*//')
INICIO_AMANECER=$(awk -F'=' '/INICIO_AMANECER/{print $2}' "$CONFIG_HORARIOS" | tr -d ' \r:')
INICIO_ATARDECER=$(awk -F'=' '/INICIO_ATARDECER/{print $2}' "$CONFIG_HORARIOS" | tr -d ' \r:')

INICIO_AMANECER_MIN=$(echo "$INICIO_AMANECER" | sed 's/^0*//')
INICIO_ATARDECER_MIN=$(echo "$INICIO_ATARDECER" | sed 's/^0*//')

if [ "$INICIO_AMANECER_MIN" -gt "$HORA_ACTUAL_MIN" ]; then
	HORA_WAKE=$(awk -F'=' '/INICIO_AMANECER/{print $2}' "$CONFIG_HORARIOS" | tr -d ' \r')
elif [ "$INICIO_ATARDECER_MIN" -gt "$HORA_ACTUAL_MIN" ]; then
	HORA_WAKE=$(awk -F'=' '/INICIO_ATARDECER/{print $2}' "$CONFIG_HORARIOS" | tr -d ' \r')
else
	HORA_WAKE=$(awk -F'=' '/INICIO_AMANECER/{print $2}' "$CONFIG_HORARIOS" | tr -d ' \r')
fi

PROXIMA_VENTANA=$(echo "$HORA_WAKE" | awk -F: '{m=$2+2; h=$1; if(m>=60){m=m-60; h=h+1; if(h>=24){h=h-24}} printf "%02d:%02d\n", h, m}')

# Programar alarma (por ahora sin efecto -- ver PENDIENTE en set_wake_rtc.py)
python3 "$BASE_PATH/python/set_wake_rtc.py" $HORA_WAKE
log "Conectado a $SSID_CONECTADA. Próxima ventana: $PROXIMA_VENTANA. Apagando."

# Subir log a Drive
rclone copy "$LOG_PATH" "gdrive:$DRIVE_PATH/"
bash "$BASE_PATH/scripts/generar_log_reciente.sh"
bash "$BASE_PATH/scripts/publicar_estado.sh"
sudo nmcli radio wifi off

sudo chown "$REAL_USER:$REAL_USER" "$USER_HOME/.config/rclone/rclone.conf"

# PENDIENTE: acá la v1.1 apagaba la Raspberry (SetPowerOff + poweroff) tras
# la configuración exitosa. Sin circuito de corte de energía todavía (ver
# set_wake_rtc.py y el README), la Pi queda encendida y en operación normal
# en vez de apagarse.
