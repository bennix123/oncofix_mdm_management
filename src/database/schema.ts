export const CREATE_TABLES_SQL = `
  -- Queued heartbeats for offline buffering
  CREATE TABLE IF NOT EXISTS heartbeat_queue (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    payload TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    sent_at TEXT,
    status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending', 'sent', 'failed'))
  );

  -- Command execution log
  CREATE TABLE IF NOT EXISTS command_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    command_id TEXT NOT NULL,
    command_type TEXT NOT NULL,
    payload TEXT,
    status TEXT NOT NULL DEFAULT 'received' CHECK(status IN ('received', 'executing', 'completed', 'failed')),
    exit_code INTEGER,
    output TEXT,
    received_at TEXT NOT NULL DEFAULT (datetime('now')),
    executed_at TEXT,
    reported_at TEXT
  );

  -- Provisioning state
  CREATE TABLE IF NOT EXISTS provisioning_state (
    id INTEGER PRIMARY KEY CHECK(id = 1),
    state TEXT NOT NULL DEFAULT 'manufactured',
    device_id TEXT,
    device_token TEXT,
    server_url TEXT,
    hardware_fingerprint TEXT,
    provisioned_at TEXT,
    last_updated TEXT NOT NULL DEFAULT (datetime('now'))
  );

  -- OTA update state tracking
  CREATE TABLE IF NOT EXISTS update_state (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    version TEXT NOT NULL,
    deb_url TEXT,
    deb_path TEXT,
    checksum TEXT,
    status TEXT NOT NULL DEFAULT 'detected' CHECK(status IN ('detected', 'downloading', 'downloaded', 'verified', 'waiting_confirmation', 'installing', 'verifying', 'completed', 'failed', 'rolled_back')),
    retry_count INTEGER NOT NULL DEFAULT 0,
    error_message TEXT,
    detected_at TEXT NOT NULL DEFAULT (datetime('now')),
    downloaded_at TEXT,
    confirmed_at TEXT,
    installed_at TEXT,
    completed_at TEXT
  );

  -- Connectivity status log
  CREATE TABLE IF NOT EXISTS connectivity_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    online INTEGER NOT NULL DEFAULT 0,
    checked_at TEXT NOT NULL DEFAULT (datetime('now'))
  );

  -- Create indexes
  CREATE INDEX IF NOT EXISTS idx_heartbeat_status ON heartbeat_queue(status);
  CREATE INDEX IF NOT EXISTS idx_command_status ON command_log(status);
  CREATE INDEX IF NOT EXISTS idx_update_status ON update_state(status);
`;
