'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  findBattery,
  isLikelyMouse,
  parseBatteryValue,
  parseSystemProfilerPayload,
} = require('../electron/providers/macos-bluetooth');

test('parseBatteryValue understands percentages and numbers', () => {
  assert.equal(parseBatteryValue('68%'), 68);
  assert.equal(parseBatteryValue(' 7 % '), 7);
  assert.equal(parseBatteryValue(42), 42);
  assert.equal(parseBatteryValue(undefined), null);
  assert.equal(parseBatteryValue('unknown'), null);
  assert.equal(parseBatteryValue('140%'), null);
});

test('findBattery prefers the main battery over case/left/right values', () => {
  assert.equal(
    findBattery({
      device_batteryLevelCase: '95%',
      device_batteryLevelLeft: '20%',
      device_batteryLevelMain: '68%',
    }),
    68,
  );
  assert.equal(findBattery({ device_batteryLevel: '50%' }), 50);
  assert.equal(findBattery({ device_batteryLevelCase: '95%' }), null);
});

test('isLikelyMouse uses the minor type and known model names', () => {
  assert.equal(isLikelyMouse('MX Master 3S', {}), true);
  assert.equal(isLikelyMouse('Something', { device_minorType: 'Mouse' }), true);
  assert.equal(isLikelyMouse('AirPods Pro', { device_minorType: 'Headphones' }), false);
  assert.equal(isLikelyMouse('ATK X1 Ultimate', {}), true);
});

test('parseSystemProfilerPayload extracts connected mice and ignores other gadgets', () => {
  const payload = {
    SPBluetoothDataType: [
      {
        device_connected: [
          {
            'ATK X1 Ultimate': {
              device_address: 'AA:BB:CC:DD:EE:FF',
              device_batteryLevelMain: '68%',
              device_batteryLevel: '67%',
              device_minorType: 'Mouse',
              charging: 'No',
              'device_vendorID': '0x373B',
            },
            'AirPods Pro': {
              device_batteryLevelMain: '50%',
              device_batteryLevelCase: '80%',
              device_minorType: 'Headphones',
            },
          },
          {
            'Magic Mouse': {
              device_batteryLevelMain: '24%',
              device_minorType: 'Mouse',
              charging: 'Yes',
            },
          },
        ],
      },
    ],
  };

  const devices = parseSystemProfilerPayload(payload);
  assert.equal(devices.length, 2);
  assert.equal(devices[0].name, 'ATK X1 Ultimate');
  assert.equal(devices[0].battery, 68);
  assert.equal(devices[0].charging, false);
  assert.equal(devices[0].connection, 'bluetooth');
  assert.equal(devices[0].id, 'bt-macos:aa:bb:cc:dd:ee:ff');
  assert.equal(devices[1].name, 'Magic Mouse');
  assert.equal(devices[1].charging, true);
});

test('parseSystemProfilerPayload deduplicates by address and handles a root object', () => {
  const payload = {
    SPBluetoothDataType: {
      device_connected: {
        Mouse: {
          device_address: '11:22:33:44:55:66',
          device_batteryLevel: '80%',
          device_minorType: 'Mouse',
        },
      },
    },
  };
  const devices = parseSystemProfilerPayload(payload);
  assert.equal(devices.length, 1);
  assert.equal(devices[0].battery, 80);
});
