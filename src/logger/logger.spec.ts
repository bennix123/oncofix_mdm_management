import { Logger, initLogger, getLogger } from './index';
import * as fs from 'fs';

jest.mock('fs');
const mockFs = fs as jest.Mocked<typeof fs>;

describe('Logger', () => {
  beforeEach(() => {
    jest.resetAllMocks();
    mockFs.existsSync.mockReturnValue(true);
  });

  it('should create logger without file path', () => {
    const logger = new Logger(null, 'info');
    expect(logger).toBeDefined();
  });

  it('should write to stdout for info messages', () => {
    const spy = jest.spyOn(process.stdout, 'write').mockImplementation(() => true);
    const logger = new Logger(null, 'info');
    logger.info('test message', 'TestCtx');
    expect(spy).toHaveBeenCalledWith(expect.stringContaining('[INFO] [TestCtx] test message'));
    spy.mockRestore();
  });

  it('should write to stderr for error messages', () => {
    const spy = jest.spyOn(process.stderr, 'write').mockImplementation(() => true);
    const logger = new Logger(null, 'info');
    logger.error('error message');
    expect(spy).toHaveBeenCalledWith(expect.stringContaining('[ERROR] error message'));
    spy.mockRestore();
  });

  it('should filter messages below min level', () => {
    const spy = jest.spyOn(process.stdout, 'write').mockImplementation(() => true);
    const logger = new Logger(null, 'warn');
    logger.debug('debug msg');
    logger.info('info msg');
    expect(spy).not.toHaveBeenCalled();
    spy.mockRestore();
  });

  it('should write to file when path provided', () => {
    mockFs.existsSync.mockReturnValue(true);
    mockFs.appendFileSync.mockImplementation(() => {});
    const spy = jest.spyOn(process.stdout, 'write').mockImplementation(() => true);
    const logger = new Logger('/tmp/test.log', 'info');
    logger.info('test');
    expect(mockFs.appendFileSync).toHaveBeenCalled();
    spy.mockRestore();
  });

  it('initLogger and getLogger should work together', () => {
    initLogger(null, 'info');
    const logger = getLogger();
    expect(logger).toBeInstanceOf(Logger);
  });
});
