import * as fs from 'fs';
import * as path from 'path';
import * as crypto from 'crypto';
import axios from 'axios';
import { AgentConfig } from '../../config';
import { getLogger } from '../../logger';
import { DEFAULTS } from '../../config/constants';

export interface DownloadResult {
  success: boolean;
  debPath?: string;
  error?: string;
}

export class UpdateDownloader {
  private config: AgentConfig;
  private logger = getLogger();

  constructor(config: AgentConfig) {
    this.config = config;
  }

  async download(debUrl: string, expectedChecksum: string): Promise<DownloadResult> {
    const debPath = '/tmp/oncofix-update.deb';

    try {
      // Download the .deb file
      this.logger.info(`Downloading from ${debUrl}`, 'Downloader');
      const response = await axios.get(debUrl, {
        responseType: 'arraybuffer',
        timeout: DEFAULTS.DOWNLOAD_TIMEOUT_MS,
        onDownloadProgress: (progress) => {
          if (progress.total) {
            const pct = Math.round((progress.loaded / progress.total) * 100);
            if (pct % 25 === 0) {
              this.logger.info(`Download progress: ${pct}%`, 'Downloader');
            }
          }
        },
      });

      fs.writeFileSync(debPath, response.data);
      const fileSize = fs.statSync(debPath).size;
      this.logger.info(`Downloaded ${(fileSize / 1048576).toFixed(1)}MB to ${debPath}`, 'Downloader');

      // Verify checksum
      if (expectedChecksum) {
        const verified = this.verifyChecksum(debPath, expectedChecksum);
        if (!verified) {
          fs.unlinkSync(debPath);
          return { success: false, error: 'Checksum verification failed' };
        }
        this.logger.info('Checksum verified successfully', 'Downloader');
      } else {
        this.logger.warn('No checksum provided, skipping verification', 'Downloader');
      }

      return { success: true, debPath };
    } catch (err) {
      // Clean up partial download
      try { if (fs.existsSync(debPath)) fs.unlinkSync(debPath); } catch { /* ignore */ }
      return { success: false, error: `Download failed: ${err}` };
    }
  }

  private verifyChecksum(filePath: string, expected: string): boolean {
    // Support "sha256:<hash>" or plain hash format
    const cleanExpected = expected.replace(/^sha256:/, '').toLowerCase();

    const fileBuffer = fs.readFileSync(filePath);
    const actual = crypto.createHash('sha256').update(fileBuffer).digest('hex').toLowerCase();

    this.logger.debug(`Checksum expected: ${cleanExpected}`, 'Downloader');
    this.logger.debug(`Checksum actual:   ${actual}`, 'Downloader');

    return actual === cleanExpected;
  }
}
