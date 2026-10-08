#!/bin/bash
# À lancer sur le MAC (lecture seule) : que dit Time Machine, et vers quelle destination ?
# Usage : bash tools/mac-timemachine-report.sh [jours]   (défaut 3)
DAYS="${1:-3}"
echo "=== Destinations Time Machine (2 destinations = risque de confusion / d'écriture double) ==="
tmutil destinationinfo | grep -E "Name|Kind|URL"
echo; echo "=== Sauvegarde en cours ==="
tmutil status | grep -E "Running|BackupPhase|Percent|DestinationID"
echo; echo "=== Espace sur le volume de sauvegarde ==="
mount | grep -E "smbfs|afpfs" | sed -E 's/\(.*//' | head -3
df -h 2>/dev/null | grep -iE "Sauvegardes|TimeMachine|timemachine" | head -3
echo; echo "=== Erreurs Time Machine ($DAYS derniers jours), regroupées par type ==="
/usr/bin/log show --last "${DAYS}d" --style compact \
  --predicate 'subsystem == "com.apple.TimeMachine" AND messageType == error' 2>/dev/null \
  | grep -vE "^Timestamp|Failed to read capabilities|connection invalid|is still valid" \
  | sed -E 's/^[0-9-]+ [0-9:.]+ +[A-Z] +[a-zA-Z]+\[[0-9:a-f]+\] //; s/[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]+ \+0000/DATE/g; s/[0-9.]+ GB/N GB/g' \
  | cut -c1-170 | sort | uniq -c | sort -rn | head -12
echo; echo "Lecture : TARGETVOL_DISK_FULL / 'Insufficient free space' = la capsule est pleine (Time Machine exige 100 Go libres)."
