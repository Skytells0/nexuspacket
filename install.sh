#!/usr/bin/env bash
set -euo pipefail

GH_USER="Skytells0"
GH_REPO="nexuspacket"
GH_BRANCH="main"
RAW="https://raw.githubusercontent.com/$GH_USER/$GH_REPO/$GH_BRANCH"

PREFIX="/usr/local/lib/nexuspacket-manager"
BIN="/usr/local/bin/nexuspacket"
ETC="/etc/nexuspacket-manager"

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }

echo "== NexusPacket Installer =="
echo "Channel: https://t.me/NexusPacket_Official"
echo "Contact: https://t.me/NexusPacket"

apt-get update -y
apt-get install -y bash curl jq openssh-server openssl procps iproute2 ca-certificates

mkdir -p "$PREFIX" "$ETC"

download_file() {
  local dest="$1" url="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$dest" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$dest" "$url"
  else
    echo "Error: neither curl nor wget is installed."; exit 1
  fi
}

# If running locally with the files next to this script, use them.
# Otherwise (curl | bash one-liner), fetch each file from GitHub.
SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" ]] && [[ -f "${BASH_SOURCE[0]}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/menu.sh" ]]; then
  install -m 0755 "$SCRIPT_DIR/menu.sh" "$PREFIX/menu.sh"
  install -m 0755 "$SCRIPT_DIR/panel.py" "$PREFIX/panel.py"
  install -m 0644 "$SCRIPT_DIR/README.md" "$PREFIX/README.md"
else
  echo "Fetching NexusPacket files from GitHub ($GH_USER/$GH_REPO)..."
  download_file "$PREFIX/menu.sh" "$RAW/menu.sh"
  download_file "$PREFIX/panel.py" "$RAW/panel.py"
  download_file "$PREFIX/README.md" "$RAW/README.md"
  chmod 0755 "$PREFIX/menu.sh" "$PREFIX/panel.py"
  chmod 0644 "$PREFIX/README.md"
fi

ln -sf "$PREFIX/menu.sh" "$BIN"

cat > /etc/systemd/system/nexuspacket-expiry.service <<EOF
[Unit]
Description=NexusPacket Manager account expiry worker
After=network.target

[Service]
Type=oneshot
ExecStart=$PREFIX/menu.sh --expiry-worker
EOF

cat > /etc/systemd/system/nexuspacket-expiry.timer <<EOF
[Unit]
Description=Run NexusPacket Manager expiry worker every minute

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=10s
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now nexuspacket-expiry.timer

echo "Installed. Start with: nexuspacket"
echo "Powered by NexusPacket | https://t.me/NexusPacket_Official"
