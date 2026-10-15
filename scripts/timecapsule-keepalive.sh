#!/bin/bash
# Couche 2 + sonde : lancé chaque minute par timecapsule-keepalive.timer.
#  - sonde en lecture seule (stat) + test d'écriture rare (toutes les 6 h par défaut)
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

# Écrire sur la capsule chaque minute la réveille à chaque fois (mesuré : une écriture après plus de
# 60 s de repos coûte ~5 s, signe d'un disque en veille) et l'empêche de dormir : usure inutile.
# La session AFP est déjà maintenue par le protocole (la capsule envoie un "tickle" toutes les 30 s
# et le client y répond), et la santé du montage est vérifiée par `stat` (lecture, sans toucher au disque).
# On ne fait donc un vrai test d'écriture qu'à intervalle rare (KEEPALIVE_WRITE_EVERY_S, défaut 6 h).
now=$(date +%s)
if [ "$s_stat_rc" = 0 ] && [ "$KEEPALIVE_WRITE_EVERY_S" -gt 0 ] && [ $(( now - ${ST_LAST_KA_WRITE:-0} )) -ge "$KEEPALIVE_WRITE_EVERY_S" ]; then
    tc_run 20 sh -c 'date +%s > "$1/.keepalive" && cat "$1/.keepalive"' _ "$MOUNT_POINT"
    S ka_rc "$TC_RC"; S ka_ms "$TC_MS"
    ST_LAST_KA_WRITE=$now
else
    S ka_rc NA; S ka_ms NA
fi

tc_classify
tc_track_smb
tc_track_activity
tc_update_state
tc_state_save
