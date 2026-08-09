#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

APP="NexusPacket"
VERSION="1.0.0"
ROOT="/etc/nexuspacket-manager"
GH_USER="Skytells0"
GH_REPO="nexuspacket"
GH_BRANCH="main"
DB="$ROOT/users.db"
CONF="$ROOT/config"
LOG="$ROOT/actions.log"
GROUP="nexuspacket-users"
BANNER="/etc/ssh/sshd_config.d/nexuspacket-manager.conf"
PANEL_SERVICE="/etc/systemd/system/nexuspacket-panel.service"
PANEL="/usr/local/lib/nexuspacket-manager/panel.py"

R=$'\033[38;5;196m'; G=$'\033[38;5;46m'; Y=$'\033[38;5;226m'
B=$'\033[38;5;33m'; P=$'\033[38;5;93m'; C=$'\033[38;5;51m'
W=$'\033[38;5;255m'; D=$'\033[38;5;245m'; O=$'\033[38;5;213m'; Z=$'\033[0m'
N=$'\033[38;5;201m'  # NexusPacket neon accent

need_root(){ [[ $EUID -eq 0 ]] || { echo "${R}Root required.${Z}"; exit 1; }; }
init(){
  mkdir -p "$ROOT"
  touch "$DB" "$LOG"
  getent group "$GROUP" >/dev/null 2>&1 || groupadd "$GROUP"
  [[ -f "$CONF" ]] || cat >"$CONF" <<EOF
PANEL_PORT=44380
PANEL_ENABLED=0
EOF
}
log(){ printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; }

download_file(){
  local dest="$1" url="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$dest" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$dest" "$url"
  else
    return 1
  fi
}

valid_user(){ [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
randpass(){ tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-12}"; }

load_user(){
  local u="$1"
  awk -F: -v u="$u" '$1==u{print; exit}' "$DB"
}

user_exists(){ id "$1" >/dev/null 2>&1 || load_user "$1" | grep -q .; }

set_db(){
  local u="$1" line="$2" tmp
  tmp=$(mktemp)
  awk -F: -v u="$u" -v line="$line" 'BEGIN{OFS=":"} $1==u{print line; found=1; next} {print} END{if(!found) print line}' "$DB" >"$tmp"
  mv "$tmp" "$DB"
}

remove_db(){
  local u="$1" tmp
  tmp=$(mktemp); awk -F: -v u="$u" '$1!=u' "$DB" >"$tmp"; mv "$tmp" "$DB"
}

active_sessions(){
  local u="$1"
  ps -eo user=,comm= 2>/dev/null | awk -v u="$u" '$1==u && $2 ~ /^(sshd|sshd-session)$/ {n++} END{print n+0}'
}

TG_CHANNEL="https://t.me/NexusPacket_Official"
TG_CONTACT="https://t.me/NexusPacket"

show_banner(){
  local os mem load up total online
  os=$(awk -F= '$1=="PRETTY_NAME"{gsub(/"/,"",$2);print $2}' /etc/os-release)
  mem=$(free | awk '/^Mem:/{printf "%.1f",$3*100/$2}')
  load=$(awk '{print $1}' /proc/loadavg)
  up=$(uptime -p 2>/dev/null | sed 's/^up //')
  total=$(awk -F: '$1!=""{n++}END{print n+0}' "$DB")
  online=0
  while IFS=: read -r u _; do [[ -n "$u" ]] && online=$((online+$(active_sessions "$u"))); done <"$DB"
  clear 2>/dev/null || true
  echo
  echo -e "${N} ███╗   ██╗███████╗██╗  ██╗██╗   ██╗███████╗${Z}"
  echo -e "${N} ████╗  ██║██╔════╝╚██╗██╔╝██║   ██║██╔════╝${Z}"
  echo -e "${N} ██╔██╗ ██║█████╗   ╚███╔╝ ██║   ██║███████╗${Z}"
  echo -e "${N} ██║╚██╗██║██╔══╝   ██╔██╗ ██║   ██║╚════██║${Z}"
  echo -e "${N} ██║ ╚████║███████╗██╔╝ ██╗╚██████╔╝███████║${Z}"
  echo -e "${N} ╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝${Z} ${D}P A C K E T${Z}"
  echo -e "${P}${APP} ${D}| v${VERSION} ${D}| Channel:${C} ${TG_CHANNEL}${Z}"
  echo -e "${B}────────────────────────────────────────────────────────${Z}"
  printf "  ${D}OS${Z}       %-25s ${D}|${Z} Uptime: %s\n" "$os" "$up"
  printf "  ${D}Memory${Z}   %-25s ${D}|${Z} Online Sessions: ${W}%s${Z}\n" "${mem}% Used" "$online"
  printf "  ${D}Users${Z}    %-25s ${D}|${Z} Sys Load (1m): ${G}%s${Z}\n" "$total Managed Accounts" "$load"
  echo -e "${B}────────────────────────────────────────────────────────${Z}"
}

ensure_ssh_dropin(){
  mkdir -p /etc/ssh/sshd_config.d
  cat >"$BANNER" <<'EOF'
# Managed by NexusPacket Manager.
# Keep SSH defaults intact; account expiration is enforced by the worker.
UsePAM yes
PasswordAuthentication yes
EOF
  sshd -t
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
}

create_user(){
  show_banner
  echo -e "${P}--- ✨ Create User ---${Z}"
  read -r -p "Username: " u
  valid_user "$u" || { echo -e "${R}Invalid username.${Z}"; return; }
  user_exists "$u" && { echo -e "${R}User already exists.${Z}"; return; }
  read -r -p "Password (Enter = random): " p
  [[ -n "$p" ]] || p=$(randpass 12)
  read -r -p "Days [30]: " days; days=${days:-30}
  [[ "$days" =~ ^[0-9]+$ && "$days" -ge 1 ]] || { echo "Invalid days."; return; }
  read -r -p "Connection limit [1]: " lim; lim=${lim:-1}
  [[ "$lim" =~ ^[0-9]+$ && "$lim" -ge 1 ]] || { echo "Invalid limit."; return; }
  read -r -p "Bandwidth GB (0=unlimited) [0]: " bw; bw=${bw:-0}
  [[ "$bw" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "Invalid bandwidth."; return; }
  useradd -m -s /bin/bash -g "$GROUP" "$u"
  echo "$u:$p" | chpasswd
  chage -E "$(date -d "+$days days" +%F)" "$u"
  local exp; exp=$(date -d "+$days days" '+%F %T')
  set_db "$u" "$u:$p:$exp:$lim:$bw:active"
  log "create user=$u expiry=$exp limit=$lim bw=$bw"
  echo -e "${G}Created.${Z}"; printf "Username: %s\nPassword: %s\nExpires: %s\n" "$u" "$p" "$exp"
}

create_trial(){
  show_banner
  echo -e "${P}--- ⏱ Create Trial ---${Z}"
  read -r -p "Hours [1]: " h; h=${h:-1}
  [[ "$h" =~ ^[0-9]+$ && "$h" -ge 1 ]] || { echo "Invalid hours."; return; }
  local u="trial_$(tr -dc 'a-z0-9' </dev/urandom | head -c 5)" p; p=$(randpass 10)
  useradd -m -s /bin/bash -g "$GROUP" "$u"
  echo "$u:$p" | chpasswd
  local exp; exp=$(date -d "+$h hours" '+%F %T')
  chage -E "$(date -d "+$h hours" +%F)" "$u"
  set_db "$u" "$p:$p:$exp:1:0:trial"  # immediately replaced below
  set_db "$u" "$u:$p:$exp:1:0:trial"
  log "trial user=$u expiry=$exp"
  echo -e "${G}Trial created.${Z}"; printf "Username: %s\nPassword: %s\nExpires: %s\n" "$u" "$p" "$exp"
}

delete_user(){
  show_banner
  read -r -p "Username: " u
  user_exists "$u" || { echo "Not found."; return; }
  read -r -p "Type DELETE to confirm: " x
  [[ "$x" == DELETE ]] || return
  pkill -KILL -u "$u" 2>/dev/null || true
  userdel -r "$u" 2>/dev/null || true
  remove_db "$u"; log "delete user=$u"; echo -e "${G}Deleted.${Z}"
}
lock_user(){
  show_banner; read -r -p "Username: " u
  user_exists "$u" || return
  passwd -l "$u" >/dev/null
  awk -F: -v u="$u" 'BEGIN{OFS=":"} $1==u{$6="locked"}1' "$DB" >"$DB.tmp"; mv "$DB.tmp" "$DB"
  log "lock user=$u"; echo "Locked."
}
unlock_user(){
  show_banner; read -r -p "Username: " u
  user_exists "$u" || return
  passwd -u "$u" >/dev/null
  awk -F: -v u="$u" 'BEGIN{OFS=":"} $1==u{$6="active"}1' "$DB" >"$DB.tmp"; mv "$DB.tmp" "$DB"
  log "unlock user=$u"; echo "Unlocked."
}
renew_user(){
  show_banner; read -r -p "Username: " u
  local line; line=$(load_user "$u"); [[ -n "$line" ]] || return
  read -r -p "Add days [30]: " d; d=${d:-30}
  local exp; exp=$(date -d "+$d days" '+%F %T')
  chage -E "$(date -d "+$d days" +%F)" "$u"
  awk -F: -v u="$u" -v e="$exp" 'BEGIN{OFS=":"} $1==u{$3=e;$6="active"}1' "$DB" >"$DB.tmp"; mv "$DB.tmp" "$DB"
  passwd -u "$u" >/dev/null 2>&1 || true
  log "renew user=$u expiry=$exp"; echo "Renewed until $exp"
}
list_users(){
  show_banner
  printf "${C}%-18s %-20s %-8s %-12s %-10s %-8s${Z}\n" User Expires Limit BW Status Online
  echo "--------------------------------------------------------------------------------"
  while IFS=: read -r u p e lim bw st; do
    [[ -n "$u" ]] || continue
    printf "%-18s %-20s %-8s %-12s %-10s %-8s\n" "$u" "$e" "$lim" "${bw}GB" "$st" "$(active_sessions "$u")"
  done <"$DB"
  read -r -p "Enter to continue..." _
}
bulk(){
  show_banner
  echo "Enter usernames separated by spaces. Supported: delete lock unlock renew"
  read -r -p "Action: " a
  read -r -p "Users: " users
  for u in $users; do case "$a" in delete) printf "DELETE\n" | sed -n '1p' >/dev/null; user_exists "$u" && { pkill -KILL -u "$u" 2>/dev/null || true; userdel -r "$u" 2>/dev/null || true; remove_db "$u"; };;
    lock) passwd -l "$u" >/dev/null 2>&1 || true;;
    unlock) passwd -u "$u" >/dev/null 2>&1 || true;;
    renew) local exp; exp=$(date -d '+30 days' '+%F %T'); chage -E "$(date -d '+30 days' +%F)" "$u" 2>/dev/null || true; awk -F: -v u="$u" -v e="$exp" 'BEGIN{OFS=":"}$1==u{$3=e}1' "$DB">"$DB.tmp";mv "$DB.tmp" "$DB";;
  esac; done
  log "bulk action=$a users=$users"; echo "Done."
}
traffic(){
  show_banner
  local iface rx1 tx1 rx2 tx2
  iface=$(ip -4 route show default 2>/dev/null | awk '{print $5;exit}')
  [[ -n "$iface" ]] || { echo "No default interface."; return; }
  echo "Interface: $iface"
  rx1=$(cat "/sys/class/net/$iface/statistics/rx_bytes"); tx1=$(cat "/sys/class/net/$iface/statistics/tx_bytes")
  sleep 2
  rx2=$(cat "/sys/class/net/$iface/statistics/rx_bytes"); tx2=$(cat "/sys/class/net/$iface/statistics/tx_bytes")
  echo "Download: $(((rx2-rx1)/2048)) KB/s"
  echo "Upload:   $(((tx2-tx1)/2048)) KB/s"
  echo "Total RX: $((rx2/1024/1024)) MB"
  echo "Total TX: $((tx2/1024/1024)) MB"
}
ssh_banner(){
  cat >/etc/ssh/sshd_config.d/nexuspacket-banner.conf <<'EOF'
PrintMotd no
Banner /etc/issue.net
EOF
  cat >/etc/issue.net <<EOF
==================================================
   N E X U S P A C K E T
   Authorized access only — all sessions logged
   Channel: $TG_CHANNEL
   Contact: $TG_CONTACT
==================================================
EOF
  sshd -t && (systemctl reload ssh || systemctl reload sshd)
  echo "SSH banner enabled."
}
install_pkg(){ apt-get update -y && apt-get install -y "$@"; }
protocols(){
  while true; do
    show_banner
    echo -e "${P}--- ⚙ Protocol & Panel Management ---${Z}"
    for n in "BadVPN / UDP Gateway" "UDP Custom" "HAProxy Edge" "Nginx Reverse Proxy" "DNSTT" "NexusPacket Proxy (WS relay)" "ZiVPN" "3X-UI"; do echo " - $n"; done
    echo
    echo "[1] Install HAProxy + Nginx"
    echo "[2] Install 3X-UI"
    echo "[3] Service status"
    echo "[4] Uninstall manager-installed web stack"
    echo "[5] Install NexusPacket Proxy (WebSocket relay)"
    echo "[6] Uninstall NexusPacket Proxy"
    echo "[0] Return"
    read -r -p "Choice: " c
    case "$c" in
      1) install_pkg haproxy nginx; systemctl enable --now nginx haproxy; echo "HAProxy/Nginx installed. Configure routing before exposing production traffic."; read -r -p "Enter..." _;;
      2) echo "Official 3X-UI installer is upstream-managed. Run only after reviewing its release/source."; echo "https://github.com/MHSanaei/3x-ui"; read -r -p "Install now? [y/N] " x; [[ "$x" =~ ^[Yy]$ ]] && bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh);;
      3) systemctl --no-pager --type=service --state=running | grep -E 'haproxy|nginx|ssh|nexuspacket' || true; read -r -p "Enter..." _;;
      4) systemctl disable --now haproxy nginx 2>/dev/null || true; apt-get purge -y haproxy nginx nginx-common >/dev/null 2>&1 || true; echo "Removed."; read -r -p "Enter..." _;;
      5) install_nexuspacket_proxy;;
      6) uninstall_nexuspacket_proxy;;
      0) return;;
    esac
  done
}
install_nexuspacket_proxy(){
  show_banner
  echo -e "${P}--- Installing NexusPacket Proxy (WebSocket relay) ---${Z}"
  read -r -p "Listen port [8080]: " lp; lp=${lp:-8080}
  read -r -p "Target host [127.0.0.1]: " th; th=${th:-127.0.0.1}
  read -r -p "Target port (e.g. 22 for SSH) [22]: " tp; tp=${tp:-22}
  mkdir -p /usr/local/lib/nexuspacket-manager
  download_file /usr/local/lib/nexuspacket-manager/nexuspacket_proxy.py \
    "https://raw.githubusercontent.com/$GH_USER/$GH_REPO/$GH_BRANCH/nexuspacket_proxy.py" \
    2>/dev/null || true
  if [[ ! -s /usr/local/lib/nexuspacket-manager/nexuspacket_proxy.py ]]; then
    echo -e "${R}Could not fetch nexuspacket_proxy.py — place it manually at /usr/local/lib/nexuspacket-manager/nexuspacket_proxy.py${Z}"
    read -r -p "Enter..." _; return
  fi
  cat > /etc/systemd/system/nexuspacket-proxy.service <<EOF
[Unit]
Description=NexusPacket Proxy (WebSocket relay)
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/lib/nexuspacket-manager/nexuspacket_proxy.py --listen-port $lp --target-host $th --target-port $tp
Restart=always

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now nexuspacket-proxy.service
  echo -e "${G}NexusPacket Proxy installed and running on port $lp -> $th:$tp${Z}"
  read -r -p "Enter..." _
}
uninstall_nexuspacket_proxy(){
  systemctl disable --now nexuspacket-proxy.service 2>/dev/null || true
  rm -f /etc/systemd/system/nexuspacket-proxy.service /usr/local/lib/nexuspacket-manager/nexuspacket_proxy.py
  systemctl daemon-reload
  echo "NexusPacket Proxy removed."
  read -r -p "Enter..." _
}
panel(){
  source "$CONF"
  local p="${PANEL_PORT:-44380}"
  [[ -f "$PANEL_SERVICE" ]] || cat >"$PANEL_SERVICE" <<EOF
[Unit]
Description=NexusPacket Manager Web Panel
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/bin/python3 $PANEL --port $p
Restart=always
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload; systemctl enable --now nexuspacket-panel.service
  sed -i "s/^PANEL_ENABLED=.*/PANEL_ENABLED=1/" "$CONF"
  echo "Panel: http://SERVER_IP:$p/"
  echo "The included panel is intentionally minimal and local-admin oriented."
  read -r -p "Enter..." _
}
system_settings(){
  show_banner
  echo "[1] Update packages"
  echo "[2] SSH banner"
  echo "[3] Show firewall"
  echo "[4] Backup manager data"
  echo "[0] Return"
  read -r -p "Choice: " c
  case "$c" in
    1) apt-get update -y && apt-get upgrade -y;;
    2) ssh_banner;;
    3) command -v ufw >/dev/null && ufw status || ss -lntup;;
    4) tar -czf "/root/nexuspacket-backup-$(date +%F-%H%M%S).tgz" "$ROOT"; echo "Backup created in /root.";;
  esac
  read -r -p "Enter..." _
}
uninstall(){
  show_banner
  echo -e "${R}This removes the manager and its data, not third-party protocol software.${Z}"
  read -r -p "Type UNINSTALL: " x
  [[ "$x" == UNINSTALL ]] || return
  systemctl disable --now nexuspacket-expiry.timer 2>/dev/null || true
  rm -f /etc/systemd/system/nexuspacket-expiry.timer /etc/systemd/system/nexuspacket-expiry.service "$BANNER"
  systemctl daemon-reload
  rm -f /usr/local/bin/nexuspacket
  rm -rf /usr/local/lib/nexuspacket-manager /etc/nexuspacket-manager
  echo "Uninstalled."
  exit 0
}
expiry_worker(){
  init
  local now u p e lim bw st
  now=$(date +%s)
  while IFS=: read -r u p e lim bw st; do
    [[ -n "$u" && "$e" =~ ^[0-9]{4}- ]] || continue
    if (( $(date -d "$e" +%s 2>/dev/null || echo 0) <= now )); then
      passwd -l "$u" >/dev/null 2>&1 || true
      pkill -KILL -u "$u" 2>/dev/null || true
      awk -F: -v u="$u" 'BEGIN{OFS=":"}$1==u{$6="expired"}1' "$DB" >"$DB.tmp"; mv "$DB.tmp" "$DB"
      log "expired user=$u"
    fi
  done <"$DB"
}
main(){
  need_root; init; ensure_ssh_dropin
  [[ "${1:-}" == "--expiry-worker" ]] && { expiry_worker; exit; }
  while true; do
    show_banner
    echo -e "${P}================ [ USER MANAGEMENT ] ================${Z}"
    echo "[1] ✨ Create User          [2] 🗑 Delete User"
    echo "[3] 🔄 Renew User          [4] 🔒 Lock User"
    echo "[5] 🔓 Unlock User         [6] ✏ Edit Password"
    echo "[7] 📋 List Users           [8] 📱 Generate Client Info"
    echo "[9] ⏱ Trial Account        [10] 📈 Traffic Monitor"
    echo "[11] 👥 Bulk Operations"
    echo
    echo -e "${P}================ [ PROTOCOLS & PANELS ] ================${Z}"
    echo "[12] ⚙ Protocol Manager      [13] 📊 Service Monitor"
    echo "[14] 🚫 Torrent Guard (not enabled by default)"
    echo
    echo -e "${P}================ [ SYSTEM SETTINGS ] ================${Z}"
    echo "[15] 🌐 DNS/Host Info         [16] 🪧 SSH Banner"
    echo "[17] 🔄 Package Update        [18] 💾 Backup"
    echo "[19] 🌐 Web Control Panel     [20] 🧹 Cleanup Expired"
    echo
    echo -e "${R}[99] 🔥 Uninstall Manager${Z}   [0] Exit"
    echo -e "${D}────────────────────────────────────────────────────────${Z}"
    echo -e "${O}Powered by NexusPacket${Z} ${D}|${Z} ${C}Channel:${Z} ${TG_CHANNEL} ${D}|${Z} ${C}Contact:${Z} ${TG_CONTACT}"
    read -r -p "Select: " c
    case "$c" in
      1) create_user;; 2) delete_user;; 3) renew_user;; 4) lock_user;; 5) unlock_user;;
      6) show_banner; read -r -p "Username: " u; read -r -s -p "New password: " p; echo; echo "$u:$p"|chpasswd; echo "Changed.";;
      7) list_users;; 8) show_banner; read -r -p "Username: " u; line=$(load_user "$u"); echo "$line"; echo "SSH: ssh $u@SERVER_IP"; read -r -p "Enter..." _;;
      9) create_trial;; 10) traffic;; 11) bulk;; 12) protocols;;
      13) show_banner; systemctl --no-pager --type=service --state=running | head -40; read -r -p "Enter..." _;;
      14) echo "Torrent blocking is intentionally opt-in and should be designed for your network policy."; read -r -p "Enter..." _;;
      15) show_banner; hostnamectl 2>/dev/null || hostname; ip -brief addr; ip route; read -r -p "Enter..." _;;
      16) ssh_banner; read -r -p "Enter..." _;;
      17) apt-get update -y && apt-get upgrade -y;;
      18) tar -czf "/root/nexuspacket-backup-$(date +%F-%H%M%S).tgz" "$ROOT"; echo "Backup created."; read -r -p "Enter..." _;;
      19) panel;;
      20) expiry_worker; echo "Expired accounts cleaned."; read -r -p "Enter..." _;;
      99) uninstall;;
      0) exit 0;;
      *) echo "Invalid option."; sleep 1;;
    esac
  done
}
main "$@"
