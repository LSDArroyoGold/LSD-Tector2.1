#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Escribe el resumen de un dia: una fila por deteccion, sin el audio.

POR QUE EXISTE
--------------
Hasta ahora el registro de una deteccion ERA su archivo de audio: la especie,
la confianza y la hora estan en el nombre del mp3, y tanto los scripts del
dispositivo como la app los sacan de ahi. No hay ninguna otra base de datos.

Eso funciona hasta el dia que el audio se borra por retencion. Ahi no se
pierde solo la posibilidad de escuchar: se pierde el dato. El histograma de
horarios, el ranking de especies y la riqueza acumulada de todo lo anterior
desaparecen con los archivos.

Este resumen separa las dos cosas. El audio es lo que se puede escuchar y
tiene un vencimiento; el resumen es el dato cientifico y no se borra nunca.

CUANTO PESA
-----------
Un dia tipico son ~60 detecciones. Como CSV, unos 5 KB. El mismo dia en audio
son ~50 MB. Cuatro ordenes de magnitud de diferencia: guardar el resumen para
siempre no cuesta nada.

Uso:
    python3 resumir_dia.py             # el dia de hoy
    python3 resumir_dia.py 2026-09-10  # un dia puntual
"""
import csv
import os
import re
import sys
from datetime import date
from pathlib import Path

BASE_PATH = Path(__file__).resolve().parent.parent
CONFIG_GENERAL = BASE_PATH / 'config' / 'config_general.txt'
SERIE_PATH = BASE_PATH / 'config' / 'serie.txt'

# Mismo patron que usan el servidor y los scripts de cierre. Acepta el nombre
# viejo (birdnet) y el nuevo (tectornet).
PATRON = re.compile(
    r'^(?P<especie>.+?)-(?P<confianza>\d{1,3})-'
    r'(?P<fecha>\d{4}-\d{2}-\d{2})-(?:birdnet|tectornet)-'
    r'(?P<hora>\d{2}:\d{2}:\d{2})\.(?:mp3|wav|flac)$')

COLUMNAS = ['fecha', 'hora', 'especie', 'confianza', 'serie', 'archivo',
            'bytes']


def leer_clave(archivo, clave):
    try:
        for linea in Path(archivo).read_text(encoding='utf-8').splitlines():
            linea = linea.strip()
            if linea.startswith('#') or '=' not in linea:
                continue
            k, v = linea.split('=', 1)
            if k.strip() == clave:
                return v.strip()
    except OSError:
        return None
    return None


def main():
    fecha = sys.argv[1] if len(sys.argv) > 1 else date.today().isoformat()
    if not re.fullmatch(r'\d{4}-\d{2}-\d{2}', fecha):
        print(f'Fecha invalida: {fecha}', file=sys.stderr)
        return 2

    usuario = os.environ.get('SUDO_USER') or os.environ.get('USER') or ''
    home = Path(os.environ.get('HOME') or Path.home())
    carpeta = home / 'BirdSongs' / 'Extracted' / 'By_Date' / fecha
    if not carpeta.is_dir():
        print(f'No hay detecciones de {fecha}.')
        return 0

    serie = leer_clave(SERIE_PATH, 'SERIE') or ''
    filas = []
    for archivo in sorted(carpeta.rglob('*')):
        if not archivo.is_file():
            continue
        m = PATRON.match(archivo.name)
        if not m:
            continue
        filas.append({
            'fecha': m.group('fecha'),
            'hora': m.group('hora'),
            'especie': m.group('especie').replace('_', ' '),
            'confianza': int(m.group('confianza')),
            'serie': serie,
            'archivo': archivo.name,
            'bytes': archivo.stat().st_size,
        })

    if not filas:
        print(f'No hay detecciones parseables en {fecha}.')
        return 0

    filas.sort(key=lambda f: f['hora'])
    destino = BASE_PATH / 'resumenes'
    destino.mkdir(exist_ok=True)
    salida = destino / f'{fecha}.csv'

    # utf-8-sig: estos CSV se terminan abriendo en Excel, y sin BOM los
    # nombres con acentos salen rotos.
    with open(salida, 'w', newline='', encoding='utf-8-sig') as f:
        w = csv.DictWriter(f, fieldnames=COLUMNAS)
        w.writeheader()
        w.writerows(filas)

    total_mb = sum(f['bytes'] for f in filas) / 1024 / 1024
    print(f'{salida.name}: {len(filas)} detecciones, '
          f'{len(set(f["especie"] for f in filas))} especies, '
          f'{total_mb:.0f} MB de audio, resumen de {salida.stat().st_size} bytes')
    return 0


if __name__ == '__main__':
    sys.exit(main())
