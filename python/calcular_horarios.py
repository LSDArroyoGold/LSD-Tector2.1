from astral import LocationInfo
from astral.sun import sun
from datetime import date, timedelta
from pathlib import Path
import subprocess

# Autodeteccion de rutas: el script vive en <repo>/python/, el config en <repo>/config/
BASE_PATH = Path(__file__).resolve().parent.parent
CONFIG_GENERAL = BASE_PATH / 'config' / 'config_general.txt'
CONFIG_HORARIOS = BASE_PATH / 'config' / 'config_horarios.txt'

# Leer coordenadas desde config_general.txt
def leer_config(archivo, clave):
    with open(archivo) as f:
        for linea in f:
            if clave + '=' in linea:
                return linea.split('=',1)[1].strip()

# Las coordenadas salen de config_general.txt (las de instalacion), SALVO que
# config_horarios.txt traiga LAT= y LON=: ese archivo lo escribe la app de
# Tector Hub y el equipo lo baja de Drive, asi que es la unica forma de
# cambiarlas a distancia (config_general.txt no se sincroniza). Si lo que
# viene no es un numero, se ignora y se sigue con las de instalacion: un
# valor roto no puede dejar al equipo sin horarios.
def coordenadas():
    try:
        lat = float(leer_config(CONFIG_HORARIOS, 'LAT'))
        lon = float(leer_config(CONFIG_HORARIOS, 'LON'))
        if -90 <= lat <= 90 and -180 <= lon <= 180:
            return lat, lon
    except (TypeError, ValueError):
        pass
    return (float(leer_config(CONFIG_GENERAL, 'LAT')),
            float(leer_config(CONFIG_GENERAL, 'LON')))

LAT, LON = coordenadas()

DURACION_AMANECER = float(leer_config(CONFIG_HORARIOS, 'DURACION_AMANECER_SYNC'))
DURACION_ATARDECER = float(leer_config(CONFIG_HORARIOS, 'DURACION_ATARDECER_SYNC'))

OFFSET_AMANECER = float(leer_config(CONFIG_HORARIOS, 'OFFSET_AMANECER_SYNC'))
OFFSET_ATARDECER = float(leer_config(CONFIG_HORARIOS, 'OFFSET_ATARDECER_SYNC'))

DRIVE_PATH = leer_config(CONFIG_GENERAL, 'DRIVE_PATH')

# Calcular horarios de hoy y mañana
ubicacion = LocationInfo(latitude=LAT, longitude=LON)
hoy = sun(ubicacion.observer, date=date.today())
manana = sun(ubicacion.observer, date=date.today() + timedelta(days=1))

#Le resto 3 por el huso horario de Argentina

inicio_atardecer = (hoy['sunset'] - timedelta(hours=3) + timedelta(minutes=OFFSET_ATARDECER)).strftime('%H:%M')
fin_atardecer = (hoy['sunset'] - timedelta(hours=3) + timedelta(hours=DURACION_ATARDECER) + timedelta(minutes=OFFSET_ATARDECER)).strftime('%H:%M')
inicio_amanecer = (manana['sunrise'] - timedelta(hours=3) + timedelta(minutes=OFFSET_AMANECER)).strftime('%H:%M')
fin_amanecer = (manana['sunrise'] - timedelta(hours=3) + timedelta(hours=DURACION_AMANECER) + timedelta(minutes=OFFSET_AMANECER)).strftime('%H:%M')

print(f"inicio_atardecer = {inicio_atardecer}")
print(f"fin_atardecer = {fin_atardecer}")
print(f"inicio_amanecer = {inicio_amanecer}")
print(f"fin_amanecer = {fin_amanecer}")

import re

with open(CONFIG_HORARIOS,'r') as f:
    contenido = f.read()

contenido = re.sub(r'INICIO_AMANECER=.*', f'INICIO_AMANECER={inicio_amanecer}', contenido)
contenido = re.sub(r'FIN_AMANECER=.*', f'FIN_AMANECER={fin_amanecer}', contenido)
contenido = re.sub(r'INICIO_ATARDECER=.*', f'INICIO_ATARDECER={inicio_atardecer}', contenido)
contenido = re.sub(r'FIN_ATARDECER=.*', f'FIN_ATARDECER={fin_atardecer}', contenido)

with open(CONFIG_HORARIOS,'w') as f:
    f.write(contenido)

import subprocess
subprocess.run(['rclone', 'copy', str(CONFIG_HORARIOS), f'gdrive:{DRIVE_PATH}/'])

print("config_horarios.txt actualizado y subido a Drive")
