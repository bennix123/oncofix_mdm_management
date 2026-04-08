import { AgentConfig, getCurrentVersion } from '../../config';
import { getDatabase } from '../../database';
import { getLogger } from '../../logger';
import { getHttpClient } from '../../utils/http-client';
import { UpdateDownloader } from './update-downloader';
import { UpdateInstaller } from './update-installer';
import { writeUpdateReady, readUpdateProceed, cleanupFlagFiles } from '../../utils/flag-files';

interface UpdateCheckResponse {
  update_available: boolean;
  version: string;
  deb_url: string;
  checksum: string;
}

export class UpdateChecker {
  private config: AgentConfig;
  private logger = getLogger();
  private timer: ReturnType<typeof setInterval> | null = null;
  private downloader: UpdateDownloader;
  private installer: UpdateInstaller;
  private isProcessing = false;

  constructor(config: AgentConfig) {
    this.config = config;
    this.downloader = new UpdateDownloader(config);
    this.installer = new UpdateInstaller(config);
  }

  start(): void {
    this.logger.info('OTA update checker started', 'OTA');
    this.timer = setInterval(() => this.check(), this.config.updateCheckIntervalMs);
  }

  stop(): void {
    if (this.timer) {
      clearInterval(this.timer);
      this.timer = null;
    }
    this.logger.info('OTA update checker stopped', 'OTA');
  }

  private async check(): Promise<void> {
    if (this.isProcessing) {
      this.logger.debug('Update already in progress, skipping check', 'OTA');
      return;
    }

    try {
      const currentVersion = getCurrentVersion(this.config.versionFilePath);
      const client = getHttpClient();
      const response = await client.get<UpdateCheckResponse>(
        `/devices/update-check?current_version=${currentVersion}`
      );

      const data = response.data;
      if (!data.update_available) {
        this.logger.debug('No update available', 'OTA');
        return;
      }

      this.logger.info(`Update available: ${currentVersion} -> ${data.version}`, 'OTA');
      this.isProcessing = true;

      await this.processUpdate(data);
    } catch {
      // Server unreachable — skip this cycle
    } finally {
      this.isProcessing = false;
    }
  }

  private async processUpdate(update: UpdateCheckResponse): Promise<void> {
    const db = getDatabase();

    // Record detected update
    db.prepare(`
      INSERT INTO update_state (version, deb_url, checksum, status)
      VALUES (?, ?, ?, 'detected')
    `).run(update.version, update.deb_url, update.checksum);

    // Phase 1: Download
    this.logger.info(`Downloading ${update.deb_url}...`, 'OTA');
    const downloadResult = await this.downloader.download(update.deb_url, update.checksum);

    if (!downloadResult.success) {
      this.logger.error(`Download failed: ${downloadResult.error}`, 'OTA');
      this.updateState(update.version, 'failed', downloadResult.error);
      await this.notifyServer('failed', `Download failed: ${downloadResult.error}`);
      return;
    }

    this.updateState(update.version, 'verified');
    this.logger.info('Download verified, writing update-ready flag', 'OTA');

    // Phase 2: Write flag file for frontend notification
    writeUpdateReady(this.config.flagDir, {
      version: update.version,
      deb_path: downloadResult.debPath!,
      checksum: update.checksum,
      downloaded_at: new Date().toISOString(),
    });

    this.updateState(update.version, 'waiting_confirmation');

    // Phase 3: Wait for doctor confirmation
    const confirmed = await this.waitForConfirmation();
    if (!confirmed) {
      this.logger.warn('Confirmation timeout, will retry next cycle', 'OTA');
      cleanupFlagFiles(this.config.flagDir);
      return;
    }

    this.logger.info('Doctor confirmed update, proceeding with installation', 'OTA');
    this.updateState(update.version, 'installing');

    // Phase 4: Install with retry and rollback
    const installResult = await this.installer.install(
      downloadResult.debPath!,
      update.version,
    );

    if (installResult.success) {
      this.updateState(update.version, 'completed');
      cleanupFlagFiles(this.config.flagDir);
      await this.notifyServer('success', `Updated to ${update.version}`);
      this.logger.info(`Update to ${update.version} completed successfully`, 'OTA');
    } else {
      this.updateState(update.version, installResult.rolledBack ? 'rolled_back' : 'failed', installResult.error);
      cleanupFlagFiles(this.config.flagDir);
      await this.notifyServer('failed', installResult.error || 'Install failed');
      this.logger.error(`Update to ${update.version} failed: ${installResult.error}`, 'OTA');
    }
  }

  private async waitForConfirmation(): Promise<boolean> {
    // Poll update-proceed.json every 10 seconds for up to 24 hours
    const maxWaitMs = 24 * 60 * 60 * 1000;
    const startTime = Date.now();

    while (Date.now() - startTime < maxWaitMs) {
      const proceed = readUpdateProceed(this.config.flagDir);
      if (proceed?.confirmed) {
        return true;
      }
      await this.sleep(this.config.proceedPollIntervalMs);
    }

    return false;
  }

  private updateState(version: string, status: string, errorMessage?: string): void {
    const db = getDatabase();
    const timestampCol =
      status === 'verified' ? 'downloaded_at' :
      status === 'installing' ? 'confirmed_at' :
      status === 'completed' ? 'completed_at' : null;

    if (timestampCol) {
      db.prepare(`
        UPDATE update_state SET status = ?, ${timestampCol} = datetime('now')
        WHERE version = ? AND status != 'completed'
        ORDER BY detected_at DESC LIMIT 1
      `).run(status, version);
    } else if (errorMessage) {
      db.prepare(`
        UPDATE update_state SET status = ?, error_message = ?
        WHERE version = ? AND status != 'completed'
      `).run(status, errorMessage, version);
    } else {
      db.prepare(`
        UPDATE update_state SET status = ?
        WHERE version = ? AND status != 'completed'
      `).run(status, version);
    }
  }

  private async notifyServer(status: string, output: string): Promise<void> {
    try {
      const client = getHttpClient();
      await client.post('/devices/command-result', {
        command_id: `ota-${Date.now()}`,
        device_id: this.config.deviceId,
        status,
        output: output.substring(0, 10000),
      });
    } catch {
      this.logger.warn('Failed to notify server of update result', 'OTA');
    }
  }

  private sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }
}
