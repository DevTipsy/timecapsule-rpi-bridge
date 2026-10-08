#!/bin/bash
# Monte / démonte / nettoie le montage AFP de la Time Capsule.
# Usage : timecapsule-mount.sh [mount|unmount|clean]
#
# Mot de passe de la capsule (jamais en clair sur disque, jamais dans argv) :
#   1. $CREDENTIALS_DIRECTORY/capsule-password : fourni par systemd (chiffré au repos)
#   2. sinon, si on est dans un terminal : saisie masquée, utilisée une fois
# Il est transmis à afp_client par l'entrée standard (-p -), donc invisible dans `ps`.
source "${TC_LIB:-/usr/local/lib/timecapsule/timecapsule-lib.sh}"

read_password() { # -> PW (variable locale à l'appelant)
    local f="${CREDENTIALS_DIRECTORY:-}/capsule-password"
    if [ -n "${CREDENTIALS_DIRECTORY:-}" ] && [ -r "$f" ]; then
        IFS= read -r PW < "$f"; return 0
    fi
    if [ -t 0 ]; then
        read -rs -p "Mot de passe du disque de la Time Capsule : " PW; echo; return 0
    fi
    return 1
}

clean() {
    local id w rc
    id=$(tc_conn_id); w=$(cat "/sys/fs/fuse/connections/$id/waiting" 2>/dev/null)
    tc_log INFO clean_start fuse_conn="${id:-none}" fuse_waiting="${w:-NA}" afpfsd_pid="$(tc_afpfsd_pid)"
    # 1. libère d'un coup tous les processus bloqués sur le montage (ils reçoivent ENOTCONN)
    if [ -n "$id" ] && [ -w "/sys/fs/fuse/connections/$id/abort" ]; then
        echo 1 > "/sys/fs/fuse/connections/$id/abort"; tc_log INFO clean_step step=fuse_abort rc=$?
    fi
    # 2. démonte
    tc_run 15 fusermount -uz "$MOUNT_POINT"; tc_log INFO clean_step step=fusermount rc="$TC_RC" ms="$TC_MS"
    tc_run 15 umount -l "$MOUNT_POINT";      tc_log INFO clean_step step=umount_lazy rc="$TC_RC" ms="$TC_MS"
    # 3. tue le client AFP (même emballé / bloqué)
    pkill -9 -x afpfsd; sleep 2
    tc_log INFO clean_step step=kill_afpfsd remaining="$(tc_afpfsd_pid || true)"
    # 4. recrée un point de montage propre
    rmdir "$MOUNT_POINT" 2>/dev/null; mkdir -p "$MOUNT_POINT"
    tc_log INFO clean_done stuck_left="$(ps -eo args= | grep -c "[ ]$MOUNT_POINT")" procs_D="$(ps -eo stat= | grep -c '^D')"
}

mount_capsule() {
    local PW="" t0 t1 out; out=$(mktemp)
    [ -n "$CAPSULE_IP" ] && [ -n "$VOLUME_NAME" ] || { tc_log ERROR mount_failed reason=config_missing; echo "Configuration absente ($TC_CONF)" >&2; return 2; }
    if ! read_password; then
        tc_log ERROR mount_failed reason=no_credential hint="sudo timecapsule-ctl set-password"
        echo "Aucun mot de passe disponible. Lancez : sudo timecapsule-ctl set-password" >&2
        return 3
    fi
    mkdir -p "$MOUNT_POINT"
    pgrep -x afpfsd > /dev/null || { afpfsd; sleep 3; }
    t0=$(date +%s%N)
    printf '%s\n' "$PW" | afp_client mount "$CAPSULE_IP:$VOLUME_NAME" "$MOUNT_POINT" -u "$CAPSULE_USER" -p - > "$out" 2>&1
    local rc=$?; PW=""; unset PW
    t1=$(date +%s%N)
    # les messages d'afp_client sont journalisés, sans la ligne du prompt
    tc_log INFO afp_client_output rc=$rc ms=$(( (t1 - t0) / 1000000 )) out="$(grep -v 'AFP Password' "$out" | tr '\n' ' ' | head -c 400)"
    out_copy=$(mktemp); grep -v 'AFP Password' "$out" > "$out_copy"; rm -f "$out"

    tc_run "$STAT_TIMEOUT" stat -t "$MOUNT_POINT"
    if [ "$rc" = 0 ] && [ "$TC_RC" = 0 ] && [ -n "$(tc_conn_id)" ]; then
        rm -f "$TC_STATE_DIR/auth_failed"
        tc_log INFO mount_ok afpfsd_pid="$(tc_afpfsd_pid)" stat_ms="$TC_MS"
        rm -f "$out_copy"; return 0
    fi
    # Mot de passe refusé : inutile de réessayer toutes les 2 min (le watchdog s'arrête tant que
    # le mot de passe n'a pas été ressaisi avec `timecapsule-ctl set-password`)
    if grep -q "Authentication failed" "$out_copy" 2>/dev/null; then
        date +%s > "$TC_STATE_DIR/auth_failed"
        tc_log ERROR mount_failed reason=auth_failed hint="mot de passe refusé par la capsule: sudo timecapsule-ctl set-password"
    fi
    rm -f "$out_copy"
    tc_log ERROR mount_failed afp_client_rc=$rc stat_rc="$TC_RC" mounted="$([ -n "$(tc_conn_id)" ] && echo yes || echo no)"
    return 1
}

case "${1:-mount}" in
    mount)   mount_capsule ;;
    clean)   clean ;;
    unmount) tc_run 20 afp_client unmount "$MOUNT_POINT"; tc_log INFO unmount rc="$TC_RC" ms="$TC_MS"
             pgrep -x afpfsd > /dev/null && clean ;;
    *) echo "Usage: $0 [mount|unmount|clean]" >&2; exit 2 ;;
esac
