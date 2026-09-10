#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BASE_PATH="$(dirname "$SCRIPT_DIR")"
AUTO_SYNC=$(awk -F'=' '/AUTO_SYNC/{print $2}' "$BASE_PATH/config/config_horarios.txt" | tr -d "\r")
if [ "$AUTO_SYNC" = "ON" ]; then
	python3 "$BASE_PATH/python/calcular_horarios.py"
fi
