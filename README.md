# NexusPacket Manager

A terminal-based Linux server management panel for handling SSH/VPN user
accounts, trial accounts, protocol installs, and basic system administration.

Channel: https://t.me/NexusPacket_Official
Contact: https://t.me/NexusPacket

## Included
- Root-checked installer
- Terminal dashboard with OS/RAM/load/uptime/session information
- SSH account create/delete/lock/unlock/renew
- Trial accounts with automatic expiry
- User metadata: expiry, connection allowance, bandwidth allowance
- Bulk account operations
- Live interface traffic snapshot
- SSH login banner (NexusPacket branded)
- Package update / backup / cleanup
- HAProxy + Nginx package management
- Optional 3X-UI handoff to its official upstream installer
- Minimal local-admin web panel
- systemd expiry worker

## Install
```bash
chmod +x install.sh
sudo ./install.sh
sudo nexuspacket
```

## Security notes
- Review every third-party installer before executing it.
- The web panel is intentionally minimal and has no production authentication layer. Keep it behind a trusted network/VPN/reverse proxy or add authentication before exposing it publicly.
- The manager does not silently modify DNS, firewall policy, or third-party protocol binaries.
