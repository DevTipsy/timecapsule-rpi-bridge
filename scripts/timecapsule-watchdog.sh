#!/bin/bash
# Couche 3 : watchdog, lancé chaque minute par timecapsule-watchdog.timer.
# Si le montage est mort : capture un dossier d'incident, arrête Samba (aucune
# écriture sur un montage mort), nettoie, remonte, vérifie, relance Samba.
# Chaque étape est journalisée avec sa durée. Un disjoncteur évite les boucles.
source "${TC_LIB:-/usr/local/lib/timecapsule/timecapsule-lib.sh}"

exec 9> /run/timecapsule-watchdog.lock
flock -n 9 || exit 0

MAX_ATTEMPTS_PER_HOUR=6
ATTEMPTS="$TC_STATE_DIR/recovery_attempts"

tc_state_load
now=$(date +%s)

# La sonde (keepalive) tourne-t-elle encore ? Sinon on le dit, c'était une panne silencieuse en août.
state_mtime=$(stat -c %Y "$TC_STATE" 2>/dev/null || echo 0)
if [ $(( now - state_mtime )) -gt 300 ]; then
    tc_log ERROR probe_stale last_probe_age_s=$(( now - state_mtime )) hint="systemctl status timecapsule-keepalive.timer"
    systemctl start timecapsule-keepalive.service --no-block
fi

# Vérification fraîche, indépendante de l'état mémorisé
tc_snapshot; tc_classify
healthy=no; [ "$CLASS" != DOWN ] && healthy=yes

if [ "$healthy" = yes ]; then
    if ! systemctl is-active --quiet smbd; then
        tc_log WARN smbd_started_by_watchdog reason="mount healthy but smbd stopped"
        systemctl start smbd
    fi
    : > "$ATTEMPTS.ok" 2>/dev/null
    exit 0
fi

# Confirmation : 2 sondes DOWN consécutives (évite de réagir à un accroc de 30 s)
# Une erreur franche (déconnecté, ENOTCONN, non monté) se traite tout de suite ; seul un timeout (rc 137),
# qui peut être une lenteur passagère de la capsule, demande une seconde confirmation.
if [ "${ST_FAILS:-0}" -lt 2 ] && [ "${s_stat_rc:-}" = 137 ] && [ "${s_fuse_waiting:-0}" != NA ] && [ "${s_fuse_waiting:-0}" -lt "$FUSE_QUEUE_MAX" ]; then
    tc_log WARN watchdog_waiting fails="${ST_FAILS:-0}" reasons="$REASONS"
    exit 0
fi

# Mot de passe refusé par la capsule : on n'insiste pas (verrouillage possible, et c'est inutile)
if [ -e "$TC_STATE_DIR/auth_failed" ]; then
    tc_log WARN recovery_skipped reason=auth_failed hint="sudo timecapsule-ctl set-password"
    exit 0
fi

# Disjoncteur
touch "$ATTEMPTS"
awk -v n="$now" '$1 > n - 3600' "$ATTEMPTS" > "$ATTEMPTS.new"; mv "$ATTEMPTS.new" "$ATTEMPTS"
if [ "$(wc -l < "$ATTEMPTS")" -ge "$MAX_ATTEMPTS_PER_HOUR" ]; then
    tc_log ERROR recovery_suspended attempts_last_hour="$(wc -l < "$ATTEMPTS")" reasons="$REASONS" hint="intervention manuelle: sudo timecapsule-ctl status"
    exit 1
fi
echo "$now" >> "$ATTEMPTS"

T0=$(date +%s)
tc_log ERROR recovery_start reasons="$REASONS" down_for="$(tc_human $(( now - ${ST_SINCE:-$now} )))" before="${ST_LAST_GOOD_SNAP:-unknown}" now_state="$SNAP"
tc_incident_bundle "before-recovery"

systemctl stop smbd;  tc_log INFO recovery_step step=smbd_stopped rc=$?

# Si la capsule elle-même ne répond pas, inutile d'insister : on attend (Samba reste arrêté).
if [ "${s_dsi_rc:-0}" != 0 ]; then
    tc_log ERROR recovery_aborted reason=capsule_unreachable ping_loss="${s_ping_loss:-NA}" hint="vérifier alimentation/réseau de la capsule"
    exit 1
fi

/usr/local/bin/timecapsule-mount.sh clean
systemctl restart timecapsule-mount.service; rc=$?
tc_log INFO recovery_step step=mount_service_restart rc=$rc

tc_snapshot; tc_classify
if [ "$CLASS" != DOWN ]; then
    systemctl start smbd
    sleep 2
    tc_snapshot; tc_classify    # l'état final est mesuré une fois Samba relancé
    tc_log INFO recovery_ok duration_s=$(( $(date +%s) - T0 )) down_for="$(tc_human $(( $(date +%s) - ${ST_SINCE:-$T0} )))" after="$SNAP"
    ST_FAILS=0
else
    tc_log ERROR recovery_failed duration_s=$(( $(date +%s) - T0 )) reasons="$REASONS" after="$SNAP" hint="Samba laissé arrêté, nouvel essai à la prochaine minute"
fi
# le keepalive a pu enregistrer la reprise pendant la récupération : on repart de son état pour éviter un doublon
SNAP_NOW=$SNAP; CLASS_NOW=$CLASS; REASONS_NOW=$REASONS
tc_state_load
SNAP=$SNAP_NOW; CLASS=$CLASS_NOW; REASONS=$REASONS_NOW
tc_update_state; tc_state_save
