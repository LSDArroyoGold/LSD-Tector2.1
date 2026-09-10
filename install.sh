#!/bin/bash
#
# install.sh - Instalador del LSD-Tector 2.1
#
# Deja el sistema completamente listo para operar: paquetes del sistema,
# I2C, overlay del DS3231, dependencias de Python, permisos, servicios
# systemd y crontab. Autodetecta la ubicacion del repositorio y el usuario.
#
# No instala BirdNET-Pi (instalador propio, opcional, ver README) ni
# configura rclone (necesita autenticacion interactiva con Google, ver
# README) -- eso queda aparte a proposito.
#
# Uso: ./install.sh   (NO con sudo; el script pide sudo donde lo necesita)

set -e

# --- Autodeteccion de rutas ---
BASE_PATH="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
SCRIPTS_DIR="$BASE_PATH/scripts"
PYTHON_DIR="$BASE_PATH/python"
SYSTEMD_DIR="$BASE_PATH/systemd"
CONFIG_TXT="/boot/firmware/config.txt"

# --- Deteccion del usuario real (aunque se corra con sudo por error) ---
REAL_USER="${SUDO_USER:-$(whoami)}"

echo "==> Instalando LSD-Tector 2.1"
echo "    Repositorio detectado en: $BASE_PATH"
echo "    Usuario: $REAL_USER"
echo ""

# --- 1. Paquetes del sistema ---
echo "==> Paquetes del sistema (dnsmasq, util-linux-extra, i2c-tools)"
sudo apt-get update -qq
sudo apt-get install -y -qq dnsmasq util-linux-extra i2c-tools

# NO habilitar dnsmasq como servicio systemd: hotspot.sh lo mata a mano
# (pkill dnsmasq) antes de levantar el AP, y NetworkManager lanza su propia
# instancia privada al activar la conexion Hotspot (ipv4.method shared).
# Un dnsmasq systemd corriendo de forma standalone escucha DHCP/DNS en todas
# las interfaces por default, incluida wlan0 mientras esta conectada como
# cliente normal -- eso corto la conexion de wlan0 la primera vez que se
# corrio este instalador. Solo hace falta el paquete instalado.
sudo systemctl disable --now dnsmasq 2>/dev/null || true
echo "    hwclock disponible en: $(which hwclock || echo '/usr/sbin/hwclock')"

# --- 2. I2C, para el DS3231 ---
echo "==> Habilitando I2C"
sudo raspi-config nonint do_i2c 0

# --- 3. Overlay del DS3231 ---
# wakeup-source: sin este parametro el kernel no expone
# /sys/class/rtc/rtc0/wakealarm (necesario para set_wake_rtc.py) aunque el
# RTC funcione bien para todo lo demas -- no hace falta declarar el pin de
# interrupcion del DS3231 como GPIO de la Raspberry, porque en este
# circuito ese pin va directo al latch 74HC74, no a la Pi.
echo "==> Configurando overlay del DS3231 en $CONFIG_TXT"
REBOOT_NECESARIO=0
if grep -q "^dtoverlay=i2c-rtc,ds3231,wakeup-source" "$CONFIG_TXT" 2>/dev/null; then
	echo "    Ya estaba configurado."
elif grep -q "^dtoverlay=i2c-rtc,ds3231" "$CONFIG_TXT" 2>/dev/null; then
	sudo sed -i "s|^dtoverlay=i2c-rtc,ds3231.*|dtoverlay=i2c-rtc,ds3231,wakeup-source|" "$CONFIG_TXT"
	echo "    Agregado wakeup-source a la linea existente."
	REBOOT_NECESARIO=1
else
	echo "dtoverlay=i2c-rtc,ds3231,wakeup-source" | sudo tee -a "$CONFIG_TXT" > /dev/null
	echo "    Agregado."
	REBOOT_NECESARIO=1
fi

# --- 4. Dependencias de Python ---
echo "==> Dependencias de Python (astral, smbus2)"
pip install astral smbus2 --break-system-packages --quiet
# smbus2 es para el DS3231 (lectura directa de registros, ver
# python/set_wake_rtc.py) y el INA219 (ver python/leer_ina219.py, usado por
# el watchdog de bateria -- ver config/config_general.txt).

# --- 5. Permisos de ejecucion a los scripts ---
echo "==> Dando permisos de ejecucion a los scripts .sh"
chmod +x "$SCRIPTS_DIR"/*.sh


# --- 6. Numero de serie ---
# Se asigna una sola vez y no se vuelve a tocar: es la identidad de este
# dispositivo. Aparece en el SSID de la red de setup (Tector-<SERIE>-setup) y
# es lo que la app usa para distinguir un Tector de otro.
#
# Idempotente: si este instalador se vuelve a correr sobre un equipo ya
# instalado, devuelve el numero que ya tenia sin cambiar nada.
echo "==> Numero de serie del dispositivo"
SERIE=$(python3 "$PYTHON_DIR/asignar_serie.py")
echo "    Este Tector es el numero: $SERIE"
echo "    Red de configuracion:     Tector-$SERIE-setup"
# --- 7. Servicios systemd ---
echo "==> Instalando servicios systemd"

# hotspot.service: reemplazar el placeholder __BASE_PATH__ por la ruta real
sed "s|__BASE_PATH__|$BASE_PATH|g" "$SYSTEMD_DIR/hotspot.service" \
	| sudo tee /etc/systemd/system/hotspot.service > /dev/null

# sync-rtc.service: no tiene rutas del proyecto, se copia tal cual
sudo cp "$SYSTEMD_DIR/sync-rtc.service" /etc/systemd/system/sync-rtc.service

# cortar-alimentacion.service: mismo placeholder que hotspot.service. Se
# habilita (queda "activo" via RemainAfterExit) para que al llegar un
# poweroff/halt real systemd lo pare y corra el ExecStop= -- ver notas en
# el archivo de la unit sobre por que no se dispara con reboot.
sed "s|__BASE_PATH__|$BASE_PATH|g" "$SYSTEMD_DIR/cortar-alimentacion.service" \
	| sudo tee /etc/systemd/system/cortar-alimentacion.service > /dev/null

sudo chmod 644 /etc/systemd/system/hotspot.service
sudo chmod 644 /etc/systemd/system/sync-rtc.service
sudo chmod 644 /etc/systemd/system/cortar-alimentacion.service

sudo systemctl daemon-reload
sudo systemctl enable hotspot.service
sudo systemctl enable sync-rtc.service
sudo systemctl enable --now cortar-alimentacion.service

echo "    Servicios hotspot.service, sync-rtc.service y cortar-alimentacion.service habilitados"

# 90-sync-rtc: dispatcher de NetworkManager, complementa a sync-rtc.service.
# sync-rtc.service solo carga el RTC al sistema al bootear (mejor esfuerzo
# con lo que el RTC tenga en ese momento, puede estar stale si el equipo
# perdio energia de golpe antes de la ultima escritura). Este dispatcher
# escribe el RTC cada vez que hay conectividad real confirmada por NTP, sin
# depender de que una ventana amanecer/atardecer llegue a su cierre normal.
# No requiere "systemctl enable": NetworkManager lo detecta solo por estar
# presente y ser ejecutable en dispatcher.d/.
sudo cp "$SYSTEMD_DIR/90-sync-rtc" /etc/NetworkManager/dispatcher.d/90-sync-rtc
sudo chown root:root /etc/NetworkManager/dispatcher.d/90-sync-rtc
sudo chmod 755 /etc/NetworkManager/dispatcher.d/90-sync-rtc

echo "    Dispatcher 90-sync-rtc instalado (sincroniza el RTC en cada conexion real)"

# --- 8. Rotacion de logs (logrotate) ---
echo "==> Instalando rotacion de logs"
sudo cp "$BASE_PATH/config/logrotate-tector" /etc/logrotate.d/tector
sudo chown root:root /etc/logrotate.d/tector
sudo chmod 644 /etc/logrotate.d/tector
echo "    /etc/logrotate.d/tector instalado (corre solo via el cron.daily estandar de logrotate)"

# --- 9. Crontab del usuario ---
echo "==> Configurando crontab para el usuario $REAL_USER"

# Lineas del crontab, apuntando a las rutas reales del repo
CRON_LINES="* * * * * $SCRIPTS_DIR/cierre_amanecer.sh
* * * * * $SCRIPTS_DIR/cierre_atardecer.sh
* * * * * $SCRIPTS_DIR/inicio_amanecer.sh
* * * * * $SCRIPTS_DIR/inicio_atardecer.sh
* * * * * python3 $PYTHON_DIR/check_button.py
*/5 * * * * $SCRIPTS_DIR/chequeo_bateria.sh"

# Tomar el crontab actual del usuario (si existe), quitar cualquier linea previa
# de LSD-Tector para no duplicar, y agregar las nuevas.
CRON_ACTUAL=$(crontab -u "$REAL_USER" -l 2>/dev/null | grep -v "$SCRIPTS_DIR" | grep -v "$PYTHON_DIR/check_button.py" || true)

printf '%s\n%s\n' "$CRON_ACTUAL" "$CRON_LINES" | grep -v '^$' | crontab -u "$REAL_USER" -

echo "    Crontab configurado con 6 tareas"

# --- Fin ---
echo ""
echo "==> Instalacion completada."
echo ""
echo "    NUMERO DE SERIE: $SERIE   (anotarlo en la caja del equipo)"
echo ""
echo "    Verifica los servicios con: sudo systemctl status hotspot.service"
echo "    Verifica el crontab con:    crontab -l"

if [ "$REBOOT_NECESARIO" = "1" ]; then
	echo ""
	echo "    IMPORTANTE: el overlay del DS3231 se agrego recien. Reiniciar para"
	echo "    que tome efecto:"
	echo ""
	echo "        sudo reboot"
	echo ""
	echo "    Despues del reinicio, verificar con: ls /dev/rtc*"
fi
