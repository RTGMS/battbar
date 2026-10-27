'use strict';

const crypto = require('node:crypto');

const GET_BATTERY_COMMAND = 0x04;
const REPORT_ID = 0x08;
const PACKET_LENGTH = 16;
const ATK_VENDOR_IDS = new Set([0x373b, 0x3554]);
const VENDOR_USAGE_PAGE = 0xff04;
const VENDOR_USAGE = 0x02;

function clampPercent(value) {
  const number = Number(value);
  if (!Number.isFinite(number)) return null;
  return Math.max(0, Math.min(100, Math.round(number)));
}

/**
 * The ATK/Compx dongle expects a fixed 16-byte packet through HID report 8.
 * Byte 0 is the command, byte 15 is a checksum. The checksum seed includes the
 * report ID, which is how ATK HUB's own WebHID implementation calculates it.
 */
function buildBatteryRequest() {
  const packet = Buffer.alloc(PACKET_LENGTH);
  packet[0] = GET_BATTERY_COMMAND;
  let sum = REPORT_ID;
  for (let index = 0; index < PACKET_LENGTH - 1; index += 1) {
    sum += packet[index];
  }
  packet[PACKET_LENGTH - 1] = (0x55 - (sum & 0xff)) & 0xff;
  return Buffer.concat([Buffer.from([REPORT_ID]), packet]);
}

function decodeBatteryResponse(rawData) {
  if (!rawData) return null;
  const data = Buffer.from(rawData);
  if (data.length < 9) return null;

  const payload = data[0] === REPORT_ID ? data.subarray(1) : data;
  if (payload.length < 7 || payload[0] !== GET_BATTERY_COMMAND) return null;

  const status = payload[1];
  if (status !== 0) {
    return { error: `ATK 设备返回状态码 0x${status.toString(16)}` };
  }

  const battery = clampPercent(payload[5]);
  if (battery === null) return { error: 'ATK 设备返回了无效电量' };

  return {
    battery,
    charging: payload[6] === 1,
  };
}

function looksLikeAtkProduct(product) {
  return /vxe|mad\s*r|compx|mouse|mice|dongle|receiver|接收器|鼠标/i.test(product || '');
}

function isAtkCandidate(device) {
  if (!device || !ATK_VENDOR_IDS.has(device.vendorId)) return false;
  if (device.usagePage === VENDOR_USAGE_PAGE && device.usage === VENDOR_USAGE) return true;

  // Some Windows HID stacks only expose the first top-level collection. In
  // that case fall back to the vendor interface (interface 1), but still guard
  // against querying other ATK peripherals such as keyboards.
  if (device.interface === 1 && looksLikeAtkProduct(device.product)) {
    return true;
  }
  return false;
}

function findAtkCandidates(devices) {
  if (!Array.isArray(devices)) return [];
  const grouped = new Map();

  for (const device of devices) {
    if (!isAtkCandidate(device)) continue;
    const key = `${device.path}\u0000${device.interface ?? ''}`;
    const current = grouped.get(key);
    const exactCollection =
      device.usagePage === VENDOR_USAGE_PAGE && device.usage === VENDOR_USAGE;
    if (!current || exactCollection) {
      grouped.set(key, device);
    }
  }

  return [...grouped.values()].slice(0, 4);
}

function brandFromProduct(product) {
  const value = String(product || '');
  if (/vxe/i.test(value)) return 'VXE';
  if (/mad\s*r/i.test(value)) return 'MAD';
  return 'ATK';
}

function makeDisplayName(product) {
  const value = String(product || '').trim();
  const brand = brandFromProduct(value);
  const isDongle = /dongle|receiver|接收器/i.test(value);

  if (isDongle) {
    return {
      name: `${brand} 无线鼠标`,
      subtitle: value || `${brand} 接收器`,
      connectionLabel: '2.4 GHz',
    };
  }

  const stripped = value
    .replace(/\s*(?:1k|2k|4k|8k)?\s*(?:wireless\s+)?dongle\s*$/i, '')
    .trim();
  return {
    name: stripped || `${brand} 无线鼠标`,
    subtitle: value || `${brand} HID`,
    connectionLabel: '2.4 GHz',
  };
}

function stableDeviceId(device) {
  const serial = String(device.serialNumber || '').trim();
  if (serial) {
    return `atk:${device.vendorId.toString(16)}:${device.productId.toString(16)}:${serial}`;
  }

  // Do not include the raw HID path: it changes across reconnects and would
  // lose the user's selected mouse. A short product fingerprint is stable
  // enough for the common one-receiver case.
  const fingerprint = crypto
    .createHash('sha1')
    .update(`${device.vendorId}:${device.productId}:${device.product || ''}`)
    .digest('hex')
    .slice(0, 8);
  return `atk:${device.vendorId.toString(16)}:${device.productId.toString(16)}:${fingerprint}`;
}

module.exports = {
  ATK_VENDOR_IDS,
  GET_BATTERY_COMMAND,
  PACKET_LENGTH,
  REPORT_ID,
  buildBatteryRequest,
  decodeBatteryResponse,
  findAtkCandidates,
  isAtkCandidate,
  makeDisplayName,
  stableDeviceId,
};
