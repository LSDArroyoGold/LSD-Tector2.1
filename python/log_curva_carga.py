#!/usr/bin/env python3
# log_curva_carga.py - RETIRADO/SUPERADO el 4/9/2026, mismo dia que se
# agrego: chequeo_bateria.sh + registrar_bateria.py hacen ahora lo mismo
# (y mas: lectura dual con/sin carga, no solo sin carga) de forma
# permanente y unificada, sin necesitar este script aparte -- ver
# config/config_general.txt. Sacado del crontab, se deja el archivo en el
# repo solo de referencia historica, no volver a agregarlo al cron.
#
# --- descripcion original, ya no aplica tal cual ---
# registra voltaje/corriente del pack cada vez que se lo llama, para
# reconstruir la curva de carga real mientras el MPPT esta cargando de
# verdad. EXPLORATORIO/TEMPORAL -- no es parte de la instalacion
# permanente (no esta en install.sh ni en actualizar_repo.sh a
# proposito), se agrega y se saca del crontab a mano cuando hace falta.
# Pensado para correr cada 5 min por cron:
#   */5 * * * * python3 /home/lsd/LSD-Tector2.0/python/log_curva_carga.py
#
# Reusa leer_ina219.leer() tal cual (con aislamiento de carga MPPT antes de
# medir, ver ese archivo) -- cada punto de esta curva es la tension real
# del pack en descarga pura, no inflada por la corriente de carga entrando
# en ese instante.

import csv
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import leer_ina219

ARCHIVO = "/home/lsd/curva_carga.csv"


def main():
    existe = os.path.exists(ARCHIVO)

    try:
        voltaje_v, corriente_ma = leer_ina219.leer(aislar_carga=True)
        error = ""
    except Exception as e:
        voltaje_v, corriente_ma = None, None
        error = str(e)

    with open(ARCHIVO, "a", newline="") as f:
        w = csv.writer(f)
        if not existe:
            w.writerow(["timestamp", "voltaje_v", "corriente_ma", "error"])
        w.writerow([
            time.strftime("%Y-%m-%d %H:%M:%S"),
            f"{voltaje_v:.3f}" if voltaje_v is not None else "",
            f"{corriente_ma:.1f}" if corriente_ma is not None else "",
            error,
        ])


if __name__ == "__main__":
    main()
