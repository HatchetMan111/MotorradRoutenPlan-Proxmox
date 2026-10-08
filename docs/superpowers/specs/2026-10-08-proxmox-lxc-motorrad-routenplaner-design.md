# Design: Proxmox-LXC Einzeiler für motorrad-routenplaner (mit Mobile/GPS)

Datum: 2026-10-08
Status: freigegeben (konversationell), wartet auf Datei-Review
Repo: https://github.com/mzluzifer/motorrad-routenplaner
App: motorrad-routenplaner — Open-Source Motorrad-Routenplaner (kurvig/schnell pro Abschnitt, Baustellen, POIs, GPX, Wetter, Höhenprofil)
Tech-Stack: React+TypeScript+Vite+MapLibre (frontend) / Node 22 + Fastify (backend, Port 8080, serviert `frontend/dist` statisch) / BRouter via öffentliche Instanz (default `https://brouter.de/brouter`) / OSM-Dienste (Nominatim, Overpass mit Fallback-Kette, Open-Meteo, Autobahn-GmbH-API)

## 1. Ziel & Erfolgskriterien

- Einzeiler auf Proxmox-Host (PVE 8+, root) erstellt vollautomatisch einen LXC und installiert die App:
  `bash -c "$(wget -qLO - https://raw.githubusercontent.com/mzluzifer/motorrad-routenplaner/main/install/motorrad-routenplaner.sh)"`
- Nach Installation: Web UI auf `http://[LXC-IP]:8080` (Desktop) UND `https://[LXC-IP]` bzw. `https://[LXC-IP]:443` (Handy mit GPS) erreichbar.
- Handy im gleichen WLAN/LAN kann Karte nutzen UND per Browser-GPS („aktueller Standort") orten. Ohne HTTPS blocken mobile Browser `navigator.geolocation` (Secure-Context-Pflicht) — daher ist TLS Pflichtbestandteil, nicht optional.
- Reboot-sicher: CT `onboot: 1`, systemd `enable` + `Restart=always` + `After=network-online.target`.
- Verifikation im Script: `systemctl is-active`, HTTP-Check `localhost:8080/api/health`, HTTPS-Check via Caddy, Ausgabe finaler URLs + CT-IP.
- Debugging: volle Fehlerkette (Stacktrace, stderr/stdout, Exit-Codes, Logs), `bash -x`-Hinweis. `set -euo pipefail`, idempotent (Re-Run = Update, kein Duplikat-CT).

## 2. Architektur (Ansatz A: 2-Stufen-Einzeiler)

```
Proxmox-Host (root)
  └─ install/motorrad-routenplaner.sh  [STUFE 1: Host]
       ├─ Variablenblock oben (alle Defaults änderbar)
       ├─ Checks: root, pveversion/pct vorhanden
       ├─ next_ctid(): nächste freie ID via `pvesh get /cluster/nextid`
       ├─ Template sicherstellen (debian-12-standard, pveam download)
       ├─ pct create <CTID> (hostname motorrad-routenplaner, 2vCPU/2GB/8GB,
       │   unprivileged 1, onboot 1, DHCP, bridge vmbr0)
       ├─ pct start + pct exec: STUFE 2 als Heredoc ODER wget zweites Script aus Repo
       └─ IP via `pct exec … ip -4 addr` / `pvesh`, finale Ausgabe beider URLs
LXC (Debian 12)
  ├─ Setup: apt (git, curl, node 22 via nodesource), git clone/pull /opt/motorrad-routenplaner
  ├─ Build: `npm ci && npm run build` (backend dist + frontend dist)
  ├─ Config: /opt/motorrad-routenplaner/backend/.env (PORT=8080, BROUTER_URL public, CONTACT_EMAIL)
  ├─ Patch: sed `127.0.0.1` → `0.0.0.0` in backend/dist/index.js (upstream-Fix empfohlen: HOST env)
  ├─ systemd: motorrad-routenplaner.service (node backend/dist/index.js)
  ├─ Caddy: Reverse-Proxy :80/:443 → 127.0.0.1:8080, `tls internal` (self-signed, voll lokal)
  └─ Verifikation im CT + Rückmeldung an Host
```

Dateien im Repo (neu):
- `install/motorrad-routenplaner.sh` — der Einzeiler-Einstieg (Host-Teil + eingebetteter CT-Teil).
- `install/motorrad-routenplaner.service` — systemd-Unit App.
- `install/Caddyfile` — Caddy-Config (Reverse-Proxy + `tls internal`).
- `README.md` (Ergänzung) — Einzeiler, Update (`pct exec` + git pull + rebuild), Deinstall (`pct destroy`), Handy-Hinweise (Zertifikat/Flag), `CONTACT_EMAIL`-Hinweis.
- Dieser Spec: `docs/superpowers/specs/2026-10-08-proxmox-lxc-motorrad-routenplaner-design.md`.

Kein Docker im LXC (Public-BRouter macht BRouter-Container überflüssig). Keine VM (Leistungsbedarf 2vCPU/2GB reicht; VM nur als dokumentierter Fallback, nicht implementiert).

## 3. LXC-Defaults (Variablen oben im Script)

| Variable | Default | Bemerkung |
|---|---|---|
| APP_NAME / HOSTNAME | `motorrad-routenplaner` | CT-Name = App-Name (Forderung) |
| CTID | auto (`pvesh get /cluster/nextid`) | „Immer nächste freie ID"; per `CTID=123` übersteuerbar |
| TEMPLATE | `debian-12-standard_*.tar.zst` | via `pveam update` + Download falls fehlend |
| STORAGE | `local-lvm` | per Env übersteuerbar |
| BRIDGE | `vmbr0` | DHCP (`ip=dhcp`); statisch optional |
| CORES / MEMORY / DISK | `2` / `2048` / `8` | Standard 1–2 vCPU, 1–2 GB RAM, 4–8 GB Disk erfüllt |
| UNPRIVILEGED / ONBOOT | `1` / `1` | reboot-sicher |
| APP_PORT | `8080` | Backend |
| HTTPS_PORT | `443` | Caddy |
| REPO / BRANCH | `mzluzifer/motorrad-routenplaner` / `main` | GitHub-first |
| BROUTER_URL | `https://brouter.de/brouter` | schlank, kein rd5-Download |
| CONTACT_EMAIL | `` (Env/Flag, interaktiv Abfrage) | Pflicht für Nominatim Fair-Use; `example.com` wird abgelehnt |

Alle Variablen als `VAR="${VAR:-default}"` oben, damit `CTID=150 CONTACT_EMAIL=a@b.de bash -c "$(…)"` funktioniert.

## 4. Container-Setup & systemd (Detail)

1. Base: `apt-get update && apt-get install -y git curl ca-certificates iproute2`.
2. Node 22 via nodesource (pin 22.x), `node -v` prüfen.
3. Caddy via offizielles apt-Repo (`caddy` Paket) — kein manueller Binary-Download.
4. App: `/opt/motorrad-routenplaner`, `git clone -b $BRANCH` oder `git pull --ff-only` (idempotent), `npm ci`, `npm run build`.
5. `.env` schreiben (nur falls geändert): PORT, BROUTER_URL, OVERPASS_URL, NOMINATIM_URL, AUTOBAHN_URL, CONTACT_EMAIL.
6. Bind-Patch: nach jedem Build `grep -q 127.0.0.1 backend/dist/index.js && sed -i 's/127\.0\.0\.1/0.0.0.0/g'` + Log-Zeile. Langfristig: Upstream-PR `HOST` env (Forderung an Repo-Betreiber dokumentieren).
7. systemd-Unit `/etc/systemd/system/motorrad-routenplaner.service`:
   ```
   [Unit] Description=Motorrad-Routenplaner
   After=network-online.target Wants=network-online.target
   [Service] Type=simple WorkingDirectory=/opt/motorrad-routenplaner/backend
   EnvironmentFile=/opt/motorrad-routenplaner/backend/.env
   ExecStart=/usr/bin/node /opt/motorrad-routenplaner/backend/dist/index.js
   Restart=always RestartSec=5
   [Install] WantedBy=multi-user.target
   ```
   `daemon-reload && enable --now`.
8. Caddyfile `/etc/caddy/Caddyfile` (ersetzen/ergänzen, Backup `.bak`):
   ```
   :80 { redir https://{http.request.host}{uri} }
   :443 {
     tls internal
     reverse_proxy 127.0.0.1:8080
   }
   ```
   `systemctl enable --now caddy`. Hinweis: `tls internal` = self-signed, voll lokal, keine öffentliche Domain/Ports nötig.
9. Firewall im LXC: falls `ufw`/`iptables` aktiv, `8080,443,80` öffnen; sonst nur dokumentieren (PVE-Firewall auf CT-Ebene default offen).

## 5. Mobile / GPS (Pflicht)

- Problem: `navigator.geolocation` + `getCurrentPosition` verlangen Secure Context. `http://192.168.x.x:8080` = unsicher → Handy-Chrome/Safari blockt „aktueller Standort" still. Karte ginge, GPS nicht — App unterwegs nutzlos.
- Lösung: Caddy mit `tls internal` liefert `https://[LXC-IP]/` im gleichen LAN. Erster Handy-Aufruf zeigt Zertifikatswarnung (erwartet, self-signed) → „Erweitert → trotzdem fortfahren". Danach läuft GPS, weil Secure Context erfüllt.
- Alternativen dokumentieren: (a) CA-Zert von LXC auf Handy importieren (warnungsfrei), (b) `chrome://flags#unsafely-treat-insecure-origins-as-secure` mit `http://IP:8080` als Notlösung, (c) echte Domain + Let's Encrypt nur falls öffentliche Domain vorhanden (nicht Standard).
- PWA/Service-Worker nicht nötig (V1). Responsive UI existiert (ziehbare Sidebar); im Installer-Test: Viewport 360px prüfen (manuell, kein Auto-Test).
- Keine Standort-Daten verlassen das LAN zusätzlich: Geocoding/Routing laufen weiter über öffentliche APIs (wie Desktop), GPS-Fix bleibt im Browser.

## 6. Verifikation, Debugging, Reboot-Test

Script-eigene Checks (Host + CT, Exit-Code ≠ 0 bei Fail):
- `systemctl is-active motorrad-routenplaner` und `caddy` → `active`.
- `curl -fsS http://127.0.0.1:8080/api/health` → `{"ok":true}`.
- `curl -fkSs https://127.0.0.1/api/health` → ok (Caddy).
- IP-Auflösung + finale Ausgabe:
  ```
  ✔ Motorrad-Routenplaner läuft in CT 101 (192.168.1.50)
    Desktop: http://192.168.1.50:8080
    Handy (GPS): https://192.168.1.50/  (Zertifikatswarnung bestätigen)
  ```
- Fehler: volle Kette — `set -x`-Ausschnitt, stderr/stdout des fehlgeschlagenen Befehls, Exit-Code, `journalctl -u motorrad-routenplaner -n 50`, `journalctl -u caddy -n 30`, `curl -v` Ausgabe. Hinweis: `bash -x install/motorrad-routenplaner.sh 2>&1 | tee install.log`.
- Lint: `bash -n` vor jedem Commit; ShellCheck wenn verfügbar (Warnungen, kein Hard-Fail).
- Reboot-Test (manuell zu belegen): `pct reboot <CTID>` → nach 30s beide Health-Checks grün + Logauszug ins README/PR.

## 7. Nicht-Ziele (V1)

- Kein self-hosted BRouter/rd5-Download, kein Docker im LXC, keine VM-Variante im Script (nur Doku-Hinweis).
- Kein Let's-Encrypt-Auto mit öffentlicher Domain, kein Tailscale/Cloudflare-Tunnel, keine PWA-Offline-Karten.
- Kein PVE-Firewall-/Reverse-Proxy auf Host-Ebene, kein Cluster-/Backup-Script.

## 8. Risiken & Gegenmittel

- Hardcoded `127.0.0.1` im Backend → sed-Patch brüchig bei Upstream-Änderung → Gegenmittel: Patch mit `grep` guard + Warnung + Upstream-Issue `HOST`-Env.
- `tls internal` Warnung schreckt Nutzer → Gegenmittel: README mit Screenshots/Steps + CA-Import-Anleitung.
- Nominatim `403` bei `example.com` → Gegenmittel: Installer verlangt echte CONTACT_EMAIL — falls leer und stdin ein TTY ist, wird interaktiv gefragt; ohne TTY bricht er mit klarer Meldung ab (kein Silent-Fail).
- Template/Storage-Namen je PVE anders → Gegenmittel: Auto-Detect (`pveam available`, `pvesm status`), Env-Override.
