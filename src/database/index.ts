import Database from 'better-sqlite3';
import * as fs from 'fs';
import * as path from 'path';
import { CREATE_TABLES_SQL } from './schema';
import { getLogger } from '../logger';

let db: Database.Database | null = null;

export function initDatabase(dbPath: string): Database.Database {
  const logger = getLogger();
  const dir = path.dirname(dbPath);
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }

  db = new Database(dbPath);
  db.pragma('journal_mode = WAL');
  db.pragma('foreign_keys = ON');

  db.exec(CREATE_TABLES_SQL);

  // Seed provisioning state if empty
  const row = db.prepare('SELECT COUNT(*) as count FROM provisioning_state').get() as { count: number };
  if (row.count === 0) {
    db.prepare('INSERT INTO provisioning_state (id, state) VALUES (1, ?)').run('manufactured');
  }

  logger.info(`SQLite database initialized at ${dbPath}`, 'Database');
  return db;
}

export function getDatabase(): Database.Database {
  if (!db) {
    throw new Error('Database not initialized. Call initDatabase() first.');
  }
  return db;
}

export function closeDatabase(): void {
  if (db) {
    db.close();
    db = null;
  }
}
