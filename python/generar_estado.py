#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Escribe estado.json: la foto del dispositivo que lee la app.

POR QUE EXISTE
--------------
La app no puede preguntarle nada al Tector: el equipo esta apagado entre
ventanas, y cuando esta despierto vive detras del router de quien lo hospeda.
Todo lo que la app sabe, lo sabe por Drive.

Hasta ahora a Drive subian detecciones y logs. El log alcanza para
reconstruir el estado a fuerza de parsear texto en castellano con regex --
fragil, y ademas obliga a la app a conocer el formato de cada linea. Este
archivo es el reemplazo: un JSON chico, estable, pensado para que lo lea un
programa.

Lo escribe publicar_estado.sh en tres momentos: al abrir ventana, al
cerrarla, y al terminar la configuracion inicial en hotspot.sh.

SOBRE LA ANTIGUEDAD DEL DATO
----------------------------
'generado' es cuando el Tector escribio esto, no cuando la app lo leyo.
Entre ventanas el equipo esta fisicamente apagado, asi que este archivo
SIEMPRE esta viejo cuando la app lo mira -- eso es normal, no una falla. La
app decide si un Tector esta mudo comparando 'generado' con
'proxima_ventana': recien cuando paso una ventana entera sin que el archivo
se actualice hay algo que reportar.
"""
import csv
import json
import subprocess
from datetime import datetime
from pathlib import Path

BASE_PATH = Path(__file__).resolve().parent.parent
CONFIG_GENERAL = BASE_PATH / 'config' / 'config_general.txt'
CONFIG_HORARIOS = BASE_PATH / 'config' / 'config_horarios.txt'
SERIE_PATH = BASE_PATH / 'config' / 'serie.txt'
LOG_BATERIA = BASE_PATH / 'log_bateria.txt'
MARCA_SHA = BASE_PATH / '.ultima_actualizacion'
SALIDA = BASE_PATH / 'estado.json'


def leer_claves(archivo):
    """Todas las claves KEY=valor de un archivo de config del proyecto."""
    datos = {}
    try:
        for linea in Path(archivo).read_text(encoding='utf-8').splitlines():
            linea = linea.strip()
            if linea.startswith('#') or '=' not in linea:
                continue
            k, v = linea.split('=', 1)
            datos[k.strip()] = v.strip()
    except OSError:
        pass
    return datos


def ultima_bateria():
    """Ultima fila de log_bateria.txt, o None. Se lee por encabezado y no por
    posicion: las filas viejas tienen menos columnas a proposito (ver la nota
    en registrar_bateria.py)."""
    try:
        with open(LOG_BATERIA, newline='', encoding='utf-8') as f:
            filas = list(csv.DictReader(f))
    except (OSError, csv.Error):
        return None
    if not filas:
        return None
    fila = filas[-1]

    def num(clave):
        try:
            return float(fila.get(clave) or '')
        except ValueError:
            return None

    return {
        'timestamp': fila.get('timestamp'),
        'voltaje_v': num('voltaje_sin_carga_v'),
        'corriente_ma': num('corriente_sin_carga_ma'),
        'temp_cpu_c': num('temp_cpu_c'),
        # 0x0 es "limpio". Cualquier otra cosa es undervoltage o throttling
        # real, y la app lo muestra como alerta.
        'throttled': fila.get('throttled') or None,
    }


def detecciones_de_hoy(usuario_home):
    """Cuantos mp3 exporto el motor hoy. Mismo criterio que usan
    cierre_amanecer/atardecer.sh para el conteo que va al log."""
    carpeta = Path(usuario_home) / 'BirdSongs' / 'Extracted' / 'By_Date' / \
        datetime.now().strftime('%Y-%m-%d')
    try:
        return sum(1 for _ in carpeta.rglob('*.mp3'))
    except OSError:
        return 0


def sha_instalado():
    try:
        return MARCA_SHA.read_text().strip()[:7] or None
    except OSError:
        return None


def proxima_ventana(horarios, ventana_activa):
    """(etiqueta, HH:MM) de la proxima ventana que abre. Si hay una ventana
    en curso, devuelve esa misma con su hora de fin."""
    ahora = datetime.now().strftime('%H:%M')
    ini_am = horarios.get('INICIO_AMANECER', '')
    ini_at = horarios.get('INICIO_ATARDECER', '')

    if ventana_activa == 'amanecer':
        return 'amanecer', horarios.get('FIN_AMANECER', '')
    if ventana_activa == 'atardecer':
        return 'atardecer', horarios.get('FIN_ATARDECER', '')

    if ini_am and ahora < ini_am:
        return 'amanecer', ini_am
    if ini_at and ahora < ini_at:
        return 'atardecer', ini_at
    return 'amanecer', ini_am  # ya pasaron las dos: manana temprano


def main():
    general = leer_claves(CONFIG_GENERAL)
    horarios = leer_claves(CONFIG_HORARIOS)
    serie = leer_claves(SERIE_PATH).get('SERIE')

    ventana_activa = general.get('VENTANA_ACTIVA', 'NONE')
    grabando = ventana_activa not in ('', 'NONE')
    etiqueta, hora = proxima_ventana(horarios, ventana_activa)

    import os
    home = os.environ.get('HOME') or str(Path.home())

    estado = {
        'version_formato': 1,
        'serie': serie,
        'generado': datetime.now().isoformat(timespec='seconds'),

        # Lo que la app muestra al lado del nombre del dispositivo.
        'estado': 'grabando' if grabando else 'en_espera',
        'ventana_activa': ventana_activa if grabando else None,
        'proxima_ventana': {'cual': etiqueta, 'hora': hora},
        'cierre_forzado': general.get('CIERRE_FORZADO') == 'TRUE',

        'horarios': {
            'auto_sync': horarios.get('AUTO_SYNC') == 'ON',
            'amanecer': {'inicio': horarios.get('INICIO_AMANECER'),
                         'fin': horarios.get('FIN_AMANECER')},
            'atardecer': {'inicio': horarios.get('INICIO_ATARDECER'),
                          'fin': horarios.get('FIN_ATARDECER')},
            'duracion_amanecer_h': horarios.get('DURACION_AMANECER_SYNC'),
            'duracion_atardecer_h': horarios.get('DURACION_ATARDECER_SYNC'),
            'offset_amanecer_min': horarios.get('OFFSET_AMANECER_SYNC'),
            'offset_atardecer_min': horarios.get('OFFSET_ATARDECER_SYNC'),
        },

        'ubicacion': {'lat': general.get('LAT'), 'lon': general.get('LON')},
        'bateria': ultima_bateria(),
        'umbral_bateria_v': general.get('UMBRAL_BATERIA_V'),
        'detecciones_hoy': detecciones_de_hoy(home),
        'version_software': sha_instalado(),
        'drive_path': general.get('DRIVE_PATH'),
    }

    SALIDA.write_text(json.dumps(estado, indent=2, ensure_ascii=False) + '\n',
                      encoding='utf-8')
    print(f'estado.json escrito ({estado["estado"]})')


if __name__ == '__main__':
    main()
