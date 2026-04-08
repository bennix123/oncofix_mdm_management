import { execSync } from 'child_process';
import * as os from 'os';
import * as fs from 'fs';

export interface SystemHealth {
  cpu_load: number;
  memory_usage: number;
  memory_total_mb: number;
  memory_used_mb: number;
  disk_usage: number;
  disk_total_gb: number;
  disk_used_gb: number;
  uptime_seconds: number;
  network_latency_ms: number | null;
}

export interface ServiceStatus {
  name: string;
  active: boolean;
  status: string;
}

export function getSystemHealth(): SystemHealth {
  const cpus = os.cpus();
  const cpuLoad = cpus.length > 0
    ? cpus.reduce((sum, cpu) => {
        const total = Object.values(cpu.times).reduce((a, b) => a + b, 0);
        const idle = cpu.times.idle;
        return sum + ((total - idle) / total) * 100;
      }, 0) / cpus.length
    : 0;

  const totalMem = os.totalmem();
  const freeMem = os.freemem();
  const usedMem = totalMem - freeMem;

  const disk = getDiskUsage();

  return {
    cpu_load: Math.round(cpuLoad * 100) / 100,
    memory_usage: Math.round((usedMem / totalMem) * 10000) / 100,
    memory_total_mb: Math.round(totalMem / 1048576),
    memory_used_mb: Math.round(usedMem / 1048576),
    disk_usage: disk.usagePercent,
    disk_total_gb: disk.totalGb,
    disk_used_gb: disk.usedGb,
    uptime_seconds: os.uptime(),
    network_latency_ms: measureNetworkLatency(),
  };
}

export function getServiceStatus(serviceName: string): ServiceStatus {
  try {
    const result = execSync(`systemctl is-active ${serviceName} 2>/dev/null`, {
      encoding: 'utf-8',
      timeout: 5000,
    }).trim();
    return { name: serviceName, active: result === 'active', status: result };
  } catch {
    return { name: serviceName, active: false, status: 'inactive' };
  }
}

export function getServicesStatus(serviceNames: readonly string[]): ServiceStatus[] {
  return serviceNames.map(getServiceStatus);
}

export function getHardwareFingerprint(): { mac_address: string; cpu_serial: string; board_model: string; hostname: string } {
  return {
    mac_address: getMacAddress(),
    cpu_serial: getCpuSerial(),
    board_model: getBoardModel(),
    hostname: os.hostname(),
  };
}

function getMacAddress(): string {
  const interfaces = os.networkInterfaces();
  for (const name of Object.keys(interfaces)) {
    const iface = interfaces[name];
    if (!iface) continue;
    for (const entry of iface) {
      if (!entry.internal && entry.mac && entry.mac !== '00:00:00:00:00:00') {
        return entry.mac;
      }
    }
  }
  return 'unknown';
}

function getCpuSerial(): string {
  try {
    const content = fs.readFileSync('/proc/cpuinfo', 'utf-8');
    const match = content.match(/Serial\s*:\s*(\S+)/);
    return match ? match[1] : 'unknown';
  } catch {
    return 'unknown';
  }
}

function getBoardModel(): string {
  try {
    return fs.readFileSync('/proc/device-tree/model', 'utf-8').replace(/\0/g, '').trim();
  } catch {
    return os.platform() + ' ' + os.arch();
  }
}

function getDiskUsage(): { usagePercent: number; totalGb: number; usedGb: number } {
  try {
    const output = execSync("df -B1 / | tail -1 | awk '{print $2,$3,$5}'", {
      encoding: 'utf-8',
      timeout: 5000,
    }).trim();
    const [total, used, percentStr] = output.split(/\s+/);
    return {
      totalGb: Math.round(parseInt(total) / 1073741824 * 100) / 100,
      usedGb: Math.round(parseInt(used) / 1073741824 * 100) / 100,
      usagePercent: parseInt(percentStr) || 0,
    };
  } catch {
    return { usagePercent: 0, totalGb: 0, usedGb: 0 };
  }
}

function measureNetworkLatency(): number | null {
  try {
    const start = Date.now();
    execSync('ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1', { timeout: 5000 });
    return Date.now() - start;
  } catch {
    return null;
  }
}
