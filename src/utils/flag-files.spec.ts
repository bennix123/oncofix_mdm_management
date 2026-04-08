import * as fs from 'fs';
import {
  writeJsonFile,
  readJsonFile,
  removeFile,
  writeUpdateReady,
  readUpdateReady,
  writeUpdateProceed,
  readUpdateProceed,
  cleanupFlagFiles,
} from './flag-files';
import { initLogger } from '../logger';

jest.mock('fs');
const mockFs = fs as jest.Mocked<typeof fs>;

describe('FlagFiles', () => {
  beforeAll(() => {
    initLogger(null, 'error');
  });

  beforeEach(() => {
    jest.resetAllMocks();
  });

  describe('writeJsonFile', () => {
    it('should write JSON to file', () => {
      mockFs.writeFileSync.mockImplementation(() => {});
      writeJsonFile('/tmp/test.json', { key: 'value' });
      expect(mockFs.writeFileSync).toHaveBeenCalledWith(
        '/tmp/test.json',
        JSON.stringify({ key: 'value' }, null, 2),
        'utf-8',
      );
    });
  });

  describe('readJsonFile', () => {
    it('should return null if file does not exist', () => {
      mockFs.existsSync.mockReturnValue(false);
      expect(readJsonFile('/tmp/nope.json')).toBeNull();
    });

    it('should parse valid JSON file', () => {
      mockFs.existsSync.mockReturnValue(true);
      mockFs.readFileSync.mockReturnValue('{"version":"1.0.0"}');
      expect(readJsonFile('/tmp/test.json')).toEqual({ version: '1.0.0' });
    });

    it('should return null on invalid JSON', () => {
      mockFs.existsSync.mockReturnValue(true);
      mockFs.readFileSync.mockReturnValue('not json');
      expect(readJsonFile('/tmp/bad.json')).toBeNull();
    });
  });

  describe('removeFile', () => {
    it('should remove existing file', () => {
      mockFs.existsSync.mockReturnValue(true);
      mockFs.unlinkSync.mockImplementation(() => {});
      removeFile('/tmp/del.json');
      expect(mockFs.unlinkSync).toHaveBeenCalledWith('/tmp/del.json');
    });

    it('should not throw if file does not exist', () => {
      mockFs.existsSync.mockReturnValue(false);
      expect(() => removeFile('/tmp/nope.json')).not.toThrow();
    });
  });

  describe('writeUpdateReady / readUpdateReady', () => {
    it('should write and read update-ready flag', () => {
      const data = {
        version: '1.2.0',
        deb_path: '/tmp/update.deb',
        checksum: 'sha256:abc123',
        downloaded_at: '2026-01-01T00:00:00Z',
      };
      mockFs.writeFileSync.mockImplementation(() => {});
      writeUpdateReady('/var/lib/oncofix', data);
      expect(mockFs.writeFileSync).toHaveBeenCalledWith(
        '/var/lib/oncofix/update-ready.json',
        expect.any(String),
        'utf-8',
      );
    });
  });

  describe('writeUpdateProceed / readUpdateProceed', () => {
    it('should write proceed flag', () => {
      mockFs.writeFileSync.mockImplementation(() => {});
      writeUpdateProceed('/var/lib/oncofix', {
        confirmed: true,
        confirmed_at: '2026-01-01T00:00:00Z',
      });
      expect(mockFs.writeFileSync).toHaveBeenCalled();
    });
  });

  describe('cleanupFlagFiles', () => {
    it('should remove both flag files', () => {
      mockFs.existsSync.mockReturnValue(true);
      mockFs.unlinkSync.mockImplementation(() => {});
      cleanupFlagFiles('/var/lib/oncofix');
      expect(mockFs.unlinkSync).toHaveBeenCalledTimes(2);
    });
  });
});
