#!/bin/bash
# timecapsule-lib.sh : bibliothèque commune, sourcée par les autres scripts.
#
# Principes :
#  - AUCUN accès au montage sans timeout (un montage FUSE bloqué fait geler
#    n'importe quel `ls`/`stat` normal, c'était la cause de la panne d'août 2026).
#  - AUCUN mot de passe ici : il vient de systemd ($CREDENTIALS_DIRECTORY)
#    ou d'une saisie masquée au terminal, jamais d'un fichier en clair.
#  - Tout changement d'état est journalisé avec un instantané AVANT et APRÈS.

umask 077
TC_CONF="${TC_CONF:-/etc/timecapsule/timecapsule.conf}"
TC_LOG_DIR="${TC_LOG_DIR:-/var/log/timecapsule}"
TC_STATE_DIR="${TC_STATE_DIR:-/var/lib/timecapsule}"
# shellcheck disable=SC1090
[ -r "$TC_CONF" ] && . "$TC_CONF"

CAPSULE_IP="${CAPSULE_IP:-}"
VOLUME_NAME="${VOLUME_NAME:-}"
CAPSULE_USER="${CAPSULE_USER:-}"          # vide = mot de passe de disque seul (cas habituel)
MOUNT_POINT="${MOUNT_POINT:-/mnt/timecapsule}"
STAT_TIMEOUT="${STAT_TIMEOUT:-8}"          # s, accès au montage
DISK_WARN_GB="${DISK_WARN_GB:-150}"        # alerte si moins de Go libres sur la capsule
FUSE_QUEUE_MAX="${FUSE_QUEUE_MAX:-100}"    # requêtes FUSE en attente => montage considéré bloqué
SNAPSHOT_EVERY_S="${SNAPSHOT_EVERY_S:-300}" # instantané périodique quand tout va bien
DSI_PROBE="${DSI_PROBE:-/usr/local/bin/timecapsule-dsi-probe}"

TC_EVENTS="$TC_LOG_DIR/events.log"
TC_STATE="$TC_STATE_DIR/state.env"
mkdir -p "$TC_LOG_DIR/incidents" "$TC_STATE_DIR" 2>/dev/null

# ------------------------------------------------------------------ utilitaires
tc_human() { local s=${1:-0}; printf '%dj%02dh%02dm%02ds' $((s/86400)) $((s%86400/3600)) $((s%3600/60)) $((s%60)); }

tc_q() { # protège une valeur pour le format clé=valeur
    case "$1" in
        "") printf '""' ;;
        *[[:space:]\"]*) printf '"%s"' "${1//\"/\'}" ;;
        *) printf '%s' "$1" ;;
    esac
}

tc_log() { # tc_log NIVEAU EVENEMENT [clé=valeur ...]
    local level=$1 event=$2 line kv prio; shift 2
    line="$(date -Is) level=$level event=$event"
    for kv in "$@"; do line+=" ${kv%%=*}=$(tc_q "${kv#*=}")"; done
    printf '%s\n' "$line" >> "$TC_EVENTS"
    case "$level" in ERROR) prio=err ;; WARN) prio=warning ;; *) prio=info ;; esac
    logger -t timecapsule -p "daemon.$prio" -- "event=$event $*" 2>/dev/null || true
}

# tc_run SECONDES commande... -> TC_RC (137 = tué par timeout), TC_MS, TC_OUT
tc_run() {
    local t=$1 s e f; shift
    f=$(mktemp)
    s=$(date +%s%N)
    { timeout -s KILL "$t" "$@" > "$f" 2>&1; } 2>/dev/null
    TC_RC=$?
    e=$(date +%s%N)
    TC_MS=$(( (e - s) / 1000000 ))
    TC_OUT=$(head -c 4000 "$f")
    rm -f "$f"
}

# Identifiant de la connexion FUSE du montage (= numéro mineur du périphérique)
tc_conn_id() {
    awk -v mp="$MOUNT_POINT" '$5 == mp && /fuse/ { split($3, a, ":"); print a[2]; exit }' /proc/self/mountinfo 2>/dev/null
}

tc_afpfsd_pid() { pgrep -x afpfsd 2>/dev/null | head -n1; }

# ------------------------------------------------------------------ état persistant
TC_STATE_VARS="ST_STATE ST_SINCE ST_FAILS ST_LAST_GOOD_SNAP ST_LAST_GOOD_T ST_PREV_SNAP
ST_CPU_PID ST_CPU_TICKS ST_CPU_T ST_TCP_PORT ST_TCP_SEGS ST_TCP_T ST_TCP_BYTES ST_DISK_AVAIL_GB ST_DISK_T
ST_LAST_SNAPLOG ST_LAST_STILL"

tc_state_load() { [ -r "$TC_STATE" ] && . "$TC_STATE"; return 0; }
tc_state_save() {
    local v f="$TC_STATE.tmp"
    { for v in $TC_STATE_VARS; do printf '%s=%q\n' "$v" "${!v:-}"; done; } > "$f" && mv "$f" "$TC_STATE"
}

# ------------------------------------------------------------------ instantané
# S clé valeur : ajoute au SNAP (sans espaces) et crée la variable s_<clé>
S() {
    local k=$1 v=${2:-NA}
    v=${v//[[:space:]]/_}
    [ -n "$v" ] || v=NA
    printf -v "s_${k//-/_}" '%s' "$v"
    SNAP+="$k=$v "
}

tc_snapshot() {
    local now id pid out t ticks dt cpu port segs dsec pps bytes kb u cg i ip

    now=$(date +%s); SNAP=""
    S ts "$now"
    S uptime_s "$(cut -d. -f1 /proc/uptime)"

    # -- montage FUSE (toujours avec timeout)
    id=$(tc_conn_id)
    if [ -n "$id" ]; then
        S mount_present yes; S fuse_conn "$id"
        S fuse_waiting "$(cat "/sys/fs/fuse/connections/$id/waiting" 2>/dev/null)"
        tc_run "$STAT_TIMEOUT" stat -t "$MOUNT_POINT"
        S stat_rc "$TC_RC"; S stat_ms "$TC_MS"
    else
        S mount_present no; S fuse_conn NA; S fuse_waiting NA; S stat_rc NA; S stat_ms NA
    fi

    # -- la capsule elle-même, indépendamment d'afpfsd
    if [ -n "$CAPSULE_IP" ]; then
        tc_run 6 ping -c 3 -i 0.3 -W 1 -q "$CAPSULE_IP"
        S ping_loss "$(sed -nE 's/.* ([0-9.]+)% packet loss.*/\1/p' <<<"$TC_OUT")"
        S ping_ms "$(sed -nE 's#.*= [0-9.]+/([0-9.]+)/.*#\1#p' <<<"$TC_OUT")"
        if [ -x "$DSI_PROBE" ]; then
            tc_run 6 "$DSI_PROBE" "$CAPSULE_IP" 4
            S dsi_rc "$TC_RC"
            S dsi_tcp_ms "$(sed -nE 's/.*tcp=([0-9]+)ms.*/\1/p' <<<"$TC_OUT")"
            S dsi_ms "$(sed -nE 's/.*dsi_getstatus=([0-9]+)ms.*/\1/p' <<<"$TC_OUT")"
        fi
    fi

    # -- processus afpfsd (le client AFP) : état, âge, CPU instantané
    pid=$(tc_afpfsd_pid)
    if [ -n "$pid" ] && [ -r "/proc/$pid/stat" ]; then
        S afpfsd_pid "$pid"
        S afpfsd_age_s "$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')"
        S afpfsd_state "$(awk '/^State/{print $2}' "/proc/$pid/status")"
        S afpfsd_threads "$(awk '/^Threads/{print $2}' "/proc/$pid/status")"
        S afpfsd_rss_kb "$(awk '/^VmRSS/{print $2}' "/proc/$pid/status")"
        ticks=$(awk '{print $14 + $15}' "/proc/$pid/stat")
        cpu=NA
        if [ "${ST_CPU_PID:-}" = "$pid" ] && [ -n "${ST_CPU_T:-}" ] && [ "$now" -gt "$ST_CPU_T" ]; then
            dt=$(( now - ST_CPU_T ))
            cpu=$(( (ticks - ST_CPU_TICKS) * 100 / ($(getconf CLK_TCK) * dt) ))
        fi
        S afpfsd_cpu_pct "$cpu"
        ST_CPU_PID=$pid; ST_CPU_TICKS=$ticks; ST_CPU_T=$now
    else
        S afpfsd_pid none; S afpfsd_age_s NA; S afpfsd_state NA; S afpfsd_threads NA; S afpfsd_rss_kb NA; S afpfsd_cpu_pct NA
    fi

    # -- session TCP AFP vers la capsule (port 548)
    if [ -n "$CAPSULE_IP" ]; then
        out=$(ss -tnoi dst "$CAPSULE_IP" '( dport = :548 )' 2>/dev/null)
        if grep -q ESTAB <<<"$out"; then
            S tcp_state ESTAB
            S tcp_local "$(awk '/ESTAB/{print $4}' <<<"$out" | head -n1)"
            S tcp_sendq "$(awk '/ESTAB/{print $3}' <<<"$out" | head -n1)"
            S tcp_rtt_ms "$(grep -oE 'rtt:[0-9.]+' <<<"$out" | head -n1 | cut -d: -f2)"
            S tcp_retrans_total "$(grep -oE 'retrans:[0-9]+/[0-9]+' <<<"$out" | head -n1 | cut -d/ -f2)"
            S tcp_tx_bytes "$(grep -oE 'bytes_acked:[0-9]+' <<<"$out" | head -n1 | cut -d: -f2)"
            S tcp_rx_bytes "$(grep -oE 'bytes_received:[0-9]+' <<<"$out" | head -n1 | cut -d: -f2)"
            port=$(awk '/ESTAB/{n=split($4,a,":"); print a[n]}' <<<"$out" | head -n1)
            segs=$(grep -oE 'segs_out:[0-9]+' <<<"$out" | head -n1 | cut -d: -f2)
            # paquets/s : un afpfsd emballé (boucle) génère ~1700 pkt/s pour presque aucun octet utile
            bytes=$(( ${s_tcp_tx_bytes:-0} + ${s_tcp_rx_bytes:-0} ))
            if [ "${ST_TCP_PORT:-}" = "$port" ] && [ -n "${ST_TCP_T:-}" ] && [ "$now" -gt "$ST_TCP_T" ] && [ -n "$segs" ]; then
                dsec=$(( now - ST_TCP_T ))
                pps=$(( (segs - ST_TCP_SEGS) / dsec ))
                S tcp_pps "$pps"
                # octets moyens par paquet : < 120 avec > 800 pkt/s = boucle folle, pas une sauvegarde
                if [ "$pps" -gt 0 ]; then S tcp_bytes_per_pkt "$(( (bytes - ${ST_TCP_BYTES:-$bytes}) / dsec / pps ))"; else S tcp_bytes_per_pkt NA; fi
            else
                S tcp_pps NA; S tcp_bytes_per_pkt NA
            fi
            ST_TCP_PORT=$port; ST_TCP_SEGS=$segs; ST_TCP_T=$now; ST_TCP_BYTES=$bytes
        else
            S tcp_state none; S tcp_pps NA; S tcp_bytes_per_pkt NA
        fi
    fi

    # -- Samba
    S smbd_active "$(systemctl is-active smbd 2>/dev/null)"
    S smbd_tasks "$(systemctl show smbd -p TasksCurrent --value 2>/dev/null)"
    tc_run 5 smbstatus -b
    S smb_sessions "$(grep -cE 'SMB[0-9]' <<<"$TC_OUT")"

    # -- limites de processus (cgroups) : le gel d'août est venu d'ici
    for u in timecapsule-mount smbd cron; do
        cg=/sys/fs/cgroup/system.slice/$u.service
        S "pids_${u#timecapsule-}" "$(cat "$cg/pids.current" 2>/dev/null)/$(cat "$cg/pids.max" 2>/dev/null)"
    done
    S stuck_on_mount "$(ps -eo args= | awk -v mp="$MOUNT_POINT" 'index($0, mp) && $1 ~ /(^|\/)(ls|stat|cat|df|du|find)$/ {n++} END{print n+0}')"
    S procs_state_D "$(ps -eo stat= | grep -c '^D')"

    # -- réseau du Pi
    for i in eth0 wlan0; do
        ip=$(ip -4 -o addr show dev "$i" 2>/dev/null | awk '{print $4}' | head -n1)
        S "$i" "$(cat "/sys/class/net/$i/operstate" 2>/dev/null)/${ip:-noip}"
    done
    S default_routes "$(ip route 2>/dev/null | grep -c '^default')"

    # -- santé du Pi
    S load1 "$(cut -d' ' -f1 /proc/loadavg)"
    S mem_avail_mb "$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo)"
    t=$(vcgencmd measure_temp 2>/dev/null | sed -nE "s/temp=([0-9.]+).*/\1/p")
    [ -n "$t" ] || t=$(awk '{printf "%.1f", $1/1000}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
    S temp_c "$t"
    S throttled "$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2)"

    # -- espace libre sur la capsule (au plus toutes les 10 min, seulement si le montage répond)
    if [ "$s_stat_rc" = 0 ] && [ $(( now - ${ST_DISK_T:-0} )) -ge 600 ]; then
        tc_run 10 df -Pk "$MOUNT_POINT"
        kb=$(awk 'NR==2{print $4}' <<<"$TC_OUT")
        if [ "$TC_RC" = 0 ] && [ -n "$kb" ]; then ST_DISK_AVAIL_GB=$(( kb / 1024 / 1024 )); ST_DISK_T=$now; fi
    fi
    S capsule_free_gb "${ST_DISK_AVAIL_GB:-NA}"
}

# ------------------------------------------------------------------ classification
# CLASS = OK | DEGRADED | DOWN ; REASONS = liste séparée par des virgules
tc_classify() {
    local n; CLASS=OK; REASONS=""
    add() { REASONS+="$1,"; }

    if [ "$s_mount_present" != yes ]; then CLASS=DOWN; add not_mounted
    elif [ "$s_stat_rc" != 0 ]; then CLASS=DOWN; add "stat_failed_rc$s_stat_rc"; fi
    if [ -n "${s_ka_rc:-}" ] && [ "$s_ka_rc" != 0 ] && [ "$s_ka_rc" != NA ]; then CLASS=DOWN; add "keepalive_write_failed_rc$s_ka_rc"; fi
    if [ "$s_fuse_waiting" != NA ] && [ "$s_fuse_waiting" -ge "$FUSE_QUEUE_MAX" ] 2>/dev/null; then CLASS=DOWN; add "fuse_queue_stalled_$s_fuse_waiting"; fi
    if [ "${s_dsi_rc:-0}" != 0 ] || [ "${s_ping_loss:-0}" = 100 ]; then add capsule_unreachable; fi

    if [ "$CLASS" = OK ]; then
        n=${s_stat_ms:-0};            [ "$n" != NA ] && [ "$n" -gt 3000 ] 2>/dev/null && { CLASS=DEGRADED; add "slow_stat_${n}ms"; }
        n=${s_fuse_waiting:-0};       [ "$n" != NA ] && [ "$n" -gt 10 ]   2>/dev/null && { CLASS=DEGRADED; add "fuse_queue_${n}"; }
        n=${s_afpfsd_cpu_pct:-0};     [ "$n" != NA ] && [ "$n" -gt 80 ]   2>/dev/null && { CLASS=DEGRADED; add "afpfsd_cpu_${n}pct"; }
        n=${s_tcp_pps:-0}
        if [ "$n" != NA ] && [ "$n" -gt 800 ] 2>/dev/null && [ "${s_tcp_bytes_per_pkt:-NA}" != NA ] && [ "$s_tcp_bytes_per_pkt" -lt 120 ] 2>/dev/null; then
            CLASS=DEGRADED; add "tcp_packet_storm_${n}pps_${s_tcp_bytes_per_pkt}B"
        fi
        [ "${s_dsi_rc:-0}" != 0 ] && CLASS=DEGRADED
        [ "${s_smbd_active:-}" != active ] && { CLASS=DEGRADED; add smbd_not_running; }
        n=${s_capsule_free_gb:-NA};   [ "$n" != NA ] && [ "$n" -lt "$DISK_WARN_GB" ] 2>/dev/null && { CLASS=DEGRADED; add "capsule_low_space_${n}GB"; }
    fi
    REASONS=${REASONS%,}; [ -n "$REASONS" ] || REASONS=none
}

# ------------------------------------------------------------------ différence avant/après
TC_VOLATILE="ts uptime_s afpfsd_age_s tcp_tx_bytes tcp_rx_bytes load1 mem_avail_mb temp_c tcp_local tcp_rtt_ms ping_ms dsi_tcp_ms dsi_ms"
tc_diff() { # tc_diff "avant" "après" -> "clé:ancienne->nouvelle ..."
    awk -v A="$1" -v B="$2" -v skip="$TC_VOLATILE" '
        BEGIN {
            n = split(A, a, " "); for (i = 1; i <= n; i++) { k = a[i]; sub(/=.*/, "", k); old[k] = substr(a[i], length(k) + 2) }
            m = split(B, b, " ")
            for (i = 1; i <= m; i++) {
                k = b[i]; sub(/=.*/, "", k); v = substr(b[i], length(k) + 2)
                if ((k in old) && old[k] != v && index(" " skip " ", " " k " ") == 0) printf "%s:%s->%s ", k, old[k], v
            }
            print ""
        }'
}

# ------------------------------------------------------------------ transitions + journaux périodiques
tc_update_state() {
    local prev=${ST_STATE:-UNKNOWN} now=$s_ts dur level before diff
    if [ "$CLASS" = DOWN ]; then ST_FAILS=$(( ${ST_FAILS:-0} + 1 )); else ST_FAILS=0; fi

    if [ "$CLASS" != "$prev" ]; then
        dur=$(( now - ${ST_SINCE:-$now} ))
        case "$CLASS" in DOWN) level=ERROR ;; DEGRADED) level=WARN ;; *) level=INFO ;; esac
        # "avant" = dernier instantané où tout allait bien ; sinon l'instantané précédent
        before=${ST_LAST_GOOD_SNAP:-$ST_PREV_SNAP}
        [ "$prev" = OK ] || before=${ST_PREV_SNAP:-$before}
        diff=$(tc_diff "$before" "$SNAP")
        tc_log "$level" state_change from="$prev" to="$CLASS" reasons="$REASONS" \
            prev_duration_s="$dur" prev_duration="$(tc_human "$dur")" \
            afpfsd_age="$(tc_human "${s_afpfsd_age_s:-0}")" \
            changed="${diff:-none}" before="$before" after="$SNAP"
        if [ "$CLASS" = DOWN ]; then tc_incident_bundle "${prev}-to-DOWN"; fi
        ST_STATE=$CLASS; ST_SINCE=$now
    elif [ "$CLASS" = OK ]; then
        if [ $(( now - ${ST_LAST_SNAPLOG:-0} )) -ge "$SNAPSHOT_EVERY_S" ]; then
            tc_log INFO snapshot reasons="$REASONS" up_for="$(tc_human $(( now - ST_SINCE )))" snap="$SNAP"
            ST_LAST_SNAPLOG=$now
        fi
    elif [ $(( now - ${ST_LAST_STILL:-0} )) -ge 60 ]; then
        tc_log WARN still_"$CLASS" reasons="$REASONS" since="$(tc_human $(( now - ST_SINCE )))" fails="$ST_FAILS" snap="$SNAP"
        ST_LAST_STILL=$now
    fi
    if [ "$CLASS" = OK ]; then ST_LAST_GOOD_SNAP=$SNAP; ST_LAST_GOOD_T=$now; fi
    ST_PREV_SNAP=$SNAP
}

# ------------------------------------------------------------------ dossier d'incident
# Capture TOUT ce qui permet de comprendre une panne, avant qu'on y touche.
tc_incident_bundle() {
    local f="$TC_LOG_DIR/incidents/$(date +%Y%m%d-%H%M%S)-$1.txt" pid id sec
    {
        echo "##### INCIDENT $1 - $(date -Is) - $(hostname)"
        echo; echo "### Avant (dernier état OK) / Après (maintenant)"
        echo "avant : ${ST_LAST_GOOD_SNAP:-inconnu}"
        echo "après : ${SNAP:-inconnu}"
        echo "changé: $(tc_diff "${ST_LAST_GOOD_SNAP:-}" "${SNAP:-}")"
        echo; echo "### Processus liés (afpfsd, scripts, accès bloqués sur le montage)"
        ps -eo pid,ppid,stat,etime,pcpu,wchan:20,args | grep -E 'afpfsd|afp_client|timecapsule|smbd -D|ls .*timecapsule|stat .*timecapsule' | grep -v grep | head -40
        pid=$(tc_afpfsd_pid)
        if [ -n "$pid" ]; then
            echo; echo "### afpfsd $pid : threads"
            for sec in /proc/$pid/task/*; do echo "$(basename "$sec") $(awk '/^State/{print $2,$3}' "$sec/status") wchan=$(cat "$sec/wchan" 2>/dev/null) cpu_ticks=$(awk '{print $14"+"$15}' "$sec/stat")"; done
            echo "cgroup: $(cat /proc/$pid/cgroup)"
        fi
        id=$(tc_conn_id); echo; echo "### FUSE connexion=${id:-aucune} waiting=$(cat /sys/fs/fuse/connections/$id/waiting 2>/dev/null)"
        echo; echo "### Session TCP vers la capsule"; ss -tnoi dst "$CAPSULE_IP" 2>&1 | head -12
        echo; echo "### Compteurs TCP noyau (retransmissions, resets)"; grep -E '^Tcp:' /proc/net/snmp
        echo; echo "### Réseau"; ip -br addr; ip route; ip -s link show eth0 2>/dev/null | head -8; ip -s link show wlan0 2>/dev/null | head -8
        echo; echo "### Capsule (ping + sonde AFP/DSI)"
        ping -c 5 -i 0.3 -W 1 -q "$CAPSULE_IP" 2>&1 | tail -3
        [ -x "$DSI_PROBE" ] && timeout -s KILL 6 "$DSI_PROBE" "$CAPSULE_IP" 4 2>&1
        echo; echo "### Samba"; timeout -s KILL 5 smbstatus -b 2>&1 | head -25
        echo; echo "### Cgroups (limites de processus)"
        for sec in timecapsule-mount smbd cron; do echo "$sec pids=$(cat /sys/fs/cgroup/system.slice/$sec.service/pids.current 2>/dev/null)/$(cat /sys/fs/cgroup/system.slice/$sec.service/pids.max 2>/dev/null)"; done
        echo; echo "### Noyau (30 min)"; journalctl -k --since "-30min" --no-pager 2>&1 | tail -40
        echo; echo "### Journaux afpfsd / smbd / mount / watchdog / réseau (30 min)"
        journalctl --since "-30min" --no-pager -t afpfsd -t timecapsule -u smbd -u timecapsule-mount -u NetworkManager 2>&1 | tail -80
        echo; echo "### Santé du Pi"; uptime; free -m | head -2; vcgencmd measure_temp get_throttled 2>&1
    } > "$f" 2>&1
    chmod 600 "$f"
    tc_log INFO incident_saved file="$f"
}
