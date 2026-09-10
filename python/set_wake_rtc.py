import subprocess
import sys
from datetime import datetime, timedelta

# Arma la alarma nativa del DS3231 para la proxima ventana -- reemplaza al
# no-op que esto fue desde el 14/8 (ver git log), ahora que el circuito
# DS3231 + latch 74HC74 + MOSFET esta armado y probado en banco (2/9-3/9).
#
# Como funciona: /PRE1 del 74HC74 esta atado al pin INT/SQW del DS3231 (con
# pull-up R1, ver tabla de pines del circuito). Cuando la alarma del DS3231
# hace match, el chip baja ese pin solo, en hardware, sin que la Raspberry
# tenga que estar prendida ni escuchando nada -- eso es lo que fuerza el
# SET del latch y prende la Pi. Esta rutina solo tiene que dejar cargado el
# registro de alarma del DS3231 antes de que la Pi se apague.
#
# El kernel expone la alarma via /sys/class/rtc/rtc0/wakealarm -- pero esa
# ruta solo aparece si el overlay tiene el parametro wakeup-source (ver
# install.sh, dtoverlay=i2c-rtc,ds3231,wakeup-source). Sin ese parametro el
# archivo no existe aunque el RTC funcione bien para todo lo demas (fecha/
# hora), que es como estaba configurado hasta ahora -- de ahi que nunca se
# haya notado que esto faltaba.

RUTA_WAKEALARM = "/sys/class/rtc/rtc0/wakealarm"


def log(mensaje, alerta=False):
    prefijo = "ALERTA: " if alerta else ""
    try:
        subprocess.run(
            ["python3", "/home/lsd/LSD-Tector2.0/python/log_sistema.py", "MSG",
             f"set_wake_rtc: {prefijo}{mensaje}"],
            capture_output=True, timeout=10,
        )
    except Exception:
        pass
    print(f"{prefijo}{mensaje}")


def escribir_wakealarm(valor):
    resultado = subprocess.run(
        ["sudo", "sh", "-c", f"echo {valor} > {RUTA_WAKEALARM}"],
        capture_output=True, text=True,
    )
    return resultado.returncode == 0, resultado.stderr.strip()


if len(sys.argv) < 2:
    log("uso: set_wake_rtc.py HH:MM -- no se paso horario, alarma no armada", alerta=True)
    sys.exit(1)

hora_wake = sys.argv[1]

try:
    h, m = map(int, hora_wake.split(":"))
except ValueError:
    log(f"horario '{hora_wake}' no tiene formato HH:MM, alarma no armada", alerta=True)
    sys.exit(1)

import os
if not os.path.exists(RUTA_WAKEALARM):
    log(
        f"{RUTA_WAKEALARM} no existe -- falta wakeup-source en el overlay del "
        f"DS3231 (config.txt) o no se reinicio despues de agregarlo. La Pi NO "
        f"se va a despertar sola a las {hora_wake}.",
        alerta=True,
    )
    sys.exit(1)

ahora = datetime.now()
objetivo = ahora.replace(hour=h, minute=m, second=0, microsecond=0)
if objetivo <= ahora:
    objetivo += timedelta(days=1)

timestamp = int(objetivo.timestamp())

# Limpiar cualquier alarma previa antes de programar la nueva -- si no, en
# algunos drivers escribir un timestamp nuevo con una alarma vieja todavia
# activa no la reemplaza limpiamente.
ok_clear, err_clear = escribir_wakealarm(0)
if not ok_clear:
    log(f"no se pudo limpiar la alarma previa ({err_clear}), sigo igual", alerta=False)

ok_set, err_set = escribir_wakealarm(timestamp)
if not ok_set:
    log(f"fallo al armar la alarma para las {hora_wake}: {err_set}", alerta=True)
    sys.exit(1)

# Verificar que quedo escrito de verdad, no confiar en el returncode solo.
try:
    with open(RUTA_WAKEALARM) as f:
        leido = f.read().strip()
except Exception as e:
    log(f"alarma armada pero no se pudo releer para confirmar ({e})", alerta=True)
    sys.exit(1)

if leido != str(timestamp):
    log(
        f"alarma armada para las {hora_wake} pero la relectura no coincide "
        f"(escribi {timestamp}, lei '{leido}') -- no confiar en este despertar",
        alerta=True,
    )
    sys.exit(1)

log(f"alarma DS3231 armada OK para las {hora_wake} ({timestamp}, {objetivo.isoformat()})")
