'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const { DEFAULT_SETTINGS, pickPatch, sanitizeSettings } = require('../electron/settings');

test('sanitizeSettings falls back for unknown refresh intervals', () => {
  const settings = sanitizeSettings({ refreshInterval: 7 });
  assert.equal(settings.refreshInterval, 60);
  assert.equal(settings.lowBatteryAlerts, true);
  assert.equal(settings.launchAtLogin, false);
});

test('sanitizeSettings accepts valid values and rejects oversized IDs', () => {
  assert.equal(sanitizeSettings({ refreshInterval: 30 }).refreshInterval, 30);
  assert.equal(sanitizeSettings({ refreshInterval: 300 }).refreshInterval, 300);
  assert.equal(sanitizeSettings({ lowBatteryAlerts: false }).lowBatteryAlerts, false);
  assert.equal(sanitizeSettings({ selectedDeviceId: 'x'.repeat(513) }).selectedDeviceId, null);
  assert.equal(sanitizeSettings({ selectedDeviceId: 'atk:123' }).selectedDeviceId, 'atk:123');
});

test('pickPatch only passes known settings keys', () => {
  assert.deepEqual(pickPatch({ lowBatteryAlerts: false, arbitrary: true }), {
    lowBatteryAlerts: false,
  });
  assert.deepEqual(DEFAULT_SETTINGS.settingsVersion, 1);
});
