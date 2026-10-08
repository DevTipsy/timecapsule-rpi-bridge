#!/bin/bash
# =============================================================================
#  Installateur macOS : Time Capsule + Raspberry Pi (pont AFP -> SMB)
#  Double-cliquez ce fichier. Il copie le projet sur le Raspberry Pi puis lance
#  l'installation a distance. Les mots de passe sont demandes par le Pi
#  (ssh / sudo), ce script ne les voit jamais.
# =============================================================================
cd "$(dirname "$0")" || exit 1
PAYLOAD="$(pwd)/payload"
TMPTGZ="$(mktemp -t tcb).tgz"
trap 'rm -f "$TMPTGZ"' EXIT

clear
cat <<'B'
 ======================================================
   Time Capsule + Raspberry Pi  -  Installateur macOS
 ======================================================
  Avant de commencer, il faut :
   - un Raspberry Pi avec Raspberry Pi OS Lite, branche en Ethernet, SSH active
   - le disque de la Time Capsule renomme SANS espaces (Utilitaire AirPort)
   - le mot de passe du disque de la Time Capsule sous la main

B

HOST="${TCB_HOST:-}"; USERNAME="${TCB_USER:-}"
if [ -z "$HOST" ]; then
    read -r -p "Adresse du Raspberry Pi (Entree = raspberrypi.local) : " HOST
    HOST="${HOST:-raspberrypi.local}"
fi
if [ -z "$USERNAME" ]; then
    read -r -p "Nom d'utilisateur du Raspberry Pi : " USERNAME
fi
[ -n "$USERNAME" ] || { echo "Nom d'utilisateur obligatoire."; exit 1; }
[ -d "$PAYLOAD" ] || { echo "Dossier 'payload' introuvable : decompressez tout le zip avant de lancer."; exit 1; }

# Une seule connexion (un seul mot de passe) pour la copie ET l'installation
CTL="/tmp/tcb-ssh-$$"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o ControlMaster=auto -o "ControlPath=$CTL" -o ControlPersist=300)
cleanup() { ssh "${SSH_OPTS[@]}" -O exit "$USERNAME@$HOST" 2>/dev/null; rm -f "$TMPTGZ"; }
trap cleanup EXIT

echo
echo "==> Preparation du paquet..."
# sans les attributs etendus macOS (sinon le Pi affiche des avertissements inutiles)
{ COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -czf "$TMPTGZ" -C "$PAYLOAD" . 2>/dev/null \
    || COPYFILE_DISABLE=1 tar -czf "$TMPTGZ" -C "$PAYLOAD" . ; } || { echo "Impossible de preparer le paquet."; exit 1; }

echo "==> Connexion au Raspberry Pi ($USERNAME@$HOST)."
echo "    Si on vous demande un mot de passe, c'est celui de l'utilisateur du Pi (rien ne s'affiche quand vous tapez)."
if ! scp "${SSH_OPTS[@]}" -q "$TMPTGZ" "$USERNAME@$HOST:/tmp/tcb.tgz"; then
    echo
    echo "Connexion impossible. Verifiez :"
    echo "  - que le Pi est allume et branche en Ethernet, et que SSH est active"
    echo "  - l'adresse : essayez l'IP du Pi (visible dans l'interface de votre box) a la place de $HOST"
    echo "  - le nom d'utilisateur et le mot de passe"
    exit 1
fi
echo "==> Paquet copie sur le Pi."

REMOTE='mkdir -p "$HOME/timecapsule-rpi-bridge" && tar -xzf /tmp/tcb.tgz -C "$HOME/timecapsule-rpi-bridge" && rm -f /tmp/tcb.tgz && cd "$HOME/timecapsule-rpi-bridge"'
if [ -n "${TCB_TEST:-}" ]; then
    REMOTE="$REMOTE && echo TEST-OK: \$(ls | tr '\\n' ' ') && bash -n install.sh && echo 'install.sh : syntaxe OK'"
else
    REMOTE="$REMOTE && sudo bash install.sh"
fi
echo "==> Lancement de l'installation sur le Pi (suivez les questions a l'ecran)..."
echo
ssh -t "${SSH_OPTS[@]}" "$USERNAME@$HOST" "$REMOTE"
RC=$?
echo
if [ $RC -eq 0 ]; then echo "Termine. Vous pouvez fermer cette fenetre."; else echo "L'installation s'est arretee (code $RC). Relancez ce fichier pour reessayer, ou copiez le message d'erreur."; fi
[ -z "${TCB_TEST:-}" ] && read -r -p "Appuyez sur Entree pour fermer..." _
exit $RC
