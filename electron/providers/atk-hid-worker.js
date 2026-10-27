'use strict';

const { parentPort, workerData } = require('node:worker_threads');
const HID = require('node-hid');
const { buildBatteryRequest, decodeBatteryResponse } = require('./atk-protocol');

const READ_WINDOW_MS = 1500;
const READ_SLICE_MS = 200;

let handle = null;

function finish(message) {
  try {
    if (handle) {
      handle.close();
      handle = null;
    }
  } catch {
    // The OS may already have reclaimed the handle.
  }
  parentPort.postMessage(message);
}

try {
  handle = new HID.HID(workerData.path);
  const request = buildBatteryRequest();
  const written = handle.write(request);
  if (!written) throw new Error('ATK 接收器拒绝写入指令');

  const deadline = Date.now() + READ_WINDOW_MS;
  while (Date.now() < deadline) {
    const remaining = Math.max(1, deadline - Date.now());
    const data = handle.readTimeout(Math.min(READ_SLICE_MS, remaining));
    if (!data || data.length === 0) continue;

    const decoded = decodeBatteryResponse(data);
    if (decoded?.error) {
      finish({ ok: false, error: decoded.error });
      process.exit(0);
    }
    if (decoded) {
      finish({ ok: true, reading: decoded });
      process.exit(0);
    }
  }

  finish({ ok: false, error: 'ATK 电量读取超时', code: 'HID_TIMEOUT' });
  process.exit(0);
} catch (error) {
  finish({
    ok: false,
    error: error?.message || String(error),
    code: error?.code === 'HID_TIMEOUT' ? 'HID_TIMEOUT' : 'HID_READ_FAILED',
  });
  process.exit(1);
}
