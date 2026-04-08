import { loadConfig, loadIdentity, getCurrentVersion } from './index';
import * as fs from 'fs';
import * as path from 'path';

jest.mock('fs');

const mockFs = fs as jest.Mocked<typeof fs>;

describe('Config', () => {
  beforeEach(() => {
    jest.resetAllMocks();
    delete process.env.MDM_SERVER_URL;
    delete process.env.DEVICE_ID;
    delete process.env.DEVICE_TOKEN;
  });

  describe('loadIdentity', () => {
    it('should return null if identity file does not exist', () => {
      mockFs.existsSync.mockReturnValue(false);
      expect(loadIdentity('/etc/oncofix/device-identity.json')).toBeNull();
    });

    it('should parse valid identity file', () => {
      const identity = {
        device_id: 'dev_test_123',
        device_token: 'token123',
        server_url: 'http://server.local',
        mac_address: 'aa:bb:cc:dd:ee:ff',
        cpu_serial: '0000000012345678',
        board_model: 'Raspberry Pi 5',
        hostname: 'rpi-test',
        provisioned_at: '2026-01-01T00:00:00Z',
      };
      mockFs.existsSync.mockReturnValue(true);
      mockFs.readFileSync.mockReturnValue(JSON.stringify(identity));
      expect(loadIdentity('/etc/oncofix/device-identity.json')).toEqual(identity);
    });

    it('should return null on invalid JSON', () => {
      mockFs.existsSync.mockReturnValue(true);
      mockFs.readFileSync.mockReturnValue('not json');
      expect(loadIdentity('/etc/oncofix/device-identity.json')).toBeNull();
    });
  });

  describe('getCurrentVersion', () => {
    it('should return 0.0.0 if version file does not exist', () => {
      mockFs.existsSync.mockReturnValue(false);
      expect(getCurrentVersion('/opt/oncofix/VERSION')).toBe('0.0.0');
    });

    it('should parse version from file content', () => {
      mockFs.existsSync.mockReturnValue(true);
      mockFs.readFileSync.mockReturnValue('version=1.2.3\nbuild_date=2026-01-01');
      expect(getCurrentVersion('/opt/oncofix/VERSION')).toBe('1.2.3');
    });
  });

  describe('loadConfig', () => {
    it('should load config with defaults when no identity file', () => {
      mockFs.existsSync.mockReturnValue(false);
      const config = loadConfig();
      expect(config.deviceId).toBe('unknown');
      expect(config.heartbeatIntervalMs).toBe(300000);
      expect(config.maxRetryAttempts).toBe(2);
    });

    it('should use env variables when set', () => {
      mockFs.existsSync.mockReturnValue(false);
      process.env.MDM_SERVER_URL = 'http://test-server:443';
      process.env.DEVICE_ID = 'dev_env_123';
      process.env.DEVICE_TOKEN = 'env_token';
      const config = loadConfig();
      expect(config.serverUrl).toBe('http://test-server:443');
      expect(config.deviceId).toBe('dev_env_123');
      expect(config.deviceToken).toBe('env_token');
    });
  });
});
