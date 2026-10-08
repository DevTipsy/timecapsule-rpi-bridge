#!/bin/bash
# =============================================================================
#  Time Capsule + Raspberry Pi : pont AFP -> SMB pour Time Machine
#  Installateur automatique / Automatic installer
#
#  Usage (sur le Raspberry Pi / on the Raspberry Pi) :
#       sudo bash install.sh
#
#  SÉCURITÉ : cet installateur ne lit, ne stocke et n'affiche AUCUN mot de passe.
#   - mot de passe de la capsule : demandé par `timecapsule-ctl set-password`,
#     chiffré par systemd-creds (jamais en clair sur disque, jamais dans `ps`)
#   - mot de passe Samba : demandé directement par `smbpasswd`
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="/opt/timecapsule-build"
MOUNT_POINT="/mnt/timecapsule"
CONF_DIR="/etc/timecapsule"
LIB_DIR="/usr/local/lib/timecapsule"

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
info()  { printf '\033[34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[32m OK\033[0m %s\n' "$*"; }
warn()  { printf '\033[33m !!\033[0m %s\n' "$*"; }
die()   { printf '\033[31mERREUR / ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Remplace @CLE@ par une valeur (sans interpréter &, \ ou /)
render() {
    local text="$1" out key val; shift
    while [ $# -gt 0 ]; do
        key="@$1@"; val="$2"; out=""
        while [[ "$text" == *"$key"* ]]; do
            out="$out${text%%"$key"*}$val"
            text="${text#*"$key"}"
        done
        text="$out$text"
        shift 2
    done
    printf '%s\n' "$text"
}

ask() { # ask "Question" "défaut" -> $REPLY
    local prompt="$1" default="${2:-}" answer
    if [ -n "$default" ]; then
        read -r -p "$prompt [$default] : " answer
        REPLY="${answer:-$default}"
    else
        read -r -p "$prompt : " answer
        REPLY="$answer"
    fi
}

ask_yn() { # ask_yn "Question" o|n -> 0 si oui
    local def="$2" answer
    read -r -p "$1 [$( [ "$def" = o ] && echo 'O/n' || echo 'o/N' )] : " answer
    answer="${answer:-$def}"
    [[ "$answer" =~ ^[oOyY]$ ]]
}

# ---------------------------------------------------------------- vérifications
[ "$(id -u)" -eq 0 ] || exec sudo -E bash "$0" "$@"
[ -t 0 ] || die "Lancez ce script dans un terminal interactif (les mots de passe sont saisis à la main)."

for f in scripts/timecapsule-lib.sh scripts/timecapsule-mount.sh scripts/timecapsule-keepalive.sh \
         scripts/timecapsule-watchdog.sh scripts/timecapsule-ctl scripts/timecapsule-dsi-probe \
         configs/Dockerfile configs/timecapsule.conf.template configs/smb-global.conf.template \
         configs/smb-share.conf.template configs/avahi-timecapsule.service \
         configs/timecapsule-mount.service configs/timecapsule-keepalive.service configs/timecapsule-keepalive.timer \
         configs/timecapsule-watchdog.service configs/timecapsule-watchdog.timer configs/smbd-override.conf \
         configs/journald-persistent.conf configs/timecapsule.logrotate configs/timecapsule-tmpfiles.conf \
         configs/99-timecapsule-keepalive.conf; do
    [ -f "$REPO_DIR/$f" ] || die "Fichier manquant / missing file: $f (dézippez tout le dossier / unzip the whole folder)"
done

command -v apt-get >/dev/null || die "Ce script est prévu pour Raspberry Pi OS / Debian."
command -v systemctl >/dev/null || die "systemd requis."
case "$(uname -m)" in
    aarch64|arm64|x86_64) ;;
    *) warn "Architecture $(uname -m) non testée / untested architecture." ;;
esac

bold "
 Time Capsule -> Raspberry Pi -> Time Machine (SMB)
 ---------------------------------------------------
 Ce script installe et configure le pont AFP -> SMB, avec surveillance et journaux.
 This script installs the AFP -> SMB bridge, with monitoring and detailed logs.
"

# ---------------------------------------------------------------- questions
DEFAULT_USER="${TC_SMB_USER:-${SUDO_USER:-}}"
[ "$DEFAULT_USER" = "root" ] && DEFAULT_USER=""

while true; do
    ask "IP de la Time Capsule / Time Capsule IP (ex: 192.168.1.15)" "${TC_CAPSULE_IP:-}"
    CAPSULE_IP="$REPLY"
    [[ "$CAPSULE_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && break
    warn "Adresse IP invalide / invalid IP address"
done

while true; do
    ask "Nom du volume de la capsule, SANS espaces / Volume name, NO spaces (ex: AirPortTimeCapsule)" "${TC_VOLUME_NAME:-}"
    VOLUME_NAME="$REPLY"
    [[ "$VOLUME_NAME" =~ ^[A-Za-z0-9._-]+$ ]] && break
    warn "Pas d'espaces ni de caractères spéciaux : renommez le disque dans Utilitaire AirPort / no spaces or special characters: rename the disk in AirPort Utility"
done

while true; do
    ask "Nom d'utilisateur Samba (compte Linux existant du Pi) / Samba username (existing Pi user)" "$DEFAULT_USER"
    SMB_USER="$REPLY"
    [ -n "$SMB_USER" ] && id "$SMB_USER" >/dev/null 2>&1 && break
    warn "L'utilisateur '$SMB_USER' n'existe pas sur ce Pi / user does not exist on this Pi"
done

ask "Nom d'utilisateur AFP de la capsule (souvent vide ; sinon celui du Trousseau d'accès, ex: AirportTimeCapsule) / AFP username (often empty)" "${TC_CAPSULE_USER:-}"
CAPSULE_USER="$REPLY"

ask "Taille max de la sauvegarde Time Machine (ex: 1500G, '-' = illimitée) / Max backup size ('-' = unlimited)" "${TC_MAX_SIZE:--}"
MAX_SIZE="$REPLY"; [ "$MAX_SIZE" = "-" ] && MAX_SIZE=""

echo
bold "Mot de passe de la capsule / Capsule password"
cat <<'E'
  Il ne sera JAMAIS écrit en clair. Deux modes :
   1) chiffré sur le Pi par systemd (remontage automatique après un redémarrage ou une coupure)  [recommandé]
   2) en mémoire seulement : perdu au redémarrage, à ressaisir avec `sudo timecapsule-ctl mount`
  It is never stored in clear text. Mode 1: encrypted by systemd (auto-remount). Mode 2: RAM only.
E
if ask_yn "Chiffrer et mémoriser pour le remontage automatique ? / Store encrypted for auto-remount?" o; then
    SECRET_MODE=persistent
else
    SECRET_MODE=ephemeral
fi

NETBIOS_NAME="$(hostname -s | cut -c1-15)"

# ---------------------------------------------------------------- paquets
info "Installation des paquets..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y samba smbclient cifs-utils avahi-daemon avahi-utils docker.io git psmisc procps \
    util-linux iproute2 iputils-ping python3 logrotate perl
apt-get install -y fuse 2>/dev/null || apt-get install -y fuse3
systemctl enable --now docker >/dev/null 2>&1 || true
ok "Paquets installés"

command -v systemd-creds >/dev/null || [ "$SECRET_MODE" = ephemeral ] || \
    die "systemd-creds absent (systemd >= 250 requis) : relancez en choisissant le mode 2 (mémoire seulement)."

# FUSE allow_other
if grep -q '^#user_allow_other' /etc/fuse.conf 2>/dev/null; then
    sed -i 's/^#user_allow_other/user_allow_other/' /etc/fuse.conf
elif ! grep -q '^user_allow_other' /etc/fuse.conf 2>/dev/null; then
    echo "user_allow_other" >> /etc/fuse.conf
fi

# ---------------------------------------------------------------- installation des fichiers
info "Installation des scripts, services et de la configuration..."
install -d -m 755 "$LIB_DIR"
install -m 755 "$REPO_DIR/scripts/timecapsule-lib.sh" "$LIB_DIR/timecapsule-lib.sh"
install -m 755 "$REPO_DIR/scripts/timecapsule-mount.sh" "$REPO_DIR/scripts/timecapsule-keepalive.sh" \
    "$REPO_DIR/scripts/timecapsule-watchdog.sh" "$REPO_DIR/scripts/timecapsule-ctl" \
    "$REPO_DIR/scripts/timecapsule-dsi-probe" /usr/local/bin/
ln -sf /usr/local/bin/timecapsule-ctl /usr/local/bin/tc-ctl 2>/dev/null || true

install -d -m 700 "$CONF_DIR" /var/log/timecapsule /var/log/timecapsule/incidents /var/lib/timecapsule
render "$(cat "$REPO_DIR/configs/timecapsule.conf.template")" \
    CAPSULE_IP "$CAPSULE_IP" VOLUME_NAME "$VOLUME_NAME" CAPSULE_USER "$(printf '%q' "$CAPSULE_USER")" > "$CONF_DIR/timecapsule.conf"
chmod 600 "$CONF_DIR/timecapsule.conf"

# Journal systemd persistant : sans lui, l'historique des pannes disparaît
install -d /etc/systemd/journald.conf.d /var/log/journal
install -m 644 "$REPO_DIR/configs/journald-persistent.conf" /etc/systemd/journald.conf.d/timecapsule.conf
systemctl restart systemd-journald || true
install -m 644 "$REPO_DIR/configs/timecapsule.logrotate" /etc/logrotate.d/timecapsule
install -m 644 "$REPO_DIR/configs/timecapsule-tmpfiles.conf" /etc/tmpfiles.d/timecapsule.conf

install -m 644 "$REPO_DIR/configs/timecapsule-mount.service" "$REPO_DIR/configs/timecapsule-keepalive.service" \
    "$REPO_DIR/configs/timecapsule-keepalive.timer" "$REPO_DIR/configs/timecapsule-watchdog.service" \
    "$REPO_DIR/configs/timecapsule-watchdog.timer" /etc/systemd/system/
install -d /etc/systemd/system/smbd.service.d
install -m 644 "$REPO_DIR/configs/smbd-override.conf" /etc/systemd/system/smbd.service.d/timecapsule.conf
install -m 644 "$REPO_DIR/configs/99-timecapsule-keepalive.conf" /etc/sysctl.d/99-timecapsule-keepalive.conf
install -m 644 "$REPO_DIR/configs/avahi-timecapsule.service" /etc/avahi/services/timecapsule.service
sysctl --system >/dev/null
systemctl daemon-reload
ok "Couche 1 : TCP keepalive noyau actif"

# ---------------------------------------------------------------- nettoyage de l'ancienne installation (cron + mot de passe en clair)
LEGACY=no
if crontab -l 2>/dev/null | grep -q timecapsule || [ -e /etc/cron.d/timecapsule ] || [ -e /usr/local/bin/timecapsule-watchdog.sh.bak ]; then
    LEGACY=yes
    info "Ancienne installation détectée : suppression des tâches cron et des fichiers contenant un mot de passe en clair..."
    crontab -l 2>/dev/null | grep -v timecapsule | crontab - || true
    rm -f /etc/cron.d/timecapsule
    for old in /usr/local/bin/timecapsule-watchdog.sh.bak /usr/local/bin/timecapsule-*.bak; do
        [ -e "$old" ] && shred -u "$old" 2>/dev/null || rm -f "$old"
    done
    # 1. libère tous les accès bloqués sur le montage mort, 2. tue afpfsd, 3. seulement ensuite arrête les services
    #    (sinon l'ancien ExecStop attend 90 s sur un montage gelé)
    pid="$(pgrep -x afpfsd | head -n1 || true)"
    IN_CRON=no
    [ -n "$pid" ] && grep -q cron.service "/proc/$pid/cgroup" 2>/dev/null && IN_CRON=yes
    # IMPORTANT : tuer d'abord les anciens scripts cron encore bloqués. Si on libérait le montage avant,
    # ils se réveilleraient et relanceraient chacun un remontage (mot de passe en clair dans `ps`,
    # sortie illimitée dans /tmp qui est en RAM).
    pkill -9 -f 'timecapsule-(watchdog|keepalive)\.sh' 2>/dev/null || true
    pkill -9 -x afp_client 2>/dev/null || true
    for c in /sys/fs/fuse/connections/*/abort; do
        [ -w "$c" ] && echo 1 > "$c" 2>/dev/null || true
    done
    pkill -9 -x afpfsd 2>/dev/null || true
    systemctl stop smbd timecapsule-mount.service 2>/dev/null || true
    if [ "$IN_CRON" = yes ]; then
        systemctl restart cron
        ok "afpfsd retiré de cron.service (les processus bloqués sont libérés)"
    fi
    TC_LIB="$LIB_DIR/timecapsule-lib.sh" /usr/local/bin/timecapsule-mount.sh clean || true
fi

# ---------------------------------------------------------------- afpfs-ng
if command -v afp_client >/dev/null && command -v afpfsd >/dev/null && ldd "$(command -v afpfsd)" 2>/dev/null | grep -q libgcrypt; then
    ok "afpfs-ng (avec DHX2) déjà installé, compilation ignorée / already installed, skipping build"
else
    info "Compilation d'afpfs-ng via Docker (10 à 30 min sur un Pi, patience)..."
    rm -rf "$BUILD_DIR"
    git clone --depth 1 https://github.com/rc2dev/afpfs-ng-deb.git "$BUILD_DIR"
    cp "$REPO_DIR/configs/Dockerfile" "$BUILD_DIR/docker/Dockerfile"

    # Patch allow_other : insère 2 lignes sed à la fin de apply_patches()
    awk '
        /^apply_patches\(\)/ { inside=1 }
        inside && /^}/ {
            print "  sed -i \"s/static int changeuid=0/static int changeuid=1/\" \"$repo_dir/fuse/client.c\""
            print "  sed -i \"s/if (arg->changeuid) {/if (1) {/\" \"$repo_dir/fuse/commands.c\""
            inside=0
        }
        { print }
    ' "$BUILD_DIR/docker/entrypoint.sh" > "$BUILD_DIR/docker/entrypoint.sh.new"
    mv "$BUILD_DIR/docker/entrypoint.sh.new" "$BUILD_DIR/docker/entrypoint.sh"
    grep -q 'if (1) {' "$BUILD_DIR/docker/entrypoint.sh" || die "Le patch allow_other n'a pas pu être appliqué (entrypoint.sh amont modifié ?)"

    docker build --no-cache -t afpfs-ng-deb "$BUILD_DIR/docker"
    mkdir -p "$BUILD_DIR/dist"
    docker run --rm -v "$BUILD_DIR/patches:/app/patches" -v "$BUILD_DIR/dist:/app/dist" afpfs-ng-deb
    DEB="$(ls "$BUILD_DIR"/dist/afpfs-ng_*.deb 2>/dev/null | head -n1)"
    [ -n "$DEB" ] || die "Le paquet .deb n'a pas été généré / .deb not produced"
    apt-get install -y "$DEB"

    ldd "$(command -v afpfsd)" 2>/dev/null | grep -q libgcrypt || warn "afpfsd sans libgcrypt : l'authentification DHX2 risque d'échouer"
    ok "afpfs-ng installé"
fi

# ---------------------------------------------------------------- test de la capsule
info "Test de la Time Capsule (sonde AFP, sans mot de passe)..."
if probe="$(/usr/local/bin/timecapsule-dsi-probe "$CAPSULE_IP" 5 2>&1)"; then
    ok "Time Capsule joignable : $probe"
else
    warn "La capsule ne répond pas sur $CAPSULE_IP:548 ($probe)"
    ask_yn "Continuer quand même ? / Continue anyway ?" n || exit 1
fi

# ---------------------------------------------------------------- mot de passe de la capsule (chiffré)
info "Enregistrement du mot de passe de la capsule..."
if [ "$SECRET_MODE" = persistent ]; then
    /usr/local/bin/timecapsule-ctl set-password
else
    /usr/local/bin/timecapsule-ctl set-password --ephemeral
fi

# ---------------------------------------------------------------- Samba
info "Configuration de Samba..."
SMB_CONF=/etc/samba/smb.conf
[ -f "$SMB_CONF.pre-timecapsule" ] || cp "$SMB_CONF" "$SMB_CONF.pre-timecapsule"

MAX_SIZE_LINE=""
[ -n "$MAX_SIZE" ] && MAX_SIZE_LINE="fruit:time machine max size = $MAX_SIZE"

render "$(cat "$REPO_DIR/configs/smb-global.conf.template")" NETBIOS_NAME "$NETBIOS_NAME" \
    > /etc/samba/timecapsule-global.conf
render "$(cat "$REPO_DIR/configs/smb-share.conf.template")" SMB_USER "$SMB_USER" MAX_SIZE_LINE "$MAX_SIZE_LINE" \
    > /etc/samba/timecapsule-share.conf

# Les anciennes options du guide, collées à la main dans smb.conf, sont désormais dans les fichiers inclus
# Migration : l'ancien guide faisait coller ces options et le bloc [TimeMachine] à la main dans smb.conf.
# Ils écraseraient les fichiers inclus (la dernière valeur gagne) : on les retire (sauvegarde : .pre-timecapsule).
if ! grep -q 'timecapsule-share.conf' "$SMB_CONF" && grep -q '^\[TimeMachine\]' "$SMB_CONF"; then
    info "smb.conf édité à la main détecté : migration vers les fichiers inclus"
    perl -0pi -e 's/^\[TimeMachine\].*?(?=^\[|\z)//ms' "$SMB_CONF"
    perl -ni -e 'print unless /^\s*(smbd:backgroundqueue|netbios name|server string|socket options|min protocol|kernel oplocks|kernel share modes)\s*=/' "$SMB_CONF"
fi
if ! grep -q 'timecapsule-global.conf' "$SMB_CONF"; then
    perl -0pi -e 's/^\[global\]/[global]\n   include = \/etc\/samba\/timecapsule-global.conf/m' "$SMB_CONF"
fi
if ! grep -q 'timecapsule-share.conf' "$SMB_CONF"; then
    if grep -q '^\[TimeMachine\]' "$SMB_CONF"; then
        warn "Un bloc [TimeMachine] manuel existe déjà dans smb.conf : retirez-le pour éviter un doublon (sauvegarde: $SMB_CONF.pre-timecapsule)"
    else
        printf '\ninclude = /etc/samba/timecapsule-share.conf\n' >> "$SMB_CONF"
    fi
fi
grep -q 'timecapsule-global.conf' "$SMB_CONF" || die "[global] introuvable dans $SMB_CONF"
testparm -s >/dev/null 2>&1 || die "smb.conf invalide, vérifiez avec : testparm"

# Mot de passe Samba : saisi directement dans smbpasswd, ce script ne le voit jamais
if pdbedit -L 2>/dev/null | grep -q "^$SMB_USER:" && ! ask_yn "L'utilisateur Samba '$SMB_USER' existe déjà. Changer son mot de passe ? / Change its password?" n; then
    ok "Mot de passe Samba conservé"
else
    echo "Choisissez le mot de passe Samba (celui que vous taperez sur le Mac) :"
    smbpasswd -a "$SMB_USER"
fi
ok "Samba configuré"

# ---------------------------------------------------------------- démarrage
info "Montage de la Time Capsule et démarrage des services..."
systemctl enable timecapsule-mount.service smbd avahi-daemon timecapsule-keepalive.timer timecapsule-watchdog.timer >/dev/null 2>&1
systemctl restart avahi-daemon

if systemctl restart timecapsule-mount.service; then
    ok "Time Capsule montée sur $MOUNT_POINT"
    systemctl restart smbd
    ok "Samba démarré"
else
    warn "Le montage a échoué. Vérifiez l'IP, le nom du volume et le mot de passe (sudo timecapsule-ctl set-password), puis :"
    warn "  sudo timecapsule-ctl mount     (journal : sudo timecapsule-ctl logs)"
fi
systemctl start timecapsule-keepalive.timer timecapsule-watchdog.timer
systemctl start timecapsule-keepalive.service || true

# Vérification allow_other (accès sans root)
if timeout 15 mountpoint -q "$MOUNT_POINT" && ! sudo -u "$SMB_USER" timeout 15 ls "$MOUNT_POINT" >/dev/null 2>&1; then
    warn "Le montage n'est pas lisible sans root : le patch allow_other n'est pas actif (voir README, Dépannage)."
fi

echo
/usr/local/bin/timecapsule-ctl audit || true

bold "
 Terminé / Done !

 Sur le Mac : Réglages Système > Général > Time Machine > +
 puis choisissez « TimeMachine » sur « $NETBIOS_NAME.local »
 Identifiants : $SMB_USER + le mot de passe Samba que vous venez de définir.
 On the Mac: System Settings > General > Time Machine > + > pick \"TimeMachine\" on \"$NETBIOS_NAME.local\".

 Protections actives / Active protections :
   1. TCP keepalive noyau (sysctl)
   2. Keepalive AFP chaque minute   (timecapsule-keepalive.timer)
   3. Watchdog chaque minute (timecapsule-watchdog.timer), avec dossier d'incident

 Commandes utiles / Useful commands :
   sudo timecapsule-ctl status      état actuel et depuis combien de temps
   sudo timecapsule-ctl report      historique des pannes : durées connecté, causes, avant/après
   sudo timecapsule-ctl logs -f     journal en direct
   sudo timecapsule-ctl mount       remonter à la main (demande le mot de passe au terminal)
   sudo timecapsule-ctl audit       vérifications de sécurité

 Une première sauvegarde complète peut durer plusieurs jours (les suivantes prennent quelques minutes).
"
