# LSD-Tector 2.1 — Software

Este repositorio contiene todo el software necesario para replicar el sistema de monitoreo autónomo de aves LSD-Tector, desarrollado en el Laboratorio de Sistemas Dinámicos (LSD), Facultad de Ciencias Exactas y Naturales, Universidad de Buenos Aires.

El sistema gestiona automáticamente ventanas de grabación en horarios de amanecer y atardecer, identifica especies mediante BirdNET-Pi, y envía detecciones a Google Drive. Para una descripción completa del hardware y el diseño físico del dispositivo, referirse al artículo asociado.

Este software fue desarrollado y probado sobre una **Raspberry Pi 4 Model B (2GB RAM)**. No se garantiza compatibilidad con otros modelos o configuraciones de hardware.

> [!IMPORTANT]
> **Hardware en transición respecto al LSD-Tector 1.0/1.1.** Esta versión reemplaza la PiJuice HAT por un RTC externo **DS3231** + un latch propio (74HC74 + MOSFET P) para el corte/reposición física de alimentación, y un módulo **INA219** para medir batería por voltaje/corriente. Estado al 3/9/2026 (verificado en banco sobre tector2, todavía no probado en campo):
> - **La Raspberry sí se apaga y despierta sola entre ventanas.** El circuito DS3231+latch+MOSFET está armado y probado de punta a punta: `cierre_amanecer.sh`/`cierre_atardecer.sh` arman la alarma del RTC (`set_wake_rtc.py`) y recién ahí apagan (`sudo poweroff`, solo si la alarma quedó confirmada armada); el corte físico real lo hace `cortar-alimentacion.service` (pulso de GPIO al latch, se dispara justo antes del apagado final del kernel, nunca en un `reboot`).
> - **Hay monitoreo de batería activo.** `chequeo_bateria.sh` corre cada 5 min por cron, lee el INA219 (`python/leer_ina219.py`) y fuerza el cierre de la ventana (`CIERRE_FORZADO`) si el voltaje cae por debajo de `UMBRAL_BATERIA_V=6.9` — corte por voltaje puro, no por ningún porcentaje estimado (más robusto). Antes de cada lectura, un segundo circuito (aislador de carga MPPT, GPIO17) corta un instante la entrada del panel para que la medición sea siempre en descarga pura — sin esto, un rato de sol podía inflar la lectura más de 1V. Un % de batería más preciso para logs/dashboard (compensado por caída IR + curva empírica del pack, en vez de la curva genérica del datasheet) queda pendiente — no bloquea nada del funcionamiento, ver la nota completa en `config/config_general.txt`.

---


---

## Novedades de la 2.1

Esta versión es la 2.0 más lo que hacía falta para que exista **Tector Hub**,
la app móvil de administración. El ciclo de grabación, el corte por batería y
el manejo de energía no cambian.

### Número de serie

Cada dispositivo tiene ahora un identificador propio de 4 dígitos, asignado
por `install.sh` (`python/asignar_serie.py`) y guardado en `config/serie.txt`.

Se deriva del serial del SoC, no de un azar: el mismo hardware vuelve a
calcular el mismo número después de reflashear la microSD, así que la
etiqueta pegada en la caja sigue siendo válida. Como 4 dígitos son 10000
valores, dos equipos podrían colisionar; `python/registrar_dispositivo.py` lo
resuelve contra el servidor en el primer arranque con internet y reescribe el
número si hace falta.

`config/serie.txt` está en `.gitignore` y fuera de la lista de
`actualizar_repo.sh`, igual que `config_general.txt`: es estado real del
dispositivo, no plantilla.

### La red de setup cambió de nombre y ya no tiene contraseña

Antes: `Tector-Setup`, protegida con `lsdtector123`, igual en todos los
equipos. Ahora: **`Tector-<SERIE>-setup`**, abierta.

Los dos cambios apuntan a lo mismo. El SSID con serie deja que la app sepa con
qué dispositivo está hablando cuando hay más de uno en modo configuración. Y
la clave no protegía nada: estaba escrita en este repo, que es público, así
que solo agregaba un paso manual y obligaba a la app a llevarla embebida. La
exposición real es corta y acotada — el hotspot solo existe con
`FIRST_START=TRUE` o después de apretar el botón físico, y lo único que se
puede hacer desde él es indicarle al Tector a qué red conectarse.

> Ojo con el cambio de mecanismo: `nmcli device wifi hotspot` **siempre** pone
> seguridad — si no se le pasa contraseña, genera una al azar y la red queda
> protegida con una clave que nadie conoce. Para un AP abierto hay que armar
> el perfil con `nmcli connection add ... 802-11-wireless.mode ap` y no
> declarar ninguna sección `802-11-wireless-security`.

### El portal de configuración

`python/portal_configuracion.py` ahora usa la identidad visual del proyecto
(paleta, isotipo de `assets/tector_isotipo.svg`) y muestra el número de serie
del equipo que se está configurando.

No usa Space Grotesk: la página se sirve en una red sin internet, así que
cualquier fuente externa terminaría en un fallback silencioso. La identidad la
llevan el isotipo, la paleta y el espaciado, que sí viajan con la página.

Tres endpoints nuevos para que la app dibuje esta pantalla de forma nativa en
vez de embeberla en un webview:

| Endpoint | Devuelve |
|---|---|
| `GET /info` | `{serie, ssid_setup, version_portal}` — para confirmar el equipo antes de mandar credenciales |
| `GET /redes` | Las mismas redes del `<select>`, en JSON |
| `POST /configurar` | Acepta JSON además de urlencoded |

El formulario HTML sigue funcionando igual para quien entre desde un
navegador. Son dos caras de lo mismo, no dos mecanismos.

### estado.json

`scripts/publicar_estado.sh` sube a Drive una foto del dispositivo al abrir
ventana, al cerrarla y al terminar la configuración inicial: si está grabando,
cuál es la próxima ventana, los horarios vigentes, la última lectura de
batería, el SHA instalado y cuántas detecciones lleva hoy.

Existe porque hasta ahora la app habría tenido que reconstruir todo eso
parseando líneas de log en castellano con expresiones regulares. El log sigue
igual y sirve para leerlo a mano; `estado.json` es para que lo lea un programa.

### La configuración de la app se aplica más rápido

`cierre_*.sh` ya bajaba `config_horarios.txt` de Drive. Ahora `inicio_*.sh`
también lo baja al abrir la ventana, así que un cambio hecho desde la app
durante el día alcanza al cierre de esa misma ventana en vez de esperar hasta
la siguiente.

Lo que no cambia: la hora de **inicio** de una ventana ya se usó para
despertar al equipo, así que modificarla nunca puede aplicar retroactivamente
a la ventana en curso. La app lo dice explícitamente al confirmar.

### Nombre de archivo de las detecciones

El conteo de detecciones de `cierre_*.sh` ahora acepta `birdnet-` y
`tectornet-` en el nombre del archivo. El nombre lo genera
`scripts/exportador.py` del repo **TectorNet**, así que el cambio del lado que
escribe va allá; este repo queda listo para los dos, y los archivos históricos
que ya están en Drive se siguen contando bien.

### `SERVIDOR_URL`

Clave nueva en `config_general.txt`, vacía por defecto. Es la URL del servidor
de Tector Hub, y el dispositivo la usa para una sola cosa: registrarse y
resolver colisiones de número de serie.

**Dejarla vacía es una configuración válida y soportada.** El Tector graba,
detecta y sube a Drive exactamente igual; lo único que pierde es aparecer en
la app.

---
## Dependencias

- Raspberry Pi OS Lite 64-bit (Bookworm)
- BirdNET-Pi (ver paso 9; salteable si por ahora solo se quiere probar el software propio del LSD-Tector)
- [LSDTector-BirdNET-retrain-bsas](https://github.com/LSDArroyoGold/LSDTector-BirdNET-retrain-bsas) (clasificador reentrenado, opcional — ver paso 9.5)
- Python 3 (incluido en Raspberry Pi OS)
- rclone
- astral (librería Python) — instalada automáticamente por `install.sh`
- nmcli (incluido en Raspberry Pi OS)
- dnsmasq y util-linux-extra — instalados automáticamente por `install.sh`
- DS3231 (RTC externo, soportado nativamente por el kernel de Linux — no requiere ninguna librería propia)

### 1. Sistema operativo

Instalar **Raspberry Pi OS Lite 64-bit (Bookworm)** en la microSD usando [Raspberry Pi Imager](https://www.raspberrypi.com/software/). Durante el proceso de flasheo, en la sección de configuración avanzada del Imager (ícono del engranaje), crear un usuario con nombre y contraseña a elección, y habilitar SSH.

> [!NOTE]
> Se usa Lite y no Full: el dispositivo corre siempre headless (todo el manejo es por SSH/cron), y el entorno gráfico de Full no aporta nada salvo consumo de batería — en la v1.1 medimos ~19% de reducción real al sacarlo de encendido permanente. Arrancar directo con Lite evita ese ajuste manual.

> [!NOTE]
> Los scripts detectan automáticamente la ubicación del repositorio y el usuario del sistema, por lo que no es necesario usar un nombre de usuario específico ni una ruta fija. El repositorio puede clonarse en cualquier ubicación y con cualquier usuario.

Una vez flasheada la microSD, insertarla en la Raspberry Pi y encenderla.

### 2. Clonar el repositorio

Clonar este repositorio en la Raspberry Pi, en la ubicación deseada (por ejemplo, el directorio home del usuario):

```bash
cd ~
git clone https://github.com/LSDArroyoGold/LSD-Tector2.1.git
```

Los scripts se ejecutan directamente desde el repositorio, respetando su estructura de carpetas (`scripts/`, `python/`, `config/`, `systemd/`). No es necesario copiar ni mover archivos.

### 3. sudo sin contraseña

> [!IMPORTANT]
> Este paso no es opcional. Todo el sistema depende de que `cron` pueda ejecutar `sudo` (nmcli, systemctl, etc. en `inicio_*.sh`, `cierre_*.sh`, `hotspot.sh`) sin que haya nadie conectado para tipear una contraseña — el dispositivo corre desatendido en campo. También lo exige el instalador oficial de BirdNET-Pi (paso 9), que aborta si no lo detecta.

```bash
echo "$(whoami) ALL=(ALL) NOPASSWD: ALL" | sudo EDITOR="tee" visudo -f /etc/sudoers.d/010-lsd-nopasswd
sudo chmod 440 /etc/sudoers.d/010-lsd-nopasswd
sudo visudo -c
```

La tercera línea valida la sintaxis del archivo nuevo antes de confiar en él (evita dejar `sudo` roto por un error de tipeo). Verificar que funcionó:

```bash
sudo -n true && echo OK
```

### 4. Ejecutar el instalador

El script `install.sh` deja el sistema listo en una sola corrida: paquetes del sistema (`dnsmasq`, `util-linux-extra`), habilita I2C, agrega el overlay del DS3231, instala `astral`, da permisos de ejecución a los scripts, instala y habilita los servicios de systemd (`hotspot.service` y `sync-rtc.service`), instala el dispatcher de NetworkManager `90-sync-rtc`, y configura el crontab con las cinco tareas periódicas. Autodetecta la ubicación del repositorio y el usuario del sistema.

Ejecutarlo desde la raíz del repositorio, sin `sudo` (el script pide permisos de administrador solo donde los necesita):

```bash
cd ~/LSD-Tector2.0
./install.sh
```

Verificar que la instalación fue exitosa:

```bash
sudo systemctl status hotspot.service
sudo systemctl status sync-rtc.service
ls -la /etc/NetworkManager/dispatcher.d/90-sync-rtc
crontab -l
```

**Sincronización del RTC (DS3231), dos mecanismos complementarios** — ninguno depende de que una ventana amanecer/atardecer llegue a cerrar normalmente:

1. `sync-rtc.service` (systemd, `RTC → sistema`): corre una sola vez al bootear, carga en el reloj del sistema lo que el RTC tenga en ese momento. Es solo un mejor-esfuerzo de arranque — si el equipo perdió energía de golpe antes de la última escritura al RTC, esta carga puede quedar stale hasta que NTP corrija el reloj del sistema por su cuenta (systemd-timesyncd ya lo hace solo, sin intervención).
2. `90-sync-rtc` (dispatcher de NetworkManager, `sistema → RTC`): se dispara automáticamente cada vez que hay un evento de conectividad real (`up` o `connectivity-change`), espera a que `systemd-timesyncd` confirme sincronización NTP efectiva (no solo "hay wifi"), y recién ahí escribe la hora ya corregida al RTC — sin esperar al cierre de ventana. Verificado el 25/08: forzando el RTC a una fecha incorrecta y reconectando la wifi de verdad (no invocando el script a mano), el dispatcher lo corrigió solo en menos de 15 segundos.

Los servicios deben aparecer habilitados y el crontab debe listar las cinco tareas. Al final, el script avisa si hace falta reiniciar — la primera vez que se corre, sí (para activar el overlay del DS3231 recién agregado).

### 5. Reiniciar y verificar el DS3231

```bash
sudo reboot
```

Después de reconectarse por SSH, verificar que el DS3231 quedó reconocido como reloj de hardware:

```bash
ls /dev/rtc*
sudo hwclock -r
```

Debe listar `/dev/rtc0` (o `/dev/rtc1` si ya hay otro RTC registrado) y devolver la hora actual sin errores.

> [!NOTE]
> Si `/dev/rtc*` no aparece, lo más probable es que el módulo DS3231 no esté bien conectado físicamente (SDA/SCL/VCC/GND) — no suele ser un problema de configuración. `dmesg | grep rtc` mostrando `probe ... failed with error -5` confirma que el software está buscando el chip correctamente pero nadie responde en el bus I2C.

Si el reloj está muy desfasado (por ejemplo, si el módulo es nuevo y nunca se sincronizó), escribirle la hora del sistema una vez de forma manual:

```bash
sudo hwclock -w
```

> [!NOTE]
> La alarma del DS3231 la programa `python/set_wake_rtc.py`, llamado desde `cierre_amanecer.sh`/`cierre_atardecer.sh` antes de apagar — activo desde el 3/9/2026, ver la nota al principio de este README.

### 6. rclone

Instalar rclone:

```bash
sudo apt install rclone
```

**Autenticación con Google Drive**

La autenticación con Google requiere un navegador con interfaz gráfica. Como BirdNET-Pi ocupa el navegador de la Raspberry Pi, la autenticación se realiza desde una PC con Windows o Linux como intermediaria.

**En la PC intermediaria:**

1. Descargar rclone para el sistema operativo correspondiente desde [https://rclone.org/downloads/](https://rclone.org/downloads/)
2. Descomprimir el archivo
3. Abrir una terminal (PowerShell en Windows) en la carpeta donde se descomprimió rclone
4. Ejecutar el siguiente comando:

```bash
.\rclone.exe authorize "drive"
```

> **Nota:** en Linux o macOS el comando es `./rclone authorize "drive"`.

5. El navegador se abrirá automáticamente. Iniciar sesión con la cuenta de Google deseada y otorgar los permisos solicitados.
6. La terminal mostrará un token JSON entre llaves (`{...}`). Copiar el token completo, incluyendo las llaves.

**En la Raspberry Pi:**

Ejecutar el asistente de configuración:

```bash
rclone config
```

Seguir el asistente interactivo con las siguientes respuestas:

- `n` → crear una nueva configuración
- Nombre: `gdrive`
- Seleccionar el número correspondiente a **Google Drive** en la lista
- `client_id`: dejar vacío y presionar Enter
- `client_secret`: dejar vacío y presionar Enter
- Scope: opción `1` (acceso completo)
- `service_account_file`: dejar vacío y presionar Enter
- Configuración avanzada: `n`
- Autenticación desde este dispositivo (auto config): `n`
- Pegar el token JSON obtenido desde la PC intermediaria
- Configurar como shared drive: `n`
- Confirmar configuración: `y`
- Salir del asistente: `q`

> **Nota sobre `client_id` y `client_secret`:** dejarlos vacíos hace que rclone utilice las credenciales OAuth por defecto, que son compartidas entre todos los usuarios de rclone. En condiciones de uso intensivo esto puede ocasionalmente generar errores del tipo `429 Too Many Requests` por exceder los límites de cuota de Google. Para uso normal del LSD-Tector (subida de pocos archivos por día) esto no representa un problema. Si se desea utilizar credenciales propias, generar un Client ID y Client Secret en Google Cloud Console siguiendo la guía oficial de rclone: [https://rclone.org/drive/#making-your-own-client-id](https://rclone.org/drive/#making-your-own-client-id).

**Verificación**

Verificar que la conexión funciona correctamente listando las carpetas de Google Drive:

```bash
rclone lsd gdrive:
```

Si el comando devuelve la lista de carpetas existentes en la cuenta de Google, la configuración fue exitosa.

### 7. Archivos de configuración

Los archivos `config_general.txt` y `config_horarios.txt` se encuentran en la carpeta `config/` del repositorio. Editarlos según las necesidades del dispositivo.

**Editar `config_general.txt`:**

```bash
nano ~/LSD-Tector2.0/config/config_general.txt
```

El archivo contiene los siguientes parámetros:

| Parámetro | Descripción |
|---|---|
| `DRIVE_PATH` | Ruta de la carpeta en Google Drive donde se sincronizan datos y configuración. Puede ser una carpeta en la raíz (ej: `LSD-Tector`) o anidada (ej: `Proyectos/LSD/Tector`). |
| `FIRST_START` | Mantener en `TRUE` para activar el modo hotspot en el primer arranque. Una vez configurada la red WiFi exitosamente, el sistema lo cambia automáticamente a `FALSE`. Si el WiFi ya se configuró a mano (por ejemplo por SSH directo), poner en `FALSE` para no disparar el portal de configuración en el próximo arranque. |
| `HOTSPOT_SSID` | Nombre de la red WiFi de configuración que emite el dispositivo en el primer arranque. |
| `HOTSPOT_PASSWORD` | Contraseña de esa red WiFi de configuración. |
| `LAT` y `LON` | Coordenadas geográficas del lugar de instalación. Pueden dejarse con valores aproximados ya que se actualizan automáticamente mediante geolocalización por IP al utilizar el modo hotspot. |

> [!NOTE]
> Los parámetros energéticos de la v1.1 (`CONSUMO_W`, `CAPACIDAD_MAH`, `VOLTAJE_BATERIA`, `MARGEN_SEGURIDAD`, `UMBRAL_BATERIA`) no están en este archivo: dependían de la PiJuice y su corte predictivo, que este hardware no tiene. El esquema nuevo es reactivo por voltaje puro (`UMBRAL_BATERIA_V=6.9`, justificación completa al principio del archivo) vía `scripts/chequeo_bateria.sh` — activo desde el 3/9/2026, ver la nota al principio de este README.

**Editar `config_horarios.txt`:**

```bash
nano ~/LSD-Tector2.0/config/config_horarios.txt
```

El archivo contiene los siguientes parámetros:

| Parámetro | Descripción |
|---|---|
| `AUTO_SYNC` | Mantener en `ON` para que el sistema recalcule automáticamente los horarios al final de cada ventana, usando la librería `astral` y las coordenadas del archivo `config_general.txt`. |
| `OFFSET_AMANECER_SYNC` y `OFFSET_ATARDECER_SYNC` | Offset en minutos respecto al amanecer y atardecer astronómicos. Valores positivos retrasan el inicio de la ventana, negativos la adelantan. Si no se desea offset, utilizar `0`. |
| `DURACION_AMANECER_SYNC` y `DURACION_ATARDECER_SYNC` | Duración en horas de cada ventana de grabación. Reemplazar por la duración deseada (por ejemplo, `2` para una ventana de 2 horas). |
| `INICIO_AMANECER`, `FIN_AMANECER`, `INICIO_ATARDECER`, `FIN_ATARDECER` | Se usan solo si `AUTO_SYNC` está en `OFF`. Con `AUTO_SYNC=ON`, estos horarios se calculan y completan automáticamente con `astral` a partir de las coordenadas, las duraciones y los offsets. |

> **Importante:** en ambos archivos, las variables se escriben sin espacios alrededor del signo `=` (formato `CLAVE=valor`). No modificar los nombres de las variables.

**Verificación**

Una vez editados ambos archivos, verificar que el contenido quedó correcto:

```bash
cat ~/LSD-Tector2.0/config/config_general.txt
cat ~/LSD-Tector2.0/config/config_horarios.txt
```

Revisar que todos los valores fueron completados correctamente y que se respeta el formato `CLAVE=valor` sin espacios.

### 8. Crear carpetas en Google Drive y subir archivos de configuración

Crear las carpetas que utilizará el sistema en Google Drive, usando la ruta definida en `DRIVE_PATH` (en los ejemplos siguientes se asume `DRIVE_PATH=Laboratorio 7/Tector 2`, el valor real usado por este dispositivo):

```bash
rclone mkdir "gdrive:Laboratorio 7/Tector 2"
rclone mkdir "gdrive:Laboratorio 7/Tector 2/Detecciones"
```

Subir los archivos de configuración iniciales:

```bash
rclone copy ~/LSD-Tector2.0/config/config_horarios.txt "gdrive:Laboratorio 7/Tector 2/"
rclone copy ~/LSD-Tector2.0/config/config_general.txt "gdrive:Laboratorio 7/Tector 2/"
```

Verificar que los archivos fueron subidos correctamente:

```bash
rclone ls "gdrive:Laboratorio 7/Tector 2/"
```

La salida debe listar los dos archivos de configuración.

> **Nota:** la carpeta de Google Drive se define mediante `DRIVE_PATH` en `config_general.txt`. La subcarpeta `Detecciones` es fija, y las detecciones quedan ahí directamente organizadas en subcarpetas por fecha (heredadas de la estructura que ya usa BirdNET-Pi localmente).

Con esto, el software propio del LSD-Tector (WiFi, portal de configuración, sincronización con Drive, RTC) ya está completamente operativo. Los dos pasos que siguen son sobre BirdNET-Pi, opcionales para llegar a este punto.

### 9. BirdNET-Pi

BirdNET-Pi es el motor de grabación, análisis y extracción de detecciones: LSD-Tector no reimplementa nada de eso, se apoya en su pipeline (`birdnet_recording.service` + `birdnet_analysis.service`) y en su convención de carpetas (`BirdSongs/Extracted/By_Date/`), de la que dependen directamente `cierre_amanecer.sh` y `cierre_atardecer.sh` para subir las detecciones a Drive. También se usa su integración nativa con BirdWeather.

> [!NOTE]
> Si el objetivo inmediato es solo poner en marcha la Raspberry con el software propio del LSD-Tector y dejar BirdNET-Pi para después, este paso puede saltearse: nada de los pasos anteriores depende de que esté presente. Los scripts nuevos de este repositorio (`actualizar_modelo.sh`, el chequeo de salud en los `cierre_*.sh`) detectan que no está instalado y no hacen nada.

> [!NOTE]
> **Alternativa:** [`TectorNET-Pi`](https://github.com/LSDArroyoGold/TectorNET-Pi) (llamado `birdnet-lsd` hasta el 7/9/2026) es un motor de grabación y análisis propio, en reemplazo completo de BirdNET-Pi (no un complemento) -- resuelve la falta de confirmación entre ventanas de BirdNET-Pi (ver el README de ese repo para el detalle del problema y el diseño). Usa la misma convención de carpetas y nombre de archivo, así que `cierre_amanecer.sh`/`cierre_atardecer.sh` siguen funcionando sin cambios. Si está instalado (`TectorNET-Pi.service` presente, o todavía `birdnet-lsd.service` en un dispositivo que no pasó por el renombrado), este repositorio lo detecta solo: `inicio_amanecer.sh`/`inicio_atardecer.sh` actualizan su modelo y sesgo regional en vez de los de BirdNET-Pi (o corren el renombrado, si corresponde), y `cierre_amanecer.sh`/`cierre_atardecer.sh` chequean su salud en vez de (o además de, si ambos coexisten) la de `birdnet_recording.service`/`birdnet_analysis.service`. Sincroniza a BirdWeather y Drive por detección (no periódico) -- ver la sección de sincronización en su propio README.

Desde la terminal de la RP, ejecutar:

```bash
curl -s https://raw.githubusercontent.com/Nachtzuster/BirdNET-Pi/main/newinstaller.sh | bash
```

La instalación tarda varios minutos (y necesita `sudo` sin contraseña — ver paso 3). Una vez finalizada, BirdNET-Pi queda corriendo automáticamente y es accesible desde cualquier dispositivo en la misma red ingresando `http://[IP_de_la_RP]` en el navegador (antes de correr el paso 9.5, que apaga esa interfaz web para ahorrar batería). Para obtener la IP de la Raspberry Pi, ejecutar desde su terminal:

```bash
hostname -I
```

El primer valor que devuelve es la IP local del dispositivo.

### 9.5. Configurar BirdNET-Pi para uso desatendido, y cargar el modelo reentrenado

BirdNET-Pi instala por defecto un conjunto de servicios pensados para cuando alguien mira el dashboard desde el navegador en la misma red (streaming de audio en vivo, visor de espectrograma, gráficos, terminal web, panel de estadísticas). En un dispositivo desatendido en el campo no hay nadie mirando esos servicios, y miden un consumo real: apagarlos midió una reducción de **~19% en el consumo instantáneo** en pruebas de campo de la v1.1, sin afectar la grabación, el análisis ni la subida a BirdWeather, que no dependen de ninguno de ellos.

El script `configurar_birdnet.sh` hace esto de forma automática (apagar y enmascarar los servicios de dashboard/streaming, arrancar en modo consola, configurar la gestión de disco, y dejar `CONFIDENCE`/`SENSITIVITY` en los valores de partida para monitoreo continuo), y de paso pide el token de BirdWeather:

```bash
cd ~/LSD-Tector2.0
./scripts/configurar_birdnet.sh
```

Correrlo una sola vez, después de instalar BirdNET-Pi. El token de BirdWeather queda guardado en `birdnet.conf` (fuera de este repositorio, nunca se sube a GitHub).

> [!NOTE]
> El modelo reentrenado (las 193 especies locales, además del catálogo global de BirdNET sin modificar) se instala aparte, automáticamente, mediante `actualizar_modelo.sh`: se corre solo en cada ventana de grabación (junto con `actualizar_repo.sh`) y actualiza el `.tflite` cada vez que hay una versión nueva en [`LSDTector-BirdNET-retrain-bsas`](https://github.com/LSDArroyoGold/LSDTector-BirdNET-retrain-bsas), sin necesidad de reinstalar nada a mano. Para forzarlo de inmediato en vez de esperar a la próxima ventana: `bash ~/LSD-Tector2.0/scripts/actualizar_modelo.sh`.

> [!NOTE]
> Además del modelo universal, `LSDTector-BirdNET-retrain-bsas` permite generar una versión ajustada a la región del dispositivo: a cada una de las 193 especies locales se le suma un sesgo según su frecuencia real de observación en esa región (nunca la descarta, solo la refuerza o atenúa). Corre solo, vía `scripts/aplicar_ajuste_regional.sh` (agregado junto a `actualizar_modelo.sh` en `inicio_amanecer.sh`/`inicio_atardecer.sh`), pero necesita el entorno `~/birdnet-v2-env` (`bash instalar.sh` dentro de un clon de `LSDTector-BirdNET-retrain-bsas`). Prioriza un archivo de frecuencias ya descargado a mano y versionado en ese repositorio (sin conexión a eBird desde el dispositivo); si todavía no existe para la región y se cargó `EBIRD_API_KEY` en `config_general.txt` (opcional, ver advertencia de uso comercial en ese repositorio), usa la API pública de eBird como respaldo. Sin ninguna de las dos cosas, sigue con el modelo universal sin ajustar, que es siempre el comportamiento por defecto.

> [!NOTE]
> `LATITUDE`/`LONGITUDE` en `birdnet.conf` (usadas por BirdNET-Pi para su filtro de especies plausibles por región y época) se sincronizan automáticamente con `LAT`/`LON` de `config_general.txt` cuando corre `hotspot.sh` — es decir, recién en el primer arranque con `FIRST_START=TRUE` (paso 7), o si el WiFi se configuró por ese camino. Si el WiFi se configuró a mano (SSH directo, sin pasar por el portal), `birdnet.conf` queda con las coordenadas por defecto del instalador de BirdNET-Pi hasta que se corrijan manualmente: `sudo nano ~/BirdNET-Pi/birdnet.conf`, buscar `LATITUDE`/`LONGITUDE`.

---

## Primer arranque en campo

Una vez completados todos los pasos de instalación, el dispositivo está listo para ser desplegado en campo. El procedimiento de primer arranque es el siguiente:

1. Verificar que en `config_general.txt` el parámetro `FIRST_START` está en `TRUE`.
2. Encender la Raspberry Pi. Esperar aproximadamente 30 segundos a que el sistema arranque completamente y se active el servicio `hotspot.service`.
3. Desde un celular o computadora, buscar redes WiFi disponibles. Conectarse a la red de configuración (nombre y contraseña definidos en `HOTSPOT_SSID` y `HOTSPOT_PASSWORD` de `config_general.txt`).
4. Abrir un navegador web y navegar a `http://192.168.4.1:5000`. Se mostrará el portal de configuración.
5. Seleccionar de la lista la red WiFi a la que se conectará el dispositivo en campo. Ingresar la contraseña correspondiente. Presionar **Conectar**.
6. El dispositivo se desconecta del modo hotspot e intenta conectarse a la red indicada. Si la conexión es exitosa:
   - Las coordenadas geográficas se actualizan automáticamente mediante geolocalización por IP (y se propagan a `birdnet.conf` si BirdNET-Pi está instalado).
   - Los horarios de amanecer y atardecer se calculan y se escriben en `config_horarios.txt`.
   - El parámetro `FIRST_START` se cambia a `FALSE`.
   - El dispositivo calcula el horario de la próxima ventana de grabación y **queda encendido** (todavía no hay circuito de corte de energía — ver la nota al principio de este README).
7. Si la conexión falla, la red de configuración vuelve a aparecer automáticamente. Reconectarse y reintentar con las credenciales correctas.

A partir de este momento, el dispositivo opera de forma autónoma siguiendo el ciclo programado de ventanas de grabación, permaneciendo encendido de forma continua entre ellas.

> [!NOTE]
> Si el WiFi ya se configuró a mano durante la instalación (por ejemplo, por SSH directo sin pasar por el portal), este procedimiento no hace falta: dejar `FIRST_START=FALSE` y el dispositivo arranca operando directamente, sin intentar levantar el hotspot.

---

## Control remoto via Google Drive

Una vez el dispositivo está en operación en campo, los archivos `config_horarios.txt` y `config_general.txt` en la carpeta de Google Drive definida por `DRIVE_PATH` pueden editarse desde cualquier lugar para modificar la configuración del dispositivo. Los cambios se aplican en el siguiente ciclo, cuando el dispositivo descarga la versión actualizada de Drive al final de la ventana de grabación.

El archivo `log_sistema.txt` se sube a Drive al final de cada ventana y permite monitorear el estado del dispositivo de forma remota: cantidad de detecciones registradas y eventuales cierres sin conectividad. El campo de batería en cada entrada figura como `N/A` hasta que el INA219 esté instalado — ver la nota al principio de este README.

Si BirdNET-Pi está instalado, cada cierre de ventana también chequea que `birdnet_recording.service` y `birdnet_analysis.service` sigan activos, y deja una línea `ALERTA: servicios de BirdNET-Pi caidos: ...` en el log si alguno se cayó. systemd ya los reinicia solo (`Restart=always`), así que esta alerta no es para arreglarlos: es para enterarse por Drive de un problema persistente sin tener que esperar a volver al campo y notar la falta de detecciones. Si en cambio el motor instalado es `TectorNET-Pi`, el mismo chequeo aplica sobre `TectorNET-Pi.service` (`ALERTA: TectorNET-Pi.service caido`) -- o, en un dispositivo que todavía no pasó por el renombrado, sobre `birdnet-lsd.service` (`ALERTA: birdnet-lsd.service caido`).

Junto con `log_sistema.txt` también se sube `log_reciente.txt`, con el mismo contenido pero filtrado a solo los últimos 2 días — pensado para revisar la actividad reciente sin tener que scrollear todo el historial completo.
