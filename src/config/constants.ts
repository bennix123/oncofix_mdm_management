export const DEFAULTS = {
  HEARTBEAT_INTERVAL_MS: 5 * 60 * 1000, // 5 minutes
  UPDATE_CHECK_INTERVAL_MS: 60 * 60 * 1000, // 1 hour
  COMMAND_POLL_INTERVAL_MS: 5 * 60 * 1000, // 5 minutes
  PROCEED_POLL_INTERVAL_MS: 10 * 1000, // 10 seconds
  UPDATE_STATUS_POLL_INTERVAL_MS: 30 * 1000, // 30 seconds

  CONFIG_DIR: '/etc/oncofix',
  DATA_DIR: '/var/lib/oncofix',
  LOG_DIR: '/var/log/oncofix',
  INSTALL_DIR: '/opt/oncofix',

  IDENTITY_FILE: '/etc/oncofix/device-identity.json',
  DEVICE_INFO_FILE: '/etc/oncofix/device-info.json',
  BACKEND_ENV_FILE: '/etc/oncofix/backend.env',
  GCP_CREDENTIALS_FILE: '/etc/oncofix/gcp-credentials.json',

  SQLITE_DB_PATH: '/var/lib/oncofix/mdm-agent.sqlite',
  BACKUP_DIR: '/var/lib/oncofix/backups',

  FLAG_DIR: '/var/lib/oncofix',
  UPDATE_READY_FILE: '/var/lib/oncofix/update-ready.json',
  UPDATE_PROCEED_FILE: '/var/lib/oncofix/update-proceed.json',

  VERSION_FILE: '/opt/oncofix/VERSION',
  AGENT_LOG_FILE: '/var/log/oncofix/agent.log',

  MAX_RETRY_ATTEMPTS: 2,
  HEALTH_CHECK_TIMEOUT_MS: 5000,
  DOWNLOAD_TIMEOUT_MS: 10 * 60 * 1000, // 10 minutes

  SERVICES: ['oncofix-backend', 'oncofix-ai', 'nginx', 'rabbitmq-server'] as const,
} as const;

export const PROVISIONING_STATES = {
  MANUFACTURED: 'manufactured',
  PROVISIONED: 'provisioned',
  PROVISION_FAILED: 'provision_failed',
} as const;

export type ProvisioningState = typeof PROVISIONING_STATES[keyof typeof PROVISIONING_STATES];

export const COMMAND_TYPES = {
  RESTART_SERVICE: 'restart_service',
  RESTART_BACKEND: 'restart_backend',
  RESTART_AI: 'restart_ai',
  RESTART_ALL: 'restart_all',
  REBOOT_DEVICE: 'reboot',
  FETCH_LOGS: 'upload_logs',
  HEALTH_CHECK: 'run_healthcheck',
  UPDATE: 'update',
} as const;

export type CommandType = typeof COMMAND_TYPES[keyof typeof COMMAND_TYPES];
