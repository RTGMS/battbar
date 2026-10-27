'use strict';

const LOW_THRESHOLD = 20;
const CRITICAL_THRESHOLD = 10;
const RESET_THRESHOLD = 25;

class BatteryAlertManager {
  constructor() {
    this.states = new Map();
  }

  evaluate(devices, enabled) {
    const events = [];
    const activeIds = new Set();

    for (const device of Array.isArray(devices) ? devices : []) {
      if (!device?.id) continue;
      activeIds.add(device.id);
      if (device.stale) continue;

      if (!enabled) continue;
      if (typeof device.battery !== 'number' || !Number.isFinite(device.battery)) continue;
      if (device.charging === true || device.battery > RESET_THRESHOLD) {
        this.states.delete(device.id);
        continue;
      }

      let state = this.states.get(device.id);
      if (!state) {
        state = new Set();
        this.states.set(device.id, state);
      }

      if (device.battery <= CRITICAL_THRESHOLD) {
        if (!state.has(CRITICAL_THRESHOLD)) {
          state.add(CRITICAL_THRESHOLD);
          state.add(LOW_THRESHOLD);
          events.push({
            type: 'critical',
            device,
            level: CRITICAL_THRESHOLD,
            title: `鼠标电量仅剩 ${device.battery}%`,
            body: `${device.name} 快没电了，建议立即充电。`,
          });
        }
      } else if (device.battery <= LOW_THRESHOLD) {
        if (!state.has(LOW_THRESHOLD)) {
          state.add(LOW_THRESHOLD);
          events.push({
            type: 'low',
            device,
            level: LOW_THRESHOLD,
            title: `鼠标电量偏低（${device.battery}%）`,
            body: `${device.name} 建议尽快充电，避免使用中断。`,
          });
        }
      }
    }

    // Forget devices that are no longer present so a future reconnect can alert again.
    for (const id of this.states.keys()) {
      if (!activeIds.has(id)) this.states.delete(id);
    }

    if (!enabled) this.states.clear();
    return events;
  }

  reset() {
    this.states.clear();
  }
}

module.exports = { BatteryAlertManager, CRITICAL_THRESHOLD, LOW_THRESHOLD, RESET_THRESHOLD };
