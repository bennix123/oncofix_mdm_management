import { AgentConfig } from '../../config';
import { getCurrentVersion } from '../../config';
import { getDatabase } from '../../database';
import { getLogger } from '../../logger';
import { getHttpClient } from '../../utils/http-client';
import { getSystemHealth, getServicesStatus } from '../../utils/system-info';
import { DEFAULTS } from '../../config/constants';

export class HeartbeatService {
  private config: AgentConfig;
  private logger = getLogger();
  private timer: ReturnType<typeof setInterval> | null = null;

  constructor(config: AgentConfig) {
    this.config = config;
  }

  start(): void {
    this.logger.info('Heartbeat engine started', 'Heartbeat');
    // Send first heartbeat immediately
    this.tick();
    this.timer = setInterval(() => this.tick(), this.config.heartbeatIntervalMs);
  }

  stop(): void {
    if (this.timer) {
      clearInterval(this.timer);
      this.timer = null;
    }
    this.logger.info('Heartbeat engine stopped', 'Heartbeat');
  }

  private async tick(): Promise<void> {
    const payload = this.collectPayload();

    try {
      const client = getHttpClient();
      await client.post('/devices/heartbeat', payload);
      this.logger.debug('Heartbeat sent successfully', 'Heartbeat');

      // Flush any queued heartbeats
      await this.flushQueue();
    } catch {
      this.logger.warn('Server unreachable, queuing heartbeat locally', 'Heartbeat');
      this.queueHeartbeat(payload);
    }
  }

  private collectPayload(): Record<string, unknown> {
    const health = getSystemHealth();
    const services = getServicesStatus(DEFAULTS.SERVICES);
    const version = getCurrentVersion(this.config.versionFilePath);
    const unsyncedCount = this.getUnsyncedCount();

    return {
      device_id: this.config.deviceId,
      version,
      cpu_load: health.cpu_load,
      memory_usage: health.memory_usage,
      memory_total_mb: health.memory_total_mb,
      memory_used_mb: health.memory_used_mb,
      disk_usage: health.disk_usage,
      disk_total_gb: health.disk_total_gb,
      disk_used_gb: health.disk_used_gb,
      uptime_seconds: health.uptime_seconds,
      network_latency_ms: health.network_latency_ms,
      services: Object.fromEntries(services.map(s => [s.name, s.status])),
      unsynced_count: unsyncedCount,
      timestamp: new Date().toISOString(),
    };
  }

  private getUnsyncedCount(): number {
    try {
      // Query the medical app's SQLite database for unsynced records
      // This is a read-only check against the application database
      const appDbPath = '/var/lib/oncofix/database.sqlite';
      const fs = require('fs');
      if (!fs.existsSync(appDbPath)) return 0;

      const BetterSqlite3 = require('better-sqlite3');
      const appDb = new BetterSqlite3(appDbPath, { readonly: true });
      try {
        const result = appDb.prepare(
          "SELECT COUNT(*) as count FROM patients WHERE is_sync = 0 OR is_sync IS NULL"
        ).get() as { count: number };
        return result?.count || 0;
      } finally {
        appDb.close();
      }
    } catch {
      return 0;
    }
  }

  private queueHeartbeat(payload: Record<string, unknown>): void {
    const db = getDatabase();
    db.prepare('INSERT INTO heartbeat_queue (payload, status) VALUES (?, ?)').run(
      JSON.stringify(payload),
      'pending',
    );
  }

  private async flushQueue(): Promise<void> {
    const db = getDatabase();
    const pending = db.prepare(
      'SELECT id, payload FROM heartbeat_queue WHERE status = ? ORDER BY created_at ASC LIMIT 50'
    ).all('pending') as { id: number; payload: string }[];

    if (pending.length === 0) return;

    this.logger.info(`Flushing ${pending.length} queued heartbeats`, 'Heartbeat');
    const client = getHttpClient();

    for (const row of pending) {
      try {
        await client.post('/devices/heartbeat', JSON.parse(row.payload));
        db.prepare(`UPDATE heartbeat_queue SET status = ?, sent_at = datetime('now') WHERE id = ?`).run('sent', row.id);
      } catch {
        db.prepare('UPDATE heartbeat_queue SET status = ? WHERE id = ?').run('failed', row.id);
        break; // Stop flushing if server goes offline again
      }
    }

    // Cleanup sent heartbeats older than 24h
    db.prepare("DELETE FROM heartbeat_queue WHERE status = 'sent' AND sent_at < datetime('now', '-24 hours')").run();
  }
}
