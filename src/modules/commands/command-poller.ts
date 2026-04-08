import { AgentConfig } from '../../config';
import { getDatabase } from '../../database';
import { getLogger } from '../../logger';
import { getHttpClient } from '../../utils/http-client';
import { executeCommand, CommandResult } from './command-executor';

interface PendingCommand {
  command_id: string;
  command_type: string;
  payload?: string;
}

export class CommandPoller {
  private config: AgentConfig;
  private logger = getLogger();
  private timer: ReturnType<typeof setInterval> | null = null;

  constructor(config: AgentConfig) {
    this.config = config;
  }

  start(): void {
    this.logger.info('Command poller started', 'Commands');
    this.timer = setInterval(() => this.poll(), this.config.commandPollIntervalMs);
  }

  stop(): void {
    if (this.timer) {
      clearInterval(this.timer);
      this.timer = null;
    }
    this.logger.info('Command poller stopped', 'Commands');
  }

  private async poll(): Promise<void> {
    try {
      const client = getHttpClient();
      const response = await client.get('/devices/commands');
      const commands: PendingCommand[] = response.data?.commands || response.data || [];

      if (!Array.isArray(commands) || commands.length === 0) return;

      this.logger.info(`Received ${commands.length} pending command(s)`, 'Commands');

      for (const cmd of commands) {
        await this.processCommand(cmd);
      }
    } catch {
      // Server unreachable — skip this cycle, heartbeat handles offline logging
    }
  }

  private async processCommand(cmd: PendingCommand): Promise<void> {
    const db = getDatabase();

    // Log command received
    db.prepare(`
      INSERT INTO command_log (command_id, command_type, payload, status)
      VALUES (?, ?, ?, 'executing')
    `).run(cmd.command_id, cmd.command_type, cmd.payload || null);

    // Execute
    const result: CommandResult = executeCommand(cmd.command_type, cmd.payload);

    // Update local log
    db.prepare(`
      UPDATE command_log
      SET status = ?, exit_code = ?, output = ?, executed_at = datetime('now')
      WHERE command_id = ?
    `).run(
      result.success ? 'completed' : 'failed',
      result.exit_code,
      result.output.substring(0, 10000), // Truncate large outputs
      cmd.command_id,
    );

    // Report result to server
    await this.reportResult(cmd.command_id, result);
  }

  private async reportResult(commandId: string, result: CommandResult): Promise<void> {
    try {
      const client = getHttpClient();
      await client.post('/devices/command-result', {
        command_id: commandId,
        device_id: this.config.deviceId,
        status: result.success ? 'completed' : 'failed',
        exit_code: result.exit_code,
        output: result.output.substring(0, 10000),
      });

      const db = getDatabase();
      db.prepare(`UPDATE command_log SET reported_at = datetime('now') WHERE command_id = ?`).run(commandId);
    } catch {
      this.logger.warn(`Failed to report result for command ${commandId}`, 'Commands');
    }
  }
}
