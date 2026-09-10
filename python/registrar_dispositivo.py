#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Registra este Tector contra el servidor de Tector Hub, y resuelve colisiones
de numero de serie.

Corre desde hotspot.sh, apenas la conexion WiFi quedo levantada -- es el
primer momento en la vida del dispositivo en que hay internet. Tambien lo
llama chequeo_bateria.sh de vez en cuando, para que un equipo que se
registro cuando el servidor estaba caido lo reintente solo.

QUE HACE
--------
POST {SERVIDOR_URL}/dispositivos/registrar con {serie, id_hardware}.

El servidor responde una de tres cosas:

  {"estado": "ok", "serie": "4417"}
      El numero propuesto estaba libre, o ya era de este mismo hardware.
      No se toca nada.

  {"estado": "reasignado", "serie": "4418"}
      Otro hardware ya tenia ese numero. El servidor eligio uno libre y
      este script reescribe config/serie.txt con el nuevo. El SSID de setup
      pasa a usar el numero nuevo en el proximo arranque en modo hotspot.

  HTTP != 200, o sin red
      No se cambia nada y se sale con codigo 1. El dispositivo sigue
      funcionando con el numero derivado del hardware; lo unico que no pasa
      es quedar visible en la app. Se reintenta despues.

Este script NO es un requisito para operar: un Tector sin servidor
configurado (SERVIDOR_URL vacio) graba, detecta y sube a Drive igual que
siempre. Solo pierde la parte de administracion remota.

Uso:
    python3 registrar_dispositivo.py           # registra, silencioso
    python3 registrar_dispositivo.py --verboso # imprime que paso
"""
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path

BASE_PATH = Path(__file__).resolve().parent.parent
CONFIG_GENERAL = BASE_PATH / 'config' / 'config_general.txt'
SERIE_PATH = BASE_PATH / 'config' / 'serie.txt'

sys.path.insert(0, str(BASE_PATH / 'python'))
from asignar_serie import leer_serie, _id_hardware  # noqa: E402

TIMEOUT_S = 15


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


def reescribir_serie(nueva):
    """Reemplaza SOLO la linea SERIE, como pide la convencion del proyecto
    (nunca sobreescribir un archivo de estado entero -- ver la advertencia
    en config/config_general.txt)."""
    lineas = SERIE_PATH.read_text(encoding='utf-8').splitlines(keepends=True)
    salida = []
    for linea in lineas:
        if linea.split('=', 1)[0].strip() == 'SERIE':
            salida.append(f'SERIE={nueva}\n')
        else:
            salida.append(linea)
    SERIE_PATH.write_text(''.join(salida), encoding='utf-8')


def main():
    verboso = '--verboso' in sys.argv

    def decir(msg):
        if verboso:
            print(msg)

    servidor = leer_clave(CONFIG_GENERAL, 'SERVIDOR_URL')
    if not servidor:
        decir('SERVIDOR_URL vacio: no hay nada que registrar.')
        return 0

    serie = leer_serie()
    if serie is None:
        print('No hay numero de serie asignado. Corre install.sh primero.',
              file=sys.stderr)
        return 2

    id_hw, _ = _id_hardware()
    # DRIVE_PATH viaja en el registro porque es lo unico que le falta al
    # servidor para poder leer las detecciones y el estado de este equipo.
    # Sin esto el servidor sabria que el Tector existe pero no donde mirar.
    drive_path = leer_clave(CONFIG_GENERAL, 'DRIVE_PATH')
    cuerpo = json.dumps({'serie': serie, 'id_hardware': id_hw,
                         'drive_path': drive_path}).encode()

    pedido = urllib.request.Request(
        servidor.rstrip('/') + '/dispositivos/registrar',
        data=cuerpo,
        headers={'Content-Type': 'application/json'},
        method='POST')

    try:
        with urllib.request.urlopen(pedido, timeout=TIMEOUT_S) as resp:
            datos = json.loads(resp.read().decode())
    except (urllib.error.URLError, OSError, ValueError) as e:
        decir(f'No se pudo registrar ({e}). Se reintenta despues.')
        return 1

    estado = datos.get('estado')

    if estado == 'reasignado':
        nueva = datos.get('serie', '')
        if not (nueva.isdigit() and len(nueva) == 4):
            decir(f'El servidor devolvio un serie invalido: {nueva!r}')
            return 1
        reescribir_serie(nueva)
        decir(f'Numero de serie reasignado por colision: {serie} -> {nueva}')
        # Lo dejamos en el log del sistema: es un cambio de identidad del
        # dispositivo y tiene que quedar rastro.
        import subprocess
        subprocess.run(
            ['python3', str(BASE_PATH / 'python' / 'log_sistema.py'), 'MSG',
             f'Numero de serie reasignado por colision: {serie} -> {nueva}'],
            capture_output=True)
        return 0

    if estado == 'ok':
        decir(f'Registrado como Tector {datos.get("serie", serie)}.')
        return 0

    decir(f'Respuesta inesperada del servidor: {datos!r}')
    return 1


if __name__ == '__main__':
    sys.exit(main())
