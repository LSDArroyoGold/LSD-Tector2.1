#!/bin/bash
#
# actualizar_modelo.sh - Mantiene al dia el clasificador de BirdNET
# reentrenado (LSDTector-BirdNET-retrain-bsas), sin tocar el resto de
# BirdNET-Pi.
#
# Mismo patron que actualizar_repo.sh: compara el SHA del ultimo commit del
# repo del modelo via la API de GitHub, y si cambio, descarga los dos
# archivos (.tflite y _Labels.txt) via raw.githubusercontent.com. No
# requiere git ni credenciales en el dispositivo, solo HTTPS de salida.
#
# El archivo .tflite pesa varias decenas de MB, asi que esto solo hace
# trabajo real cuando el modelo efectivamente cambio (SHA distinto); en
# cualquier otra corrida sale de inmediato.
#
# No hace nada si BirdNET-Pi no esta instalado todavia (instalacion
# opcional por ahora, ver README).

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BASE_PATH="$(dirname "$SCRIPT_DIR")"

REAL_USER="${SUDO_USER:-$(whoami)}"
USER_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

BIRDNET_PI_DIR="$USER_HOME/BirdNET-Pi"
BIRDNET_MODEL_DIR="$BIRDNET_PI_DIR/model"

if [ ! -d "$BIRDNET_MODEL_DIR" ]; then
	# BirdNET-Pi no esta instalado todavia. Nada que hacer.
	exit 0
fi

REPO="LSDArroyoGold/LSDTector-BirdNET-retrain-bsas"
RAW="https://raw.githubusercontent.com/$REPO/main"
API="https://api.github.com/repos/$REPO/commits/main"
MARCA="$BASE_PATH/.ultima_actualizacion_modelo"
TMP="$BASE_PATH/.actualizar_modelo_tmp"

# Nombres tal cual los espera BirdNET-Pi (scripts/utils/models.py de
# BirdNET-Pi carga el modelo V2.4 por este nombre fijo): reemplazando estos
# dos archivos, con estos mismos nombres, BirdNET-Pi usa nuestro modelo sin
# ningun cambio de codigo de su lado.
DESTINO_TFLITE="$BIRDNET_MODEL_DIR/BirdNET_GLOBAL_6K_V2.4_Model_FP16.tflite"
DESTINO_LABELS="$BIRDNET_MODEL_DIR/BirdNET_GLOBAL_6K_V2.4_Model_FP16_Labels.txt"

ULTIMO_SHA=$(cat "$MARCA" 2>/dev/null)
SHA_ACTUAL=$(curl -s "$API" | python3 -c "import sys,json; print(json.load(sys.stdin)['sha'])" 2>/dev/null)

if [ -z "$SHA_ACTUAL" ] || [ "$SHA_ACTUAL" = "$ULTIMO_SHA" ]; then
	exit 0
fi

rm -rf "$TMP"
mkdir -p "$TMP"

if ! curl -sf -o "$TMP/modelo.tflite" "$RAW/modelo/LSDTector_Classifier_v2.tflite"; then
	echo "Fallo la descarga del .tflite, aborto sin tocar el modelo actual" >&2
	rm -rf "$TMP"
	exit 1
fi

if ! curl -sf -o "$TMP/modelo_labels.txt" "$RAW/modelo/LSDTector_Classifier_v2_Labels.txt"; then
	echo "Fallo la descarga de las labels, aborto sin tocar el modelo actual" >&2
	rm -rf "$TMP"
	exit 1
fi

# Mismo filesystem que BIRDNET_MODEL_DIR (ambos bajo el home del usuario):
# el mv es un rename atomico, no deja al modelo a medio escribir si algo
# se corta en el medio.
mv "$TMP/modelo.tflite" "$DESTINO_TFLITE"
mv "$TMP/modelo_labels.txt" "$DESTINO_LABELS"
rm -rf "$TMP"

# TectorNET-Pi (repo aparte) puede estar reemplazando a BirdNET-Pi como
# motor de analisis en este dispositivo, en cuyo caso este servicio ya no
# existe -- el resto de este script (actualizar el .tflite/labels dentro
# de BirdNET-Pi) sigue corriendo igual, solo el reinicio queda condicionado.
if systemctl list-unit-files birdnet_analysis.service &>/dev/null; then
	sudo systemctl restart birdnet_analysis.service
fi

echo "$SHA_ACTUAL" > "$MARCA"

python3 "$BASE_PATH/python/log_sistema.py" MSG "Modelo de BirdNET actualizado ($SHA_ACTUAL)"
