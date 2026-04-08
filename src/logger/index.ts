import * as fs from 'fs';
import * as path from 'path';

export type LogLevel = 'debug' | 'info' | 'warn' | 'error';

const LOG_LEVELS: Record<LogLevel, number> = {
  debug: 0,
  info: 1,
  warn: 2,
  error: 3,
};

export class Logger {
  private logFilePath: string | null;
  private minLevel: LogLevel;

  constructor(logFilePath: string | null = null, minLevel: LogLevel = 'info') {
    this.logFilePath = logFilePath;
    this.minLevel = minLevel;

    if (this.logFilePath) {
      const dir = path.dirname(this.logFilePath);
      if (!fs.existsSync(dir)) {
        fs.mkdirSync(dir, { recursive: true });
      }
    }
  }

  debug(message: string, context?: string): void {
    this.log('debug', message, context);
  }

  info(message: string, context?: string): void {
    this.log('info', message, context);
  }

  warn(message: string, context?: string): void {
    this.log('warn', message, context);
  }

  error(message: string, context?: string): void {
    this.log('error', message, context);
  }

  private log(level: LogLevel, message: string, context?: string): void {
    if (LOG_LEVELS[level] < LOG_LEVELS[this.minLevel]) return;

    const timestamp = new Date().toISOString();
    const ctx = context ? `[${context}] ` : '';
    const line = `${timestamp} [${level.toUpperCase()}] ${ctx}${message}`;

    if (level === 'error') {
      process.stderr.write(line + '\n');
    } else {
      process.stdout.write(line + '\n');
    }

    if (this.logFilePath) {
      try {
        fs.appendFileSync(this.logFilePath, line + '\n');
      } catch {
        // Silently ignore file write errors
      }
    }
  }
}

let defaultLogger: Logger | null = null;

export function initLogger(logFilePath: string | null, minLevel: LogLevel = 'info'): Logger {
  defaultLogger = new Logger(logFilePath, minLevel);
  return defaultLogger;
}

export function getLogger(): Logger {
  if (!defaultLogger) {
    defaultLogger = new Logger(null, 'info');
  }
  return defaultLogger;
}
