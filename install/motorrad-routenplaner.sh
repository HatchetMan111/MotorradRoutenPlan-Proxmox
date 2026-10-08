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
