# Apple Time Capsule + Raspberry Pi: AFP to SMB Bridge for Time Machine

**Keep using your Apple Time Capsule with future macOS versions.**

Apple discontinued the Time Capsule in 2018. Future macOS versions (27+) will drop AFP support entirely. This guide configures a Raspberry Pi as a bridge: it mounts the Time Capsule via AFP, then re-shares it via SMB. Your Mac backs up via Time Machine over SMB through the Pi to the Time Capsule.

This setup is unique and not documented anywhere else.

```
Mac (Time Machine / SMB) ──> Raspberry Pi (Samba) ──> Time Capsule (AFP)
                                     │
                              afpfs-ng (FUSE)
                                     │
                           /mnt/timecapsule
```

## Easy install for beginners / Installation facile pour les débutants

No command line needed: download the zip for your computer, unzip it, and double-click the installer. It copies the project to your Raspberry Pi and runs the setup there. **The Pi asks for its own passwords; the installer never sees them.**

Pas de ligne de commande : téléchargez le zip de votre ordinateur, décompressez-le et double-cliquez sur l'installateur. Il copie le projet sur votre Raspberry Pi et lance l'installation. **Les mots de passe sont demandés par le Pi lui-même ; l'installateur ne les voit jamais.**

| Your computer / Votre ordinateur | Download / Téléchargement | Then / Ensuite |
|---|---|---|
| **Mac** | [TimeCapsule-Bridge-macOS.zip](https://github.com/DevTipsy/timecapsule-rpi-bridge/raw/main/installers/TimeCapsule-Bridge-macOS.zip) | Unzip, double-click `Installer-macOS.command` |
| **Windows 10 / 11** | [TimeCapsule-Bridge-Windows.zip](https://github.com/DevTipsy/timecapsule-rpi-bridge/raw/main/installers/TimeCapsule-Bridge-Windows.zip) | Right-click › Extract All, double-click `Installer-Windows.bat` |

Before you start / Avant de commencer:

1. **Raspberry Pi**: install *Raspberry Pi OS Lite (64-bit)* with [Raspberry Pi Imager](https://www.raspberrypi.com/software/), enable **SSH**, choose a username and password, plug it in with **Ethernet**.
2. **Time Capsule**: in AirPort Utility, rename the disk **without spaces** (e.g. `AirPortTimeCapsule`) and note its disk password (and the capsule IP).
3. Run the installer, answer the questions (capsule IP, volume name, ...), then add the share in *System Settings > General > Time Machine > +*.

macOS or Windows may warn that the installer is unsigned. Mac: right-click › Open › Open (or *System Settings > Privacy & Security > Open Anyway*). Windows: *More info* › *Run anyway*. The Windows installer needs the built-in "OpenSSH Client" (installed by default on Windows 10/11). Detailed step-by-step instructions: see the PDFs below. A `LISEZ-MOI.txt` (FR/EN) is included in each zip. On the first connection the installer automatically trusts the Pi's SSH host key (`StrictHostKeyChecking=accept-new`), which is fine on your home network.

> The installers are plain scripts you can read before running: [`installers/macos/Installer-macOS.command`](installers/macos/Installer-macOS.command), [`installers/windows/Installer-Windows.ps1`](installers/windows/Installer-Windows.ps1). They only copy this project to the Pi and run `install.sh` there over SSH. Rebuild the zips after changing the project with `bash tools/build-installers.sh`.

## Downloads / Téléchargements

- **[TimeCapsule_RPi_Bridge_Guide_FR_EN.pdf](TimeCapsule_RPi_Bridge_Guide_FR_EN.pdf)** — Time Capsule bridge guide, version 2: one-click install, monitoring, logs, encrypted passwords (French + English)
- **[Tuto_Raspberry_Pi_Serveur_Maison.pdf](Tuto_Raspberry_Pi_Serveur_Maison.pdf)** — Complete home server tutorial in French, version 2 (Pi-hole, WireGuard VPN, DuckDNS, AnyDesk, Wake-on-LAN, Time Machine, SSH hardening)

## Quick Install / Installation rapide

**On the Raspberry Pi (Ethernet, Raspberry Pi OS Lite 64-bit):**

```bash
git clone https://github.com/DevTipsy/timecapsule-rpi-bridge.git
cd timecapsule-rpi-bridge
sudo bash install.sh
```

No `git`? Download the ZIP from GitHub (**Code > Download ZIP**), copy it to the Pi, `unzip` it, then `cd` into the folder and run `sudo bash install.sh`.

Sans `git` ? Téléchargez le ZIP depuis GitHub (**Code > Download ZIP**), copiez-le sur le Pi, décompressez-le, puis lancez `sudo bash install.sh` dans le dossier.

Before you start, rename the Time Capsule disk **without spaces** in AirPort Utility (e.g. `AirPortTimeCapsule`). The installer asks for the capsule IP, the volume name, a Samba username (an existing Linux user on the Pi) and an optional max backup size. Then it does everything: installs packages, compiles afpfs-ng with Docker (10 to 30 minutes on a Pi), patches `allow_other`, configures Samba, Avahi, systemd, sysctl and the monitoring, and mounts the capsule. When it finishes, pick **TimeMachine** on `<hostname>.local` in *System Settings > General > Time Machine*.

**No password is ever written in clear text, passed on a command line, or read by the installer** (see [Security](#security)):

- the Time Capsule disk password is typed once into `timecapsule-ctl set-password`, which encrypts it with `systemd-creds`;
- the Samba password is typed directly into `smbpasswd`.

The installer is safe to re-run (the afpfs-ng build is skipped if already installed, `smb.conf` is backed up to `smb.conf.pre-timecapsule`). Upgrading from the older cron-based version is handled automatically: old cron jobs and every file containing a clear-text password are removed.

## The Problem

The Apple Time Capsule only shares its disk via AFP (Apple Filing Protocol). Modern Linux kernels have dropped SMB1/NTLM support, and the only AFP client for Linux (afpfs-ng) has been abandoned since 2020. Mounting a Time Capsule from a Raspberry Pi in 2026 is extremely difficult.

## The Solution

This guide walks you through:

1. **Compiling afpfs-ng** with libgcrypt (for DHX2 authentication) and allow_other (for Samba access) using Docker
2. **Mounting the Time Capsule** via AFP on the Raspberry Pi
3. **Configuring Samba** with specific options that prevent crashes on FUSE mounts
4. **Configuring Avahi** so macOS auto-discovers the Pi as a Time Machine target
5. **Setting up a systemd service** for auto-mount on boot
6. **Protecting the connection with 3 layers** (kernel TCP keepalive, AFP keepalive, smart watchdog)

## Key Technical Challenges Solved

| Problem | Solution |
|---------|----------|
| afpfs-ng won't compile on modern systems | Built via Docker using [rc2dev/afpfs-ng-deb](https://github.com/rc2dev/afpfs-ng-deb) + libgcrypt20-dev |
| Pre-built package lacks DHX2 authentication | Added libgcrypt20-dev to Dockerfile |
| FUSE blocks access from other users (Samba) | Patched source: `changeuid=1` + `if(1)` in commands.c |
| Samba kernel oplocks crash FUSE mount | `kernel oplocks = no` + `kernel share modes = no` in smb.conf |
| Extended attributes not supported on FUSE/AFP | `streams_depot` instead of `streams_xattr` |
| AFP mount disconnects over time | 3 layers of protection (see below) |
| Spaces in volume name crash afpfs-ng | Rename volume without spaces in AirPort Utility |
| Samba connection drops during backup | `socket options = TCP_NODELAY SO_KEEPALIVE` |

## 3 Layers of Stability

The AFP session of a Time Capsule can drop when it stays idle or when the network hiccups, and the Linux AFP client can freeze. Three independent layers handle that:

| Layer | What | How often | File |
|-------|------|-----------|------|
| 1. Kernel TCP keepalive | Detects a dead connection in ~2 min instead of 2 h | permanent | [`configs/99-timecapsule-keepalive.conf`](configs/99-timecapsule-keepalive.conf) |
| 2. Read-only probe | Checks the mount with a read (`stat`, served from the capsule's memory), pings the capsule and records a full health snapshot. It does **not** write every minute: the capsule's disk falls asleep after about a minute of inactivity (a write after that costs ~5 s), so a minute-by-minute write would wake it up 1,440 times a day for nothing. The AFP session itself is kept alive by the protocol (the capsule sends a "tickle" every 30 s and the client answers). A real write test runs only every 6 h (`KEEPALIVE_WRITE_EVERY_S`, `0` = never) | every minute | [`scripts/timecapsule-keepalive.sh`](scripts/timecapsule-keepalive.sh) |
| 3. Watchdog | If the mount is dead: saves an incident report, **stops Samba first**, aborts the frozen FUSE connection, remounts, verifies, restarts Samba. Circuit breaker: max 6 attempts per hour | every minute | [`scripts/timecapsule-watchdog.sh`](scripts/timecapsule-watchdog.sh) |

**Why systemd timers instead of cron:** a frozen mount makes any plain `ls` hang forever. With cron, each run stacked on the previous ones until cron hit its process limit and stopped running anything (see the [post-mortem](docs/POSTMORTEM.md)). The timers never overlap, kill hung runs after a timeout, and have their own process cap. Every access to the mount also goes through `timeout -s KILL`.

`smbd` is bound to the mount service (`Requires=timecapsule-mount.service`), so Samba never starts at boot if the capsule isn't mounted (Time Machine would otherwise write its backup into an empty folder on the Pi's SD card).

## Logs and Diagnostics

Everything is logged, so the next failure explains itself: how long the connection stayed up, and **what changed between the last good state and the failure**.

```bash
sudo timecapsule-ctl status      # current state, since when, last events
sudo timecapsule-ctl report      # every state change: causes, how long the previous state lasted, what changed
sudo timecapsule-ctl logs -f     # live event log
sudo timecapsule-ctl incidents   # list of incident reports
```

| What | Where |
|------|-------|
| Event log (`key=value`, one line per event) | `/var/log/timecapsule/events.log` (rotated weekly, 26 weeks kept) |
| Incident report at each failure and before each recovery | `/var/log/timecapsule/incidents/` (kept 6 months) |
| Same events in the system journal | `journalctl -t timecapsule` (journal is made persistent by the installer) |

**State changes** (`OK`, `DEGRADED`, `DOWN`) are logged with `prev_duration` (how long the previous state lasted, e.g. how long it stayed connected), `reasons`, `changed` (the fields that differ) and the full `before` / `after` snapshots. A snapshot contains: mount and FUSE queue length, `stat` latency, capsule ping and a low-level AFP probe (independent of the Pi's AFP client), `afpfsd` state/age/CPU, TCP session counters and packets per second, Samba sessions and tasks, process limits of each service, stuck processes, both network interfaces, load, memory, temperature, throttling, and free space on the capsule.

Example (illustrative values):

```
2026-10-08T12:31:25+02:00 level=ERROR event=state_change from=OK to=DOWN reasons=stat_failed_rc137,fuse_queue_stalled_998
  prev_duration=12j04h31m10s changed="stat_rc:0->137 fuse_waiting:0->998 tcp_pps:35->1604 ..." before="..." after="..."
```

An **incident report** adds: the process list with kernel wait channel, `afpfsd` threads and cgroup, FUSE connection state, TCP details and kernel retransmission counters, interface error counters, ping and AFP probe, Samba sessions, and the last 30 minutes of kernel and service logs.

**Backups seen by the bridge.** Each Time Machine run shows up as traffic to the capsule, so the Pi logs `backup_traffic_start` / `backup_traffic_end` (when, how long, how many MB each way, free space). `sudo timecapsule-ctl report` summarises them per day and flags gaps longer than 90 minutes, which answers "did the automatic backup run?" without relying on the Mac's logs (which only keep about 19 hours of detail). The Pi also logs every Samba connection and disconnection (`smb_clients_changed`), and Samba itself logs each authentication, successful or refused, with the client (`/var/log/samba/log.*`).

**On the Mac**, run once `bash tools/install-mac-logger.sh` (a user LaunchAgent, no sudo; remove with `--uninstall`). Every 10 minutes it saves Time Machine's decisions (which destination it picked, the pre-backup write test, backup passes, failures, "Backup succeeded, elapsed time") to `~/Library/Logs/TimeCapsuleBridge/tm-events.log`, plus an environment line in `mac-env.log` (is a backup running, does the Pi answer on DNS/ping/SMB, is the share mounted, last snapshot of each destination, what blocks sleep).

Warnings are raised before things break: free space on the capsule below 150 GB, slow responses, a FUSE queue building up, a packet storm from the AFP client, Samba stopped while the mount is healthy.

On the Mac, [`tools/mac-timemachine-report.sh`](tools/mac-timemachine-report.sh) shows which destination Time Machine uses and groups its recent errors (disk full, broken pipe, ...).

## Security

- **No clear-text password anywhere.** The Time Capsule password is encrypted with `systemd-creds` (`/etc/timecapsule/capsule-password.cred`, root only). systemd decrypts it **in memory only, for the mount service**, and the script hands it to `afp_client` through standard input (`-p -`), so it never appears in `ps`, in a unit file, or in a script.
- **Manual mode.** If you'd rather never store it, choose "memory only" at install, or run `sudo timecapsule-ctl mount`: the password is requested at the terminal (hidden input) and kept only in RAM until reboot. After a reboot the mount then waits for you.
- **Samba** keeps only a password hash (standard Samba behaviour); the installer never sees the password.
- **Honest limits:** `systemd-creds` on a Pi (no TPM) uses a key stored on the same SD card, so it protects against casual reads, copies of config files, backups and screen sharing, but not against someone holding both the SD card image and root. Unattended auto-remount necessarily means the machine can recover the secret; use manual mode if that trade-off is not acceptable.
- `sudo timecapsule-ctl audit` checks: leftover clear-text passwords (scripts, units, cron, shell history), file permissions, SSH password login, unneeded open ports (`netatalk`, `rpcbind`), pending updates, persistent journal, two interfaces on the same subnet.
- Rotate the capsule password if it ever appeared in a script, unit file, shell history, chat or screenshot.

## Critical smb.conf Options

```ini
[global]
    smbd:backgroundqueue = no
    socket options = TCP_NODELAY SO_KEEPALIVE
    min protocol = SMB2
    kernel oplocks = no
    kernel share modes = no

[TimeMachine]
    path = /mnt/timecapsule
    force user = root
    vfs objects = catia fruit streams_depot
    fruit:metadata = stream
    fruit:encoding = native
    fruit:aapl = yes
    fruit:time machine = yes
    nt acl support = no
```

## Repository Layout

```
install.sh                         Interactive installer (run with sudo bash)
scripts/
  timecapsule-lib.sh               Shared functions: timeouts, snapshot, state machine, logs
  timecapsule-mount.sh             Mount / unmount / clean (password via systemd or hidden prompt)
  timecapsule-keepalive.sh         Layer 2, every minute (+ health probe and logging)
  timecapsule-watchdog.sh          Layer 3, every 2 minutes (detect, capture, remount)
  timecapsule-ctl                  status, report, logs, set-password, mount, audit
  timecapsule-dsi-probe            Low-level AFP probe (is the capsule itself alive?)
configs/
  Dockerfile                       afpfs-ng build image (adds libgcrypt for DHX2)
  timecapsule.conf.template        Capsule IP / volume (no password)
  timecapsule-mount.service        systemd mount unit
  timecapsule-{keepalive,watchdog}.{service,timer}   systemd timers (replace cron)
  smbd-override.conf               Samba depends on the mount, process cap
  smb-global.conf.template         Samba [global] options (included from smb.conf)
  smb-share.conf.template          Samba [TimeMachine] share (included from smb.conf)
  avahi-timecapsule.service        Bonjour advertisement for Time Machine
  99-timecapsule-keepalive.conf    Layer 1 sysctl
  journald-persistent.conf, timecapsule.logrotate, timecapsule-tmpfiles.conf   Logs
installers/
  TimeCapsule-Bridge-macOS.zip      Beginner installer for Mac (double-click)
  TimeCapsule-Bridge-Windows.zip    Beginner installer for Windows (double-click)
  macos/, windows/                  Sources of the launchers (zips are built from these)
tools/
  mac-timemachine-report.sh        Run on the Mac: Time Machine destinations and errors
  mac-tm-logger.sh, install-mac-logger.sh   Durable Time Machine log on the Mac (LaunchAgent)
  build-installers.sh              Rebuild the installer zips
  build-pdfs.sh                    Rebuild the PDFs from docs/pdf-src/ (needs Google Chrome)
docs/POSTMORTEM.md                 Why backups stopped after a few weeks
docs/pdf-src/                      HTML sources of the PDFs
*.pdf                              Written guides (FR/EN), version 2
```

The installer includes the Samba files from `/etc/samba/timecapsule-*.conf` instead of rewriting `smb.conf`, so you can remove the bridge by deleting the two `include` lines.

## Tested On

- Raspberry Pi 4 (2 GB RAM)
- Raspberry Pi OS Lite 64-bit (Debian Trixie)
- macOS Tahoe
- Apple Time Capsule 802.11ac (firmware 7.9.1)
- Ethernet connection for the Pi (essential)

## Good to Know

- A first *full* backup is slow (days for a 1–2 TB disk: roughly 10 to 20 GB/h observed through the AFP/FUSE bridge). Later backups only copy what changed and take minutes
- The Pi **must** be on Ethernet for stability
- The 3 protection layers auto-remount the capsule if the AFP connection drops
- Keep at least 100 GB free on the capsule: Time Machine refuses to back up below that. Set a `Max backup size` that fits the capsule's real free space (Time Machine only sees this quota, not the disk): `sudo timecapsule-ctl set-max-size 1200G` (`none` = unlimited). Remove old backups before the disk fills up
- Configure **only one** Time Machine destination for the same capsule on the Mac (not the capsule directly over AFP *and* the Pi over SMB): both destinations point to the same backup file, which is confusing and risky

## Troubleshooting

Start with `sudo timecapsule-ctl status`, then `sudo timecapsule-ctl report`.

| Symptom | Fix |
|---------|-----|
| Mount frozen / `Transport endpoint not connected` | The watchdog fixes it within ~1-2 min. By hand: `sudo timecapsule-ctl clean && sudo timecapsule-ctl mount` |
| After a reboot, nothing is mounted | You chose "memory only": run `sudo timecapsule-ctl mount` and type the password |
| `Authentication failed` from the capsule | Wrong password **or missing username**. Test by hand: `sudo timecapsule-ctl mount-test [username]` (typed at the keyboard). The username is the account name in your Mac's Keychain entry for the capsule (often empty, or e.g. `AirportTimeCapsule`). Then `sudo timecapsule-ctl set-user NAME` and `sudo timecapsule-ctl set-password`. The watchdog stops retrying until you do, to avoid locking the capsule |
| `ls` works only with `sudo` | `allow_other` patch missing: `sudo rm -rf /opt/timecapsule-build; sudo apt remove afpfs-ng` and re-run `sudo bash install.sh` |
| Time Machine doesn't see the Pi | `sudo systemctl restart avahi-daemon smbd`; on the Mac, remove the disk (-) and re-add it (+) |
| Samba won't start after boot | Expected if the capsule isn't mounted; the watchdog starts it once the mount works |
| "Disk full" in Time Machine | See the `capsule_low_space` warnings in the report; free space on the capsule |
| `recovery_suspended` in the log | 6 failed recoveries in an hour: the capsule is probably off or unreachable; see the latest file in `/var/log/timecapsule/incidents/` |

Remote access from an iPhone or iPad over a VPN (WireGuard/PiVPN): in the Files app, *Connect to Server* with `smb://<IP_OF_THE_PI>/TimeMachine`. The VPN setup is covered in [Tuto_Raspberry_Pi_Serveur_Maison.pdf](Tuto_Raspberry_Pi_Serveur_Maison.pdf).

## AI-Assisted Setup

If this tutorial seems too complicated, you can give the PDF to an AI (Claude, ChatGPT or similar) and ask it to guide you step by step. However, **write down your usernames, IP addresses and passwords separately**: do not share them with the AI, enter them yourself when needed.

## Credits

- [afpfs-ng](https://github.com/simonvetter/afpfs-ng) by Simon Vetter — AFP client for Linux
- [afpfs-ng-deb](https://github.com/rc2dev/afpfs-ng-deb) by Rafael Cavalcanti — Debian packaging for afpfs-ng
- [Samba](https://www.samba.org/) — SMB server with fruit module for Time Machine
- [Avahi](https://avahi.org/) — mDNS/Bonjour for Linux

## License

This guide is provided as-is for educational and personal use.
