'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  extractJson,
  isLikelyMouse,
  parsePowerShellOutput,
} = require('../electron/providers/windows-bluetooth');

test('extractJson handles BOMs and noisy PowerShell output', () => {
  const parsed = extractJson(
    '\uFEFFWARNING: something unimportant\n[{"name":"ATK X1","battery":55}]\n',
  );
  assert.deepEqual(parsed, [{ name: 'ATK X1', battery: 55 }]);
  assert.equal(extractJson('not json'), null);
  assert.equal(extractJson(''), null);
});

test('parsePowerShellOutput maps connected mouse rows', () => {
  const stdout = JSON.stringify([
    {
      name: 'ATK X1 Ultimate',
      instanceId: 'BTHLE\\DEV_AA',
      battery: 55,
      status: 'OK',
      present: true,
      class: 'Bluetooth',
    },
    {
      name: 'Bluetooth Keyboard',
      instanceId: 'BTHLE\\DEV_BB',
      battery: 90,
      status: 'OK',
      present: true,
      class: 'Bluetooth',
    },
    {
      name: 'ATK X1 Ultimate',
      instanceId: 'BTHLE\\DEV_AA_DUP',
      battery: 54,
      status: 'OK',
      present: true,
      class: 'Mouse',
    },
    {
      name: 'MX Master 3S',
      instanceId: 'BTHLE\\DEV_CC',
      battery: 30,
      status: 'Unknown',
      present: false,
      class: 'Bluetooth',
    },
  ]);

  const devices = parsePowerShellOutput(stdout);
  assert.equal(devices.length, 1);
  assert.equal(devices[0].name, 'ATK X1 Ultimate');
  assert.equal(devices[0].battery, 55);
  assert.equal(devices[0].provider, 'windows-bt');
  assert.equal(devices[0].connection, 'bluetooth');
  assert.match(devices[0].id, /^bt-win:/);
});

test('parsePowerShellOutput tolerates a single object and rejects bad levels', () => {
  const devices = parsePowerShellOutput(
    JSON.stringify([
      { name: 'BT Mouse', class: 'Mouse', battery: 101, present: true },
      { name: 'BT Mouse', class: 'Mouse', battery: 47, present: true },
      { name: 'BT Mouse', class: 'Mouse', battery: '47', present: true },
    ]),
  );
  assert.equal(devices.length, 1);
  assert.equal(devices[0].battery, 47);

  const empty = parsePowerShellOutput('[]');
  assert.deepEqual(empty, []);
});

test('isLikelyMouse recognizes class and model heuristics', () => {
  assert.equal(isLikelyMouse('Anything', 'Mouse'), true);
  assert.equal(isLikelyMouse('ATK X1', 'Bluetooth'), true);
  assert.equal(isLikelyMouse('Logitech MX Master', 'Bluetooth'), true);
  assert.equal(isLikelyMouse('Soundcore Speaker', 'Bluetooth'), false);
});
