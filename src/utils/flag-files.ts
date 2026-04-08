import * as fs from 'fs';
import { getLogger } from '../logger';

export interface UpdateReadyFlag {
  version: string;
  deb_path: string;
  checksum: string;
  downloaded_at: string;
}

export interface UpdateProceedFlag {
  confirmed: boolean;
  confirmed_at: string;
}

export function writeJsonFile<T>(filePath: string, data: T): void {
  const logger = getLogger();
  try {
    fs.writeFileSync(filePath, JSON.stringify(data, null, 2), 'utf-8');
    logger.info(`Wrote flag file: ${filePath}`, 'FlagFiles');
  } catch (err) {
    logger.error(`Failed to write ${filePath}: ${err}`, 'FlagFiles');
    throw err;
  }
}

export function readJsonFile<T>(filePath: string): T | null {
  try {
    if (!fs.existsSync(filePath)) return null;
    const raw = fs.readFileSync(filePath, 'utf-8');
    return JSON.parse(raw) as T;
  } catch {
    return null;
  }
}

export function removeFile(filePath: string): void {
  try {
    if (fs.existsSync(filePath)) {
      fs.unlinkSync(filePath);
      getLogger().info(`Removed flag file: ${filePath}`, 'FlagFiles');
    }
  } catch {
    // Ignore removal errors
  }
}

export function writeUpdateReady(flagDir: string, data: UpdateReadyFlag): void {
  writeJsonFile(`${flagDir}/update-ready.json`, data);
}

export function readUpdateReady(flagDir: string): UpdateReadyFlag | null {
  return readJsonFile<UpdateReadyFlag>(`${flagDir}/update-ready.json`);
}

export function writeUpdateProceed(flagDir: string, data: UpdateProceedFlag): void {
  writeJsonFile(`${flagDir}/update-proceed.json`, data);
}

export function readUpdateProceed(flagDir: string): UpdateProceedFlag | null {
  return readJsonFile<UpdateProceedFlag>(`${flagDir}/update-proceed.json`);
}

export function cleanupFlagFiles(flagDir: string): void {
  removeFile(`${flagDir}/update-ready.json`);
  removeFile(`${flagDir}/update-proceed.json`);
}
