import sys
from pathlib import Path
from datetime import datetime

BASE_PATH = Path(__file__).resolve().parent.parent
LOG_SISTEMA = BASE_PATH / 'log_sistema.txt'

timestamp = datetime.now().strftime('%Y-%m-%d %H:%M')
evento = sys.argv[1]

# Mensaje libre: no requiere lectura de batería
if evento == 'MSG':
    mensaje = sys.argv[2]
    linea = f"[{timestamp}] {mensaje}\n"
else:
    # PENDIENTE: nivel de bateria vía INA219. La v1.1 leía pj.status.GetChargeLevel()
    # de la PiJuice acá. Sin PiJuice y sin el INA219 armado todavía (falta el
    # battery pack), no hay forma de medir batería, así que el campo queda en
    # 'N/A' hasta que se instale. Cuando esté: leer el voltaje/corriente del
    # INA219 (I2C), estimar el nivel de carga, y volver a poner el valor real
    # en `nivel` como hacía la v1.1.
    nivel = 'N/A'
    ventana = sys.argv[2]

    if evento == 'FIN':
        proxima_ventana = sys.argv[3]
        detecciones = sys.argv[4] if len(sys.argv) > 4 else '0'
        linea = f"[{timestamp}] FIN ventana {ventana} | Batería: {nivel} | Detecciones subidas: {detecciones} | Próxima ventana: {proxima_ventana}\n"
    elif evento == 'CANCELADA':
        linea = f"[{timestamp}] VENTANA cancelada - {ventana} | Batería: {nivel}\n"
    elif evento == 'SIN_CONEXION':
        proxima_ventana = sys.argv[3]
        detecciones = sys.argv[4] if len(sys.argv) > 4 else '0'
        linea = f"[{timestamp}] FIN ventana {ventana} | SIN CONEXIÓN, archivos se subirán en la próxima ventana | Batería: {nivel} | Detecciones: {detecciones} | Próxima ventana: {proxima_ventana}\n"
    else:
        fin_esperado = sys.argv[3]
        linea = f"[{timestamp}] INICIO ventana {ventana} | Batería: {nivel} | Fin esperado: {fin_esperado}\n"

with open(LOG_SISTEMA,'a') as f:
    f.write(linea)
print(linea.strip())
