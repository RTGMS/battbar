'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');

const execFileAsync = promisify(execFile);
const bundledScriptPath = path.join(__dirname, 'windows-bt.ps1');
const unpackedScriptPath = process.resourcesPath
  ? path.join(process.resourcesPath, 'app.asar.unpacked', 'electron', 'providers', 'windows-bt.ps1')
  : null;

// PowerShell cannot read a script from inside app.asar, so electron-builder
// also places this file in app.asar.unpacked.
const SCRIPT_PATH =
  unpackedScriptPath && fs.existsSync(unpackedScriptPath) ? unpackedScriptPath : bundledScriptPath;

const MOUSE_NAME_PATTERN =
  /mouse|mice|鼠标|atk|vxe|mad\s*r|logitech|罗技|razer|雷蛇|pulsar|lamzu|ninja|glorious|zowie|benq|steelseries|赛睿|roccat|corsair|海盗船|hyperx|pwnage|finalmouse|endgame|wl\s*mouse|hitscan|arbiter|scyrox|incott|waizowl|darmoshark|ajazz|mchose|attack\s*shark|g\s*pro|mx\s*(master|anywhere)|deathadder|viper|basilisk|aerox|rival/i;

function extractJson(text) {
  if (typeof text !== 'string') return null;
  const trimmed = text.replace(/^\uFEFF/, '').trim();
  if (!trimmed) return null;
  try {
    return JSON.parse(trimmed);
  } catch {
    const start = trimmed.search(/[[{]/);
    if (start === -1) return null;
    const opener = trimmed[start];
    const closer = opener === '[' ? ']' : '}';
    const end = trimmed.lastIndexOf(closer);
    if (end <= start) return null;
    try {
      return JSON.parse(trimmed.slice(start, end + 1));
    } catch {
      return null;
    }
  }
}

function isLikelyMouse(name, className) {
  if (String(className || '').toLowerCase() === 'mouse') return true;
  return MOUSE_NAME_PATTERN.test(String(name || ''));
}

function parsePowerShellOutput(text) {
  const parsed = extractJson(text);
  if (!parsed) return [];
  const rows = Array.isArray(parsed) ? parsed : [parsed];
  const seen = new Set();
  const devices = [];

  for (const row of rows) {
    if (!row || typeof row !== 'object') continue;
    const name = String(row.name || '').trim();
    if (!name) continue;
    const battery = Number(row.battery);
    if (!Number.isFinite(battery) || battery < 0 || battery > 100) continue;
    if (row.present === false) continue;
    if (!isLikelyMouse(name, row.class)) continue;

    const dedupeKey = name.toLowerCase();
    if (seen.has(dedupeKey)) continue;
    seen.add(dedupeKey);

    const instanceId = String(row.instanceId || name);
    devices.push({
      id: `bt-win:${instanceId}`,
      provider: 'windows-bt',
      kind: 'mouse',
      name,
      subtitle: row.class === 'Mouse' ? 'Windows 指针设备' : 'Windows 蓝牙设备',
      connection: 'bluetooth',
      connectionLabel: '蓝牙',
      battery: Math.round(battery),
      charging: null,
      voltage: null,
      address: null,
      source: 'Windows 蓝牙',
      transport: 'builtin-bluetooth',
      hardware: {
        instanceId,
        class: row.class || null,
        status: row.status || null,
      },
    });
  }

  return devices;
}

async function invokePowerShell() {
  const args = [
    '-NoLogo',
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    SCRIPT_PATH,
  ];
  try {
    return await execFileAsync('powershell.exe', args, {
      timeout: 20000,
      windowsHide: true,
      maxBuffer: 4 * 1024 * 1024,
      encoding: 'utf8',
    });
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
    return execFileAsync('pwsh.exe', args, {
      timeout: 20000,
      windowsHide: true,
      maxBuffer: 4 * 1024 * 1024,
      encoding: 'utf8',
    });
  }
}

async function scan() {
  if (process.platform !== 'win32') return { devices: [], errors: [] };

  try {
    const { stdout, stderr } = await invokePowerShell();
    const devices = parsePowerShellOutput(stdout);
    if (!devices.length) {
      const detail = String(stderr || '').trim();
      return {
        devices,
        errors: detail
          ? [
              {
                provider: 'windows-bt',
                code: 'WIN_BLUETOOTH_EMPTY',
                message: 'Windows 未返回蓝牙鼠标电量。请确认鼠标已连接并在“设置 > 蓝牙和设备”中可见。',
                detail,
              },
            ]
          : [],
      };
    }
    return { devices, errors: [] };
  } catch (error) {
    return {
      devices: [],
      errors: [
        {
          provider: 'windows-bt',
          code: 'WIN_BLUETOOTH_READ_FAILED',
          message: '无法读取 Windows 蓝牙设备信息。请确认蓝牙已开启。',
          detail: error.message,
        },
      ],
    };
  }
}

module.exports = {
  SCRIPT_PATH,
  extractJson,
  isLikelyMouse,
  parsePowerShellOutput,
  scan,
};
