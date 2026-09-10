# -*- coding: utf-8 -*-
"""
Portal de configuracion WiFi que el Tector sirve en su red de setup.

CAMBIOS RESPECTO DE LA 2.0
--------------------------
1. La red de setup es ABIERTA (ver hotspot.sh). reactivar_hotspot() ya no
   pasa password.
2. El SSID lleva el numero de serie: Tector-####-setup. El portal lo muestra
   para que el usuario confirme que esta configurando el equipo que cree.
3. Identidad visual del proyecto (paleta, isotipo) en vez del HTML pelado.
4. Dos endpoints JSON nuevos, GET /info y GET /redes, y POST /configurar que
   ademas acepta JSON, para que la app pueda dibujar esta misma pantalla de
   forma nativa en vez de embeberla en un webview. El formulario HTML sigue
   existiendo igual para quien entra desde un navegador -- son dos caras de
   la misma cosa, no dos mecanismos distintos.

SOBRE LAS TIPOGRAFIAS
---------------------
Esta pagina se sirve en una red SIN internet: el Tector todavia no sabe
conectarse a ningun lado, esa es justamente la razon de que exista el
portal. Asi que no se puede pedir Space Grotesk a Google Fonts ni cargar
nada externo -- quedaria un fallback silencioso a Times New Roman. Se usa la
pila de fuentes del sistema, y el peso de la identidad lo llevan el isotipo,
la paleta y el espaciado, que si viajan con la pagina.
"""
import http.server
import json
import re
import subprocess
import threading
import time
import urllib.parse
from pathlib import Path

BASE_PATH = Path(__file__).resolve().parent.parent
SERIE_PATH = BASE_PATH / 'config' / 'serie.txt'
ISOTIPO_PATH = BASE_PATH / 'assets' / 'tector_isotipo.svg'


# ---------- UTILIDADES ----------

def leer_config(archivo, clave):
    try:
        with open(archivo, encoding='utf-8') as f:
            for linea in f:
                linea = linea.strip()
                if linea.startswith('#') or '=' not in linea:
                    continue
                k, v = linea.split('=', 1)
                if k.strip() == clave:
                    return v.strip()
    except OSError:
        return None
    return None


SERIE = leer_config(SERIE_PATH, 'SERIE') or '0000'
HOTSPOT_SSID = f'Tector-{SERIE}-setup'


def isotipo(alto=52):
    """El isotipo del proyecto, inline. Se le fija el alto y se reemplaza el
    color literal por currentColor para poder pintarlo desde CSS. Si el
    archivo no esta, la pagina se sirve igual, sin logo."""
    try:
        svg = ISOTIPO_PATH.read_text(encoding='utf-8')
    except OSError:
        return ''
    svg = re.sub(r'<\?xml[^>]*\?>', '', svg).strip()
    svg = re.sub(r'<title>.*?</title>', '', svg, flags=re.S)
    svg = svg.replace('stroke="#E85628"', 'stroke="currentColor"')
    svg = svg.replace('<svg ', f'<svg height="{alto}" aria-hidden="true" ', 1)
    return svg


def escanear_redes():
    subprocess.run(['sudo', 'nmcli', 'device', 'wifi', 'rescan'],
                   capture_output=True, text=True)
    time.sleep(3)
    result = subprocess.run(
        ['nmcli', '-t', '-f', 'SSID,SIGNAL,SECURITY', 'device', 'wifi', 'list'],
        capture_output=True, text=True
    )
    redes = []
    seen = set()
    for linea in result.stdout.strip().split('\n'):
        partes = linea.split(':')
        if len(partes) >= 2:
            ssid = partes[0].strip()
            # La propia red de setup no es un destino valido: si el usuario la
            # eligiera, el Tector intentaria conectarse a si mismo.
            if not ssid or ssid in seen or ssid == HOTSPOT_SSID:
                continue
            seen.add(ssid)
            signal = partes[1].strip() if len(partes) > 1 else '?'
            security = partes[2].strip() if len(partes) > 2 else ''
            redes.append((ssid, signal, security))
    redes.sort(key=lambda r: int(r[1]) if r[1].isdigit() else 0, reverse=True)
    return redes


def intentar_conexion(ssid, password):
    subprocess.run(['sudo', 'nmcli', 'connection', 'down', 'Hotspot'],
                   capture_output=True, text=True)
    time.sleep(3)

    subprocess.run(['sudo', 'nmcli', 'connection', 'delete', ssid],
                   capture_output=True, text=True)

    # Red destino abierta: sin clave no se puede pedir wpa-psk, nmcli
    # rechaza el add con "802-11-wireless-security.psk: property is invalid".
    orden = ['sudo', 'nmcli', 'connection', 'add',
             'type', 'wifi', 'ifname', 'wlan0',
             'con-name', ssid, 'ssid', ssid]
    if password:
        orden += ['802-11-wireless-security.key-mgmt', 'wpa-psk',
                  '802-11-wireless-security.psk', password]

    result_add = subprocess.run(orden, capture_output=True, text=True,
                                timeout=30)
    if result_add.returncode != 0:
        print(f'DEBUG add error: {result_add.stderr}')
        return False

    result_up = subprocess.run(['sudo', 'nmcli', 'connection', 'up', ssid],
                               capture_output=True, text=True, timeout=60)
    print(f'DEBUG up returncode: {result_up.returncode}')
    print(f'DEBUG up stderr: {result_up.stderr}')
    return result_up.returncode == 0


def reactivar_hotspot():
    """Vuelve a levantar la red de setup, ABIERTA.

    Tiene que quedar identica a levantar_hotspot() de hotspot.sh: si las dos
    difieren, el SSID o la seguridad cambian entre el primer intento y el
    reintento, y la app deja de reconocer la red que estaba esperando."""
    subprocess.run(['sudo', 'nmcli', 'connection', 'delete', 'Hotspot'],
                   capture_output=True, text=True)
    subprocess.run(
        ['sudo', 'nmcli', 'connection', 'add', 'type', 'wifi',
         'ifname', 'wlan0', 'con-name', 'Hotspot', 'autoconnect', 'no',
         'ssid', HOTSPOT_SSID,
         '802-11-wireless.mode', 'ap',
         '802-11-wireless.band', 'bg',
         'ipv4.method', 'shared',
         'ipv4.addresses', '192.168.4.1/24'],
        capture_output=True, text=True)
    subprocess.run(['sudo', 'nmcli', 'connection', 'up', 'Hotspot'],
                   capture_output=True, text=True)


# ---------- ESTILO ----------

CSS = """
:root{
  --paper:#F4F1E8; --card:#FFFFFF; --ink:#1F2A30; --ink2:#5A666D;
  --muted:#8A8578; --rule:#D9D3C4; --terra:#D76038; --teal:#2A5A78;
  --sunk:#EDE9DD;
}
*{box-sizing:border-box}
body{
  margin:0; padding:26px 18px 44px; background:var(--paper); color:var(--ink);
  font-family:system-ui,-apple-system,"Segoe UI",Roboto,"Helvetica Neue",sans-serif;
  font-size:16px; line-height:1.5; -webkit-text-size-adjust:100%;
}
.wrap{max-width:420px;margin:0 auto}
header{display:flex;align-items:center;gap:14px;margin-bottom:4px}
header svg{color:var(--terra);flex:none}
h1{font-size:21px;letter-spacing:-.02em;margin:0;font-weight:600}
.serie{font-family:ui-monospace,"SF Mono",Menlo,Consolas,monospace;
  font-size:13px;color:var(--muted);letter-spacing:.04em;margin:3px 0 0}
.lede{color:var(--ink2);font-size:15px;margin:18px 0 24px}
label.campo-lbl{display:block;font-size:11px;font-weight:700;letter-spacing:.1em;
  text-transform:uppercase;color:var(--muted);margin:0 0 7px}
select,input[type=text],input[type=password]{
  width:100%;padding:13px 12px;font-size:16px;font-family:inherit;
  color:var(--ink);background:var(--card);
  border:1px solid var(--rule);border-radius:7px;
  appearance:none;-webkit-appearance:none;
}
select{background-image:linear-gradient(45deg,transparent 50%,var(--muted) 50%),
  linear-gradient(135deg,var(--muted) 50%,transparent 50%);
  background-position:calc(100% - 19px) 22px,calc(100% - 14px) 22px;
  background-size:5px 5px,5px 5px;background-repeat:no-repeat;padding-right:38px}
select:focus,input:focus{outline:2px solid var(--terra);outline-offset:1px;
  border-color:var(--terra)}
.campo{margin-bottom:18px}
button{width:100%;padding:14px;font-size:16px;font-weight:600;font-family:inherit;
  color:#fff;background:var(--terra);border:0;border-radius:7px;cursor:pointer}
button:active{background:#B94E2C}
button.sec{background:transparent;color:var(--ink2);border:1px solid var(--rule);
  font-size:14px;padding:11px;margin-bottom:18px;font-weight:500}
.check{display:flex;align-items:center;gap:8px;margin-top:10px}
.check input{width:auto;margin:0}
.check label{font-size:14px;color:var(--ink2);margin:0}
.aviso{background:var(--sunk);border-radius:8px;padding:14px;
  font-size:14px;color:var(--ink2);margin-top:24px}
.aviso b{color:var(--ink);font-weight:600}
.paso{display:flex;gap:11px;margin-bottom:11px;align-items:flex-start}
.paso:last-child{margin-bottom:0}
.paso span{color:var(--teal);font-weight:700;flex:none;
  font-family:ui-monospace,Menlo,Consolas,monospace;font-size:13px;padding-top:1px}
.vacio{background:var(--card);border:1px dashed var(--rule);border-radius:7px;
  padding:18px 14px;text-align:center;color:var(--muted);font-size:14px}
footer{margin-top:30px;padding-top:16px;border-top:1px solid var(--rule);
  font-size:12px;color:var(--muted);line-height:1.55}
"""

PIE = ('<footer>Dispositivo desarrollado por el Laboratorio de Sistemas '
       'Dinámicos — FCEyN — UBA</footer>')


def pagina(titulo, cuerpo):
    return f"""<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{titulo}</title>
<style>{CSS}</style>
</head>
<body><div class="wrap">
<header>{isotipo()}<div>
  <h1>Configurar Tector</h1>
  <p class="serie">N.º {SERIE}</p>
</div></header>
{cuerpo}
{PIE}
</div></body>
</html>"""


def html_redes(redes):
    if redes:
        opciones = '\n'.join(
            '<option value="{0}">{1}{0} — {2}%</option>'.format(
                ssid, '🔒 ' if sec and sec != '--' else '', signal)
            for ssid, signal, sec in redes)
        campo_redes = f'<select name="ssid" id="ssid" required>{opciones}</select>'
    else:
        campo_redes = ('<div class="vacio">No se encontró ninguna red. '
                       'Actualizá la lista.</div>')

    return pagina('Configurar Tector', f"""
<p class="lede">Elegí la red WiFi a la que se va a conectar este Tector para
subir sus detecciones.</p>
<form method="POST" action="/configurar">
  <div class="campo">
    <label class="campo-lbl" for="ssid">Red disponible</label>
    {campo_redes}
  </div>
  <button type="button" class="sec" onclick="location.reload()">↻ Actualizar lista</button>
  <div class="campo">
    <label class="campo-lbl" for="password">Contraseña de la red</label>
    <input type="password" name="password" id="password" autocomplete="off">
    <div class="check">
      <input type="checkbox" id="ver" onclick="
        var p=document.getElementById('password');
        p.type = p.type === 'password' ? 'text' : 'password';">
      <label for="ver">Mostrar contraseña</label>
    </div>
  </div>
  <button type="submit">Conectar</button>
</form>""")


HTML_ESPERA = pagina('Conectando…', f"""
<p class="lede">Le pasamos las credenciales al Tector. Conectarse puede
tardar hasta dos minutos.</p>
<div class="aviso">
  <div class="paso"><span>OK</span><div>Si la conexión funciona, el Tector
    escribe <b>Conectado a…</b> en su log y sigue con su ciclo normal.</div></div>
  <div class="paso"><span>NO</span><div>Si falla, la red
    <b>{HOTSPOT_SSID}</b> vuelve a aparecer en tu lista de WiFi.
    Conectate de nuevo y reintentá.</div></div>
</div>""")


# ---------- SERVIDOR ----------

class Handler(http.server.BaseHTTPRequestHandler):

    def _responder(self, cuerpo, tipo='text/html; charset=utf-8', codigo=200):
        datos = cuerpo.encode('utf-8')
        self.send_response(codigo)
        self.send_header('Content-type', tipo)
        self.send_header('Content-Length', str(len(datos)))
        self.end_headers()
        self.wfile.write(datos)

    def do_GET(self):
        ruta = urllib.parse.urlparse(self.path).path

        # Para la app: confirmar con que dispositivo esta hablando ANTES de
        # mandarle credenciales.
        if ruta == '/info':
            return self._responder(
                json.dumps({'serie': SERIE, 'ssid_setup': HOTSPOT_SSID,
                            'version_portal': 2}),
                'application/json; charset=utf-8')

        # Para la app: las mismas redes que muestra el <select>, en JSON, para
        # que las dibuje con sus propios componentes.
        if ruta == '/redes':
            redes = escanear_redes()
            return self._responder(
                json.dumps({'redes': [
                    {'ssid': s, 'senal': int(g) if g.isdigit() else None,
                     'protegida': bool(sec and sec != '--')}
                    for s, g, sec in redes]}),
                'application/json; charset=utf-8')

        self._responder(html_redes(escanear_redes()))

    def do_POST(self):
        content_length = self.headers.get('Content-Length')
        if not content_length:
            self.send_response(302)
            self.send_header('Location', '/')
            self.end_headers()
            return

        crudo = self.rfile.read(int(content_length)).decode()
        tipo = self.headers.get('Content-Type') or ''

        # La app manda JSON; el formulario del navegador manda urlencoded.
        if tipo.startswith('application/json'):
            try:
                datos = json.loads(crudo)
            except ValueError:
                return self._responder('{"error":"json invalido"}',
                                       'application/json', 400)
            ssid = datos.get('ssid', '')
            password = datos.get('password', '')
            responder_json = True
        else:
            datos = urllib.parse.parse_qs(crudo)
            ssid = datos.get('ssid', [''])[0]
            password = datos.get('password', [''])[0]
            responder_json = False

        if not ssid:
            if responder_json:
                return self._responder('{"error":"falta ssid"}',
                                       'application/json', 400)
            return self._responder(html_redes(escanear_redes()))

        if responder_json:
            self._responder(json.dumps({'estado': 'intentando', 'ssid': ssid}),
                            'application/json; charset=utf-8')
        else:
            self._responder(HTML_ESPERA)
        self.wfile.flush()

        def cambiar_red():
            time.sleep(2)
            if intentar_conexion(ssid, password):
                import os
                os._exit(0)
            else:
                reactivar_hotspot()

        threading.Thread(target=cambiar_red).start()

    def log_message(self, format, *args):
        pass


if __name__ == '__main__':
    server = http.server.HTTPServer(('0.0.0.0', 5000), Handler)
    print(f'Portal de configuracion iniciado en puerto 5000 (Tector {SERIE})')
    server.serve_forever()
