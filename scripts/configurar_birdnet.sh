#!/bin/bash
#
# configurar_birdnet.sh - Deja BirdNET-Pi listo para uso desatendido en
# campo. Se corre UNA sola vez, a mano, despues de instalar BirdNET-Pi con
# su instalador oficial (ver README, paso 2). No forma parte del ciclo de
# auto-actualizacion (a diferencia de actualizar_modelo.sh): estas son
# acciones de instalacion, no algo que tenga sentido repetir cada ventana.
#
# Que hace:
#   1. Apaga y enmascara los servicios de dashboard/streaming de BirdNET-Pi
#      (nadie los mira en un dispositivo desatendido en el campo; miden un
#      ~19% de consumo instantaneo, validado en LSD-Tector 1.1). Grabacion,
#      analisis y subida a BirdWeather NO dependen de ninguno de ellos.
#   2. Arranca en modo consola (sin entorno grafico).
#   3. Configura la gestion de disco (purga automatica al 75%).
#   4. Configura CONFIDENCE y SENSITIVITY para monitoreo continuo (los
#      defaults del instalador de BirdNET-Pi, ya pensados para esto).
#   5. Pide (opcional) el token de BirdWeather y lo escribe en birdnet.conf.
#      No se sube a ningun repositorio: birdnet.conf no esta versionado.
#
# Uso: ./configurar_birdnet.sh   (NO con sudo; pide sudo donde hace falta)

set -e

REAL_USER="${SUDO_USER:-$(whoami)}"
USER_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
BIRDNET_CONF="$USER_HOME/BirdNET-Pi/birdnet.conf"

if [ ! -f "$BIRDNET_CONF" ]; then
	echo "No se encontro $BIRDNET_CONF. ¿BirdNET-Pi esta instalado?" >&2
	echo "Instalarlo primero (ver paso 2 del README) y volver a correr este script." >&2
	exit 1
fi

echo "==> Paso 1/5: apagando servicios de dashboard/streaming"
echo "    (grabacion, analisis y BirdWeather no dependen de ninguno de estos)"

SERVICIOS_DASHBOARD="icecast2.service livestream.service chart_viewer.service spectrogram_viewer.service web_terminal.service caddy.service birdnet_stats.service birdnet_log.service"

sudo systemctl disable --now $SERVICIOS_DASHBOARD 2>/dev/null || true
sudo systemctl mask $SERVICIOS_DASHBOARD

# php-fpm cambia de nombre segun la version (php8.4-fpm, php8.2-fpm, etc.)
PHP_FPM=$(systemctl list-units --type=service --all 2>/dev/null | grep -oP 'php[\d.]*-fpm\.service' | head -1)
if [ -n "$PHP_FPM" ]; then
	sudo systemctl disable --now "$PHP_FPM" 2>/dev/null || true
	sudo systemctl mask "$PHP_FPM"
fi

# icecast2 y (en algunas versiones) php-fpm son scripts SysV, no unidades
# systemd nativas: si el disable --now no los frena del todo, van a mano.
sudo systemctl stop icecast2 2>/dev/null || true
if [ -n "$PHP_FPM" ]; then
	sudo systemctl stop "$PHP_FPM" 2>/dev/null || true
fi

echo "    Listo. Verificar con: systemctl is-active ${SERVICIOS_DASHBOARD} ${PHP_FPM}"

echo ""
echo "==> Paso 2/5: arranque en modo consola (sin entorno grafico)"
sudo systemctl set-default multi-user.target
echo "    Listo (aplica desde el proximo reinicio)."

echo ""
echo "==> Paso 3/5: gestion de disco y parametros de deteccion"

set_conf() {
	local clave="$1" valor="$2"
	if grep -q "^${clave}=" "$BIRDNET_CONF"; then
		sudo sed -i "s|^${clave}=.*|${clave}=${valor}|" "$BIRDNET_CONF"
	else
		echo "${clave}=${valor}" | sudo tee -a "$BIRDNET_CONF" > /dev/null
	fi
}

set_conf "FULL_DISK" "purge"
set_conf "PURGE_THRESHOLD" "75"
set_conf "CONFIDENCE" "0.7"
set_conf "SENSITIVITY" "1.25"
set_conf "MODEL" "BirdNET_GLOBAL_6K_V2.4_Model_FP16"

echo "    FULL_DISK=purge, PURGE_THRESHOLD=75, CONFIDENCE=0.7, SENSITIVITY=1.25"
echo "    (estos dos ultimos son punto de partida, ajustar despues con datos"
echo "    de campo reales -- ver la discusion correspondiente en el cuaderno"
echo "    de laboratorio)"

echo ""
echo "==> Paso 4/5: token de BirdWeather (opcional, dejar vacio para saltear)"
read -p "    Token de BirdWeather: " BIRDWEATHER_TOKEN
if [ -n "$BIRDWEATHER_TOKEN" ]; then
	set_conf "BIRDWEATHER_ID" "$BIRDWEATHER_TOKEN"
	echo "    Token configurado."
else
	echo "    Salteado. Para configurarlo despues:"
	echo "    sudo nano $BIRDNET_CONF   (buscar BIRDWEATHER_ID)"
fi

echo ""
echo "==> Paso 5/5: espectro completo en el audio y espectrograma guardados"
echo "    Por defecto, BirdNET-Pi guarda el mp3 de cada deteccion con el"
echo "    filtro pasa-bajos por defecto de LAME (~16kHz segun el bitrate) y"
echo "    genera el espectrograma remuestreado a 24kHz (eje de frecuencia"
echo "    hasta 12kHz). Ninguno de los dos afecta la deteccion en si -- el"
echo "    modelo analiza el .wav crudo a 48kHz antes de este paso -- pero"
echo "    limita lo que despues se puede escuchar/ver de cada deteccion."
REPORTING_PY="$USER_HOME/BirdNET-Pi/scripts/utils/reporting.py"
if [ -f "$REPORTING_PY" ]; then
	sudo sed -i "s/\['sox', '-V1', f'{in_file}', f'{out_file}', 'trim', f'={start}', f'={stop}'\]/['sox', '-V1', f'{in_file}', '-C', '320', f'{out_file}', 'trim', f'={start}', f'={stop}']/" "$REPORTING_PY"
	sudo sed -i "s/'remix', '1', 'rate', '24k', 'spectrogram'/'remix', '1', 'spectrogram'/" "$REPORTING_PY"
	echo "    Aplicado: mp3 de deteccion a 320kbps (sin el lowpass por defecto"
	echo "    de LAME) y espectrograma con el espectro completo hasta 24kHz."
else
	echo "    No se encontro $REPORTING_PY, salteado."
fi

# TectorNET-Pi (repo aparte) puede estar reemplazando a BirdNET-Pi como
# motor de analisis en este dispositivo, en cuyo caso este servicio ya no
# existe -- el resto de este script sigue corriendo igual, solo el
# reinicio queda condicionado.
if systemctl list-unit-files birdnet_analysis.service &>/dev/null; then
	sudo systemctl restart birdnet_analysis.service
fi

echo ""
echo "==> Configuracion completa."
echo "    El modelo reentrenado se instala aparte, con actualizar_modelo.sh"
echo "    (ya se corre solo en cada ventana; para forzarlo ahora mismo:"
echo "    bash $USER_HOME/*/scripts/actualizar_modelo.sh)"
