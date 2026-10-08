#!/usr/bin/env bash
set -euo pipefail
APP_NAME="${APP_NAME:-motorrad-routenplaner}"
HOSTNAME="${HOSTNAME:-$APP_NAME}"
CTID="${CTID:-}"
TEMPLATE="${TEMPLATE:-debian-12-standard_12.7-1_amd64.tar.zst}"
TEMPLATE_STORE="${TEMPLATE_STORE:-local}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
CORES="${CORES:-2}"
MEMORY_MB="${MEMORY_MB:-2048}"
DISK_GB="${DISK_GB:-8}"
APP_PORT="${APP_PORT:-8080}"
REPO="${REPO:-mzluzifer/motorrad-routenplaner}"
BRANCH="${BRANCH:-main}"
BROUTER_URL="${BROUTER_URL:-https://brouter.de/brouter}"
CONTACT_EMAIL="${CONTACT_EMAIL:-}"
log(){ printf '%s %s\n' "[$(date +%H:%M:%S)]" "$*"; }
msg_ok(){ log "✔ $*"; }
msg_err(){ log "✖ $*" >&2; }
die(){ msg_err "$*"; msg_err "Fehler in Zeile ${BASH_LINENO[0]}, Exit-Code $? – bei Bedarf: bash -x install/motorrad-routenplaner.sh 2>&1 | tee install.log"; exit 1; }
trap 'msg_err "Befehl fehlgeschlagen: $BASH_COMMAND (Zeile $LINENO, Code $?)"' ERR
require_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Als root auf dem Proxmox-Host ausführen."; }
require_pve(){ command -v pct >/dev/null && command -v pveam >/dev/null || die "pct/pveam nicht gefunden – auf Proxmox-Host ausführen."; }
next_ctid(){ if [[ -n "$CTID" ]]; then echo "$CTID"; else pvesh get /cluster/nextid; fi; }
require_root; require_pve
CTID="$(next_ctid)"
log "CTID=$CTID HOSTNAME=$HOSTNAME (Task-1-Gerüst)"
ensure_template(){
  pveam update >/dev/null
  if ! pveam list "$TEMPLATE_STORE" | grep -q "debian-12-standard"; then
    pveam download "$TEMPLATE_STORE" "$TEMPLATE"
  fi
  msg_ok "Template bereit ($TEMPLATE_STORE:$TEMPLATE)"
}
ct_ip(){ pct exec "$CTID" -- ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1; }
create_or_reuse_ct(){
  if pct status "$CTID" >/dev/null 2>&1; then
    msg_ok "CT $CTID existiert – Re-Use (Update-Pfad)"
  else
    pct create "$CTID" "${TEMPLATE_STORE}:vztmpl/${TEMPLATE}" \
      --hostname "$HOSTNAME" --cores "$CORES" --memory "$MEMORY_MB" \
      --rootfs "${STORAGE}:${DISK_GB}" --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
      --unprivileged 1 --onboot 1 --start 1
    msg_ok "CT $CTID erstellt ($HOSTNAME, ${CORES}vCPU/${MEMORY_MB}MB/${DISK_GB}GB)"
  fi
  pct start "$CTID" 2>/dev/null || true
  sleep 5
}
setup_app_in_ct(){
  if [[ -z "$CONTACT_EMAIL" && -t 0 ]]; then read -rp "CONTACT_EMAIL (echte Mail für Nominatim): " CONTACT_EMAIL; fi
  [[ -n "$CONTACT_EMAIL" ]] || die "CONTACT_EMAIL fehlt. Z.B. CONTACT_EMAIL=du@beispiel.de $0"
  [[ "$CONTACT_EMAIL" != *example.com* ]] || die "CONTACT_EMAIL darf kein example.com enthalten (Nominatim blockt 403)."
  pct exec "$CTID" -- bash -es <<EOF
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update && apt-get install -y git curl ca-certificates iproute2
if ! command -v node >/dev/null || ! node -v | grep -q "v22"; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
fi
if [[ -d /opt/motorrad-routenplaner/.git ]]; then git -C /opt/motorrad-routenplaner fetch origin && git -C /opt/motorrad-routenplaner checkout $BRANCH && git -C /opt/motorrad-routenplaner pull --ff-only
else git clone -b $BRANCH https://github.com/$REPO.git /opt/motorrad-routenplaner; fi
cd /opt/motorrad-routenplaner && npm ci && npm run build
if grep -q "127.0.0.1" backend/dist/index.js; then sed -i 's/127\.0\.0\.1/0.0.0.0/g' backend/dist/index.js; echo "Bind-Patch 0.0.0.0 angewendet"; fi
cat > /opt/motorrad-routenplaner/backend/.env <<ENVEOF
PORT=$APP_PORT
BROUTER_URL=$BROUTER_URL
OVERPASS_URL=https://overpass-api.de/api/interpreter
NOMINATIM_URL=https://nominatim.openstreetmap.org
AUTOBAHN_URL=https://verkehr.autobahn.de/o/autobahn
CONTACT_EMAIL=$CONTACT_EMAIL
ENVEOF
EOF
  msg_ok "App gebaut + .env geschrieben"
}
setup_services(){
  pct push "$CTID" install/motorrad-routenplaner.service /etc/systemd/system/motorrad-routenplaner.service
  pct exec "$CTID" -- bash -ec "apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list && apt-get update && apt-get install -y caddy"
  pct push "$CTID" install/Caddyfile /etc/caddy/Caddyfile
  pct exec "$CTID" -- bash -ec "(command -v ufw >/dev/null && ufw allow 80,443,8080/tcp || true); (iptables -C INPUT -p tcp --dport 8080 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 8080 -j ACCEPT 2>/dev/null || true)"
  pct exec "$CTID" -- bash -ec "systemctl daemon-reload && systemctl enable --now motorrad-routenplaner && systemctl enable --now caddy && sleep 3 && systemctl is-active motorrad-routenplaner && systemctl is-active caddy"
  msg_ok "Services laufen"
}
verify_and_print(){
  pct exec "$CTID" -- bash -ec "curl -fsS http://127.0.0.1:8080/api/health | grep -q '\"ok\":true' && curl -fkSs https://127.0.0.1/api/health | grep -q '\"ok\":true'"
  IP="$(ct_ip)"; [[ -n "${IP:-}" ]] || die "Keine CT-IP gefunden (DHCP?). Logs: pct exec $CTID -- ip a"
  msg_ok "Motorrad-Routenplaner läuft in CT $CTID ($IP)"
  echo "  Desktop: http://$IP:8080"
  echo "  Handy (GPS): https://$IP/  (Zertifikatswarnung bestätigen, dann GPS aktiv)"
}
ensure_template
create_or_reuse_ct
setup_app_in_ct
setup_services
verify_and_print
