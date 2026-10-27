'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const { BatteryAlertManager } = require('../electron/battery-alerts');

const device = (battery, extra = {}) => ({
  id: 'atk:test',
  name: 'ATK 无线鼠标',
  battery,
  charging: false,
  stale: false,
  ...extra,
});

test('low and critical alerts fire once per threshold', () => {
  const manager = new BatteryAlertManager();
  assert.equal(manager.evaluate([device(50)], true).length, 0);
  assert.equal(manager.evaluate([device(19)], true).length, 1);
  assert.equal(manager.evaluate([device(18)], true).length, 0);
  assert.equal(manager.evaluate([device(9)], true).length, 1);
  assert.equal(manager.evaluate([device(8)], true).length, 0);
  assert.equal(manager.evaluate([device(8)], true).length, 0);
});

test('charging or a healthy battery resets the alert state', () => {
  const manager = new BatteryAlertManager();
  assert.equal(manager.evaluate([device(9)], true).length, 1);
  assert.equal(manager.evaluate([device(9, { charging: true })], true).length, 0);
  assert.equal(manager.evaluate([device(9)], true).length, 1);
  manager.reset();
  assert.equal(manager.evaluate([device(9)], true).length, 1);
});

test('stale readings never raise notifications', () => {
  const manager = new BatteryAlertManager();
  assert.equal(manager.evaluate([device(9, { stale: true })], true).length, 0);
  assert.equal(manager.evaluate([device(9, { stale: true })], true).length, 0);
});

test('disabled alerts do not notify and clear stored state', () => {
  const manager = new BatteryAlertManager();
  assert.equal(manager.evaluate([device(8)], false).length, 0);
  assert.equal(manager.evaluate([device(8)], true).length, 1);
});
