#!/usr/bin/env bash
set -euo pipefail
# Hinweis: bewusst CT_HOSTNAME statt HOSTNAME – HOSTNAME ist in jeder
# Shell bereits auf den Proxmox-Hostnamen gesetzt, ein :-Default griffe nie.
CT_HOSTNAME="${CT_HOSTNAME:-motorrad-routenplaner}"
CTID="${CTID:-}"
TEMPLATE="${TEMPLATE:-debian-12-standard_12.7-1_amd64.tar.zst}"
TEMPLATE_STORE="${TEMPLATE_STORE:-local}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
CORES="${CORES:-2}"
MEMORY_MB="${MEMORY_MB:-2048}"
DISK_GB="${DISK_GB:-8}"
APP_PORT="${APP_PORT:-8080}"
HTTPS_PORT="${HTTPS_PORT:-443}"
REPO="${REPO:-mzluzifer/motorrad-routenplaner}"
BRANCH="${BRANCH:-main}"
INSTALL_REPO="${INSTALL_REPO:-HatchetMan111/MotorradRoutenPlan-Proxmox}"
INSTALL_BRANCH="${INSTALL_BRANCH:-main}"
BROUTER_URL="${BROUTER_URL:-https://brouter.de/brouter}"
CONTACT_EMAIL="${CONTACT_EMAIL:-}"
RAW_BASE="https://raw.githubusercontent.com/${INSTALL_REPO}/${INSTALL_BRANCH}/install"
DIAG_ARMED=0
log(){ printf '%s %s\n' "[$(date +%H:%M:%S)]" "$*"; }
msg_ok(){ log "✔ $*"; }
msg_err(){ log "✖ $*" >&2; }
die(){ msg_err "$*"; msg_err "Fehler in Zeile ${BASH_LINENO[0]}, Exit-Code $? – bei Bedarf: bash -x install/motorrad-routenplaner.sh 2>&1 | tee install.log"; exit 1; }
dump_diagnostics(){
  [[ -n "${CTID:-}" ]] || return 0
  pct status "$CTID" >/dev/null 2>&1 || return 0
  log "--- Diagnose motorrad-routenplaner (bounded) ---"
  pct exec "$CTID" -- systemctl status motorrad-routenplaner --no-pager 2>&1 | head -n 40 || true
  pct exec "$CTID" -- journalctl -u motorrad-routenplaner -n 50 --no-pager 2>&1 | tail -n 50 || true
  log "--- Diagnose caddy (bounded) ---"
  pct exec "$CTID" -- systemctl status caddy --no-pager 2>&1 | head -n 40 || true
  pct exec "$CTID" -- journalctl -u caddy -n 30 --no-pager 2>&1 | tail -n 30 || true
  log "--- curl app direkt ---"
  pct exec "$CTID" -- bash -c "curl -v http://127.0.0.1:${APP_PORT}/api/health 2>&1 | head -n 30; echo \"curl-app-exit=\$?\"" || true
  log "--- curl via caddy ---"
  pct exec "$CTID" -- bash -c "curl -kv https://127.0.0.1:${HTTPS_PORT}/api/health 2>&1 | head -n 30; echo \"curl-caddy-exit=\$?\"" || true
}
on_err(){
  msg_err "Befehl fehlgeschlagen: $BASH_COMMAND (Zeile $LINENO, Code $?)"
  if [[ "$DIAG_ARMED" -eq 1 ]]; then dump_diagnostics; fi
}
trap on_err ERR
require_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Als root auf dem Proxmox-Host ausführen."; }
require_pve(){ command -v pct >/dev/null && command -v pveam >/dev/null || die "pct/pveam nicht gefunden – auf Proxmox-Host ausführen."; }
find_ctid_by_hostname(){
  local hn="$1" id h
  for id in $(pct list 2>/dev/null | tail -n +2 | awk '{print $1}'); do
    h="$(pct config "$id" 2>/dev/null | awk '/^hostname:/ {print $2}')"
    if [[ "$h" == "$hn" ]]; then echo "$id"; return 0; fi
  done
  return 1
}
resolve_ctid(){
  if [[ -n "$CTID" ]]; then
    log "CTID=$CTID explizit gesetzt (Override gewinnt)"
  else
    local found=""
    found="$(find_ctid_by_hostname "$CT_HOSTNAME" || true)"
    if [[ -n "$found" ]]; then
      CTID="$found"
      log "CT $CTID mit Hostname $CT_HOSTNAME gefunden – Re-Use"
    else
      CTID="$(pvesh get /cluster/nextid)"
      log "Neue CTID=$CTID (kein CT mit Hostname $CT_HOSTNAME gefunden)"
    fi
  fi
}
require_root; require_pve
resolve_ctid
log "CTID=$CTID CT_HOSTNAME=$CT_HOSTNAME"
ensure_template(){
  pveam update >/dev/null
  if pveam list "$TEMPLATE_STORE" 2>/dev/null | grep -q "$TEMPLATE"; then
    msg_ok "Template bereit ($TEMPLATE_STORE:$TEMPLATE)"
    return 0
  fi
  log "Template $TEMPLATE nicht in Store $TEMPLATE_STORE – suche Fallback (pveam available --section system)"
  local fallback=""
  fallback="$(pveam available --section system 2>/dev/null | grep "debian-12-standard" | tail -1 | awk '{print $2}')"
  if [[ -n "$fallback" ]]; then
    TEMPLATE="$fallback"
    log "Fallback-Template: $TEMPLATE"
  else
    log "Kein debian-12-standard Template in 'pveam available --section system' gefunden – versuche $TEMPLATE direkt"
  fi
  pveam download "$TEMPLATE_STORE" "$TEMPLATE" || die "Template-Download fehlgeschlagen. Hinweis: TEMPLATE=<name> TEMPLATE_STORE=<store> setzen (z.B. TEMPLATE=$TEMPLATE TEMPLATE_STORE=$TEMPLATE_STORE)"
  msg_ok "Template bereit ($TEMPLATE_STORE:$TEMPLATE)"
}
ensure_storage(){
  if pvesm status 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$STORAGE"; then
    msg_ok "Storage bereit ($STORAGE)"
    return 0
  fi
  log "Storage $STORAGE nicht in 'pvesm status' – suche Fallback (erster aktiver dir/lvm Store mit Platz)"
  local fallback=""
  fallback="$(pvesm status 2>/dev/null | awk 'NR>1 && ($2=="dir" || $2=="lvm" || $2=="lvmthin" || $2=="zfspool") && $5>0 {print $1; exit}')"
  if [[ -n "$fallback" ]]; then
    log "Fallback-Storage: $fallback (Hinweis: STORAGE=<store> setzt Override, z.B. STORAGE=$STORAGE)"
    STORAGE="$fallback"
    msg_ok "Storage bereit ($STORAGE via Fallback)"
  else
    die "Storage $STORAGE nicht gefunden und kein Fallback verfügbar. Hinweis: 'pvesm status' prüfen und STORAGE=<store> setzen."
  fi
}
ct_ip(){ pct exec "$CTID" -- ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1; }
wait_for_ip(){
  local ip="" i
  for i in $(seq 1 12); do
    ip="$(ct_ip || true)"
    if [[ -n "$ip" ]]; then echo "$ip"; return 0; fi
    sleep 5
  done
  msg_err "Keine CT-IP nach 60s (DHCP?). Ausgabe von 'pct exec $CTID -- ip a':"
  pct exec "$CTID" -- ip a 2>&1 || true
  die "Keine CT-IP gefunden (DHCP?)."
}
# C1: Datei beschaffen – lokaler Checkout gewinnt, sonst Fetch vom RAW_BASE (One-liner-Modus).
fetch_to_tmp(){
  local src="$1" dest="$2"
  if [[ -f "install/$src" ]]; then
    cp "install/$src" "$dest"
    log "Nutze lokale Datei install/$src"
  else
    log "Keine lokale Datei install/$src – lade $RAW_BASE/$src"
    wget -qO "$dest" "$RAW_BASE/$src" || { local code=$?; die "Download fehlgeschlagen (Exit $code): $RAW_BASE/$src"; }
  fi
}
create_or_reuse_ct(){
  if pct status "$CTID" >/dev/null 2>&1; then
    msg_ok "CT $CTID existiert – Re-Use (Update-Pfad)"
  else
    pct create "$CTID" "${TEMPLATE_STORE}:vztmpl/${TEMPLATE}" \
      --hostname "$CT_HOSTNAME" --cores "$CORES" --memory "$MEMORY_MB" \
      --rootfs "${STORAGE}:${DISK_GB}" --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
      --unprivileged 1 --onboot 1 --start 1
    msg_ok "CT $CTID erstellt ($CT_HOSTNAME, ${CORES}vCPU/${MEMORY_MB}MB/${DISK_GB}GB)"
  fi
  pct start "$CTID" 2>/dev/null || true
  IP="$(wait_for_ip)"
  log "CT-IP=$IP"
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
if [[ -d /opt/motorrad-routenplaner/.git ]]; then git -C /opt/motorrad-routenplaner fetch origin && git -C /opt/motorrad-routenplaner checkout "$BRANCH" && git -C /opt/motorrad-routenplaner pull --ff-only
else git clone -b "$BRANCH" "https://github.com/$REPO.git" /opt/motorrad-routenplaner; fi
cd /opt/motorrad-routenplaner && npm ci && npm run build
if grep -q "127.0.0.1" backend/dist/index.js; then sed -i 's/127\.0\.0\.1/0.0.0.0/g' backend/dist/index.js; echo "Bind-Patch 0.0.0.0 angewendet"; fi
cat > /opt/motorrad-routenplaner/backend/.env <<ENVEOF
PORT="$APP_PORT"
BROUTER_URL="$BROUTER_URL"
OVERPASS_URL=https://overpass-api.de/api/interpreter
NOMINATIM_URL=https://nominatim.openstreetmap.org
AUTOBAHN_URL=https://verkehr.autobahn.de/o/autobahn
CONTACT_EMAIL="$CONTACT_EMAIL"
ENVEOF
EOF
  msg_ok "App gebaut + .env geschrieben"
}
setup_services(){
  DIAG_ARMED=1
  local svc_tmp caddy_tmp caddy_gen
  svc_tmp="$(mktemp)"; caddy_tmp="$(mktemp)"; caddy_gen="$(mktemp)"
  fetch_to_tmp "motorrad-routenplaner.service" "$svc_tmp"
  fetch_to_tmp "Caddyfile" "$caddy_tmp"
  sed "s/:443/:${HTTPS_PORT}/" "$caddy_tmp" > "$caddy_gen"
  pct push "$CTID" "$svc_tmp" /etc/systemd/system/motorrad-routenplaner.service
  rm -f "$svc_tmp"
  pct exec "$CTID" -- bash -ec "apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list && apt-get update && apt-get install -y caddy"
  pct exec "$CTID" -- bash -ec "cp -n /etc/caddy/Caddyfile /etc/caddy/Caddyfile.bak 2>/dev/null || true"
  pct push "$CTID" "$caddy_gen" /etc/caddy/Caddyfile
  rm -f "$caddy_tmp" "$caddy_gen"
  pct exec "$CTID" -- bash -ec "(command -v ufw >/dev/null && ufw allow 80,${HTTPS_PORT},${APP_PORT}/tcp || true); (iptables -C INPUT -p tcp --dport ${APP_PORT} -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport ${APP_PORT} -j ACCEPT 2>/dev/null || true)"
  pct exec "$CTID" -- bash -ec "systemctl daemon-reload && systemctl enable --now motorrad-routenplaner && systemctl enable --now caddy && sleep 3 && systemctl is-active motorrad-routenplaner && systemctl is-active caddy"
  msg_ok "Services laufen"
}
verify_and_print(){
  DIAG_ARMED=1
  if ! pct exec "$CTID" -- bash -ec "curl -fsS http://127.0.0.1:${APP_PORT}/api/health | grep -q '\"ok\":true' && curl -fkSs https://127.0.0.1:${HTTPS_PORT}/api/health | grep -q '\"ok\":true'"; then
    msg_err "Verify fehlgeschlagen (Exit-Code $?)"
    dump_diagnostics
    die "Verify fehlgeschlagen – Diagnose oben."
  fi
  IP="$(ct_ip)"; [[ -n "${IP:-}" ]] || { dump_diagnostics; die "Keine CT-IP gefunden (DHCP?). Logs: pct exec $CTID -- ip a"; }
  msg_ok "Motorrad-Routenplaner läuft in CT $CTID ($IP)"
  echo "  Desktop: http://$IP:${APP_PORT}"
  echo "  Handy (GPS): https://$IP:${HTTPS_PORT}/  (Zertifikatswarnung bestätigen, dann GPS aktiv)"
}
ensure_template
ensure_storage
create_or_reuse_ct
setup_app_in_ct
setup_services
verify_and_print
