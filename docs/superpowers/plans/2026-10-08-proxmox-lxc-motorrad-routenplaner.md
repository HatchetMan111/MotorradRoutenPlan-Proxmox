# Proxmox-LXC Einzeiler (mit Mobile/GPS) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ein Einzeiler auf dem Proxmox-Host erstellt einen LXC `motorrad-routenplaner` und liefert Desktop- (`http://IP:8080`) plus Handy-GPS-Zugang (`https://IP/`) via Caddy mit self-signed TLS.

**Architecture:** Ein Host-Script `install/motorrad-routenplaner.sh` (Variablen oben, `set -euo pipefail`, idempotent) erstellt den CT mit der nächsten freien ID und führt darin das App-Setup aus (Node 22, `npm ci` + `npm run build`, `0.0.0.0`-Patch, systemd-Unit, Caddy `tls internal` Reverse-Proxy, Health-Verifikation mit finaler URL-Ausgabe).

**Tech Stack:** Bash (Host + CT via `pct exec`), Proxmox `pct/pveam/pvesh`, Debian 12 LXC, Node.js 22, Caddy v2, systemd, Fastify-Backend Port 8080, `frontend/dist` wird vom Backend statisch serviert.

**Spec:** `docs/superpowers/specs/2026-10-08-proxmox-lxc-motorrad-routenplaner-design.md`

## Global Constraints

- `set -euo pipefail` in jedem Bash-Script, keine Platzhalter/TODOs im fertigen Code.
- CT-Name = `motorrad-routenplaner`, CTID = nächste freie ID via `pvesh get /cluster/nextid` (per `CTID=` übersteuerbar).
- Defaults: Debian 12 Template, `local-lvm`, `vmbr0`, DHCP, 2 vCPU / 2048 MB RAM / 8 GB Disk, `unprivileged=1`, `onboot=1`.
- App-Port `8080` bind `0.0.0.0` (sed-Patch mit grep-Guard), HTTPS via Caddy `:443` mit `tls internal`, Ports 80/443/8080 erreichbar.
- `BROUTER_URL=https://brouter.de/brouter` (public, kein rd5-Download).
- `CONTACT_EMAIL` echt (kein `example.com`): TTY → fragen, sonst Abbruch mit klarer Meldung.
- systemd: `enable`, `Restart=always`, `RestartSec=5`, `After=network-online.target`.
- Verifikation Pflicht: `systemctl is-active` (app + caddy), `curl -fsS http://127.0.0.1:8080/api/health`, `curl -fkSs https://127.0.0.1/api/health`, finale Ausgabe beider URLs + CT-IP.
- Fehler: volle Kette (Befehl, Exit-Code, stderr/stdout, `journalctl -n 50`, `curl -v`), Hinweis `bash -x`.
- Lint: `bash -n` Pflicht vor jedem Commit; ShellCheck-Warnungen prüfen wenn vorhanden.

## Review Focus

- Leere/andere `CONTACT_EMAIL` mit `example.com` muss abbrechen statt still mit 403 zu scheitern (erwartet: klare Fehlermeldung vor Build).
- Fehlende/anders benannte Storage (`local-lvm`) oder Template muss mit Env-Override funktionieren statt hart zu failen (erwartet: Auto-Detect + Hinweis).
- Re-Run auf existierendem CT mit gleichem Hostnamen darf keinen Zweit-CT erzeugen (erwartet: Update im bestehenden CT).
- Handy ruft `https://IP/` auf und bekommt Zertifikatswarnung statt Verbindungsabbruch (erwartet: Caddy antwortet mit self-signed, GPS nach Bestätigung aktiv).
- Backend nach Reboot ohne `0.0.0.0`-Patch wäre nur per localhost erreichbar (erwartet: Patch wird bei jedem Build erneut geprüft).

---

### Task 1: Gerüst + Variablenblock + Helper (Host-Teil)

**Files:**
- Create: `install/motorrad-routenplaner.sh`
- Test: `bash -n install/motorrad-routenplaner.sh`

**Interfaces:**
- Consumes: keine (erstes File).
- Produces: Variablen `APP_NAME, HOSTNAME, CTID, TEMPLATE, STORAGE, BRIDGE, CORES, MEMORY_MB, DISK_GB, APP_PORT, REPO, BRANCH, BROUTER_URL, CONTACT_EMAIL` + Helper `msg_ok/msg_err/die/next_ctid/require_root/require_pve` für Task 2–5.

- [ ] **Step 1: Write the failing test (syntax-check muss fehlschlagen weil Datei fehlt)**

```bash
test -f install/motorrad-routenplaner.sh && bash -n install/motorrad-routenplaner.sh
```

- [ ] **Step 2: Run test to verify it fails**

Run: `test -f install/motorrad-routenplaner.sh && bash -n install/motorrad-routenplaner.sh` in `/tmp/opencode/motorrad-routenplaner`
Expected: FAIL (Datei fehlt, exit ≠ 0).

- [ ] **Step 3: Write minimal implementation (Gerüst mit Variablen oben + Helper, endet mit Exit-Hinweis „Task 2 folgt")**

```bash
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash -n install/motorrad-routenplaner.sh && shellcheck -S warning install/motorrad-routenplaner.sh || true` in `/tmp/opencode/motorrad-routenplaner`
Expected: PASS (`bash -n` ohne Ausgabe).

- [ ] **Step 5: Commit**

```bash
git add install/motorrad-routenplaner.sh
git commit -m "feat(proxmox): installer gerüst mit variablen und helpern"
```

### Task 2: CT-Erstellung (idempotent, nächste freie ID, onboot, DHCP)

**Files:**
- Modify: `install/motorrad-routenplaner.sh`
- Test: `bash -n install/motorrad-routenplaner.sh`

**Interfaces:**
- Consumes: Helper aus Task 1 (`next_ctid`, `die`, Variablen).
- Produces: Funktionen `ensure_template()`, `create_or_reuse_ct()` + gestarteter CT für Task 3.

- [ ] **Step 1: Write the failing test (Funktionen müssen existieren)**

```bash
grep -q "ensure_template()" install/motorrad-routenplaner.sh && grep -q "create_or_reuse_ct()" install/motorrad-routenplaner.sh && bash -n install/motorrad-routenplaner.sh
```

- [ ] **Step 2: Run test to verify it fails**

Run: `grep -q "ensure_template()" install/motorrad-routenplaner.sh` in `/tmp/opencode/motorrad-routenplaner`
Expected: FAIL (Funktionen fehlen).

- [ ] **Step 3: Write minimal implementation (ans Ende vor finaler Ausgabe einfügen)**

```bash
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash -n install/motorrad-routenplaner.sh && grep -q "onboot 1" install/motorrad-routenplaner.sh && echo OK` in `/tmp/opencode/motorrad-routenplaner`
Expected: PASS (gibt OK).

- [ ] **Step 5: Commit**

```bash
git add install/motorrad-routenplaner.sh
git commit -m "feat(proxmox): idempotente CT-erstellung mit nextid und onboot"
```

### Task 3: App-Setup im CT (Node 22, Build, 0.0.0.0-Patch, .env)

**Files:**
- Modify: `install/motorrad-routenplaner.sh` (Funktion `setup_app_in_ct()`)
- Test: `bash -n install/motorrad-routenplaner.sh`

**Interfaces:**
- Consumes: laufender CT aus Task 2, `CONTACT_EMAIL`, `BROUTER_URL`, `APP_PORT`.
- Produces: gebautes `/opt/motorrad-routenplaner` mit `backend/dist` + `frontend/dist`, gepatchter Bind, `.env` für Task 4.

- [ ] **Step 1: Write the failing test**

```bash
grep -q "setup_app_in_ct()" install/motorrad-routenplaner.sh && grep -q "0.0.0.0" install/motorrad-routenplaner.sh && bash -n install/motorrad-routenplaner.sh
```

- [ ] **Step 2: Run test to verify it fails**

Run: `grep -q "setup_app_in_ct()" install/motorrad-routenplaner.sh` in `/tmp/opencode/motorrad-routenplaner`
Expected: FAIL.

- [ ] **Step 3: Write minimal implementation**

```bash
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash -n install/motorrad-routenplaner.sh && grep -q "example.com" install/motorrad-routenplaner.sh && echo OK` in `/tmp/opencode/motorrad-routenplaner`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add install/motorrad-routenplaner.sh
git commit -m "feat(proxmox): app-setup mit node22 build und bind-patch"
```

### Task 4: systemd + Caddy (self-signed) + Verifikation mit Doppel-URL

**Files:**
- Create: `install/motorrad-routenplaner.service`
- Create: `install/Caddyfile`
- Modify: `install/motorrad-routenplaner.sh` (Funktionen `setup_services()`, `verify_and_print()`, Hauptablauf)
- Test: `bash -n install/motorrad-routenplaner.sh`

**Interfaces:**
- Consumes: gebauter Code aus Task 3.
- Produces: laufende Services + finale Ausgabe `http://IP:8080` und `https://IP/` für Task 5-Doku.

- [ ] **Step 1: Write the failing test**

```bash
test -f install/motorrad-routenplaner.service && test -f install/Caddyfile && grep -q "verify_and_print()" install/motorrad-routenplaner.sh && bash -n install/motorrad-routenplaner.sh
```

- [ ] **Step 2: Run test to verify it fails**

Run: `test -f install/motorrad-routenplaner.service && test -f install/Caddyfile` in `/tmp/opencode/motorrad-routenplaner`
Expected: FAIL (Dateien fehlen).

- [ ] **Step 3: Write minimal implementation — systemd-Unit**

```ini
[Unit]
Description=Motorrad-Routenplaner
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
WorkingDirectory=/opt/motorrad-routenplaner/backend
EnvironmentFile=/opt/motorrad-routenplaner/backend/.env
ExecStart=/usr/bin/node /opt/motorrad-routenplaner/backend/dist/index.js
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
```

- [ ] **Step 4: Write minimal implementation — Caddyfile**

```
:80 {
  redir https://{http.request.host}{uri}
}
:443 {
  tls internal
  reverse_proxy 127.0.0.1:8080
}
```

- [ ] **Step 5: Write minimal implementation — Services + Verifikation ans Script-Ende**

```bash
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
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bash -n install/motorrad-routenplaner.sh && grep -q "Restart=always" install/motorrad-routenplaner.service && grep -q "tls internal" install/Caddyfile && echo OK` in `/tmp/opencode/motorrad-routenplaner`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add install/motorrad-routenplaner.service install/Caddyfile install/motorrad-routenplaner.sh
git commit -m "feat(proxmox): systemd plus caddy-tls und health-verifikation"
```

### Task 5: README (Einzeiler, Handy-GPS, Update, Deinstall) + Reboot-Beleg

**Files:**
- Modify: `README.md` (Abschnitt Proxmox-LXC anhängen, kein bestehender Text ändern)
- Test: `grep -q "motorrad-routenplaner.sh" README.md`

**Interfaces:**
- Consumes: finale URLs aus Task 4.
- Produces: veröffentlichungsfähiger Einzeiler + belegter Reboot-Test.

- [ ] **Step 1: Write the failing test**

```bash
grep -q 'wget -qLO - https://raw.githubusercontent.com/mzluzifer/motorrad-routenplaner/main/install/motorrad-routenplaner.sh' README.md
```

- [ ] **Step 2: Run test to verify it fails**

Run: `grep -q "motorrad-routenplaner.sh" README.md` in `/tmp/opencode/motorrad-routenplaner`
Expected: FAIL.

- [ ] **Step 3: Write minimal implementation (Anhang ans README-Ende)**

```markdown
## Proxmox-LXC (Einzeiler)

Auf dem Proxmox-Host als root:

\`\`\`bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/mzluzifer/motorrad-routenplaner/main/install/motorrad-routenplaner.sh)"
\`\`\`

Mit Optionen: `CTID=150 CONTACT_EMAIL=du@echte-mail.de bash -c "$(wget -qLO - ...)"`.
Erstellt LXC `motorrad-routenplaner` (nächste freie ID, Debian 12, 2vCPU/2GB/8GB, onboot=1, DHCP), baut die App, startet systemd + Caddy.

- Desktop: `http://[LXC-IP]:8080`
- Handy im gleichen WLAN (mit GPS): `https://[LXC-IP]/` — beim ersten Mal Zertifikatswarnung bestätigen (self-signed, `tls internal`), danach ist `navigator.geolocation` freigegeben. Notlösung: `chrome://flags#unsafely-treat-insecure-origins-as-secure`.
- Update: Script erneut laufen lassen (idempotent: git pull + rebuild, kein neuer CT).
- Deinstall: `pct stop <CTID> && pct destroy <CTID>`.
- Debug: `bash -x install/motorrad-routenplaner.sh 2>&1 | tee install.log`, im CT `journalctl -u motorrad-routenplaner -n 50`, `journalctl -u caddy -n 30`.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `grep -q "motorrad-routenplaner.sh" README.md && grep -q "Handy" README.md && echo OK` in `/tmp/opencode/motorrad-routenplaner`
Expected: PASS.

- [ ] **Step 5: Reboot-Beleg (manuell auf PVE, Ausgabe hier einkleben)**

Run: `pct reboot <CTID>; sleep 30; pct exec <CTID> -- systemctl is-active motorrad-routenplaner caddy; curl -fsS http://[IP]:8080/api/health; curl -fkSs https://[IP]/api/health` auf dem Proxmox-Host
Expected: `active/active` + zweimal `{"ok":true}`. Logauszug in PR-Beschreibung.

- [ ] **Step 6: Commit**

```bash
git add README.md
git commit -m "docs(proxmox): einzeiler mit handy-gps update und deinstall"
```
