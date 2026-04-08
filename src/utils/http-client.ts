import axios, { AxiosInstance, AxiosRequestConfig, AxiosResponse } from 'axios';
import { getLogger } from '../logger';

let client: AxiosInstance | null = null;

export interface HttpClientConfig {
  baseUrl: string;
  deviceToken: string;
  deviceId: string;
  timeoutMs?: number;
}

export function initHttpClient(config: HttpClientConfig): AxiosInstance {
  client = axios.create({
    baseURL: config.baseUrl,
    timeout: config.timeoutMs || 30000,
    headers: {
      'Content-Type': 'application/json',
      'X-Device-Id': config.deviceId,
      ...(config.deviceToken ? { Authorization: `Bearer ${config.deviceToken}` } : {}),
    },
  });

  client.interceptors.response.use(
    (response) => response,
    (error) => {
      const logger = getLogger();
      const url = error.config?.url || 'unknown';
      const status = error.response?.status || 'no response';
      logger.warn(`HTTP ${error.config?.method?.toUpperCase()} ${url} failed: ${status}`, 'HttpClient');
      return Promise.reject(error);
    },
  );

  return client;
}

export function getHttpClient(): AxiosInstance {
  if (!client) {
    throw new Error('HTTP client not initialized. Call initHttpClient() first.');
  }
  return client;
}

export async function isServerReachable(baseUrl: string, timeoutMs: number = 5000): Promise<boolean> {
  try {
    await axios.get(`${baseUrl}/api/v1/health`, { timeout: timeoutMs });
    return true;
  } catch {
    return false;
  }
}
