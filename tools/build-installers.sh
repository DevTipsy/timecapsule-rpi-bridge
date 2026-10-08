#!/bin/bash
# Construit les zips "novices" : installers/TimeCapsule-Bridge-macOS.zip et -Windows.zip
# Usage : bash tools/build-installers.sh   (a relancer apres toute modification de install.sh / scripts / configs)
# Les zips sont reproductibles (dates fixes, ordre fixe) : pas de diff inutile dans git si rien n'a change.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/installers"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

to_crlf() { sed 's/$/\r/' "$1" > "$2"; }

build() { # build macOS|Windows
    local os=$1 dir="$STAGE/TimeCapsule-Bridge-$1"
    mkdir -p "$dir/payload"
    ( cd "$ROOT" && tar --exclude='.DS_Store' -cf - install.sh scripts configs ) | tar -xf - -C "$dir/payload" 2>/dev/null
    if [ "$os" = macOS ]; then
        install -m 755 "$OUT/macos/Installer-macOS.command" "$dir/Installer-macOS.command"
        cp "$OUT/LISEZ-MOI-macOS.txt" "$dir/LISEZ-MOI.txt"
    else
        to_crlf "$OUT/windows/Installer-Windows.bat" "$dir/Installer-Windows.bat"
        { printf '\xEF\xBB\xBF'; sed 's/$/\r/' "$OUT/windows/Installer-Windows.ps1"; } > "$dir/Installer-Windows.ps1"   # BOM UTF-8 + CRLF pour PowerShell 5.1
        to_crlf "$OUT/LISEZ-MOI-Windows.txt" "$dir/LISEZ-MOI.txt"
    fi
    find "$dir" -exec touch -t 202601010000 {} +
    rm -f "$OUT/TimeCapsule-Bridge-$os.zip"
    ( cd "$STAGE" && find "TimeCapsule-Bridge-$os" -type f | LC_ALL=C sort | zip -X -q -@ "$OUT/TimeCapsule-Bridge-$os.zip" )
    echo "OK  installers/TimeCapsule-Bridge-$os.zip ($(du -k "$OUT/TimeCapsule-Bridge-$os.zip" | cut -f1) Ko)"
}
build macOS
build Windows
