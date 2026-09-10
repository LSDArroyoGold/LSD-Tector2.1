import RPi.GPIO as GPIO
import subprocess
import os
from pathlib import Path

BASE_PATH = Path(__file__).resolve().parent.parent
CONFIG_GENERAL = BASE_PATH / 'config' / 'config_general.txt'

GPIO.setmode(GPIO.BCM)
GPIO.setwarnings(False)
GPIO.setup(24, GPIO.IN, pull_up_down=GPIO.PUD_DOWN)
if GPIO.input(24) == 1:
    # Resetear latch
    GPIO.setup(25, GPIO.OUT)
    GPIO.output(25, GPIO.LOW)
    import time; time.sleep(0.1)
    GPIO.output(25, GPIO.HIGH)
    GPIO.cleanup()

    # Marcar FIRST_START y reiniciar
    subprocess.run(['sed', '-i', 's/FIRST_START=.*/FIRST_START=TRUE/',
                   str(CONFIG_GENERAL)])
    subprocess.run(['sudo', 'reboot'])
else:
    GPIO.cleanup()
