# OncoFix Debian Package Builder

Build a `.deb` package to deploy OncoFix (backend + frontend) on Debian devices (Raspberry Pi, Orange Pi, etc).

## What gets installed

| Service | Port | systemd unit |
|---|---|---|
| Backend (NestJS) | 3000 | `oncofix-backend` |
| Frontend (React) | 5173 | `oncofix-frontend` |

- SQLite local database (offline-first)
- BigQuery sync every 5 minutes (when internet available)
- Camera system (headless, 3 USB cameras)
- H2S sensor + GPIO button support

## Prerequisites

Build machine needs: `node`, `npm`, `python3`, `dpkg-deb`

Source repos must be sibling directories:
```
parent-dir/
  oncofix_online_backend/    # NestJS backend
  health-intake-form/        # React frontend
  oncofix_mdm_management/    # This repo (packaging)
```

## Build

```bash
chmod +x build-deb.sh
./build-deb.sh 2.0.0 arm64
```

Output: `oncofix_2.0.0_arm64.deb`

## Install on device

```bash
# Copy .deb to device
scp oncofix_2.0.0_arm64.deb oncofix@device-ip:~/

# Install (resolves dependencies automatically)
sudo apt install ./oncofix_2.0.0_arm64.deb
```

## Post-install steps

1. Edit config:
   ```bash
   sudo nano /etc/oncofix/backend.env
   # Set: JWT_SECRET, PHOTO_ENCRYPTION_KEY
   ```

2. Copy BigQuery credentials:
   ```bash
   scp bigquery-credentials.json oncofix@device:/opt/oncofix/oncofix_online_backend/
   sudo chown oncofix:oncofix /opt/oncofix/oncofix_online_backend/bigquery-credentials.json
   ```

3. Register device (one-time):
   ```bash
   curl -X POST http://localhost:3000/api/v1/devices/register \
     -H "Content-Type: application/json" \
     -d '{"deviceAdapterId":"OPi5_001","hospitalName":"Your Hospital","hospitalEmail":"email@hospital.com","adminName":"Admin","adminPhone":1234567890,"adminEmail":"admin@hospital.com","adminPassword":"YourPassword"}'
   ```

4. Reboot - everything starts automatically.

## Managing services

```bash
sudo systemctl status oncofix-backend
sudo systemctl status oncofix-frontend
sudo journalctl -u oncofix-backend -f
sudo systemctl restart oncofix-backend
```

## File locations

| What | Path |
|---|---|
| Backend code | `/opt/oncofix/oncofix_online_backend/` |
| Frontend dist | `/opt/oncofix/health-intake-form/dist/` |
| Backend config | `/etc/oncofix/backend.env` |
| Frontend config | `/etc/oncofix/frontend.env` |
| SQLite database | `/var/lib/oncofix/database.sqlite` |
| Logs | `journalctl -u oncofix-backend` |
| Photos | `/opt/oncofix/oncofix_online_backend/photos/` |
