#!/bin/bash
#
# chequeo_bateria.sh - corre cada 5 min por cron, siempre (no solo en
# ventana -- ver nota del 4/9 mas abajo). Dos trabajos separados:
#
# 1) Medir y loguear (con/sin carga MPPT, via registrar_bateria.py) y
#    subir ese log a Drive -- esto SIEMPRE corre, mientras la Pi este
#    prendida. Es caracterizacion/analisis, no participa de ninguna
#    decision de seguridad.
# 2) Si ademas hay una ventana activa Y el voltaje (siempre el de SIN
#    carga, nunca el de con carga) esta bajo el umbral, marcar
#    CIERRE_FORZADO=TRUE -- esto es lo unico gateado por ventana, porque
#    fuera de una ventana no hay nada que forzar a cerrar (y aunque se
#    marcara, inicio_amanecer/atardecer.sh lo resetea a FALSE apenas
#    arranca la proxima ventana, asi que no cambiaria nada dejarlo
#    sin-gatear tampoco -- se gatea igual, por claridad).
#
# Antes (hasta el 4/9) todo esto estaba gateado por ventana activa junto
# con un logger de caracterizacion aparte (log_curva_carga.py) corriendo
# siempre por su cuenta -- se unificaron en este solo script para no
# tener dos mecanismos haciendo cosas parecidas por separado.

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BASE_PATH="$(dirname "$SCRIPT_DIR")"

REAL_USER="${SUDO_USER:-$(whoami)}"
USER_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
export RCLONE_CONFIG="$USER_HOME/.config/rclone/rclone.conf"

CONFIG_GENERAL="$BASE_PATH/config/config_general.txt"
DRIVE_PATH=$(awk -F'=' '/^DRIVE_PATH=/{print $2}' "$CONFIG_GENERAL" | tr -d '\r')

VENTANA_ACTIVA=$(awk -F'=' '/^VENTANA_ACTIVA=/{print $2}' "$CONFIG_GENERAL" | tr -d ' \r')
UMBRAL=$(awk -F'=' '/^UMBRAL_BATERIA_V=/{print $2}' "$CONFIG_GENERAL" | tr -d ' \r')

# timeout defensivo: si el bus I2C se traba (paso una vez, el 3/9, y
# encolgo el sistema entero hasta un power-cycle completo), esta lectura
# no se tiene que quedar esperando para siempre -- se corta a los 12s, se
# loguea, y el proximo chequeo de cron (5 min despues) lo vuelve a
# intentar solo. 12s porque registrar_bateria.py hace DOS lecturas (con
# carga + sin carga).
#
# registrar_bateria.py hace la lectura dual y loguea las dos a
# log_bateria.txt para caracterizar ambos regimenes -- pero solo imprime
# por stdout la de SIN carga, que es la unica que participa de la
# decision de seguridad de mas abajo (ver justificacion en
# config/config_general.txt).
LECTURA=$(timeout 12 python3 "$BASE_PATH/python/registrar_bateria.py" 2>&1)
CODIGO=$?
if [ $CODIGO -eq 124 ]; then
	python3 "$BASE_PATH/python/log_sistema.py" MSG "ALERTA: chequeo_bateria -- lectura del INA219 colgada, cortada a los 12s (posible bus I2C trabado)"
	exit 1
elif [ $CODIGO -ne 0 ]; then
	python3 "$BASE_PATH/python/log_sistema.py" MSG "ALERTA: chequeo_bateria no pudo leer el INA219 -- $LECTURA"
	exit 1
fi

VOLTAJE=$(echo "$LECTURA" | grep -oP 'Voltaje \(pack\): \K[0-9.]+')

if [ -z "$VOLTAJE" ]; then
	python3 "$BASE_PATH/python/log_sistema.py" MSG "ALERTA: chequeo_bateria no pudo parsear la lectura del INA219: $LECTURA"
	exit 1
fi

# Solo importa la ventana a partir de aca: fuera de una ventana no hay
# nada que forzar a cerrar, aunque el voltaje este bajo.
if [ "$VENTANA_ACTIVA" != "NONE" ]; then
	# Comparacion de punto flotante -- bash no la hace nativamente.
	BAJO_UMBRAL=$(awk -v v="$VOLTAJE" -v u="$UMBRAL" 'BEGIN { print (v < u) ? "1" : "0" }')

	if [ "$BAJO_UMBRAL" = "1" ]; then
		sed -i "s/^CIERRE_FORZADO=.*/CIERRE_FORZADO=TRUE/" "$CONFIG_GENERAL"
		python3 "$BASE_PATH/python/log_sistema.py" MSG "ALERTA: bateria en ${VOLTAJE}V, por debajo del umbral (${UMBRAL}V) -- cierre forzado marcado"
	fi
fi

# Subida del log de caracterizacion de bateria a Drive, best-effort --
# siempre, no solo en ventana. Si falla (sin wifi en este instante, Drive
# caido, lo que sea) no pasa nada, se reintenta solo en la proxima
# corrida del cron, 5 min despues.
timeout 30 rclone copy "$BASE_PATH/log_bateria.txt" "gdrive:$DRIVE_PATH/" 2>/dev/null
