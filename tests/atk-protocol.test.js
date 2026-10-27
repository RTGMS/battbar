'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  buildBatteryRequest,
  decodeBatteryResponse,
  findAtkCandidates,
  isAtkCandidate,
  makeDisplayName,
  stableDeviceId,
} = require('../electron/providers/atk-protocol');

test('buildBatteryRequest uses ATK HUB report 8 command and checksum', () => {
  const request = buildBatteryRequest();
  assert.equal(request.length, 17);
  assert.equal(request.toString('hex'), '0804000000000000000000000000000049');
});

test('decodeBatteryResponse parses a real response', () => {
  const response = Buffer.from('08040000000219000e3d000000000000e3', 'hex');
  assert.deepEqual(decodeBatteryResponse(response), { battery: 25, charging: false });
});

test('decodeBatteryResponse understands charging and clamps battery', () => {
  const response = Buffer.from([8, 4, 0, 0, 0, 2, 105, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  assert.deepEqual(decodeBatteryResponse(response), { battery: 100, charging: true });
});

test('decodeBatteryResponse reports protocol errors and ignores other reports', () => {
  const errorResponse = Buffer.from([8, 4, 1, 0, 0, 0, 50, 0, 0]);
  assert.match(decodeBatteryResponse(errorResponse).error, /状态码/);
  assert.equal(decodeBatteryResponse(Buffer.from([8, 2, 0, 0, 0, 0])), null);
  assert.equal(decodeBatteryResponse(Buffer.alloc(0)), null);
});

test('findAtkCandidates filters vendor collections and deduplicates', () => {
  const devices = [
    {
      vendorId: 0x373b,
      productId: 0x101a,
      path: 'path-a',
      interface: 1,
      usagePage: 0xff04,
      usage: 2,
      product: 'ATK Mouse 1K Dongle',
    },
    {
      vendorId: 0x373b,
      productId: 0x101a,
      path: 'path-a',
      interface: 1,
      usagePage: 0x0001,
      usage: 2,
      product: 'ATK Mouse 1K Dongle',
    },
    {
      vendorId: 0x3554,
      productId: 0xf123,
      path: 'path-b',
      interface: 1,
      usagePage: 0xff04,
      usage: 2,
      product: 'VXE R1',
    },
    {
      vendorId: 0x1234,
      productId: 0x0001,
      path: 'path-c',
      interface: 1,
      usagePage: 0xff04,
      usage: 2,
      product: 'Other keyboard',
    },
    {
      vendorId: 0x373b,
      productId: 0x101a,
      path: 'path-d',
      interface: 1,
      product: 'ATK Mouse 1K Dongle',
    },
  ];

  const candidates = findAtkCandidates(devices);
  assert.equal(candidates.length, 3);
  assert.deepEqual(
    candidates.map((candidate) => candidate.path),
    ['path-a', 'path-b', 'path-d'],
  );
});

test('isAtkCandidate only uses the fallback on a mouse-like interface', () => {
  assert.equal(
    isAtkCandidate({ vendorId: 0x373b, usagePage: 0xff05, interface: 1, product: 'ATK Mouse 1K Dongle' }),
    true,
  );
  assert.equal(
    isAtkCandidate({ vendorId: 0x373b, interface: 1, product: 'ATK Mouse 1K Dongle' }),
    true,
  );
  assert.equal(
    isAtkCandidate({ vendorId: 0x373b, interface: 1, product: 'ATK Keyboard' }),
    false,
  );
  assert.equal(
    isAtkCandidate({ vendorId: 0x1234, usagePage: 0xff04, usage: 2 }),
    false,
  );
});

test('display names are friendly for receivers', () => {
  assert.deepEqual(makeDisplayName('ATK Mouse 1K Dongle'), {
    name: 'ATK 无线鼠标',
    subtitle: 'ATK Mouse 1K Dongle',
    connectionLabel: '2.4 GHz',
  });
  assert.equal(makeDisplayName('VXE R1 Wireless Dongle').name, 'VXE 无线鼠标');
});

test('stableDeviceId does not depend on transient HID paths', () => {
  const first = { vendorId: 0x373b, productId: 0x101a, product: 'ATK Mouse 1K Dongle', path: 'one' };
  const second = { ...first, path: 'two' };
  assert.equal(stableDeviceId(first), stableDeviceId(second));
  assert.equal(stableDeviceId({ ...first, serialNumber: 'ABC' }), 'atk:373b:101a:ABC');
});
