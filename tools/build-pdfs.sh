#!/bin/bash
# Regenere les PDF a partir des sources HTML de docs/pdf-src/ (necessite Google Chrome).
# Usage : bash tools/build-pdfs.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
[ -x "$CHROME" ] || { echo "Google Chrome introuvable (definir CHROME=/chemin/vers/chrome)"; exit 1; }
render() { # render source.html sortie.pdf
    "$CHROME" --headless=new --disable-gpu --no-pdf-header-footer --print-to-pdf="$ROOT/$2" "file://$ROOT/docs/pdf-src/$1" >/dev/null 2>&1
    echo "OK  $2 ($(du -k "$ROOT/$2" | cut -f1) Ko)"
}
render guide.html TimeCapsule_RPi_Bridge_Guide_FR_EN.pdf
if [ -f "$ROOT/docs/pdf-src/tuto.html" ]; then render tuto.html Tuto_Raspberry_Pi_Serveur_Maison.pdf; fi
