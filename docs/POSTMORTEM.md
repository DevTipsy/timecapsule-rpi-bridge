# Post-mortem : pourquoi la sauvegarde s'arrêtait après quelques jours

*Analyse faite le 8 octobre 2026 sur un Raspberry Pi 4 (Debian Trixie) qui servait de pont vers une Time Capsule depuis 202 jours. Les adresses et identifiants sont volontairement omis.*

## En une phrase

Le client AFP (`afpfsd`) s'est figé le 20 août ; les scripts de surveillance, qui accédaient au montage **sans timeout**, se sont figés avec lui, se sont empilés (plus de 1 500 processus) jusqu'à saturer la limite de tâches de `cron`, et **plus rien ne tournait pour réparer** : Samba restait actif sur un montage mort, et Time Machine recevait des `Broken pipe`.

## Chaîne de défaillance

| # | Quand | Ce qui s'est passé | Preuve |
|---|-------|--------------------|--------|
| 1 | 20 août, 21 h 05 | Un remontage lance `afpfsd` **depuis cron** : le démon vit dans le groupe de contrôle `cron.service` | `/proc/<pid>/cgroup` = `cron.service` |
| 2 | 20 août, 21 h 06 | Le montage ne répond plus. Les requêtes FUSE attendent indéfiniment | `wchan=request_wait_answer`, `fuse waiting=998` |
| 3 | 21 h 06 → 02 h 33 | Chaque minute, `keepalive` puis `watchdog` lancent `ls` **sans timeout** : ils se bloquent et ne rendent jamais la main (~3,7 processus de plus par minute) | 328 keepalive + 65 watchdog + 392 `ls` bloqués, tous nés dans cette fenêtre de 5 h 30 |
| 4 | 21 août, 02 h 33 | `cron.service` atteint sa limite (1 576 tâches). **Cron ne peut plus lancer aucune tâche.** | `Tasks: 1575 (limit: 1576)`, `Fork failed: Resource temporarily unavailable` chaque minute |
| 5 | 21 août → 8 octobre | Plus de keepalive, plus de watchdog. Samba reste actif et accumule 600+ processus bloqués. Le Mac reçoit des erreurs de connexion | `smbd` : 607 tâches ; côté Mac : `NAConnectToServerSync failed with error: 32 (Broken pipe)` |

Le watchdog d'origine aurait de toute façon échoué : son test (`ls … && ls -A …`) n'a pas de timeout, donc sur un montage figé il ne **détecte** rien, il se bloque.

## Ce qui n'était pas en cause

* **La Time Capsule** : elle répondait en 5 à 14 ms à une requête AFP de bas niveau (envoyée sans passer par `afpfsd`), 0 % de perte de ping.
* **Le réseau, le disque SD, l'alimentation, la température** : aucune erreur, `throttled=0x0`, 39 °C.

## Comportement observé d'`afpfsd` pendant le gel

Le processus est resté actif, ~1 600 paquets/s vers la capsule mais seulement ~60 octets par paquet (une vraie sauvegarde envoie des paquets de ~1 400 octets) et 7 jours de temps CPU cumulé en 48 jours. C'est compatible avec une boucle de resynchronisation du protocole DSI : le code d'afpfs-ng journalise `I have no idea what this is a reply to` quand il reçoit une réponse à une requête qu'il ne connaît plus. **La cause initiale du premier gel n'est pas établie** : les journaux d'août n'existent plus (journal systemd en RAM, aucun fichier de log). C'est précisément ce que les nouveaux journaux doivent capturer.

## Deuxième problème, indépendant : la capsule est pleine

Côté Mac, Time Machine échouait avec `BACKUP_FAILED_TARGETVOL_DISK_FULL` : le volume de 1,8 To était plein à 94 % (116 Go libres) alors que Time Machine exige 100 Go de marge. Le Mac sauvegardait ~1,6 To sur ce volume, ce qui ne tient plus quand on garde l'historique.

## Constats de sécurité (installation d'origine)

* Le mot de passe de la capsule figurait **en clair** dans deux scripts, une sauvegarde `.bak`, et surtout dans l'unité systemd (lisible par tous les utilisateurs du Pi via `systemctl cat`), ainsi que sur la ligne de commande d'`afp_client` (visible dans `ps`).
* SSH acceptait encore les mots de passe, malgré l'intention « clés uniquement ».
* Services inutiles exposés : un second serveur AFP (`netatalk`, port 548) et `rpcbind` (port 111).
* Le Pi avait deux interfaces (Ethernet et Wi-Fi) sur le même sous-réseau, avec deux routes par défaut.
* 217 mises à jour de paquets en attente.

## Corrections apportées par ce dépôt

| Problème | Correction |
|----------|------------|
| `ls` sans timeout qui gèle les scripts | Tous les accès au montage passent par `timeout -s KILL` |
| Empilement de processus | cron remplacé par des **timers systemd** : une seule exécution à la fois, `TimeoutStartSec`, `KillMode=control-group`, `TasksMax` |
| `afpfsd` dans `cron.service` | Le démon vit dans `timecapsule-mount.service` (limite de processus propre) |
| Montage gelé impossible à nettoyer | `echo 1 > /sys/fs/fuse/connections/N/abort` libère d'un coup tous les accès bloqués avant le démontage |
| Samba actif sur un montage mort | Samba dépend du service de montage ; le watchdog l'arrête avant de réparer et ne le relance qu'une fois le montage vérifié |
| Aucune trace des pannes | Journal d'événements, instantané complet avant/après chaque changement d'état, dossier d'incident, journal systemd persistant |
| Mot de passe en clair | Chiffré par `systemd-creds`, transmis à `afp_client` par l'entrée standard |
