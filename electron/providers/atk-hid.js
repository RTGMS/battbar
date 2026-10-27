'use strict';

const path = require('node:path');
const { Worker } = require('node:worker_threads');
const {
  findAtkCandidates,
  makeDisplayName,
  stableDeviceId,
} = require('./atk-protocol');

let HID = null;
let hidLoadError = null;
try {
  HID = require('node-hid');
} catch (error) {
  hidLoadError = error;
}

const WORKER_TIMEOUT_MS = 4200;
const READ_ATTEMPTS = 2;
const RETRY_DELAY_MS = 220;

function toDevice(candidate, reading) {
  const display = makeDisplayName(candidate.product);
  const serial = String(candidate.serialNumber || '').trim();
  return {
    id: stableDeviceId(candidate),
    provider: 'atk',
    kind: 'mouse',
    name: display.name,
    subtitle: display.subtitle,
    connection: '2.4g',
    connectionLabel: display.connectionLabel,
    battery: reading.battery,
    charging: reading.charging,
    voltage: null,
    address: serial || null,
    source: 'ATK HID',
    transport: 'usb-receiver',
    hardware: {
      vendorId: `0x${candidate.vendorId.toString(16).padStart(4, '0')}`,
      productId: `0x${candidate.productId.toString(16).padStart(4, '0')}`,
      product: candidate.product || '',
      interface: candidate.interface ?? null,
    },
  };
}

function friendlyError(error) {
  if (error?.code === 'HID_TIMEOUT') {
    return {
      provider: 'atk',
      code: 'ATK_TIMEOUT',
      message: 'ATK 接收器没有响应，请确认鼠标已唤醒并处于 2.4G 模式。',
      detail: error.message,
    };
  }
  if (error?.code === 'HID_UNAVAILABLE') {
    return {
      provider: 'atk',
      code: 'ATK_HID_UNAVAILABLE',
      message: 'HID 组件加载失败，ATK 设备暂时无法读取。',
      detail: error.message,
    };
  }
  return {
    provider: 'atk',
    code: 'ATK_READ_FAILED',
    message: 'ATK 接收器已连接，但读取电量失败。请关闭 ATK HUB 后重试。',
    detail: error?.message || String(error),
  };
}

function queryAtkDevice(candidate) {
  return new Promise((resolve, reject) => {
    let worker;
    try {
      worker = new Worker(path.join(__dirname, 'atk-hid-worker.js'), {
        workerData: { path: candidate.path },
        name: 'atk-battery-reader',
      });
    } catch (error) {
      reject(error);
      return;
    }

    let settled = false;
    let timer = null;

    const cleanup = () => {
      if (timer) clearTimeout(timer);
      worker.removeAllListeners();
    };

    const succeed = (reading) => {
      if (settled) return;
      settled = true;
      cleanup();
      resolve(reading);
      worker.terminate().catch(() => {});
    };

    const fail = (error) => {
      if (settled) return;
      settled = true;
      cleanup();
      reject(error);
      worker.terminate().catch(() => {});
    };

    timer = setTimeout(() => {
      const error = new Error('ATK 电量读取超时');
      error.code = 'HID_TIMEOUT';
      fail(error);
    }, WORKER_TIMEOUT_MS);

    worker.once('message', (message) => {
      if (!message || typeof message !== 'object') {
        fail(new Error('ATK 读取进程返回了无效结果'));
        return;
      }
      if (message.ok && message.reading) {
        succeed(message.reading);
        return;
      }
      const error = new Error(message.error || 'ATK 电量读取失败');
      if (message.code) error.code = message.code;
      fail(error);
    });

    worker.once('error', (error) => {
      fail(error);
    });

    worker.once('exit', (code) => {
      if (settled) return;
      const error = new Error(`ATK 读取进程已退出（代码 ${code}）`);
      fail(error);
    });
  });
}

async function scan() {
  if (!HID) {
    return { devices: [], errors: [friendlyError(hidLoadError)] };
  }

  let candidates;
  try {
    candidates = findAtkCandidates(HID.devices());
  } catch (error) {
    return {
      devices: [],
      errors: [
        {
          provider: 'atk',
      code: 'ATK_ENUMERATION_FAILED',
          message: '无法枚举 USB HID 设备，ATK 电量读取暂时不可用。',
          detail: error.message,
        },
      ],
    };
  }

  if (candidates.length === 0) return { devices: [], errors: [] };

  const devices = [];
  const errors = [];
  for (const candidate of candidates) {
    let lastError = null;
    for (let attempt = 0; attempt < READ_ATTEMPTS; attempt += 1) {
      try {
        const reading = await queryAtkDevice(candidate);
        devices.push(toDevice(candidate, reading));
        lastError = null;
        break;
      } catch (error) {
        lastError = error;
        if (attempt < READ_ATTEMPTS - 1) {
          await new Promise((resolve) => setTimeout(resolve, RETRY_DELAY_MS));
        }
      }
    }
    if (lastError) errors.push(friendlyError(lastError));
  }

  return { devices, errors };
}

module.exports = {
  queryAtkDevice,
  scan,
  toDevice,
};
