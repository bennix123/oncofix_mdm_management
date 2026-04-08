# OncoFix Device Management — Self-Hosted MDM

Manage OncoFix devices from factory floor to clinic operation with zero third-party MDM costs.

## Architecture Overview

```
MANUFACTURING FACILITY                         YOUR SERVER
┌──────────────────────────────┐              ┌──────────────────────────────┐
│  Flash Golden Image          │              │  NestJS Backend              │
│  ↓                           │              │   ├─ POST /devices/provision │
│  First Boot Auto-Provision ──┼── HTTPS ────▶│   ├─ POST /devices/heartbeat│
│  ↓                           │              │   ├─ GET  /devices/commands  │
│  QA Test                     │              │   ├─ GET  /devices/update    │
│  ↓                           │              │   └─ device_registry (BQ)   │
│  Box & Ship                  │              │                              │
└──────────────────────────────┘              │  Vue Admin Panel             │
                                              │   ├─ Device list & status    │
CLINIC                                        │   ├─ Push update / restart   │
┌──────────────────────────────┐              │   ├─ View logs & health      │
│  Connect WiFi                │              │   └─ Assign to hospital      │
│  ↓                           │              └──────────────────────────────┘
│  Device Registration         │                         ▲
│  ↓                           │                         │
│  Patient Screening           │              ┌──────────┴───────────────────┐
│  ↓                           │              │  GCS Bucket                  │
│  Heartbeat every 5 min ──────┼── HTTPS ────▶│   ├─ oncofix_1.2.0.deb      │
│  Poll for commands ──────────┼── HTTPS ────▶│   ├─ oncofix_1.3.0.deb      │
│  Pull OTA updates ───────────┼── HTTPS ────▶│   └─ checksums.json         │
└──────────────────────────────┘              └──────────────────────────────┘
```

### Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| **Device calls home** (not server pushes to device) | Works through any NAT/firewall, no VPN or public IP needed |
| **Per-device identity tokens** (not shared SSH keys) | Compromise one device → revoke one token, fleet unaffected |
| **HTTPS polling** (not SSH/WebSocket) | Works on any clinic network, no special ports or protocols |
| **Self-hosted** (no third-party MDM) | Zero recurring cost, full control, integrated with our stack |

---

## Device Lifecycle

```
┌────────────┐    ┌──────────────┐    ┌───────────┐    ┌──────────┐    ┌────────┐
│ manufactured│───▶│  provisioned │───▶│ qa_passed │───▶│ assigned │───▶│ active │
└────────────┘    └──────────────┘    └───────────┘    └──────────┘    └────────┘
                         │                  │                               │
                         ▼                  ▼                               ▼
                   provision_failed    qa_failed                     offline (auto)
                                           │                               │
                                        repair                    back to active (auto)
                                                                           │
                                                                    decommissioned
```

---

## Step 1: Build the Golden OS Image (one-time)

Create a reference OrangePi5 with the full OncoFix stack, then snapshot it.

```bash
# On a reference OrangePi5 device:

# 1. Install base OS (Ubuntu/Armbian for OrangePi5)

# 2. Install system dependencies
apt-get update && apt-get install -y \
    nodejs python3 python3-venv nginx rabbitmq-server \
    erlang-base sqlite3 curl wget openssl jq

# 3. Install OncoFix .deb package
dpkg -i oncofix_1.0.0_all.deb

# 4. Create service user
useradd -r -m -s /bin/bash oncofix

# 5. Restrict what oncofix user can do via sudo
cat > /etc/sudoers.d/oncofix << 'EOF'
oncofix ALL=(ALL) NOPASSWD: /bin/systemctl restart oncofix-*
oncofix ALL=(ALL) NOPASSWD: /bin/systemctl status oncofix-*
oncofix ALL=(ALL) NOPASSWD: /bin/systemctl stop oncofix-*
oncofix ALL=(ALL) NOPASSWD: /usr/bin/dpkg -i /tmp/oncofix_*.deb
oncofix ALL=(ALL) NOPASSWD: /sbin/reboot
EOF
chmod 440 /etc/sudoers.d/oncofix

# 6. Install the provisioning service (runs on first boot)
cp oncofix-provision.sh /opt/oncofix/
cp oncofix-provision.service /etc/systemd/system/
systemctl enable oncofix-provision

# 7. Install the device agent (runs after provisioning)
cp device-agent.sh /opt/oncofix/
cp oncofix-agent.service /etc/systemd/system/

# 8. Configure factory WiFi (so device gets network on first boot)
# (use nmcli or /etc/netplan depending on your OS)

# 9. Snapshot the image
# From another machine:
dd if=/dev/sdX of=oncofix-golden-v1.0.0.img bs=4M status=progress
```

---

## Step 2: Flash & First-Boot Provisioning

A technician flashes the golden image to a new OrangePi5, then powers it on.

```
Technician flashes golden image → powers on device
    │
    ▼
Device boots, connects to factory WiFi
    │
    ▼
oncofix-provision.service runs automatically:
    │
    ├─ Reads hardware info (MAC address, CPU serial, board model)
    │
    ├─ POST /api/v1/devices/provision
    │    Body: { mac_address, cpu_serial, board_info }
    │
    ├─ Server responds:
    │    {
    │      device_id: "dev_MUM_1710400000000",
    │      device_token: "unique-per-device-64-char-token",
    │      jwt_secret: "auto-generated-32-char",
    │      refresh_secret: "auto-generated-32-char",
    │      photo_key: "auto-generated-32-char",
    │      bigquery_creds: "base64-encoded-json"
    │    }
    │
    ├─ Writes /etc/oncofix/backend.env (device-specific config)
    ├─ Writes /etc/oncofix/device-identity.json (device_id + token)
    ├─ Writes /etc/oncofix/gcp-credentials.json
    │
    ├─ Restarts all services
    │
    ├─ Sends first heartbeat: POST /api/v1/devices/heartbeat
    │
    ├─ Disables oncofix-provision.service (never runs again)
    └─ Enables oncofix-agent.service (heartbeat + command polling)
```

**What the server does on `/provision`:**
1. Checks if MAC/serial already registered (prevents duplicates)
2. Generates unique `device_id` and `device_token`
3. Generates unique secrets (JWT, photo encryption)
4. Stores device in `device_registry` table, status = `provisioned`
5. Returns all config the device needs

---

## Step 3: QA Testing

Technician triggers the QA test on the freshly provisioned device:

```bash
sudo bash /opt/oncofix/qa-test.sh
```

**The QA script validates:**

| Check | What it tests |
|-------|---------------|
| Backend health | `curl https://localhost/api/v1/health` returns 200 |
| Frontend loads | `curl http://localhost:8082` returns 200 |
| Camera capture | Takes a test photo via OrangePi camera |
| AI prediction | Sends test image to AI model, gets prediction |
| SQLite write | Creates test patient + assessment |
| RabbitMQ queue | Publishes and consumes a test message |
| BigQuery sync | Syncs test record, confirms in BigQuery |
| Heartbeat | Sends heartbeat, server confirms received |
| Cleanup | Deletes all test data |

```
QA result → POST /api/v1/devices/{device_id}/qa-result
            { passed: true, tests: [...], timestamp }

Server updates: status "provisioned" → "qa_passed"
```

If QA fails → status = `qa_failed`, flagged for repair in admin panel.

---

## Step 4: Assignment & Shipping

Admin assigns the device to a hospital via the Vue admin panel (or API):

```
POST /api/v1/devices/{device_id}/assign
{ hospital_id: "hosp_ADC_17098...", clinic_name: "City Clinic Mumbai" }

Server updates: status "qa_passed" → "assigned", stores hospital_id, ship_date
```

Packing slip generated with:
- Device ID (QR code)
- Assigned hospital name
- Quick-start setup card

Device shipped to clinic.

---

## Step 5: Clinic Activation

Clinic staff powers on the device:

```
Device boots at clinic
    │
    ▼
Connects to clinic WiFi (staff configures via network manager)
    │
    ▼
Device agent sends heartbeat → server updates: status → "online_at_clinic"
    │
    ▼
Health Intake Form shows Device Registration screen:
    - Hospital/clinic name (pre-filled from assignment)
    - Admin name, phone, password
    - Internet connectivity check
    │
    ▼
POST /api/v1/device-registration
    { device_id, hospital_info, admin_user }
    │
    ▼
Server: status → "active"
    │
    ▼
Device ready for patient screening ✅
```

---

## Step 6: Daily Operation

```
┌─────────────────────────────────────────────────────────────────┐
│                       DAILY CLINIC USE                           │
│                                                                  │
│  Patient → Intake Form → Photos → AI Analysis → Doctor Review   │
│                            │                                     │
│                      SQLite (offline)                            │
│                            │                                     │
│                     Every 5 min sync                             │
│                            │                                     │
│                    RabbitMQ → BigQuery                           │
│                                                                  │
│  Device Agent (always running):                                  │
│    • Heartbeat every 5 min → server                              │
│    • Poll for commands → execute locally                         │
│    • Check for OTA updates → pull & install                     │
└─────────────────────────────────────────────────────────────────┘
```

---

## Device Agent (Self-Hosted MDM Core)

The device agent is the core of our MDM. It runs as a systemd service on every device. The device always initiates the connection — no inbound ports, no VPN, works through any NAT/firewall.

### What it does

```
Every 5 minutes:
    │
    ├─ 1. HEARTBEAT — tell server "I'm alive"
    │     POST /api/v1/devices/heartbeat
    │     { device_id, device_token, version, services, disk, memory, unsynced_count }
    │
    ├─ 2. CHECK COMMANDS — "anything for me?"
    │     GET /api/v1/devices/commands
    │     Header: X-Device-ID, X-Device-Token
    │
    ├─ 3. EXECUTE — run pending commands locally
    │     restart_backend  → systemctl restart oncofix-backend
    │     restart_ai       → systemctl restart oncofix-ai
    │     update           → download .deb, verify checksum, dpkg -i
    │     reboot           → sudo reboot
    │     upload_logs      → POST logs to server
    │     run_healthcheck  → run full QA, report results
    │
    └─ 4. REPORT — tell server what happened
          POST /api/v1/devices/command-result
          { command_id, status: "success"|"failed", output }
```

### Per-device identity

Each device gets a unique `device_token` during provisioning. This is NOT a shared key.

- **If one device is compromised** → revoke that one token on the server → only that device loses access
- **No other device is affected**
- **Full audit trail** — every heartbeat and command is logged with device_id and timestamp

### Alert rules (server-side)

| Condition | Severity | Action |
|-----------|----------|--------|
| No heartbeat for 15 min | WARN | Log in dashboard |
| No heartbeat for 1 hour | CRITICAL | Webhook + email alert |
| Backend service down | ERROR | Webhook alert |
| Disk usage > 85% | WARN | Dashboard warning |
| Unsynced records > 100 | WARN | Dashboard warning |
| QA test failed | ERROR | Webhook alert |

---

## OTA Updates

Devices check for updates as part of the agent loop. The device pulls updates — no need to push anything.

```
Device agent (hourly check):
    │
    GET /api/v1/devices/update-check?current_version=1.2.0
    │
    ▼
Server responds:
    { update_available: true, version: "1.3.0",
      deb_url: "https://storage.googleapis.com/.../oncofix_1.3.0.deb",
      checksum: "sha256:abc123...",
      mandatory: false }
    │
    ▼ (if update available)
    │
    ├─ Download .deb to /tmp/
    ├─ Verify SHA256 checksum
    ├─ Backup SQLite database
    ├─ dpkg -i oncofix_1.3.0.deb
    ├─ Restart services
    └─ Next heartbeat reports new version
        │
        ▼
    Server: version → "1.3.0", status stays "active"
```

### Rollback

If the backend fails to start after an update:

```bash
# Automatic (device agent detects backend not running after update):
#   → restores database backup
#   → re-installs previous .deb from /var/cache/oncofix/
#   → reports rollback to server

# Manual:
sudo systemctl stop oncofix-backend
sudo cp /var/lib/oncofix/backups/database-pre-update-*.sqlite /var/lib/oncofix/database.sqlite
sudo dpkg -i /var/cache/oncofix/oncofix_<old-version>_all.deb
```

---

## Quick Start

### Build the .deb package

```bash
cd /path/to/Oncofix/packaging
chmod +x build-deb.sh
./build-deb.sh 1.0.0
# Produces: oncofix_1.0.0_all.deb
```

### Bootstrap a device (physical/SSH access)

```bash
# Full setup with BigQuery sync
sudo DEVICE_ID="OPi5_clinic_mumbai_001" \
     DEVICE_NAME="Clinic Mumbai Unit 1" \
     DEVICE_LOCATION="Mumbai" \
     DEB_URL="https://your-repo/oncofix_1.0.0_all.deb" \
     GCP_CREDS_URL="https://your-bucket/gcp-creds.json" \
     bash bootstrap-device.sh

# Minimal setup (local .deb, no cloud sync)
sudo DEB_PATH="/tmp/oncofix_1.0.0_all.deb" bash bootstrap-device.sh
```

The bootstrap script handles all 8 steps:
1. Installs Node.js 18, Python 3, RabbitMQ, Nginx, SQLite
2. Installs OncoFix .deb package
3. Configures device ID, secrets (auto-generated)
4. Sets up BigQuery credentials
5. Initializes database
6. Starts all services
7. Installs device agent
8. Sets up health-check cron

### Queue a command from admin panel

```bash
# From admin panel or API:
POST /api/v1/devices/commands
{
    "device_id": "dev_MUM_1710400000",
    "command_type": "restart_backend",
    "issued_by": "admin_user_id"
}
# Device picks it up on next poll cycle (within 5 min)
```

---

## Manual Single-Device Install

For testing or when no network provisioning is available:

```bash
# Copy .deb to device via USB
sudo dpkg -i oncofix_1.0.0_all.deb
sudo apt-get install -f

# Edit config
sudo nano /etc/oncofix/backend.env

# Place GCP credentials
sudo cp gcp-credentials.json /etc/oncofix/
sudo chmod 600 /etc/oncofix/gcp-credentials.json
sudo chown oncofix:oncofix /etc/oncofix/gcp-credentials.json

# Start services
sudo systemctl restart oncofix-backend
```

---

## Monitoring & Health Checks

Every device runs `health-check.sh` every 5 minutes via cron (installed by bootstrap).

### Health report format (JSON)

```json
{
    "deviceId": "dev_MUM_1710400000",
    "timestamp": "2026-03-14T10:30:00Z",
    "hostname": "orangepi5-001",
    "ip": "192.168.1.50",
    "services": {
        "backend": "running",
        "frontend": "running",
        "ai": "running",
        "rabbitmq": "running"
    },
    "resources": {
        "diskUsagePercent": 42,
        "memoryUsagePercent": 61,
        "systemUptime": "2026-03-01 08:00:00"
    },
    "database": {
        "size": "1.3M",
        "unsyncedRecords": "3"
    },
    "packageVersion": "1.2.0"
}
```

### Monitoring tools (self-hosted, free)

| Tool | Purpose | How |
|------|---------|-----|
| **NestJS backend** | Heartbeat storage + alerting | Built-in (AlertService) |
| **Vue admin panel** | Device dashboard | Device list, status, actions page |
| **Uptime Kuma** (optional) | Ping monitoring | Self-hosted, ping each device's port 8082 |
| **Grafana + InfluxDB** (optional) | Historical metrics | Ingest health-check JSON for dashboards |

---

## BigQuery `device_registry` Table Schema

```sql
CREATE TABLE device_registry (
    device_id        STRING NOT NULL,    -- PK: dev_MUM_1710400000
    device_token     STRING NOT NULL,    -- unique per-device auth token (hashed)
    device_name      STRING,
    location         STRING,
    hospital_id      STRING,             -- FK to hospitals table
    status           STRING NOT NULL,    -- manufactured|provisioned|qa_passed|assigned|active|offline|decommissioned
    mac_address      STRING,
    cpu_serial       STRING,
    board_model      STRING,
    app_version      STRING,
    os_info          STRING,
    ip_address       STRING,
    last_heartbeat   TIMESTAMP,
    last_command_at  TIMESTAMP,
    provisioned_at   TIMESTAMP,
    qa_passed_at     TIMESTAMP,
    assigned_at      TIMESTAMP,
    activated_at     TIMESTAMP,
    shipped_at       TIMESTAMP,
    created_at       TIMESTAMP NOT NULL,
    updated_at       TIMESTAMP NOT NULL
);
```

---

## Server Endpoints Summary

| Endpoint | Method | Called by | Purpose |
|----------|--------|-----------|---------|
| `/devices/provision` | POST | Device (first boot) | Register new device, return config |
| `/devices/heartbeat` | POST | Device (every 5 min) | Report status, detect offline |
| `/devices/commands` | GET | Device (every 5 min) | Poll for pending commands |
| `/devices/commands` | POST | Admin panel | Queue command for a device |
| `/devices/command-result` | POST | Device | Report command execution result |
| `/devices/update-check` | GET | Device (hourly) | Check for OTA updates |
| `/devices/{id}/qa-result` | POST | QA script | Report QA test result |
| `/devices/{id}/assign` | POST | Admin panel | Assign device to hospital |
| `/devices/{id}/decommission` | POST | Admin panel | Retire a device |
| `/devices` | GET | Admin panel | List all devices with filters |
| `/devices/{id}` | GET | Admin panel | Device detail + command history |

---

## File Reference

```
packaging/
  build-deb.sh                  # Build the .deb package
  debian/                        # Debian package structure
    DEBIAN/
      control                    # Package metadata & dependencies
      conffiles                  # Config files preserved on upgrade
      preinst                    # Pre-install: check deps, create user
      postinst                   # Post-install: setup venv, start services
      prerm                      # Pre-remove: stop services
      postrm                     # Post-remove: cleanup
    etc/
      systemd/system/
        oncofix-backend.service  # Backend systemd unit
        oncofix-ai.service       # AI model systemd unit
        oncofix-agent.service    # Device agent systemd unit
      nginx/sites-available/
        oncofix-frontend         # Nginx config for frontend
      oncofix/
        backend.env              # Backend configuration
        frontend.env             # Frontend configuration
    opt/oncofix/                 # Application files (populated by build)
    var/lib/oncofix/             # Database & backups
    var/log/oncofix/             # Log files
  mdm/
    oncofix-provision.sh         # First-boot auto-provisioning (runs once)
    device-agent.sh              # Heartbeat + command polling agent (runs forever)
    qa-test.sh                   # Automated QA validation (factory floor)
    bootstrap-device.sh          # Full device setup in one script
    deploy-device.sh             # Single device deployment via SSH
    update-device.sh             # OTA update for existing device
    health-check.sh              # Periodic health monitoring (cron)
    batch-deploy.sh              # Deploy to multiple devices via SSH
    devices.csv.example          # Example device inventory for batch-deploy
    scalefusion-setup.sh         # (Optional) Scalefusion MDM agent enrollment
    swifai-setup.sh              # (Optional) Swif.ai MDM agent enrollment
    README.md                    # This file
```

> **Note:** `scalefusion-setup.sh` and `swifai-setup.sh` are optional — use them
> only if you want a third-party MDM alongside the self-hosted agent. The self-hosted
> `device-agent.sh` provides heartbeat, command execution, and OTA updates without
> any third-party dependency.

---

## Troubleshooting

### Device not provisioning on first boot

```bash
# Check provision service logs
journalctl -u oncofix-provision -n 50 --no-pager

# Common causes:
#   - No network (factory WiFi not configured in image)
#   - Server unreachable (wrong URL in provision script)
#   - MAC already registered (duplicate device — check server logs)
```

### Services not starting after install

```bash
journalctl -u oncofix-backend -n 50 --no-pager
journalctl -u oncofix-ai -n 50 --no-pager
```

### Device showing offline in dashboard

```bash
# Run health check manually
sudo bash /opt/oncofix/health-check.sh

# Check agent service
systemctl status oncofix-agent
journalctl -u oncofix-agent -n 20 --no-pager

# Common causes:
#   - Clinic WiFi changed / device lost network
#   - Device token revoked on server
#   - Server unreachable from clinic network
```

### Rolling back a failed update

```bash
# Database backups are in /var/lib/oncofix/backups/
ls /var/lib/oncofix/backups/

# Restore
sudo systemctl stop oncofix-backend
sudo cp /var/lib/oncofix/backups/database-pre-update-*.sqlite /var/lib/oncofix/database.sqlite
sudo chown oncofix:oncofix /var/lib/oncofix/database.sqlite
sudo dpkg -i /var/cache/oncofix/oncofix_<old-version>_all.deb
```

### Resetting a device completely

```bash
sudo dpkg --purge oncofix    # removes everything including data
sudo dpkg -i oncofix_1.0.0_all.deb   # fresh install
# Device will need to re-provision (re-enable oncofix-provision.service)
```
