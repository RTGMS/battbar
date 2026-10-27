'use strict';

const atk = require('./atk-hid');
const macosBluetooth = require('./macos-bluetooth');
const windowsBluetooth = require('./windows-bluetooth');

const PROVIDER_WEIGHT = {
  atk: 0,
  'macos-bt': 1,
  'windows-bt': 1,
};

function compareDevices(a, b) {
  const weightA = PROVIDER_WEIGHT[a.provider] ?? 9;
  const weightB = PROVIDER_WEIGHT[b.provider] ?? 9;
  if (weightA !== weightB) return weightA - weightB;
  if (a.connection !== b.connection) return a.connection === '2.4g' ? -1 : 1;
  return String(a.name).localeCompare(String(b.name), 'zh-CN');
}

async function scanAll() {
  const providers = [atk.scan()];
  if (process.platform === 'darwin') providers.push(macosBluetooth.scan());
  if (process.platform === 'win32') providers.push(windowsBluetooth.scan());

  const results = await Promise.allSettled(providers);
  const devices = [];
  const errors = [];

  for (const result of results) {
    if (result.status === 'fulfilled') {
      const value = result.value || {};
      if (Array.isArray(value.devices)) devices.push(...value.devices);
      if (Array.isArray(value.errors)) errors.push(...value.errors);
    } else {
      errors.push({
        code: 'PROVIDER_CRASHED',
        message: '一个电量读取模块意外停止运行。',
        detail: result.reason?.message || String(result.reason),
      });
    }
  }

  const unique = new Map();
  for (const device of devices) {
    if (!device?.id) continue;
    if (!unique.has(device.id)) unique.set(device.id, device);
  }

  return {
    devices: [...unique.values()].sort(compareDevices),
    errors,
  };
}

module.exports = {
  compareDevices,
  scanAll,
};
