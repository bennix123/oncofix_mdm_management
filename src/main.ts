import { loadConfig } from './config';
import { initDatabase, closeDatabase } from './database';
import { initLogger, getLogger } from './logger';
import { initHttpClient } from './utils/http-client';
import { ProvisioningService } from './modules/identity/provisioning.service';
import { HeartbeatService } from './modules/heartbeat/heartbeat.service';
import { CommandPoller } from './modules/commands/command-poller';
import { UpdateChecker } from './modules/ota/update-checker';
import { SyncBridgeService } from './modules/sync-bridge/sync-bridge.service';

async function main(): Promise<void> {
  const config = loadConfig();

  const logger = initLogger(config.agentLogFilePath, 'info');
  logger.info('=== OncoFix MDM Agent starting ===', 'Main');

  // Initialize database
  initDatabase(config.sqliteDbPath);

  // Initialize HTTP client (append /api/v1 to match backend global prefix)
  const apiBase = (url: string) => url.replace(/\/+$/, '') + '/api/v1';
  initHttpClient({
    baseUrl: apiBase(config.serverUrl),
    deviceToken: config.deviceToken,
    deviceId: config.deviceId,
  });

  // Phase 1: Provisioning (first-boot only)
  const provisioning = new ProvisioningService(config);
  await provisioning.ensureProvisioned();

  // Reload config in case provisioning updated identity
  const updatedConfig = loadConfig();
  initHttpClient({
    baseUrl: apiBase(updatedConfig.serverUrl),
    deviceToken: updatedConfig.deviceToken,
    deviceId: updatedConfig.deviceId,
  });

  // Phase 2: Heartbeat Engine
  const heartbeat = new HeartbeatService(updatedConfig);
  heartbeat.start();

  // Phase 3: Command Poller
  const commands = new CommandPoller(updatedConfig);
  commands.start();

  // Phase 4: OTA Update Checker
  const ota = new UpdateChecker(updatedConfig);
  ota.start();

  // Phase 7: Sync Bridge
  const syncBridge = new SyncBridgeService(updatedConfig);
  syncBridge.start();

  logger.info(`Agent running — device=${updatedConfig.deviceId}, server=${updatedConfig.serverUrl}`, 'Main');
  logger.info(`Heartbeat every ${updatedConfig.heartbeatIntervalMs / 1000}s, update check every ${updatedConfig.updateCheckIntervalMs / 1000}s`, 'Main');

  // Graceful shutdown
  const shutdown = () => {
    logger.info('Shutting down MDM agent...', 'Main');
    heartbeat.stop();
    commands.stop();
    ota.stop();
    syncBridge.stop();
    closeDatabase();
    process.exit(0);
  };

  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);
}

main().catch((err) => {
  console.error('Fatal error starting MDM agent:', err);
  process.exit(1);
});
