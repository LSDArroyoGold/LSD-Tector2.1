# Lectura directa del INA219 por I2C (sin la libreria pi-ina219 -- esa
# depende de Adafruit_GPIO, que falla al arrancar en la Pi 4 con kernels
# nuevos: "RuntimeError: Could not determine default I2C bus for platform"
# porque su deteccion de hardware esta desactualizada. Confirmado el
# 3/9/2026 en tector2. Esto de aca es mas simple igual: el protocolo del
# INA219 son 4 registros de 16 bits, no hace falta una libreria para eso.
#
# Antes de cada lectura, corta un instante la carga MPPT->BMS a traves del
# aislador de carga (74HC-- no, en este caso es un PNP+MOSFET, ver
# esquematico "Aislador de Carga MPPT") pulsando GPIO17 -- asi la lectura
# de tension queda SIEMPRE en regimen de descarga pura (consumo real del
# sistema, sin aporte del panel), sin importar si en ese instante hay sol
# entrando o no. Es el mismo regimen en el que se va a calibrar la curva de
# % (pendiente, ver config/config_general.txt) -- sin esto, una lectura
# tomada mientras carga daria una tension inflada por sobre la real, y el
# umbral de corte de bateria (que compara contra esta misma lectura) podria
# leer "todo bien" con el pack en un estado real mucho peor.
#
# El default seguro de ese aislador (nadie manejando GPIO17) es "carga
# conectada" -- lo sostienen R1/R2 solas, sin ayuda de la Pi (ver la nota
# en config_general.txt sobre por que el default de este circuito no puede
# depender de que la Pi este prendida). El pulso de corte de aca es la
# UNICA intervencion activa, dura menos de un segundo y medio, y se libera
# siempre pase lo que pase (try/finally) -- nunca se deja la carga cortada
# si algo de la lectura falla.

import smbus2
import time
import RPi.GPIO as GPIO

ADDR = 0x40  # direccion I2C default del INA219 (el DS3231 esta en 0x68,
             # mismo bus 1, sin conflicto)
BUS_NUM = 1

# Calibracion estandar del datasheet para shunt=0.1ohm (el valor tipico de
# estos modulos -- confirmar contra la placa propia si difiere), rango
# maximo ~3.2A: current_LSB = 100uA,
# cal = trunc(0.04096 / (100e-6 * 0.1)) = 4096
CAL = 4096
CURRENT_LSB_MA = 0.1  # mA por cuenta, con la calibracion de arriba

# Config register: 0x399F = rango 16V, ganancia shunt /8 (320mV), ADC de
# 12 bits, conversion continua de bus+shunt. Valor estandar del datasheet.
CONFIG_VALUE = 0x399F

PIN_AISLADOR = 17  # BCM -- base de Q1 del aislador de carga MPPT, ver
                   # esquematico. GPIO en 0V = corta la carga; suelto/alto
                   # (default) = carga conectada.
ASENTAMIENTO_S = 1.0  # espera despues de cortar, antes de leer -- tiempo
                       # de asentamiento del transitorio propio de la
                       # bateria al cambiar de regimen (carga->descarga
                       # pura), no es instantaneo.


def _cortar_carga():
    GPIO.setmode(GPIO.BCM)
    GPIO.setwarnings(False)
    GPIO.setup(PIN_AISLADOR, GPIO.OUT, initial=GPIO.HIGH)
    GPIO.output(PIN_AISLADOR, GPIO.LOW)


def _restablecer_carga():
    # Se libera a entrada (alta impedancia), no se deja manejado en alto --
    # el default seguro de este circuito (carga conectada) lo sostienen
    # R1/R2 del lado del hardware solas. A proposito NO se imita el patron
    # de cortar_alimentacion.py (que si deja el pin manejado activamente en
    # todo momento) -- ese circuito y este tienen defaults de seguridad
    # opuestos por diseño (uno depende de la Pi, el otro no puede depender
    # de ella), ver la nota en config_general.txt.
    GPIO.setup(PIN_AISLADOR, GPIO.IN)


def leer(bus_num=BUS_NUM, addr=ADDR, aislar_carga=True):
    """Devuelve (voltaje_V, corriente_mA). Por defecto corta la carga MPPT
    un instante antes de medir (ver notas de arriba) para que la lectura
    sea siempre en descarga pura. Pasar aislar_carga=False para leer tal
    cual, sin tocar el GPIO del aislador (por ejemplo, para diagnostico del
    propio circuito de corte, o si el aislador todavia no esta instalado)."""
    if aislar_carga:
        _cortar_carga()
        time.sleep(ASENTAMIENTO_S)

    try:
        bus = smbus2.SMBus(bus_num)
        try:
            bus.write_i2c_block_data(addr, 0x00, [CONFIG_VALUE >> 8, CONFIG_VALUE & 0xFF])
            bus.write_i2c_block_data(addr, 0x05, [(CAL >> 8) & 0xFF, CAL & 0xFF])
            time.sleep(0.05)  # tiempo de conversion del ADC

            raw_v = bus.read_i2c_block_data(addr, 0x02, 2)
            v_val = (raw_v[0] << 8) | raw_v[1]
            if v_val & 0x1:
                raise RuntimeError("INA219: overflow en la medicion de bus voltage")
            voltaje_v = ((v_val >> 3) * 4) / 1000

            raw_i = bus.read_i2c_block_data(addr, 0x04, 2)
            i_val = (raw_i[0] << 8) | raw_i[1]
            if i_val > 32767:
                i_val -= 65536
            corriente_ma = i_val * CURRENT_LSB_MA

            return voltaje_v, corriente_ma
        finally:
            bus.close()
    finally:
        if aislar_carga:
            _restablecer_carga()


if __name__ == "__main__":
    import sys

    aislar = "--sin-aislar" not in sys.argv
    v, i = leer(aislar_carga=aislar)
    print(f"Voltaje (pack): {v:.3f} V" + ("" if aislar else " (SIN aislar carga)"))
    print(f"Corriente: {i:.1f} mA")
