'use strict';

const { execFile } = require('node:child_process');
const { promisify } = require('node:util');

const execFileAsync = promisify(execFile);

const MOUSE_NAME_PATTERN =
  /mouse|mice|鼠标|atk|vxe|mad\s*r|logitech|罗技|razer|雷蛇|pulsar|lamzu|ninja|glorious|zowie|benq|steelseries|赛睿|roccat|corsair|海盗船|hyperx|pwnage|finalmouse|endgame|wl\s*mouse|hitscan|arbiter|scyrox|incott|waizowl|darmoshark|ajazz|mchose|attack\s*shark|g\s*pro|mx\s*(master|anywhere)|deathadder|viper|basilisk|aerox|rival/i;

function parseBatteryValue(value) {
  if (typeof value === 'number' && Number.isFinite(value)) {
    return Math.max(0, Math.min(100, Math.round(value)));
  }
  if (typeof value !== 'string') return null;
  const match = value.match(/(\d{1,3})\s*%?/);
  if (!match) return null;
  const number = Number(match[1]);
  if (!Number.isFinite(number) || number < 0 || number > 100) return null;
  return number;
}

function parseBoolean(value) {
  if (typeof value === 'boolean') return value;
  if (typeof value === 'number') return value !== 0;
  if (typeof value === 'string') {
    const normalized = value.trim().toLowerCase();
    if (['yes', 'true', '1', 'charging', 'on'].includes(normalized)) return true;
    if (['no', 'false', '0', 'discharging', 'off'].includes(normalized)) return false;
  }
  return null;
}

function findBattery(attributes) {
  const preferred = [
    'device_batteryLevelMain',
    'device_batteryLevel',
    'device_batteryPercent',
    'device_batteryLevelCombined',
  ];
  for (const key of preferred) {
    if (Object.prototype.hasOwnProperty.call(attributes, key)) {
      const parsed = parseBatteryValue(attributes[key]);
      if (parsed !== null) return parsed;
    }
  }

  for (const key of Object.keys(attributes)) {
    if (!/^device_battery/i.test(key)) continue;
    if (/(case|left|right|secondary)/i.test(key)) continue;
    const parsed = parseBatteryValue(attributes[key]);
    if (parsed !== null) return parsed;
  }
  return null;
}

function findCharging(attributes) {
  for (const key of [
    'device_charging',
    'device_batteryCharging',
    'device_batteryIsCharging',
    'charging',
  ]) {
    if (Object.prototype.hasOwnProperty.call(attributes, key)) {
      const parsed = parseBoolean(attributes[key]);
      if (parsed !== null) return parsed;
    }
  }
  return null;
}

function isLikelyMouse(name, attributes) {
  const minorType = String(
    attributes.device_minorType || attributes.device_minor_type || attributes.device_type || '',
  );
  if (/mouse|pointing/i.test(minorType)) return true;
  return MOUSE_NAME_PATTERN.test(`${name} ${minorType}`);
}

function normalizeConnectedGroups(value) {
  if (!value) return [];
  if (Array.isArray(value)) {
    return value.filter((entry) => entry && typeof entry === 'object');
  }
  if (typeof value === 'object') return [value];
  return [];
}

function parseSystemProfilerPayload(payload) {
  const roots = Array.isArray(payload?.SPBluetoothDataType)
    ? payload.SPBluetoothDataType
    : payload?.SPBluetoothDataType
      ? [payload.SPBluetoothDataType]
      : [];

  const seen = new Set();
  const devices = [];

  for (const root of roots) {
    if (!root || typeof root !== 'object') continue;
    for (const group of normalizeConnectedGroups(root.device_connected)) {
      for (const [entryName, rawAttributes] of Object.entries(group)) {
        if (!rawAttributes || typeof rawAttributes !== 'object') continue;
        const attributes = rawAttributes;
        const name = String(attributes.device_name || entryName || '').trim();
        if (!name) continue;

        const battery = findBattery(attributes);
        if (battery === null) continue;
        if (!isLikelyMouse(name, attributes)) continue;

        const address = String(attributes.device_address || '').trim();
        const dedupeKey = address ? address.toLowerCase() : name.toLowerCase();
        if (seen.has(dedupeKey)) continue;
        seen.add(dedupeKey);

        const minorType = String(attributes.device_minorType || '').trim();
        const detailParts = [];
        if (minorType) detailParts.push(minorType);
        if (address) detailParts.push(address);

        devices.push({
          id: address
            ? `bt-macos:${address.toLowerCase()}`
            : `bt-macos:${encodeURIComponent(name.toLowerCase())}`,
          provider: 'macos-bt',
          kind: 'mouse',
          name,
          subtitle: detailParts.join(' · ') || '系统蓝牙设备',
          connection: 'bluetooth',
          connectionLabel: '蓝牙',
          battery,
          charging: findCharging(attributes),
          voltage: null,
          address: address || null,
          source: 'macOS 蓝牙',
          transport: 'builtin-bluetooth',
          hardware: {
            minorType: minorType || null,
            vendorId: attributes.device_vendorID || null,
            productId: attributes.device_productID || null,
          },
        });
      }
    }
  }

  return devices;
}

async function scan() {
  if (process.platform !== 'darwin') return { devices: [], errors: [] };

  try {
    const { stdout } = await execFileAsync(
      '/usr/sbin/system_profiler',
      ['SPBluetoothDataType', '-json', '-detailLevel', 'full'],
      { timeout: 12000, maxBuffer: 8 * 1024 * 1024 },
    );
    const trimmed = stdout.trim();
    if (!trimmed) return { devices: [], errors: [] };

    let payload;
    try {
      payload = JSON.parse(trimmed);
    } catch (error) {
      throw new Error(`系统蓝牙信息不是有效 JSON：${error.message}`);
    }

    return { devices: parseSystemProfilerPayload(payload), errors: [] };
  } catch (error) {
    return {
      devices: [],
      errors: [
        {
          provider: 'macos-bt',
          code: 'MAC_BLUETOOTH_READ_FAILED',
          message: '无法读取 macOS 蓝牙设备信息，请确认蓝牙已开启。',
          detail: error.message,
        },
      ],
    };
  }
}

module.exports = {
  MOUSE_NAME_PATTERN,
  findBattery,
  isLikelyMouse,
  parseBatteryValue,
  parseSystemProfilerPayload,
  scan,
};
