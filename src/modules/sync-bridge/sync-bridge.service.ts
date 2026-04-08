import * as fs from 'fs';
import { AgentConfig } from '../../config';
import { getDatabase } from '../../database';
import { getLogger } from '../../logger';
import axios from 'axios';

export class SyncBridgeService {
  private config: AgentConfig;
  private logger = getLogger();
  private timer: ReturnType<typeof setInterval> | null = null;
  private lastOnlineState: boolean | null = null;

  constructor(config: AgentConfig) {
    this.config = config;
  }

  start(): void {
    this.logger.info('Sync bridge started', 'SyncBridge');
    this.timer = setInterval(() => this.checkConnectivity(), 30000);
  }

  stop(): void {
    if (this.timer) {
      clearInterval(this.timer);
      this.timer = null;
    }
    this.logger.info('Sync bridge stopped', 'SyncBridge');
  }

  private async checkConnectivity(): Promise<void> {
    const online = await this.isOnline();
    const db = getDatabase();

    // Log connectivity state
    db.prepare('INSERT INTO connectivity_log (online) VALUES (?)').run(online ? 1 : 0);

    // Detect offline->online transition
    if (online && this.lastOnlineState === false) {
      this.logger.info('Internet connectivity restored, notifying backend to trigger sync', 'SyncBridge');
      await this.triggerSync();
    }

    if (!online && this.lastOnlineState !== false) {
      this.logger.info('Internet connectivity lost', 'SyncBridge');
    }

    this.lastOnlineState = online;

    // Cleanup old connectivity logs (keep last 24h)
    db.prepare("DELETE FROM connectivity_log WHERE checked_at < datetime('now', '-24 hours')").run();
  }

  private async isOnline(): Promise<boolean> {
    // Check 1: HTTP ping to Google
    try {
      await axios.get('https://www.google.com/generate_204', { timeout: 5000 });
      return true;
    } catch { /* fall through */ }

    // Check 2: DNS resolution fallback
    try {
      const dns = require('dns');
      return new Promise<boolean>((resolve) => {
        dns.resolve('google.com', (err: Error | null) => {
          resolve(!err);
        });
      });
    } catch {
      return false;
    }
  }

  private async triggerSync(): Promise<void> {
    try {
      // Notify the local backend to trigger a sync cycle
      await axios.post('http://localhost:443/api/v1/bigquery-sync/trigger', {}, { timeout: 5000 });
      this.logger.info('Sync trigger sent to backend', 'SyncBridge');
    } catch {
      this.logger.debug('Sync trigger failed (backend may handle it via its own interval)', 'SyncBridge');
    }
  }

  getUnsyncedCount(): number {
    try {
      const appDbPath = '/var/lib/oncofix/database.sqlite';
      if (!fs.existsSync(appDbPath)) return 0;

      const BetterSqlite3 = require('better-sqlite3');
      const appDb = new BetterSqlite3(appDbPath, { readonly: true });
      try {
        const tables = ['patients', 'patients_assessments', 'patients_assessments_oral_photos'];
        let total = 0;
        for (const table of tables) {
          try {
            const row = appDb.prepare(
              `SELECT COUNT(*) as count FROM ${table} WHERE is_sync = 0 OR is_sync IS NULL`
            ).get() as { count: number };
            total += row?.count || 0;
          } catch { /* table may not exist */ }
        }
        return total;
      } finally {
        appDb.close();
      }
    } catch {
      return 0;
    }
  }
}
