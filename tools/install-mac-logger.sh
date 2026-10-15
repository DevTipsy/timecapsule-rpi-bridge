#!/bin/bash
# Installe (ou retire avec --uninstall) le journal Time Machine du Mac : un LaunchAgent utilisateur,
# sans sudo, qui lance tools/mac-tm-logger.sh toutes les 10 minutes.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APPDIR="$HOME/Library/Application Support/TimeCapsuleBridge"
PLIST="$HOME/Library/LaunchAgents/com.timecapsule-bridge.mac-logger.plist"
LABEL="com.timecapsule-bridge.mac-logger"
if [ "${1:-}" = "--uninstall" ]; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST" "$APPDIR/mac-tm-logger.sh"; echo "Journal Time Machine du Mac désinstallé (les logs restent dans ~/Library/Logs/TimeCapsuleBridge)."; exit 0
fi
mkdir -p "$APPDIR" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/TimeCapsuleBridge"
# copié hors de Documents : macOS demanderait sinon une autorisation d'accès aux dossiers
install -m 755 "$HERE/mac-tm-logger.sh" "$APPDIR/mac-tm-logger.sh"
cat > "$PLIST" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$APPDIR/mac-tm-logger.sh</string></array>
  <key>StartInterval</key><integer>600</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/TimeCapsuleBridge/agent-stderr.log</string>
</dict></plist>
P
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installé. Logs : ~/Library/Logs/TimeCapsuleBridge/ (tm-events.log, mac-env.log). Retirer : bash tools/install-mac-logger.sh --uninstall"
