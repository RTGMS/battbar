#!/usr/bin/env node
'use strict';

/**
 * Cross-platform HID probe for BattBar hardware validation.
 *
 * Usage:
 *   node tools/hid-probe.js list
 *   node tools/hid-probe.js atk
 *   node tools/hid-probe.js razer
 *
 * Requires `node-hid` (already a dependency of the legacy Electron build).
 * Run `npm install` first. On Windows, use a normal 64-bit Node.js.
 */

let HID;
try {
  HID = require('node-hid');
} catch (error) {
  // When required as a module (for the protocol cross-check) a missing native
  // binding must not kill the process; only the CLI needs it.
  if (require.main === module) {
    console.error('无法加载 node-hid，请先运行 npm install。');
    console.error(error.message);
    process.exit(1);
  }
}

const ATK_VENDOR_IDS = new Set([0x373b, 0x3554]);
const RAZER_VENDOR_ID = 0x1532;
const RAZER_PIDS = new Set([0x00c1, 0x00b3]);

function hex(value) {
  return `0x${Number(value).toString(16).padStart(4, '0').toUpperCase()}`;
}

function bufferHex(data) {
  return Buffer.from(data).toString('hex').match(/.{1,2}/g)?.join(' ') ?? '';
}

function list() {
  const devices = HID.devices();
  console.log(`node ${process.version}, ${devices.length} HID devices\n`);
  for (const device of devices) {
    console.log([
      `vid=${hex(device.vendorId)}`,
      `pid=${hex(device.productId)}`,
      `page=${hex(device.usagePage || 0)}`,
      `usage=${hex(device.usage || 0)}`,
      `iface=${device.interface ?? '?'}`,
      `product=${JSON.stringify(device.product || '')}`,
      `serial=${JSON.stringify(device.serialNumber || '')}`,
    ].join('  '));
  }
}

function atkRequest() {
  const packet = [0x08, 0x04];
  while (packet.length < 16) packet.push(0);
  let sum = 0;
  for (const byte of packet) sum += byte;
  packet.push((0x55 - (sum & 0xff)) & 0xff);
  return Buffer.from(packet);
}

function decodeAtkBattery(data) {
  const bytes = Array.from(data);
  if (bytes[0] === 0x08) bytes.shift();
  if (bytes.length < 7 || bytes[0] !== 0x04) return null;
  if (bytes[1] !== 0) return { error: `status 0x${bytes[1].toString(16)}` };
  return { battery: bytes[5], charging: bytes[6] === 1 };
}

function probeAtk() {
  const all = HID.devices().filter((device) => ATK_VENDOR_IDS.has(device.vendorId));
  const vendor = all.filter((device) => (device.usagePage || 0) >= 0xff00);
  const devices = vendor.length > 0 ? vendor : all;
  if (devices.length === 0) {
    console.log('未发现 ATK / VXE / MAD 接收器（VID 0x373B / 0x3554）。');
    return;
  }

  const request = atkRequest();
  console.log(`ATK 请求: ${bufferHex(request)}\n`);
  for (const info of devices) {
    // The vendor collection differs between Windows/HIDAPI and macOS IOKit.
    // Query every ATK collection once; the receiver ignores unrelated ones.
    let device;
    try {
      device = new HID.HID(info.path);
      const written = device.write(request);
      console.log(`打开 ${info.product || info.path} page=${hex(info.usagePage || 0)} write=${written}`);
      const deadline = Date.now() + 2500;
      let found = false;
      while (Date.now() < deadline && !found) {
        const data = device.readTimeout(500);
        if (!data || data.length === 0) continue;
        console.log(`  原始应答: ${bufferHex(data)}`);
        const decoded = decodeAtkBattery(data);
        if (decoded?.error) {
          console.log(`  错误: ${decoded.error}`);
          found = true;
        } else if (decoded) {
          console.log(`  电量: ${decoded.battery}%  充电: ${decoded.charging ? '是' : '否'}`);
          found = true;
        }
      }
      if (!found) console.log('  2.5 秒内没有有效应答（唤醒鼠标后重试）。');
    } catch (error) {
      console.log(`打开/读取失败: ${error.message}`);
    } finally {
      try { device?.close(); } catch { /* ignore */ }
    }
  }
}

function razerRequest(commandId) {
  const report = new Array(90).fill(0);
  report[1] = 0x1f;
  report[5] = 0x02;
  report[6] = 0x07;
  report[7] = commandId;
  let crc = 0;
  for (let i = 2; i < 88; i += 1) crc ^= report[i];
  report[88] = crc;
  return Buffer.from(report);
}

function decodeRazer(report) {
  const bytes = Array.from(report);
  // HIDAPI get_feature_report returns the report ID as byte 0 when the
  // requested report ID is 0; tolerate implementations that omit it.
  const payload = bytes.length >= 91 && bytes[0] === 0x00 ? bytes.slice(1) : bytes;
  if (payload.length < 10) return null;
  const status = payload[0];
  const commandClass = payload[6];
  const commandId = payload[7];
  const raw = payload[9];
  return {
    status,
    commandClass,
    commandId,
    raw,
    battery: Math.round((raw * 100) / 255),
  };
}

function probeRazer() {
  const devices = HID.devices().filter(
    (device) => device.vendorId === RAZER_VENDOR_ID && RAZER_PIDS.has(device.productId)
  );
  if (devices.length === 0) {
    console.log('未发现 Razer Viper V3 Pro / HyperPolling 接收器（VID 0x1532，PID 0x00C1 / 0x00B3）。');
    return;
  }

  for (const info of devices) {
    console.log(`\n打开 ${info.product || info.path} pid=${hex(info.productId)} page=${hex(info.usagePage || 0)}`);
    let device;
    try {
      device = new HID.HID(info.path);
      for (const [label, commandId] of [['电量', 0x80], ['充电', 0x84]]) {
        const request = razerRequest(commandId);
        // HIDAPI treats the first byte as the report ID. Report ID 0 is
        // explicitly prepended so the 90-byte struct is sent unchanged.
        const written = device.sendFeatureReport(Buffer.concat([Buffer.from([0x00]), request]));
        console.log(`  ${label}请求: ${written} 字节, cmd=0x${commandId.toString(16)}`);
        Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 100); // 100 ms
        for (const length of [91, 90]) {
          try {
            const response = device.getFeatureReport(0, length);
            console.log(`  GET ${length}: ${bufferHex(response)}`);
            const decoded = decodeRazer(response);
            if (decoded) {
              console.log(`  status=0x${decoded.status.toString(16)} class=0x${decoded.commandClass.toString(16)} cmd=0x${decoded.commandId.toString(16)} raw=${decoded.raw}${commandId === 0x80 ? ` battery=${decoded.battery}%` : ` charging=${decoded.raw === 1 ? 'yes' : 'no'}`}`);
              if (decoded.status === 0x02 || decoded.status === 0x01) break;
            }
          } catch (error) {
            console.log(`  GET ${length} 失败: ${error.message}`);
          }
        }
      }
    } catch (error) {
      console.log(`  失败: ${error.message}`);
      console.log('  提示：退出雷云 / Razer Synapse 后重试；Windows 需要先确认接收器 PID 与 HID 接口。');
    } finally {
      try { device?.close(); } catch { /* ignore */ }
    }
  }
}

// Exported so the protocol cross-check (core/scripts/crosscheck.mjs) can replay
// the shared vectors against this probe instead of duplicating the logic.
module.exports = {
  ATK_VENDOR_IDS,
  RAZER_PIDS,
  RAZER_VENDOR_ID,
  atkRequest,
  decodeAtkBattery,
  decodeRazer,
  razerRequest,
};

if (require.main === module) {
  const mode = (process.argv[2] || 'list').toLowerCase();
  if (mode === 'list') list();
  else if (mode === 'atk') probeAtk();
  else if (mode === 'razer') probeRazer();
  else {
    console.error('用法: node tools/hid-probe.js [list|atk|razer]');
    process.exit(2);
  }
}
