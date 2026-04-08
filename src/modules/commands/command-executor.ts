import { execSync } from 'child_process';
import * as fs from 'fs';
import { getLogger } from '../../logger';
import { COMMAND_TYPES, CommandType } from '../../config/constants';
import { loadConfig } from '../../config';

export interface CommandResult {
  success: boolean;
  exit_code: number;
  output: string;
}

const ALLOWED_COMMANDS: Record<string, () => CommandResult> = {
  [COMMAND_TYPES.RESTART_BACKEND]: () => execCommand('systemctl restart oncofix-backend'),
  [COMMAND_TYPES.RESTART_AI]: () => execCommand('systemctl restart oncofix-ai'),
  [COMMAND_TYPES.RESTART_ALL]: () => execCommand(
    'systemctl restart oncofix-backend && systemctl restart oncofix-ai && systemctl reload nginx'
  ),
  [COMMAND_TYPES.REBOOT_DEVICE]: () => execCommand('sudo reboot'),
  [COMMAND_TYPES.FETCH_LOGS]: () => fetchLogs(),
  [COMMAND_TYPES.HEALTH_CHECK]: () => runHealthCheck(),
};

export function executeCommand(commandType: string, _payload?: string): CommandResult {
  const logger = getLogger();

  const handler = ALLOWED_COMMANDS[commandType];
  if (!handler) {
    logger.warn(`Rejected unknown command: ${commandType}`, 'CommandExecutor');
    return { success: false, exit_code: 1, output: `Unknown command: ${commandType}` };
  }

  logger.info(`Executing command: ${commandType}`, 'CommandExecutor');
  try {
    return handler();
  } catch (err) {
    logger.error(`Command ${commandType} failed: ${err}`, 'CommandExecutor');
    return { success: false, exit_code: 1, output: String(err) };
  }
}

function execCommand(cmd: string): CommandResult {
  try {
    const output = execSync(cmd, { encoding: 'utf-8', timeout: 60000 });
    return { success: true, exit_code: 0, output: output.trim() };
  } catch (err: any) {
    return {
      success: false,
      exit_code: err.status ?? 1,
      output: (err.stderr || err.stdout || String(err)).trim(),
    };
  }
}

function fetchLogs(): CommandResult {
  const logFiles = [
    '/var/log/oncofix/backend.log',
    '/var/log/oncofix/backend-error.log',
    '/var/log/oncofix/ai.log',
    '/var/log/oncofix/agent.log',
  ];

  const output: string[] = [];
  for (const logFile of logFiles) {
    try {
      if (!fs.existsSync(logFile)) continue;
      // Read last 100 lines
      const content = execSync(`tail -100 ${logFile}`, { encoding: 'utf-8', timeout: 5000 });
      output.push(`=== ${logFile} ===\n${content}`);
    } catch {
      output.push(`=== ${logFile} === (read error)`);
    }
  }

  return { success: true, exit_code: 0, output: output.join('\n\n') };
}

function runHealthCheck(): CommandResult {
  try {
    // Try the dedicated health-check script first
    if (fs.existsSync('/opt/oncofix/health-check.sh')) {
      return execCommand('bash /opt/oncofix/health-check.sh');
    }
    // Fallback: check backend health endpoint using configured server URL
    const config = loadConfig();
    const healthUrl = `${config.serverUrl}/api/v1/health`;
    return execCommand(`curl -sf ${healthUrl}`);
  } catch {
    return { success: false, exit_code: 1, output: 'Health check failed' };
  }
}
