#!/bin/bash
# Couche 2 + sonde : lancé chaque minute par timecapsule-keepalive.timer.
#  - écrit un petit fichier sur la capsule (la session AFP n'est jamais inactive)
#  - prend un instantané complet de l'état, le classe (OK / DEGRADED / DOWN)
#  - journalise chaque changement d'état avec l'instantané avant/après
# Tous les accès au montage ont un timeout : ce script ne peut pas se bloquer.
source "${TC_LIB:-/usr/local/lib/timecapsule/timecapsule-lib.sh}"

exec 9> /run/timecapsule-keepalive.lock
flock -n 9 || { tc_log WARN keepalive_overlap; exit 0; }

# Le watchdog en cours de passe (ou de récupération) est seul à écrire l'état : on saute ce tour.
# (évite les transitions journalisées en double)
exec 8> /run/timecapsule-watchdog.lock
flock -n 8 || exit 0
flock -u 8

tc_state_load
tc_snapshot

if [ "$s_stat_rc" = 0 ]; then
    tc_run 10 sh -c 'date +%s > "$1/.keepalive" && cat "$1/.keepalive"' _ "$MOUNT_POINT"
    S ka_rc "$TC_RC"; S ka_ms "$TC_MS"
else
    S ka_rc NA; S ka_ms NA
fi

tc_classify
tc_update_state
tc_state_save
