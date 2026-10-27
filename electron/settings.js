'use strict';

const fs = require('node:fs');
const path = require('node:path');

const SETTINGS_VERSION = 1;
const REFRESH_INTERVALS = [30, 60, 300];

const DEFAULT_SETTINGS = Object.freeze({
  settingsVersion: SETTINGS_VERSION,
  refreshInterval: 60,
  lowBatteryAlerts: true,
  launchAtLogin: false,
  selectedDeviceId: null,
});

function asBoolean(value, fallback) {
  return typeof value === 'boolean' ? value : fallback;
}

function sanitizeSettings(input, base = DEFAULT_SETTINGS) {
  const source = input && typeof input === 'object' ? input : {};
  const refreshInterval = REFRESH_INTERVALS.includes(Number(source.refreshInterval))
    ? Number(source.refreshInterval)
    : base.refreshInterval;

  let selectedDeviceId = base.selectedDeviceId;
  if (Object.prototype.hasOwnProperty.call(source, 'selectedDeviceId')) {
    const candidate = source.selectedDeviceId;
    selectedDeviceId =
      typeof candidate === 'string' && candidate.length > 0 && candidate.length <= 512
        ? candidate
        : null;
  }

  return {
    settingsVersion: SETTINGS_VERSION,
    refreshInterval,
    lowBatteryAlerts: asBoolean(source.lowBatteryAlerts, base.lowBatteryAlerts),
    launchAtLogin: asBoolean(source.launchAtLogin, base.launchAtLogin),
    selectedDeviceId,
  };
}

function pickPatch(patch) {
  if (!patch || typeof patch !== 'object') return {};
  const allowed = {};
  for (const key of Object.keys(DEFAULT_SETTINGS)) {
    if (Object.prototype.hasOwnProperty.call(patch, key)) allowed[key] = patch[key];
  }
  return allowed;
}

class SettingsStore {
  constructor(userDataDir) {
    this.dir = userDataDir;
    this.file = path.join(userDataDir, 'settings.json');
    this.settings = this.load();
  }

  load() {
    try {
      const raw = fs.readFileSync(this.file, 'utf8');
      return sanitizeSettings(JSON.parse(raw));
    } catch (error) {
      if (error.code !== 'ENOENT') {
        console.warn('[settings] Could not read settings, using defaults:', error.message);
      }
      return { ...DEFAULT_SETTINGS };
    }
  }

  get() {
    return { ...this.settings };
  }

  update(patch) {
    const next = sanitizeSettings({ ...this.settings, ...pickPatch(patch) }, this.settings);
    const changed = JSON.stringify(next) !== JSON.stringify(this.settings);
    this.settings = next;
    if (changed) this.save();
    return this.get();
  }

  save() {
    try {
      fs.mkdirSync(this.dir, { recursive: true });
      const temporary = `${this.file}.tmp`;
      fs.writeFileSync(temporary, `${JSON.stringify(this.settings, null, 2)}\n`, {
        mode: 0o600,
      });
      fs.renameSync(temporary, this.file);
    } catch (error) {
      console.error('[settings] Could not save settings:', error.message);
    }
  }
}

module.exports = {
  DEFAULT_SETTINGS,
  REFRESH_INTERVALS,
  SettingsStore,
  pickPatch,
  sanitizeSettings,
};
