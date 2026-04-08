import { executeCommand } from './command-executor';
import { execSync } from 'child_process';
import * as fs from 'fs';
import { initLogger } from '../../logger';

jest.mock('child_process');
jest.mock('fs');

const mockExecSync = execSync as jest.MockedFunction<typeof execSync>;
const mockFs = fs as jest.Mocked<typeof fs>;

describe('CommandExecutor', () => {
  beforeAll(() => {
    initLogger(null, 'error');
  });

  beforeEach(() => {
    jest.resetAllMocks();
  });

  it('should execute restart_backend command', () => {
    mockExecSync.mockReturnValue('');
    const result = executeCommand('restart_backend');
    expect(result.success).toBe(true);
    expect(result.exit_code).toBe(0);
    expect(mockExecSync).toHaveBeenCalledWith(
      'systemctl restart oncofix-backend',
      expect.any(Object),
    );
  });

  it('should execute restart_ai command', () => {
    mockExecSync.mockReturnValue('');
    const result = executeCommand('restart_ai');
    expect(result.success).toBe(true);
  });

  it('should execute restart_all command', () => {
    mockExecSync.mockReturnValue('');
    const result = executeCommand('restart_all');
    expect(result.success).toBe(true);
  });

  it('should execute reboot command', () => {
    mockExecSync.mockReturnValue('');
    const result = executeCommand('reboot');
    expect(result.success).toBe(true);
  });

  it('should reject unknown commands', () => {
    const result = executeCommand('rm -rf /');
    expect(result.success).toBe(false);
    expect(result.output).toContain('Unknown command');
  });

  it('should handle command execution failure', () => {
    const error: any = new Error('Command failed');
    error.status = 1;
    error.stderr = 'service not found';
    mockExecSync.mockImplementation(() => { throw error; });
    const result = executeCommand('restart_backend');
    expect(result.success).toBe(false);
    expect(result.exit_code).toBe(1);
  });

  it('should execute upload_logs and read log files', () => {
    mockFs.existsSync.mockReturnValue(true);
    mockExecSync.mockReturnValue('log content here');
    const result = executeCommand('upload_logs');
    expect(result.success).toBe(true);
    expect(result.output).toContain('log content here');
  });

  it('should execute run_healthcheck with health-check.sh', () => {
    mockFs.existsSync.mockReturnValue(true);
    mockExecSync.mockReturnValue('{"status":"ok"}');
    const result = executeCommand('run_healthcheck');
    expect(result.success).toBe(true);
  });
});
