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

## Downloads / Téléchargements

- **[TimeCapsule_RPi_Bridge_Guide_FR_EN.pdf](TimeCapsule_RPi_Bridge_Guide_FR_EN.pdf)** — Time Capsule bridge tutorial (French + English)
- **[Tuto_Raspberry_Pi_Serveur_Maison.pdf](Tuto_Raspberry_Pi_Serveur_Maison.pdf)** — Complete home server tutorial in French (Pi-hole, WireGuard VPN, DuckDNS, AnyDesk, Wake-on-LAN, Time Machine, SSH keys)

## The Problem

The Apple Time Capsule only shares its disk via AFP (Apple Filing Protocol). Modern Linux kernels have dropped SMB1/NTLM support, and the only AFP client for Linux (afpfs-ng) has been abandoned since 2020. Mounting a Time Capsule from a Raspberry Pi in 2026 is extremely difficult.

## The Solution

This guide walks you through:

1. **Compiling afpfs-ng** with libgcrypt (for DHX2 authentication) and allow_other (for Samba access) using Docker
2. **Mounting the Time Capsule** via AFP on the Raspberry Pi
3. **Configuring Samba** with specific options that prevent crashes on FUSE mounts
4. **Configuring Avahi** so macOS auto-discovers the Pi as a Time Machine target
5. **Setting up a systemd service** for auto-mount on boot
6. **Setting up a watchdog script** that auto-remounts if the AFP connection drops

## Key Technical Challenges Solved

| Problem | Solution |
|---------|----------|
| afpfs-ng won't compile on modern systems | Built via Docker using [rc2dev/afpfs-ng-deb](https://github.com/rc2dev/afpfs-ng-deb) + libgcrypt20-dev |
| Pre-built package lacks DHX2 authentication | Added libgcrypt20-dev to Dockerfile |
| FUSE blocks access from other users (Samba) | Patched source: `changeuid=1` + `if(1)` in commands.c |
| Samba kernel oplocks crash FUSE mount | `kernel oplocks = no` + `kernel share modes = no` in smb.conf |
| Extended attributes not supported on FUSE/AFP | `streams_depot` instead of `streams_xattr` |
| AFP mount disconnects over time | Watchdog cron script every 12h |
| Spaces in volume name crash afpfs-ng | Rename volume without spaces in AirPort Utility |
| Samba connection drops during backup | `socket options = TCP_NODELAY IPTOS_LOWLATENCY SO_KEEPALIVE` |

## Critical smb.conf Options

```ini
[global]
    smbd:backgroundqueue = no
    socket options = TCP_NODELAY IPTOS_LOWLATENCY SO_KEEPALIVE
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

## Tested On

- Raspberry Pi 4 (2 GB RAM)
- Raspberry Pi OS Lite 64-bit (Debian Trixie)
- macOS Tahoe
- Apple Time Capsule 802.11ac (firmware 7.9.1)
- Ethernet connection for the Pi (essential)

## Good to Know

- The first backup is very slow (several days) — data goes through the AFP/FUSE bridge
- Subsequent incremental backups are fast (minutes)
- The Pi **must** be on Ethernet for stability
- The watchdog script auto-remounts if the AFP connection drops

## AI-Assisted Setup

If this tutorial seems too complicated, you can give the PDF to an AI (Claude, ChatGPT or similar) and ask it to guide you step by step. However, **write down your usernames, IP addresses and passwords separately**: do not share them with the AI, enter them yourself when needed.

## Credits

- [afpfs-ng](https://github.com/simonvetter/afpfs-ng) by Simon Vetter — AFP client for Linux
- [afpfs-ng-deb](https://github.com/rc2dev/afpfs-ng-deb) by Rafael Cavalcanti — Debian packaging for afpfs-ng
- [Samba](https://www.samba.org/) — SMB server with fruit module for Time Machine
- [Avahi](https://avahi.org/) — mDNS/Bonjour for Linux

## License

This guide is provided as-is for educational and personal use.
