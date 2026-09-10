import subprocess
import sys
import time

import RPi.GPIO as GPIO

# Maneja el pin que controla /CLR1 del latch (74HC74 + MOSFET P, ver tabla
# de pines del circuito -- R2 lo mantiene alto en reposo con un pull-up
# externo). Pulsarlo a bajo fuerza el RESET del latch, que corta el MOSFET
# y saca los 5V que alimentan a la Pi entera -- incluida esta misma linea
# de GPIO.
#
# Se invoca via cortar-alimentacion.service, en sus DOS puntas:
#   - ExecStart (al bootear): "armar" -- deja el pin manejado activamente
#     en alto por la propia Pi, todo el tiempo que esta prendida.
#   - ExecStop (justo antes del apagado final del kernel, cuando systemd ya
#     termino de sincronizar y desmontar todo): sin argumentos -- pulsa a
#     bajo un instante y corta.
#
# Por que "armar" hace falta y no alcanza con dejar el pin en reposo/sin
# tocar: si nadie maneja GPIO6 activamente, el pin queda en el estado que
# le toque por default al arrancar Linux (podria ser entrada flotante, con
# quien sabe que pull interno del SoC) -- eso compite contra R2 y deja la
# linea en una tension intermedia, ni claramente alta ni baja, en vez de un
# alto limpio. Midiendo en banco el 3/9: VCC=5.18V pero pin1 (/CLR1) leia
# 4.18V con la Pi manejando el pin sin este fix -- justo ese tipo de
# ambiguedad que puede disparar el latch mal.

PIN_CLR1 = 6  # BCM -- /CLR1 del 74HC74, ver tabla de pines del circuito
DURACION_PULSO_S = 0.3  # el 74HC74 necesita nanosegundos, esto sobra por lejos

GPIO.setmode(GPIO.BCM)
GPIO.setwarnings(False)
# No se llama GPIO.cleanup() en ningun punto de este archivo a proposito:
# eso libera el pin a entrada flotante, exactamente lo que NO queremos --
# el estado (OUT, HIGH o LOW segun corresponda) tiene que persistir a nivel
# de hardware aunque el proceso de Python termine.
GPIO.setup(PIN_CLR1, GPIO.OUT, initial=GPIO.HIGH)

if len(sys.argv) > 1 and sys.argv[1] == "armar":
    # Llamado al bootear (ExecStart): ya quedo en alto por el setup() de
    # arriba. Nada mas que hacer -- el pin sigue manejado por la Pi de
    # forma persistente de aca en mas, sin necesidad de que este proceso
    # siga vivo.
    sys.exit(0)

subprocess.run(
    ["logger", "-t", "cortar-alimentacion", "pulsando GPIO6 para cortar alimentacion"]
)

GPIO.output(PIN_CLR1, GPIO.LOW)
time.sleep(DURACION_PULSO_S)

# Si todo salio bien, la alimentacion ya se cortó y este proceso se
# interrumpe antes de llegar aca. Si llegamos hasta este punto (banco de
# pruebas sin la placa conectada, corte que no ocurrio, etc.) devolvemos
# GPIO6 a alto -- manejado activamente, no liberado.
GPIO.output(PIN_CLR1, GPIO.HIGH)

subprocess.run(
    ["logger", "-t", "cortar-alimentacion",
     "el pulso termino y la Pi sigue con energia -- el corte no se disparo"]
)
