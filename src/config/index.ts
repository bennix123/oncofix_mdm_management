import * as fs from 'fs';
import * as path from 'path';
import { DEFAULTS } from './constants';

export interface DeviceIdentity {
  device_id: string;
  device_token: string;
  server_url: string;
  mac_address: string;
  cpu_serial: string;
  board_model: string;
  hostname: string;
  provisioned_at: string;
}

export interface DeviceInfo {
  device_id: string;
  device_name: string;
  location: string;
  version: string;
  status: string;
  last_updated: string;
}

export interface AgentConfig {
  serverUrl: string;
  deviceId: string;
  deviceToken: string;
  heartbeatIntervalMs: number;
  updateCheckIntervalMs: number;
  commandPollIntervalMs: number;
  proceedPollIntervalMs: number;
  sqliteDbPath: string;
  dataDir: string;
  logDir: string;
  backupDir: string;
  flagDir: string;
  identityFilePath: string;
  deviceInfoFilePath: string;
  versionFilePath: string;
  agentLogFilePath: string;
  maxRetryAttempts: number;
}

export function loadIdentity(filePath: string = DEFAULTS.IDENTITY_FILE): DeviceIdentity | null {
  try {
    if (!fs.existsSync(filePath)) return null;
    const raw = fs.readFileSync(filePath, 'utf-8');
    return JSON.parse(raw) as DeviceIdentity;
  } catch {
    return null;
  }
}

export function loadDeviceInfo(filePath: string = DEFAULTS.DEVICE_INFO_FILE): DeviceInfo | null {
  try {
    if (!fs.existsSync(filePath)) return null;
    const raw = fs.readFileSync(filePath, 'utf-8');
    return JSON.parse(raw) as DeviceInfo;
  } catch {
    return null;
  }
}

export function getCurrentVersion(versionFilePath: string = DEFAULTS.VERSION_FILE): string {
  try {
    if (!fs.existsSync(versionFilePath)) return '0.0.0';
    const content = fs.readFileSync(versionFilePath, 'utf-8');
    const match = content.match(/version[=: ]+(\d+\.\d+\.\d+)/i);
    return match ? match[1] : '0.0.0';
  } catch {
    return '0.0.0';
  }
}

export function loadConfig(): AgentConfig {
  const identity = loadIdentity();

  const envServerUrl = process.env.MDM_SERVER_URL || process.env.PROVISION_SERVER_URL;
  const serverUrl = identity?.server_url || envServerUrl || 'http://localhost:443';

  return {
    serverUrl,
    deviceId: identity?.device_id || process.env.DEVICE_ID || 'unknown',
    deviceToken: identity?.device_token || process.env.DEVICE_TOKEN || '',
    heartbeatIntervalMs: intEnv('HEARTBEAT_INTERVAL_MS', DEFAULTS.HEARTBEAT_INTERVAL_MS),
    updateCheckIntervalMs: intEnv('UPDATE_CHECK_INTERVAL_MS', DEFAULTS.UPDATE_CHECK_INTERVAL_MS),
    commandPollIntervalMs: intEnv('COMMAND_POLL_INTERVAL_MS', DEFAULTS.COMMAND_POLL_INTERVAL_MS),
    proceedPollIntervalMs: intEnv('PROCEED_POLL_INTERVAL_MS', DEFAULTS.PROCEED_POLL_INTERVAL_MS),
    sqliteDbPath: process.env.MDM_SQLITE_PATH || DEFAULTS.SQLITE_DB_PATH,
    dataDir: process.env.MDM_DATA_DIR || DEFAULTS.DATA_DIR,
    logDir: process.env.MDM_LOG_DIR || DEFAULTS.LOG_DIR,
    backupDir: process.env.MDM_BACKUP_DIR || DEFAULTS.BACKUP_DIR,
    flagDir: process.env.MDM_FLAG_DIR || DEFAULTS.FLAG_DIR,
    identityFilePath: DEFAULTS.IDENTITY_FILE,
    deviceInfoFilePath: DEFAULTS.DEVICE_INFO_FILE,
    versionFilePath: DEFAULTS.VERSION_FILE,
    agentLogFilePath: process.env.MDM_LOG_FILE || DEFAULTS.AGENT_LOG_FILE,
    maxRetryAttempts: intEnv('MAX_RETRY_ATTEMPTS', DEFAULTS.MAX_RETRY_ATTEMPTS),
  };
}

function intEnv(key: string, defaultVal: number): number {
  const val = process.env[key];
  if (!val) return defaultVal;
  const parsed = parseInt(val, 10);
  return isNaN(parsed) ? defaultVal : parsed;
}
