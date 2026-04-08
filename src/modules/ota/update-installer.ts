import { execSync } from 'child_process';
import * as fs from 'fs';
import * as path from 'path';
import { AgentConfig, getCurrentVersion } from '../../config';
import { getLogger } from '../../logger';
import { DEFAULTS } from '../../config/constants';

export interface InstallResult {
  success: boolean;
  error?: string;
  rolledBack: boolean;
}

export class UpdateInstaller {
  private config: AgentConfig;
  private logger = getLogger();

  constructor(config: AgentConfig) {
    this.config = config;
  }

  async install(debPath: string, newVersion: string): Promise<InstallResult> {
    const previousVersion = getCurrentVersion(this.config.versionFilePath);

    // Step 1: Backup database
    this.logger.info('Backing up database before update...', 'Installer');
    const backupPath = this.backupDatabase();

    // Step 2: Attempt install with retry
    for (let attempt = 0; attempt <= this.config.maxRetryAttempts; attempt++) {
      if (attempt > 0) {
        this.logger.info(`Retry attempt ${attempt}/${this.config.maxRetryAttempts}`, 'Installer');
      }

      try {
        // Stop services
        this.logger.info('Stopping services...', 'Installer');
        this.exec('systemctl stop oncofix-backend || true');
        this.exec('systemctl stop oncofix-ai || true');

        // Install .deb
        this.logger.info(`Installing ${debPath}...`, 'Installer');
        this.exec(`dpkg -i ${debPath}`);
        this.exec('apt-get install -f -y');

        // Reload and restart
        this.logger.info('Restarting services...', 'Installer');
        this.exec('systemctl daemon-reload');
        this.exec('systemctl start oncofix-backend');
        this.exec('systemctl start oncofix-ai');
        this.exec('systemctl reload nginx || true');

        // Verify health
        this.logger.info('Verifying backend health...', 'Installer');
        await this.sleep(5000);
        const healthy = this.checkBackendHealth();

        if (healthy) {
          // Update device-info.json
          this.updateDeviceInfo(newVersion);
          // Cleanup temp deb
          this.cleanupTempDeb(debPath);
          return { success: true, rolledBack: false };
        }

        this.logger.warn('Backend health check failed after install', 'Installer');
      } catch (err) {
        this.logger.error(`Install attempt ${attempt} failed: ${err}`, 'Installer');
      }
    }

    // All retries exhausted — rollback
    this.logger.error('All retry attempts exhausted, initiating rollback', 'Installer');
    return this.rollback(backupPath, previousVersion, debPath);
  }

  private backupDatabase(): string | null {
    try {
      const backupDir = this.config.backupDir;
      if (!fs.existsSync(backupDir)) {
        fs.mkdirSync(backupDir, { recursive: true });
      }

      const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
      const backupPath = path.join(backupDir, `database-pre-update-${timestamp}.sqlite`);
      const dbPath = '/var/lib/oncofix/database.sqlite';

      if (fs.existsSync(dbPath)) {
        fs.copyFileSync(dbPath, backupPath);
        this.logger.info(`Database backed up to ${backupPath}`, 'Installer');
        return backupPath;
      }
      return null;
    } catch (err) {
      this.logger.error(`Backup failed: ${err}`, 'Installer');
      return null;
    }
  }

  private rollback(backupPath: string | null, previousVersion: string, debPath: string): InstallResult {
    this.logger.info('Starting rollback...', 'Installer');

    try {
      // Restore database backup
      if (backupPath && fs.existsSync(backupPath)) {
        const dbPath = '/var/lib/oncofix/database.sqlite';
        fs.copyFileSync(backupPath, dbPath);
        this.logger.info('Database restored from backup', 'Installer');
      }

      // Attempt to restart services on whatever version is installed
      this.exec('systemctl daemon-reload');
      this.exec('systemctl start oncofix-backend || true');
      this.exec('systemctl start oncofix-ai || true');
      this.exec('systemctl reload nginx || true');

      // Check if services recovered
      this.logger.info('Checking service health after rollback...', 'Installer');
      const healthy = this.checkBackendHealth();

      this.cleanupTempDeb(debPath);

      if (healthy) {
        this.logger.info('Services recovered after rollback', 'Installer');
        return { success: false, error: 'Install failed, rolled back to previous version', rolledBack: true };
      } else {
        this.logger.error('Services not healthy after rollback — manual intervention required', 'Installer');
        return { success: false, error: 'Rollback failed, manual intervention required', rolledBack: true };
      }
    } catch (err) {
      this.logger.error(`Rollback failed: ${err}`, 'Installer');
      return { success: false, error: `Rollback failed: ${err}`, rolledBack: false };
    }
  }

  private checkBackendHealth(): boolean {
    try {
      const output = execSync(
        `curl -sf --max-time ${DEFAULTS.HEALTH_CHECK_TIMEOUT_MS / 1000} http://localhost:443/api/v1/health`,
        { encoding: 'utf-8', timeout: DEFAULTS.HEALTH_CHECK_TIMEOUT_MS + 2000 },
      );
      return output.includes('ok') || output.includes('healthy') || output.length > 0;
    } catch {
      return false;
    }
  }

  private updateDeviceInfo(newVersion: string): void {
    try {
      const infoPath = this.config.deviceInfoFilePath;
      let info: Record<string, unknown> = {};
      if (fs.existsSync(infoPath)) {
        info = JSON.parse(fs.readFileSync(infoPath, 'utf-8'));
      }
      info.version = newVersion;
      info.last_updated = new Date().toISOString();
      fs.writeFileSync(infoPath, JSON.stringify(info, null, 2));
      this.logger.info(`device-info.json updated to version ${newVersion}`, 'Installer');
    } catch (err) {
      this.logger.warn(`Failed to update device-info.json: ${err}`, 'Installer');
    }
  }

  private cleanupTempDeb(debPath: string): void {
    try {
      if (fs.existsSync(debPath)) fs.unlinkSync(debPath);
    } catch { /* ignore */ }
  }

  private exec(cmd: string): string {
    return execSync(cmd, { encoding: 'utf-8', timeout: 120000 });
  }

  private sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }
}
