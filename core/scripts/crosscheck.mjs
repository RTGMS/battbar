#!/usr/bin/env node
/**
 * Replay `core/vectors/vectors.json` against the shipped JavaScript
 * implementations.
 *
 * The Rust core is the reference; this script proves that the legacy Electron
 * code (and the HID probe) still agree with it, so a user on the Electron build
 * sees the same readings as on the native one. Cases whose `targets` list does
 * not include "js" document a known, intentional difference and are reported as
 * skipped rather than failed.
 *
 * Usage: node core/scripts/crosscheck.mjs [--verbose]
 */

import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

const atkProtocol = require(join(root, 'electron/providers/atk-protocol.js'));
const macosBluetooth = require(join(root, 'electron/providers/macos-bluetooth.js'));
const { BatteryAlertManager } = require(join(root, 'electron/battery-alerts.js'));
const probe = require(join(root, 'tools/hid-probe.js'));

const vectors = JSON.parse(readFileSync(join(root, 'core/vectors/vectors.json'), 'utf8'));
const verbose = process.argv.includes('--verbose');

let passed = 0;
let failed = 0;
let skipped = 0;
const failures = [];

function applies(caseOrStep) {
  const targets = caseOrStep.targets;
  if (!targets) return true;
  return Array.isArray(targets) && targets.includes('js');
}

function record(ok, label, detail) {
  if (ok) {
    passed += 1;
    if (verbose) console.log(`  ok    ${label}`);
    return;
  }
  failed += 1;
  failures.push({ label, detail });
  console.log(`  FAIL  ${label}`);
  if (detail) console.log(`        ${detail}`);
}

function skip(label) {
  skipped += 1;
  if (verbose) console.log(`  skip  ${label}`);
}

function fromHex(hex) {
  return Buffer.from(hex, 'hex');
}

function describe(value) {
  return JSON.stringify(value);
}

/**
 * The Electron decoder takes only the buffer (no report id) and reports a
 * non-zero status as a message string, so we normalise it to the same shape the
 * vectors use.
 */
function jsAtkDecode(bytes) {
  const decoded = atkProtocol.decodeBatteryResponse(bytes);
  if (decoded === null || decoded === undefined) return { kind: 'not_for_us' };
  if (decoded.error) {
    const match = /0x([0-9a-f]+)/i.exec(String(decoded.error));
    return { kind: 'status', status: match ? Number.parseInt(match[1], 16) : null };
  }
  return { kind: 'reading', battery: decoded.battery, charging: decoded.charging };
}

/**
 * The probe's decoder returns the raw fields without validating them, so the
 * adapter applies the same accept/reject rules as the provider would.
 */
function jsRazerDecode(bytes, expectation) {
  const decoded = probe.decodeRazer(bytes);
  if (!decoded) return { kind: 'not_for_us' };

  if (decoded.status !== 0x02 && decoded.status !== 0x01) {
    return { kind: 'status', status: decoded.status };
  }

  const expectedCommand = expectation.kind === 'charging' ? 0x84 : 0x80;
  if (decoded.commandId !== expectedCommand) return { kind: 'not_for_us' };

  if (expectation.kind === 'charging') return { kind: 'charging', charging: decoded.raw === 1 };
  return { kind: 'battery', battery: decoded.battery };
}

function comparable(actual, expectation) {
  const ok = Object.keys(expectation).every((key) => actual[key] === expectation[key]);
  return { ok, actual };
}

// --- ATK -------------------------------------------------------------------

function checkAtk() {
  console.log('ATK');

  const expectedRequest = vectors.atk.request_hex;
  record(
    atkProtocol.buildBatteryRequest().toString('hex') === expectedRequest,
    'atk-protocol.buildBatteryRequest matches core',
    `electron=${atkProtocol.buildBatteryRequest().toString('hex')}`,
  );
  record(
    probe.atkRequest().toString('hex') === expectedRequest,
    'hid-probe.atkRequest matches core',
    `probe=${probe.atkRequest().toString('hex')}`,
  );

  for (const testCase of vectors.atk.decode) {
    if (!applies(testCase)) {
      skip(`atk decode: ${testCase.name}`);
      continue;
    }
    const actual = jsAtkDecode(fromHex(testCase.hex));
    const { ok } = comparable(actual, testCase.expect);
    record(ok, `atk decode: ${testCase.name}`, `expected ${describe(testCase.expect)}, got ${describe(actual)}`);
  }
}

// --- ATK device tables (captured from real hardware) -----------------------

/**
 * Candidate filtering on a descriptor table captured from a real ATK 1K
 * receiver. The table is stored per collection (HIDAPI / node-hid shape), which
 * is what the Electron implementation actually consumes.
 */
function checkAtkDeviceTable() {
  console.log('ATK device filtering');

  const section = vectors.atk.devices;
  if (!section) {
    skip('atk device table');
    return;
  }

  const devices = section.items.map((item) => ({
    path: item.path,
    vendorId: item.vendor_id,
    productId: item.product_id,
    usagePage: item.usage_page,
    usage: item.usage,
    interface: item.interface,
    product: item.product,
    serialNumber: '',
  }));

  const candidates = atkProtocol.findAtkCandidates(devices);
  const actual = candidates.map((device) => ({
    path: device.path,
    usage_page: device.usagePage,
    usage: device.usage,
  }));
  const expected = section.expect_candidates.map((candidate) => ({
    path: candidate.path,
    usage_page: candidate.usage_page,
    usage: candidate.usage,
  }));

  record(
    describe(actual) === describe(expected),
    'atk device filtering: real receiver table',
    `expected ${describe(expected)}, got ${describe(actual)}`,
  );
}

// --- Razer -----------------------------------------------------------------

function checkRazer() {
  console.log('Razer');

  for (const testCase of vectors.razer.requests) {
    if (!applies(testCase)) {
      skip(`razer request: ${testCase.name}`);
      continue;
    }
    const request = probe.razerRequest(testCase.command_id);
    const actual = {
      length: request.length,
      transaction_id: request[1],
      data_size: request[5],
      command_class: request[6],
      command_id: request[7],
      crc: request[testCase.crc_index],
    };
    const expected = {
      length: vectors.razer.report_length,
      transaction_id: testCase.transaction_id,
      data_size: testCase.data_size,
      command_class: testCase.command_class,
      command_id: testCase.command_id,
      crc: testCase.crc,
    };
    const ok = Object.keys(expected).every((key) => actual[key] === expected[key]);
    record(ok, `razer request: ${testCase.name}`, `expected ${describe(expected)}, got ${describe(actual)}`);
  }

  for (const testCase of vectors.razer.decode) {
    if (!applies(testCase)) {
      skip(`razer decode: ${testCase.name}`);
      continue;
    }
    const actual = jsRazerDecode(fromHex(testCase.hex), testCase.expect);
    const { ok } = comparable(actual, testCase.expect);
    record(
      ok,
      `razer decode: ${testCase.name}`,
      `expected ${describe(testCase.expect)}, got ${describe(actual)}`,
    );
  }
}

// --- Bluetooth -------------------------------------------------------------

function toAttributeObject(pairs) {
  return Object.fromEntries(pairs.map(([key, value]) => [key, value]));
}

function checkBluetooth() {
  console.log('Bluetooth');

  for (const testCase of vectors.bluetooth.battery_attributes) {
    if (!applies(testCase)) {
      skip(`bluetooth battery: ${testCase.name}`);
      continue;
    }
    const actual = macosBluetooth.findBattery(toAttributeObject(testCase.attributes));
    record(
      actual === testCase.expect,
      `bluetooth battery: ${testCase.name}`,
      `expected ${describe(testCase.expect)}, got ${describe(actual)}`,
    );
  }

  for (const testCase of vectors.bluetooth.mouse_names) {
    if (!applies(testCase)) {
      skip(`bluetooth name: ${testCase.name}`);
      continue;
    }
    const actual = macosBluetooth.isLikelyMouse(`${testCase.name} ${testCase.minor_type}`, {
      device_minorType: testCase.minor_type,
    });
    record(
      actual === testCase.expect,
      `bluetooth name: ${testCase.name}`,
      `expected ${describe(testCase.expect)}, got ${describe(actual)}`,
    );
  }
}

// --- Alerts ----------------------------------------------------------------

function checkAlerts() {
  console.log('Alerts');

  for (const scenario of vectors.alerts.scenarios) {
    if (!applies(scenario)) {
      skip(`alerts: ${scenario.name}`);
      continue;
    }
    const manager = new BatteryAlertManager();
    scenario.steps.forEach((step, index) => {
      const events = manager.evaluate(step.devices, scenario.enabled);
      const actual = events.map((event) => event.type);
      record(
        describe(actual) === describe(step.expect),
        `alerts: ${scenario.name} (step ${index})`,
        `expected ${describe(step.expect)}, got ${describe(actual)}`,
      );
    });
  }
}

console.log(verbose ? 'Core cross-check (verbose)\n' : 'Core cross-check\n');
checkAtk();
checkAtkDeviceTable();
checkRazer();
checkBluetooth();
checkAlerts();

console.log(`\n${passed} passed, ${failed} failed, ${skipped} skipped`);
if (failed > 0) {
  console.log('\nDivergences between the JavaScript implementation and core/vectors/vectors.json:');
  for (const failure of failures) console.log(`  - ${failure.label}: ${failure.detail}`);
  process.exit(1);
}
