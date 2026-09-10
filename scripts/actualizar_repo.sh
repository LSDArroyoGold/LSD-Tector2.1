#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BASE_PATH="$(dirname "$SCRIPT_DIR")"

REPO="LSDArroyoGold/LSD-Tector2.1"
RAW="https://raw.githubusercontent.com/$REPO/main"
API="https://api.github.com/repos/$REPO/commits/main"
MARCA="$BASE_PATH/.ultima_actualizacion"
TMP="$BASE_PATH/.actualizar_tmp"

ULTIMO_SHA=$(cat "$MARCA" 2>/dev/null)

SHA_ACTUAL=$(curl -s "$API" | python3 -c "import sys,json; print(json.load(sys.stdin)['sha'])" 2>/dev/null)

if [ -z "$SHA_ACTUAL" ] || [ "$SHA_ACTUAL" = "$ULTIMO_SHA" ]; then
	exit 0
fi

# Todos los archivos que corren activamente. config_general.txt y
# config_horarios.txt quedan afuera a propósito: guardan estado en vivo del
# dispositivo (FIRST_START, coordenadas reales, horarios recalculados), no
# solo configuración de fábrica.
#
# config/rclone.conf SACADO de esta lista el 31/08/2026 (antes se sincronizaba
# igual que el resto): tiene credenciales OAuth reales (client_secret,
# refresh_token), y este repo es publico -- GitHub lo detecto via su programa
# de partners de secret scanning (Google Cloud es partner) y Google revoco el
# token solo, silenciosamente, ~1 semana despues de que se commiteo,
# rompiendo la sincronizacion a Drive sin ningun aviso. Ver
# config/rclone.conf.ejemplo para la forma del archivo -- el real se pone a
# mano en cada dispositivo (/home/lsd/.config/rclone/rclone.conf), nunca via
# git/este script.
ARCHIVOS="scripts/inicio_amanecer.sh scripts/inicio_atardecer.sh scripts/cierre_amanecer.sh scripts/cierre_atardecer.sh scripts/hotspot.sh scripts/auto_sync_horarios.sh scripts/generar_log_reciente.sh scripts/actualizar_repo.sh scripts/actualizar_modelo.sh scripts/aplicar_ajuste_regional.sh scripts/chequeo_bateria.sh scripts/limpiar_retencion.sh python/calcular_horarios.py python/check_button.py python/log_sistema.py python/portal_configuracion.py python/set_wake_rtc.py python/sync_rtc.py python/cortar_alimentacion.py python/leer_ina219.py python/registrar_bateria.py python/asignar_serie.py python/registrar_dispositivo.py python/generar_estado.py scripts/publicar_estado.sh assets/tector_isotipo.svg systemd/hotspot.service systemd/sync-rtc.service systemd/90-sync-rtc systemd/cortar-alimentacion.service config/logrotate-tector"

rm -rf "$TMP"
mkdir -p "$TMP"

for ARCHIVO in $ARCHIVOS; do
	mkdir -p "$TMP/$(dirname "$ARCHIVO")"
	if ! curl -sf -o "$TMP/$ARCHIVO" "$RAW/$ARCHIVO"; then
		echo "Fallo la descarga de $ARCHIVO, aborto sin tocar nada" >&2
		rm -rf "$TMP"
		exit 1
	fi
done

SELF_CAMBIO=0
if [ ! -f "$BASE_PATH/scripts/actualizar_repo.sh" ] || ! cmp -s "$TMP/scripts/actualizar_repo.sh" "$BASE_PATH/scripts/actualizar_repo.sh"; then
	SELF_CAMBIO=1
fi

# Mismo filesystem que BASE_PATH: el mv es un rename atómico, seguro
# incluso si el archivo que se reemplaza es el que está corriendo ahora
# mismo (este mismo script, o el inicio_*.sh que lo llamó).
for ARCHIVO in $ARCHIVOS; do
	case "$ARCHIVO" in
		systemd/hotspot.service)
			# Tiene el placeholder __BASE_PATH__ (ver install.sh) -- no se
			# puede copiar tal cual a /etc/systemd/system.
			mv "$TMP/$ARCHIVO" "$BASE_PATH/$ARCHIVO"
			sed "s|__BASE_PATH__|$BASE_PATH|g" "$BASE_PATH/$ARCHIVO" | sudo tee /etc/systemd/system/hotspot.service > /dev/null
			sudo chmod 644 /etc/systemd/system/hotspot.service
			;;
		systemd/cortar-alimentacion.service)
			# Mismo placeholder que hotspot.service. Nota: si esta unit es
			# nueva en este dispositivo (recien esta linea la trae por
			# primera vez), copiarla acá NO la habilita -- hace falta
			# ademas "sudo systemctl enable --now cortar-alimentacion.service"
			# a mano una vez (install.sh ya lo hace en instalaciones nuevas).
			mv "$TMP/$ARCHIVO" "$BASE_PATH/$ARCHIVO"
			sed "s|__BASE_PATH__|$BASE_PATH|g" "$BASE_PATH/$ARCHIVO" | sudo tee /etc/systemd/system/cortar-alimentacion.service > /dev/null
			sudo chmod 644 /etc/systemd/system/cortar-alimentacion.service
			;;
		systemd/90-sync-rtc)
			# No es una unit de systemd (pese a vivir en systemd/ junto a
			# las que si lo son) -- es un dispatcher de NetworkManager,
			# va a otra carpeta y necesita permisos de ejecucion, no 644.
			mv "$TMP/$ARCHIVO" "$BASE_PATH/$ARCHIVO"
			sudo cp "$BASE_PATH/$ARCHIVO" /etc/NetworkManager/dispatcher.d/90-sync-rtc
			sudo chown root:root /etc/NetworkManager/dispatcher.d/90-sync-rtc
			sudo chmod 755 /etc/NetworkManager/dispatcher.d/90-sync-rtc
			;;
		systemd/*)
			NOMBRE=$(basename "$ARCHIVO")
			mv "$TMP/$ARCHIVO" "$BASE_PATH/$ARCHIVO"
			sudo cp "$BASE_PATH/$ARCHIVO" "/etc/systemd/system/$NOMBRE"
			sudo chmod 644 "/etc/systemd/system/$NOMBRE"
			;;
		config/logrotate-tector)
			# No es una unit de systemd -- va a /etc/logrotate.d/, corre solo
			# via el cron.daily estandar de logrotate, no necesita reload ni
			# enable de nada.
			mv "$TMP/$ARCHIVO" "$BASE_PATH/$ARCHIVO"
			sudo cp "$BASE_PATH/$ARCHIVO" /etc/logrotate.d/tector
			sudo chown root:root /etc/logrotate.d/tector
			sudo chmod 644 /etc/logrotate.d/tector
			;;
		*)
			# La carpeta destino puede no existir todavia en un dispositivo
			# que viene de una version anterior (caso real: assets/, nueva
			# en la 2.1). Sin esto el mv falla y la actualizacion aborta.
			mkdir -p "$BASE_PATH/$(dirname "$ARCHIVO")"
			mv "$TMP/$ARCHIVO" "$BASE_PATH/$ARCHIVO"
			;;
	esac
done

chmod +x "$BASE_PATH"/scripts/*.sh
sudo systemctl daemon-reload

rm -rf "$TMP"

# Si actualizar_repo.sh cambió, la lista de $ARCHIVOS que acabamos de usar
# para bajar todo puede ser la vieja (la que ya estaba cargada en memoria
# al arrancar esta corrida) -- por ejemplo, si el mismo commit que nos trajo
# esta versión nueva también agregó un archivo a la lista. Nos volvemos a
# ejecutar una vez con la versión ya instalada para completar el ciclo con
# la lista correcta antes de marcar la actualización como terminada.
# _REEXEC evita un bucle si por lo que sea el archivo siguiera "cambiando".
if [ "$SELF_CAMBIO" = "1" ] && [ -z "$_REEXEC" ]; then
	_REEXEC=1 exec bash "$BASE_PATH/scripts/actualizar_repo.sh"
fi

echo "$SHA_ACTUAL" > "$MARCA"

echo "[$(date '+%Y-%m-%d %H:%M')] Software actualizado ($SHA_ACTUAL)" >> "$BASE_PATH/log_sistema.txt"
