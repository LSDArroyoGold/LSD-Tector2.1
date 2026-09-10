#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BASE_PATH="$(dirname "$SCRIPT_DIR")"

REAL_USER="${SUDO_USER:-$(whoami)}"
USER_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

export RCLONE_CONFIG="$USER_HOME/.config/rclone/rclone.conf"
export HOME="$USER_HOME"

CONFIG_HORARIOS="$BASE_PATH/config/config_horarios.txt"
CONFIG_GENERAL="$BASE_PATH/config/config_general.txt"
DRIVE_PATH=$(awk -F'=' '/^DRIVE_PATH=/{print $2}' "$CONFIG_GENERAL" | tr -d '\r')

HORARIO=$(awk -F'=' '/INICIO_ATARDECER/{print $2}' "$CONFIG_HORARIOS" |  tr -d '\r')
HORA_ACTUAL=$(date +%H:%M)
FECHA_HOY=$(date +%Y-%m-%d)

HORARIO_DELAY=$(echo "$HORARIO" | awk -F: '{m=$2+2; h=$1; if(m>=60){m=m-60; h=h+1; if(h>=24){h=h-24}} printf "%02d:%02d\n", h, m}')
FIN_ESPERADO=$(awk -F'=' '/FIN_ATARDECER/{print $2}' "$CONFIG_HORARIOS" | tr -d ' \r')
MARCA="$USER_HOME/.inicio_atardecer_hecho_$FECHA_HOY"

# Ver la nota completa en inicio_amanecer.sh sobre por que se cambio de
# minuto exacto a una ventana de tolerancia con marca de "ya arranco hoy".
if [ ! -f "$MARCA" ] && [[ ! "$HORA_ACTUAL" < "$HORARIO_DELAY" ]] && [[ "$HORA_ACTUAL" < "$FIN_ESPERADO" ]]; then

	touch "$MARCA"
	find "$USER_HOME" -maxdepth 1 -name '.inicio_atardecer_hecho_*' -mtime +3 -delete 2>/dev/null

	# Reset defensivo -- ver el comentario equivalente en inicio_amanecer.sh.
	sed -i "s/^VENTANA_ACTIVA=.*/VENTANA_ACTIVA=NONE/" "$CONFIG_GENERAL"
	sed -i "s/^CIERRE_FORZADO=.*/CIERRE_FORZADO=FALSE/" "$CONFIG_GENERAL"

	python3 "$BASE_PATH/python/log_sistema.py" INICIO atardecer $FIN_ESPERADO
	sed -i "s/^VENTANA_ACTIVA=.*/VENTANA_ACTIVA=atardecer/" "$CONFIG_GENERAL"

	sudo nmcli radio wifi on
	INTENTOS=0
	until ping -c 1 google.com &>/dev/null || [ $INTENTOS -ge 6 ]; do
		sleep 5
		INTENTOS=$((INTENTOS + 1))
	done

	if ! ping -c 1 google.com &>/dev/null; then
		echo "Sin conexión, abortando"
		sudo nmcli radio wifi off
		exit 1
	fi

	rclone copy "$BASE_PATH/log_sistema.txt" "gdrive:$DRIVE_PATH/"
	bash "$BASE_PATH/scripts/generar_log_reciente.sh"

	# Bajar la configuracion que la app haya dejado en Drive. Hasta la 2.0
	# esto solo pasaba en el CIERRE de cada ventana, asi que un cambio hecho
	# desde la app podia tardar hasta ~12hs en aplicarse. Bajandolo tambien
	# aca, un cambio de duracion hecho durante el dia ya afecta el cierre de
	# esta misma ventana y el calculo de la siguiente.
	#
	# Limite real, para no prometer de mas: la hora de INICIO de esta ventana
	# ya se uso para despertar al equipo, asi que cambiarla nunca puede
	# aplicar retroactivamente a la ventana en curso -- eso rige siempre
	# desde la proxima. La app lo dice explicitamente al confirmar.
	rclone copy "gdrive:$DRIVE_PATH/config_horarios.txt" "$BASE_PATH/config/"

	# Publicar el estado apenas arranca la ventana: es lo que hace que la app
	# muestre "Grabando" en vez del ultimo estado conocido de hace 12hs.
	bash "$BASE_PATH/scripts/publicar_estado.sh"

	bash "$BASE_PATH/scripts/actualizar_repo.sh"

	if systemctl list-unit-files TectorNET-Pi.service &>/dev/null; then
		# Ver el comentario equivalente en inicio_amanecer.sh.
		if [ -f "$USER_HOME/TectorNET-Pi/scripts/actualizar_tectornet_pi.sh" ]; then
			bash "$USER_HOME/TectorNET-Pi/scripts/actualizar_tectornet_pi.sh"
		else
			git -C "$USER_HOME/TectorNET-Pi" pull --quiet 2>/dev/null
			sudo systemctl restart TectorNET-Pi.service 2>/dev/null
		fi
	elif systemctl list-unit-files birdnet-lsd.service &>/dev/null; then
		# Ver el comentario equivalente en inicio_amanecer.sh.
		if [ -f "$USER_HOME/birdnet-lsd/scripts/renombrar_a_tectornet_pi.sh" ]; then
			bash "$USER_HOME/birdnet-lsd/scripts/renombrar_a_tectornet_pi.sh"
		else
			git -C "$USER_HOME/birdnet-lsd" pull --quiet 2>/dev/null
			sudo systemctl restart birdnet-lsd.service 2>/dev/null
		fi
	else
		bash "$BASE_PATH/scripts/actualizar_modelo.sh"
		bash "$BASE_PATH/scripts/aplicar_ajuste_regional.sh"
	fi

	sudo nmcli radio wifi off
	sudo chown "$REAL_USER:$REAL_USER" "$USER_HOME/.config/rclone/rclone.conf"
fi
