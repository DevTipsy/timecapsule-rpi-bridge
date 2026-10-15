#!/bin/bash
# Journal durable de Time Machine sur le MAC (le système n'en garde que ~19 h en détail).
# Lancé toutes les 10 min par un LaunchAgent (voir tools/install-mac-logger.sh). Sans sudo.
#
# Écrit dans ~/Library/Logs/TimeCapsuleBridge/ :
#   tm-events.log  les décisions de Time Machine : démarrage, destination choisie, montage,
#                  test d'écriture, passes de copie, échecs (une ligne par message)
#   mac-env.log    une ligne d'état toutes les 10 min : sauvegarde en cours ?, le Pi répond-il
#                  (DNS, ping, port SMB), partage monté, dernier snapshot, veille bloquée ?
# Réglage : TC_PI_HOST (défaut raspberrypi.local)
PI_HOST="${TC_PI_HOST:-raspberrypi.local}"
DIR="$HOME/Library/Logs/TimeCapsuleBridge"; mkdir -p "$DIR"
EVENTS="$DIR/tm-events.log"; ENVLOG="$DIR/mac-env.log"; STATE="$DIR/.last-run"
NOW_ISO=$(date +"%Y-%m-%dT%H:%M:%S%z")

# ---- 1. décisions de Time Machine depuis la dernière exécution
if [ -r "$STATE" ]; then START=$(cat "$STATE"); else START=$(date -v-1H +"%Y-%m-%d %H:%M:%S"); fi
NEW_STATE=$(date +"%Y-%m-%d %H:%M:%S")
/usr/bin/log show --info --start "$START" --style compact \
  --predicate 'process == "backupd" AND subsystem == "com.apple.TimeMachine" AND (category == "BackupScheduling" OR category == "MountedDestinationManager" OR category == "IOCheck" OR category == "FileProtection" OR category == "CopyProgress" OR category == "BackupDispatching" OR category == "BackupCopier" OR eventMessage CONTAINS[c] "failed" OR eventMessage CONTAINS[c] "skip")' 2>/dev/null \
  | grep -v "^Timestamp" \
  | sed -E 's/^([0-9-]+ [0-9:.]+) +([A-Z]) +[a-zA-Z]+\[[0-9:a-f]+\] \[com.apple.TimeMachine:([A-Za-z]+)\] /\1 \2 [\3] /' \
  | grep -vE "Starting age based thinning|Unmounted local snapshot|Unmounted '/Volumes/com.apple.TimeMachine.localsnapshots" \
  | awk '
      /^[[:space:]]/ { if ($0 ~ /Elapsed time/) print; next }            # lignes de statistiques : seulement la durée finale
      /\[CopyProgress\]/ && !/Finished copying|Starting/ { next }          # progression : on garde seulement la fin des copies
      /\[FileProtection\]/ && !/Starting backup pass/ { next }
      /\[TMDeviceRulesEngine\]/ { next }
      { print }' \
  | cut -c1-300 >> "$EVENTS"
echo "$NEW_STATE" > "$STATE"

# ---- 2. état de l'environnement
running=$(tmutil status 2>/dev/null | awk -F'= ' '/Running/ {gsub(/;/,"",$2); print $2}')
phase=$(tmutil status 2>/dev/null | awk -F'= ' '/BackupPhase/ {gsub(/[;"]/,"",$2); print $2}')
ip=$(dscacheutil -q host -a name "$PI_HOST" 2>/dev/null | awk '/^ip_address/ {print $2; exit}')
png=$(ping -c 1 -t 2 "$PI_HOST" 2>/dev/null | sed -nE 's/.*time=([0-9.]+) ms.*/\1ms/p')
smb=$(nc -z -G 3 "$PI_HOST" 445 >/dev/null 2>&1 && echo open || echo closed)
mounted=$(mount | grep -c "raspberrypi")
sleep_blocked=$(pmset -g assertions 2>/dev/null | awk '/PreventUserIdleSystemSleep|PreventSystemSleep/ {print $1"="$2}' | tr '\n' ',' )
snaps=$(python3 - <<'P' 2>/dev/null
import plistlib, subprocess
d = plistlib.loads(subprocess.run(["defaults", "export", "/Library/Preferences/com.apple.TimeMachine", "-"], capture_output=True).stdout)
out = []
for x in d.get("Destinations", []):
    sn = sorted(x.get("SnapshotDates", []))
    out.append("%s:%s" % (x.get("DestinationID", "")[:8], sn[-1].strftime("%m-%dT%H:%MZ") if sn else "none"))
print(",".join(out), "auto=%s" % d.get("AutoBackup"), "interval=%s" % d.get("AutoBackupInterval"))
P
)
echo "$NOW_ISO running=${running:-?} phase=${phase:-none} pi_dns=${ip:-FAIL} pi_ping=${png:-FAIL} pi_smb445=$smb smb_mounts=$mounted last_snapshots=${snaps// /_} sleep_blockers=${sleep_blocked:-none}" >> "$ENVLOG"

# ---- 3. rotation simple (3 Mo par fichier, 3 générations)
for f in "$EVENTS" "$ENVLOG"; do
    [ -f "$f" ] && [ "$(stat -f %z "$f")" -gt 3145728 ] && { mv "$f.2" "$f.3" 2>/dev/null; mv "$f.1" "$f.2" 2>/dev/null; mv "$f" "$f.1"; }
done
exit 0
