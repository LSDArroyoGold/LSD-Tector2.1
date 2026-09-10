#!/usr/bin/env python3
# registrar_bateria.py - lectura DUAL del INA219 para el watchdog de
# bateria (chequeo_bateria.sh): una CON el MPPT conectado tal cual esta
# (para ver el efecto real de la carga) y otra SIN carga (aislada, via el
# aislador de carga MPPT -- descarga pura). Loguea las dos a
# log_bateria.txt para caracterizar ambos regimenes con el tiempo, y
# reporta por stdout la lectura SIN CARGA en el mismo formato que
# leer_ina219.py -- es la UNICA que participa de la decision de seguridad
# del watchdog (nunca la que tiene el MPPT metiendo carga, ver la
# justificacion completa en config/config_general.txt).
#
# Agregado el 4/9/2026: temperatura de CPU, throttled (vcgencmd) y load
# average de 1 min -- las tres, lecturas practicamente gratis (archivo de
# /sys o un solo comando corto) al lado de las dos lecturas de INA219 que
# ya hace esta corrida, pero dan contexto util para cruzar despues contra
# el voltaje/corriente (ej. si un evento de undervoltage en 'throttled'
# coincide con bateria baja, o si la temperatura sube con uso real -- load
# average alto -- o de forma independiente del uso, por ambiente).
# NOTA: columnas nuevas -- filas de log_bateria.txt anteriores a esta
# fecha tienen menos columnas (CSV desparejo a proposito, no se
# reescribe el historico).

import glob
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import leer_ina219

ARCHIVO_LOG = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "log_bateria.txt"
)


def fmt(x, decimales):
    return f"{x:.{decimales}f}" if x is not None else ""


def leer_temp_cpu():
    """Grados C, o None si el sensor no esta (ej. corriendo fuera de un
    Raspberry Pi real)."""
    rutas = glob.glob("/sys/class/thermal/thermal_zone*/temp")
    for ruta in rutas:
        try:
            with open(ruta) as f:
                return int(f.read().strip()) / 1000.0
        except Exception:
            continue
    return None


def leer_throttled():
    """Bitmask crudo de 'vcgencmd get_throttled' (ej. '0x50000'), o None
    si vcgencmd no esta disponible. Mismo bitmask usado a mano durante
    todo el debugging de undervoltage de este proyecto -- 0x0 = limpio."""
    try:
        salida = subprocess.run(
            ["vcgencmd", "get_throttled"], capture_output=True, text=True, timeout=5
        ).stdout.strip()
        return salida.split("=", 1)[1] if "=" in salida else None
    except Exception:
        return None


def leer_load_avg_1min():
    try:
        return os.getloadavg()[0]
    except Exception:
        return None


def main():
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")

    try:
        v_con, i_con = leer_ina219.leer(aislar_carga=False)
    except Exception as e:
        v_con, i_con = None, None
        print(f"ALERTA registrar_bateria: fallo lectura CON carga -- {e}", file=sys.stderr)

    try:
        v_sin, i_sin = leer_ina219.leer(aislar_carga=True)
    except Exception as e:
        v_sin, i_sin = None, None
        print(f"ALERTA registrar_bateria: fallo lectura SIN carga -- {e}", file=sys.stderr)

    temp_cpu = leer_temp_cpu()
    throttled = leer_throttled()
    load_avg = leer_load_avg_1min()

    # os.path.getsize, no solo os.path.exists: logrotate (ver
    # config/logrotate-tector) usa copytruncate, que deja el archivo
    # existiendo pero vacio (0 bytes) despues de rotar -- sin este
    # chequeo, el encabezado se perderia para siempre en la primera
    # rotacion.
    tiene_encabezado = os.path.exists(ARCHIVO_LOG) and os.path.getsize(ARCHIVO_LOG) > 0
    with open(ARCHIVO_LOG, "a") as f:
        if not tiene_encabezado:
            f.write(
                "timestamp,voltaje_con_carga_v,corriente_con_carga_ma,"
                "voltaje_sin_carga_v,corriente_sin_carga_ma,"
                "temp_cpu_c,throttled,load_avg_1min\n"
            )
        f.write(
            f"{timestamp},{fmt(v_con, 3)},{fmt(i_con, 1)},"
            f"{fmt(v_sin, 3)},{fmt(i_sin, 1)},"
            f"{fmt(temp_cpu, 1)},{throttled or ''},{fmt(load_avg, 2)}\n"
        )

    # chequeo_bateria.sh sigue parseando exactamente este formato -- la
    # decision de corte se toma SOLO con la lectura SIN CARGA.
    if v_sin is not None:
        print(f"Voltaje (pack): {v_sin:.3f} V")
        print(f"Corriente: {i_sin:.1f} mA")
    else:
        print("ERROR: no se pudo leer el INA219 en regimen SIN carga (ver stderr)")
        sys.exit(1)


if __name__ == "__main__":
    main()
