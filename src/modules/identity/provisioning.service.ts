import * as fs from 'fs';
import * as path from 'path';
import { AgentConfig, DeviceIdentity } from '../../config';
import { getDatabase } from '../../database';
import { getLogger } from '../../logger';
import { getHardwareFingerprint } from '../../utils/system-info';
import { isServerReachable } from '../../utils/http-client';
import axios from 'axios';
import { PROVISIONING_STATES, ProvisioningState } from '../../config/constants';

export class ProvisioningService {
  private config: AgentConfig;
  private logger = getLogger();

  constructor(config: AgentConfig) {
    this.config = config;
  }

  async ensureProvisioned(): Promise<void> {
    const state = this.getState();

    if (state === PROVISIONING_STATES.PROVISIONED) {
      this.logger.info('Device already provisioned, skipping', 'Provisioning');
      return;
    }

    // Check if identity file already exists (provisioned via bash script)
    if (fs.existsSync(this.config.identityFilePath)) {
      this.logger.info('Identity file found, marking as provisioned', 'Provisioning');
      this.setState(PROVISIONING_STATES.PROVISIONED);
      return;
    }

    this.logger.info('Device not provisioned, starting registration...', 'Provisioning');
    await this.register();
  }

  private async register(): Promise<void> {
    const fingerprint = getHardwareFingerprint();
    this.logger.info(`Hardware: MAC=${fingerprint.mac_address}, hostname=${fingerprint.hostname}`, 'Provisioning');

    // Wait for server to be reachable (max 10 retries, 30s apart)
    const maxRetries = 10;
    const retryDelayMs = 30000;

    for (let attempt = 1; attempt <= maxRetries; attempt++) {
      this.logger.info(`Checking server reachability (attempt ${attempt}/${maxRetries})...`, 'Provisioning');
      const reachable = await isServerReachable(this.config.serverUrl);

      if (reachable) {
        this.logger.info('Server reachable, registering device...', 'Provisioning');
        try {
          const response = await axios.post(`${this.config.serverUrl}/api/v1/devices/provision`, {
            mac_address: fingerprint.mac_address,
            cpu_serial: fingerprint.cpu_serial,
            board_model: fingerprint.board_model,
            hostname: fingerprint.hostname,
          }, { timeout: 30000 });

          const data = response.data;
          if (!data.device_id || !data.device_token) {
            this.logger.error('Invalid server response: missing device_id or device_token', 'Provisioning');
            this.setState(PROVISIONING_STATES.PROVISION_FAILED);
            return;
          }

          // Write identity file
          const identity: DeviceIdentity = {
            device_id: data.device_id,
            device_token: data.device_token,
            server_url: data.server_url || this.config.serverUrl,
            mac_address: fingerprint.mac_address,
            cpu_serial: fingerprint.cpu_serial,
            board_model: fingerprint.board_model,
            hostname: fingerprint.hostname,
            provisioned_at: new Date().toISOString(),
          };

          this.writeIdentityFile(identity);
          this.saveProvisioningData(identity);
          this.setState(PROVISIONING_STATES.PROVISIONED);
          this.logger.info(`Provisioned successfully as ${identity.device_id}`, 'Provisioning');
          return;
        } catch (err) {
          this.logger.error(`Registration failed: ${err}`, 'Provisioning');
          if (attempt === maxRetries) {
            this.setState(PROVISIONING_STATES.PROVISION_FAILED);
            return;
          }
        }
      }

      if (attempt < maxRetries) {
        this.logger.info(`Server unreachable, retrying in ${retryDelayMs / 1000}s...`, 'Provisioning');
        await this.sleep(retryDelayMs);
      }
    }

    this.logger.error('Max retries reached, provisioning failed', 'Provisioning');
    this.setState(PROVISIONING_STATES.PROVISION_FAILED);
  }

  getState(): ProvisioningState {
    const db = getDatabase();
    const row = db.prepare('SELECT state FROM provisioning_state WHERE id = 1').get() as { state: string } | undefined;
    return (row?.state as ProvisioningState) || PROVISIONING_STATES.MANUFACTURED;
  }

  private setState(state: ProvisioningState): void {
    const db = getDatabase();
    db.prepare(`UPDATE provisioning_state SET state = ?, last_updated = datetime('now') WHERE id = 1`).run(state);
  }

  private saveProvisioningData(identity: DeviceIdentity): void {
    const db = getDatabase();
    db.prepare(`
      UPDATE provisioning_state
      SET device_id = ?, device_token = ?, server_url = ?,
          hardware_fingerprint = ?, provisioned_at = ?, last_updated = datetime('now')
      WHERE id = 1
    `).run(
      identity.device_id,
      identity.device_token,
      identity.server_url,
      JSON.stringify({ mac: identity.mac_address, cpu: identity.cpu_serial, board: identity.board_model }),
      identity.provisioned_at,
    );
  }

  private writeIdentityFile(identity: DeviceIdentity): void {
    const dir = path.dirname(this.config.identityFilePath);
    if (!fs.existsSync(dir)) {
      fs.mkdirSync(dir, { recursive: true });
    }
    fs.writeFileSync(this.config.identityFilePath, JSON.stringify(identity, null, 2), { mode: 0o600 });
    this.logger.info(`Written identity file: ${this.config.identityFilePath}`, 'Provisioning');
  }

  private sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }
}
