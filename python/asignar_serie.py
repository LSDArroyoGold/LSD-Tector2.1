#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Asigna el numero de serie de 4 digitos de este Tector.

Se corre UNA sola vez, desde install.sh, antes del primer arranque. El
numero queda en config/serie.txt y no se vuelve a tocar: actualizar_repo.sh
no lo sincroniza y .gitignore lo excluye, igual que config_general.txt.

POR QUE DERIVADO DEL HARDWARE Y NO ALEATORIO
--------------------------------------------
El numero de serie tiene que existir ANTES de que el dispositivo tenga
internet: es parte del SSID de la red de setup (Tector-####-setup), que es
justamente lo que el Tector levanta cuando todavia no sabe conectarse a
ninguna red. Asi que no puede pedirselo a un servidor -- tiene que poder
calcularlo offline, solo.

Derivarlo del serial del SoC (y no de /dev/urandom) tiene ademas una
propiedad que pidio el proyecto: si se reflashea la microSD, el mismo
dispositivo fisico vuelve a calcular el mismo numero. La etiqueta pegada en
la caja sigue siendo valida despues de reinstalar de cero.

COLISIONES
----------
4 digitos son 10000 valores. Con N dispositivos la probabilidad de que dos
compartan numero es ~N^2/20000: despreciable con 20 equipos (~2%), real si
la red crece a cientos. Por eso el numero derivado del hardware es una
PROPUESTA, no la ultima palabra: en el primer arranque con internet,
registrar_dispositivo.py lo registra contra el servidor y, si ya estaba
tomado por otro hardware, el servidor devuelve uno libre y este archivo se
reescribe. La ventana de ambiguedad es el rato en que el equipo esta en
modo setup, donde el SSID todavia muestra el numero propuesto -- y ahi el
unico riesgo es que dos Tectors en modo setup a la vez, en el mismo lugar,
muestren el mismo SSID. La app contempla ese caso (pantalla S9).

Uso:
    python3 asignar_serie.py            # asigna si no existe, no pisa nada
    python3 asignar_serie.py --mostrar  # imprime el serie actual y sale
    python3 asignar_serie.py --forzar N # fija un numero a mano (migracion)
"""
import hashlib
import sys
from pathlib import Path

BASE_PATH = Path(__file__).resolve().parent.parent
SERIE_PATH = BASE_PATH / 'config' / 'serie.txt'


def _id_hardware():
    """Devuelve (identificador_estable, de_donde_salio).

    En orden de preferencia. Los dos primeros son del SoC y sobreviven a un
    reflasheo de la microSD; los ultimos dos no, y estan solo para que el
    script no falle en hardware que no sea una Raspberry (por ejemplo, al
    probar el repo en una VM).
    """
    try:
        for linea in Path('/proc/cpuinfo').read_text().splitlines():
            if linea.lower().startswith('serial'):
                valor = linea.split(':', 1)[1].strip()
                if valor and set(valor) != {'0'}:
                    return valor, 'cpuinfo'
    except OSError:
        pass

    try:
        valor = Path('/sys/firmware/devicetree/base/serial-number')\
            .read_bytes().decode('ascii', 'ignore').strip('\x00 \n')
        if valor:
            return valor, 'devicetree'
    except OSError:
        pass

    try:
        valor = Path('/etc/machine-id').read_text().strip()
        if valor:
            return valor, 'machine-id'
    except OSError:
        pass

    import uuid
    return f'{uuid.getnode():012x}', 'mac'


def calcular_serie(id_hw):
    """4 digitos con cero a la izquierda. sha256 y no hash() de Python:
    hash() de un str esta salteado por proceso (PYTHONHASHSEED) y daria un
    numero distinto en cada corrida."""
    digest = hashlib.sha256(id_hw.encode()).hexdigest()
    return f'{int(digest, 16) % 10000:04d}'


def leer_serie():
    """El numero ya asignado, o None si todavia no se asigno."""
    try:
        for linea in SERIE_PATH.read_text().splitlines():
            linea = linea.strip()
            if linea.startswith('#') or '=' not in linea:
                continue
            clave, valor = linea.split('=', 1)
            if clave.strip() == 'SERIE':
                valor = valor.strip()
                return valor if valor else None
    except OSError:
        return None
    return None


def escribir_serie(serie, id_hw, origen):
    SERIE_PATH.parent.mkdir(parents=True, exist_ok=True)
    SERIE_PATH.write_text(
        '# Numero de serie de este Tector. Se asigna una sola vez, en la\n'
        '# instalacion (python/asignar_serie.py, llamado por install.sh) y no\n'
        '# se vuelve a tocar. NO esta en la lista de actualizar_repo.sh ni se\n'
        '# commitea: es estado real de este dispositivo, como config_general.txt.\n'
        '#\n'
        '# Si hay que cambiarlo (colision detectada por el servidor, o una\n'
        '# migracion a mano), reescribir SOLO la linea SERIE con sed, igual que\n'
        '# con cualquier otra clave de configuracion de este proyecto.\n'
        f'SERIE={serie}\n'
        '\n'
        '# Solo para trazabilidad -- de donde salio el numero la primera vez.\n'
        f'ORIGEN={origen}\n'
        f'ID_HARDWARE={id_hw}\n',
        encoding='utf-8')


def main():
    args = sys.argv[1:]

    if '--mostrar' in args:
        serie = leer_serie()
        if serie is None:
            print('SIN_ASIGNAR', file=sys.stderr)
            return 1
        print(serie)
        return 0

    id_hw, origen = _id_hardware()

    if '--forzar' in args:
        i = args.index('--forzar')
        if i + 1 >= len(args):
            print('Falta el numero despues de --forzar', file=sys.stderr)
            return 2
        try:
            serie = f'{int(args[i + 1]):04d}'
        except ValueError:
            print('El numero de serie tiene que ser numerico', file=sys.stderr)
            return 2
        if len(serie) != 4:
            print('El numero de serie tiene que ser de 4 digitos', file=sys.stderr)
            return 2
        escribir_serie(serie, id_hw, 'manual')
        print(serie)
        return 0

    ya = leer_serie()
    if ya is not None:
        # Idempotente a proposito: install.sh se puede volver a correr sobre
        # un dispositivo ya instalado sin cambiarle la identidad.
        print(ya)
        return 0

    serie = calcular_serie(id_hw)
    escribir_serie(serie, id_hw, origen)
    print(serie)
    return 0


if __name__ == '__main__':
    sys.exit(main())
