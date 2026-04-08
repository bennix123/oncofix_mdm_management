import { UpdateDownloader } from './update-downloader';
import axios from 'axios';
import * as fs from 'fs';
import * as crypto from 'crypto';
import { initLogger } from '../../logger';
import { AgentConfig } from '../../config';

jest.mock('axios');
jest.mock('fs');

const mockAxios = axios as jest.Mocked<typeof axios>;
const mockFs = fs as jest.Mocked<typeof fs>;

const mockConfig: AgentConfig = {
  serverUrl: 'http://test-server',
  deviceId: 'dev_test',
  deviceToken: 'token',
  heartbeatIntervalMs: 300000,
  updateCheckIntervalMs: 3600000,
  commandPollIntervalMs: 300000,
  proceedPollIntervalMs: 10000,
  sqliteDbPath: '/tmp/test.sqlite',
  dataDir: '/var/lib/oncofix',
  logDir: '/var/log/oncofix',
  backupDir: '/var/lib/oncofix/backups',
  flagDir: '/var/lib/oncofix',
  identityFilePath: '/etc/oncofix/device-identity.json',
  deviceInfoFilePath: '/etc/oncofix/device-info.json',
  versionFilePath: '/opt/oncofix/VERSION',
  agentLogFilePath: '/var/log/oncofix/agent.log',
  maxRetryAttempts: 2,
};

describe('UpdateDownloader', () => {
  let downloader: UpdateDownloader;

  beforeAll(() => {
    initLogger(null, 'error');
  });

  beforeEach(() => {
    jest.resetAllMocks();
    downloader = new UpdateDownloader(mockConfig);
  });

  it('should download and verify checksum successfully', async () => {
    const content = Buffer.from('fake deb content');
    const expectedChecksum = crypto.createHash('sha256').update(content).digest('hex');

    mockAxios.get.mockResolvedValue({ data: content });
    mockFs.writeFileSync.mockImplementation(() => {});
    mockFs.statSync.mockReturnValue({ size: content.length } as any);
    mockFs.readFileSync.mockReturnValue(content);
    mockFs.existsSync.mockReturnValue(true);

    const result = await downloader.download('http://repo/test.deb', expectedChecksum);
    expect(result.success).toBe(true);
    expect(result.debPath).toBe('/tmp/oncofix-update.deb');
  });

  it('should fail on checksum mismatch', async () => {
    const content = Buffer.from('fake deb content');

    mockAxios.get.mockResolvedValue({ data: content });
    mockFs.writeFileSync.mockImplementation(() => {});
    mockFs.statSync.mockReturnValue({ size: content.length } as any);
    mockFs.readFileSync.mockReturnValue(content);
    mockFs.existsSync.mockReturnValue(true);
    mockFs.unlinkSync.mockImplementation(() => {});

    const result = await downloader.download('http://repo/test.deb', 'wrong-checksum');
    expect(result.success).toBe(false);
    expect(result.error).toContain('Checksum verification failed');
  });

  it('should handle download failure', async () => {
    mockAxios.get.mockRejectedValue(new Error('Network error'));
    mockFs.existsSync.mockReturnValue(false);

    const result = await downloader.download('http://repo/test.deb', 'abc');
    expect(result.success).toBe(false);
    expect(result.error).toContain('Download failed');
  });

  it('should skip checksum if none provided', async () => {
    const content = Buffer.from('fake deb');

    mockAxios.get.mockResolvedValue({ data: content });
    mockFs.writeFileSync.mockImplementation(() => {});
    mockFs.statSync.mockReturnValue({ size: content.length } as any);

    const result = await downloader.download('http://repo/test.deb', '');
    expect(result.success).toBe(true);
  });
});
