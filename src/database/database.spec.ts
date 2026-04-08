import { initDatabase, getDatabase, closeDatabase } from './index';
import * as path from 'path';
import * as fs from 'fs';
import * as os from 'os';
import { initLogger } from '../logger';

describe('Database', () => {
  const testDbPath = path.join(os.tmpdir(), `mdm-test-${Date.now()}.sqlite`);

  beforeAll(() => {
    initLogger(null, 'error');
  });

  afterAll(() => {
    closeDatabase();
    try { fs.unlinkSync(testDbPath); } catch { /* ignore */ }
  });

  it('should initialize database and create tables', () => {
    const db = initDatabase(testDbPath);
    expect(db).toBeDefined();

    // Verify tables exist
    const tables = db.prepare(
      "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
    ).all() as { name: string }[];
    const tableNames = tables.map(t => t.name);
    expect(tableNames).toContain('heartbeat_queue');
    expect(tableNames).toContain('command_log');
    expect(tableNames).toContain('provisioning_state');
    expect(tableNames).toContain('update_state');
    expect(tableNames).toContain('connectivity_log');
  });

  it('should seed provisioning state with manufactured', () => {
    const db = getDatabase();
    const row = db.prepare('SELECT state FROM provisioning_state WHERE id = 1').get() as { state: string };
    expect(row.state).toBe('manufactured');
  });

  it('should support heartbeat queue insert and query', () => {
    const db = getDatabase();
    db.prepare('INSERT INTO heartbeat_queue (payload, status) VALUES (?, ?)').run(
      '{"test": true}', 'pending'
    );
    const row = db.prepare('SELECT * FROM heartbeat_queue WHERE status = ?').get('pending') as any;
    expect(row).toBeDefined();
    expect(JSON.parse(row.payload)).toEqual({ test: true });
  });

  it('should support command log insert', () => {
    const db = getDatabase();
    db.prepare(
      'INSERT INTO command_log (command_id, command_type, status) VALUES (?, ?, ?)'
    ).run('cmd_1', 'restart_backend', 'received');
    const row = db.prepare('SELECT * FROM command_log WHERE command_id = ?').get('cmd_1') as any;
    expect(row.command_type).toBe('restart_backend');
  });

  it('should throw if getDatabase called before init', () => {
    closeDatabase();
    expect(() => getDatabase()).toThrow('Database not initialized');
    // Re-init for other tests
    initDatabase(testDbPath);
  });
});
