# =============================================================================
#  Installateur Windows : Time Capsule + Raspberry Pi (pont AFP -> SMB)
#  Copie le projet sur le Raspberry Pi puis lance l'installation a distance.
#  Les mots de passe sont demandes par le Pi (ssh / sudo) : ce script ne les voit jamais.
# =============================================================================
$ErrorActionPreference = 'Stop'
$Host.UI.RawUI.WindowTitle = 'Time Capsule + Raspberry Pi - Installateur'

function Pause-Exit([int]$code) {
    Write-Host ''
    Read-Host 'Appuyez sur Entree pour fermer'
    exit $code
}

Clear-Host
Write-Host '======================================================'
Write-Host '  Time Capsule + Raspberry Pi  -  Installateur Windows'
Write-Host '======================================================'
Write-Host ' Avant de commencer, il faut :'
Write-Host '  - un Raspberry Pi avec Raspberry Pi OS Lite, branche en Ethernet, SSH active'
Write-Host '  - le disque de la Time Capsule renomme SANS espaces (Utilitaire AirPort sur Mac, iPhone ou iPad)'
Write-Host '  - le mot de passe du disque de la Time Capsule sous la main'
Write-Host ''

# --- outils Windows necessaires : ssh, scp, tar (inclus dans Windows 10/11)
foreach ($tool in 'ssh', 'scp', 'tar') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Host "L'outil '$tool' est introuvable." -ForegroundColor Red
        Write-Host "Activez le 'Client OpenSSH' : Parametres > Systeme > Fonctionnalites facultatives > Ajouter une fonctionnalite > Client OpenSSH."
        Write-Host 'Puis relancez ce fichier.'
        Pause-Exit 1
    }
}

$payload = Join-Path $PSScriptRoot 'payload'
if (-not (Test-Path (Join-Path $payload 'install.sh'))) {
    Write-Host "Dossier 'payload' introuvable : decompressez TOUT le zip avant de lancer (clic droit > Extraire tout)." -ForegroundColor Red
    Pause-Exit 1
}

$hostName = if ($env:TCB_HOST) { $env:TCB_HOST } else { Read-Host "Adresse du Raspberry Pi (Entree = raspberrypi.local)" }
if (-not $hostName) { $hostName = 'raspberrypi.local' }
$userName = if ($env:TCB_USER) { $env:TCB_USER } else { Read-Host "Nom d'utilisateur du Raspberry Pi" }
if (-not $userName) { Write-Host "Nom d'utilisateur obligatoire." -ForegroundColor Red; Pause-Exit 1 }

$tgz = Join-Path $env:TEMP 'tcb.tgz'
if (Test-Path $tgz) { Remove-Item $tgz -Force }

Write-Host ''
Write-Host '==> Preparation du paquet...'
& tar -czf $tgz -C $payload .
if ($LASTEXITCODE -ne 0) { Write-Host 'Impossible de preparer le paquet.' -ForegroundColor Red; Pause-Exit 1 }

Write-Host "==> Connexion au Raspberry Pi ($userName@$hostName)."
Write-Host "    On vous demandera le mot de passe de l'utilisateur du Pi (rien ne s'affiche quand vous tapez)."
& scp -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -q $tgz "${userName}@${hostName}:/tmp/tcb.tgz"
if ($LASTEXITCODE -ne 0) {
    Remove-Item $tgz -Force -ErrorAction SilentlyContinue
    Write-Host ''
    Write-Host 'Connexion impossible. Verifiez :' -ForegroundColor Red
    Write-Host '  - que le Pi est allume, branche en Ethernet, et que SSH est active'
    Write-Host "  - l'adresse : essayez l'IP du Pi (visible dans l'interface de votre box) a la place de $hostName"
    Write-Host "  - le nom d'utilisateur et le mot de passe"
    Pause-Exit 1
}
Remove-Item $tgz -Force -ErrorAction SilentlyContinue
Write-Host '==> Paquet copie sur le Pi.'

$remote = 'mkdir -p "$HOME/timecapsule-rpi-bridge" && tar -xzf /tmp/tcb.tgz -C "$HOME/timecapsule-rpi-bridge" && rm -f /tmp/tcb.tgz && cd "$HOME/timecapsule-rpi-bridge" && '
if ($env:TCB_TEST) { $remote += "bash -n install.sh && echo 'TEST-OK'" } else { $remote += 'sudo bash install.sh' }

Write-Host "==> Lancement de l'installation sur le Pi (suivez les questions a l'ecran)..."
Write-Host '    Le mot de passe du Pi vous sera redemande une fois : c est normal.'
Write-Host ''
& ssh -t -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 "${userName}@${hostName}" $remote
$rc = $LASTEXITCODE
Write-Host ''
if ($rc -eq 0) { Write-Host 'Termine. Vous pouvez fermer cette fenetre.' -ForegroundColor Green }
else { Write-Host "L'installation s'est arretee (code $rc). Relancez ce fichier pour reessayer, ou copiez le message d'erreur." -ForegroundColor Yellow }
Pause-Exit $rc
