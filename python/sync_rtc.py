# Sincroniza el reloj de hardware (DS3231, expuesto por el kernel como
# /dev/rtc0 vía dtoverlay=i2c-rtc,ds3231) con la hora actual del sistema.
#
# Reemplaza a sync_pijuice_rtc.py de la v1.1: la PiJuice tenía su propio RTC
# accedido por una API Python propietaria (pj.rtcAlarm.SetTime). El DS3231
# es un RTC estándar soportado directamente por el kernel de Linux, así que
# no hace falta ninguna librería: `hwclock` ya sabe hablarle.
#
# Se invoca desde las rutinas de cierre, después de sincronizar el sistema
# por NTP, para que el DS3231 quede con la hora correcta antes de que el
# equipo pierda conectividad (o, más adelante, se apague).

import subprocess

resultado = subprocess.run(['sudo', 'hwclock', '-w'], capture_output=True, text=True)

if resultado.returncode == 0:
    print("RTC (DS3231) sincronizado con la hora del sistema")
else:
    print(f"ERROR sincronizando el RTC: {resultado.stderr}")
