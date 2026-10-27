/*
 * battbar-core C ABI
 *
 * The macOS Swift app links `libbattbar_ffi.a` and imports this header as its
 * bridging header. Windows does not need this file: the Windows UI is Rust and
 * depends on the `battbar-core` crate directly.
 *
 * ## Conventions
 *
 *   - Functions returning `int32_t` are non-negative on success (usually a byte
 *     count or a percentage) and negative on error.
 *   - `battbar_atk_decode` additionally uses 0 to mean "not an ATK report,
 *     keep reading", which is not an error.
 *   - Buffers are caller owned; nothing here allocates on the caller's behalf.
 *   - No function panics across the boundary.
 */

#ifndef BATTBAR_CORE_H
#define BATTBAR_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- Status codes ------------------------------------------------------ */

/** The call succeeded. */
#define BATTBAR_OK 1
/** The report is not one we handle; keep reading. */
#define BATTBAR_NOT_FOR_US 0
/** A null pointer or a too-small output buffer was passed. */
#define BATTBAR_ERROR_INVALID_ARGUMENT (-1)
/** The response was shorter than the protocol requires. */
#define BATTBAR_ERROR_TOO_SHORT (-2)
/** The device reported a non-zero status byte. */
#define BATTBAR_ERROR_STATUS (-3)
/** The payload could not be interpreted. */
#define BATTBAR_ERROR_MALFORMED (-4)

/* ---- Types ------------------------------------------------------------- */

/** A decoded battery reading. */
typedef struct BattbarReading {
  /** Charge percentage, 0...100. */
  uint8_t battery;
  /** 1 when charging, 0 otherwise. */
  uint8_t charging;
} BattbarReading;

/* ---- Version ----------------------------------------------------------- */

/** Core version as 0xMMmmpp (major, minor, patch). */
uint32_t battbar_core_version(void);

/* ---- ATK / VXE / MAD 2.4G --------------------------------------------- */

/** Length of the ATK request buffer in bytes (17, report id included). */
size_t battbar_atk_request_len(void);

/** HID report id used by the battery command (0x08). */
uint16_t battbar_atk_report_id(void);

/** Vendor usage page of the ATK control collection (0xFF04). */
uint16_t battbar_atk_vendor_usage_page(void);

/** Vendor usage of the ATK control collection (0x02). */
uint16_t battbar_atk_vendor_usage(void);

/**
 * Whether an IOKit-enumerated device should be opened (macOS enumeration model).
 *
 * IOKit returns one entry per device and only the primary usage page, so this
 * accepts any vendor usage page (0xFF00..0xFFFF) for a known ATK vendor id.
 * The Windows/HIDAPI per-collection rule is implemented in Rust and is not
 * needed across the C boundary.
 *
 * @return 1 when the device is a candidate, 0 otherwise.
 */
uint8_t battbar_atk_is_macos_candidate(uint16_t vendor_id, uint16_t usage_page,
                                       uint16_t usage);

/**
 * Fill `out` with the ATK battery request.
 *
 * @return the number of bytes written, or BATTBAR_ERROR_INVALID_ARGUMENT.
 */
int32_t battbar_atk_request(uint8_t *out, size_t out_len);

/**
 * Decode a report read from the receiver.
 *
 * @param report_id  report id reported by the OS (pass 0x08 when unknown).
 * @param bytes      buffer as returned by the OS; a leading report-id byte is
 *                   optional and handled transparently.
 * @param len        length of `bytes`.
 * @param out        receives the reading on BATTBAR_OK.
 * @param out_status optional (may be NULL); receives the device status byte
 *                   when the result is BATTBAR_ERROR_STATUS.
 *
 * @return BATTBAR_OK, BATTBAR_NOT_FOR_US (keep reading), or a negative code.
 */
int32_t battbar_atk_decode(uint8_t report_id, const uint8_t *bytes, size_t len,
                           BattbarReading *out, uint8_t *out_status);

/* ---- Razer 2.4G -------------------------------------------------------- */

/** Length of a Razer feature report in bytes (90). */
size_t battbar_razer_request_len(void);

/**
 * Fill `out` with a Razer request.
 *
 * @param command_class 0x07 for the commands we use.
 * @param command_id    0x80 for battery, 0x84 for charging.
 * @return the number of bytes written, or BATTBAR_ERROR_INVALID_ARGUMENT.
 */
int32_t battbar_razer_request(uint8_t command_class, uint8_t command_id,
                              uint8_t *out, size_t out_len);

/**
 * Decode a Razer battery response.
 *
 * A 91-byte buffer with a leading 0x00 report id is handled transparently.
 */
int32_t battbar_razer_decode_battery(const uint8_t *bytes, size_t len,
                                     BattbarReading *out);

/**
 * Decode a Razer charging response.
 *
 * `out->battery` is left at 0; keep showing the last known percentage.
 */
int32_t battbar_razer_decode_charging(const uint8_t *bytes, size_t len,
                                      BattbarReading *out);

/* ---- Scan merge -------------------------------------------------------- */

/** One device as the merge policy sees it. */
typedef struct BattbarDeviceSummary {
  const char *id;
  const char *name;
  /** 0 ATK, 1 Razer, 2 Bluetooth. */
  int32_t provider;
  /** 0 receiver, 1 Bluetooth. */
  int32_t connection;
} BattbarDeviceSummary;

/** Where a merged entry came from. */
typedef struct BattbarMergedDevice {
  /** 0 = taken from `fresh`, 1 = retained from `previous`. */
  uint8_t from_previous;
  /** Index into that slice. */
  int32_t index;
  /** 1 when the reading is retained from an earlier scan. */
  uint8_t stale;
} BattbarMergedDevice;

/**
 * Merge a scan with the previous result and pick the active device.
 *
 * `out_entries` must have room for `fresh_count + previous_count` entries.
 * `out_active` receives `-1` when nothing is left. Returns 0 or an error code.
 */
int32_t battbar_merge_scan(const BattbarDeviceSummary *fresh, int32_t fresh_count,
                           const BattbarDeviceSummary *previous, int32_t previous_count,
                           const int32_t *failed_providers, int32_t failed_count,
                           const char *selected_id, BattbarMergedDevice *out_entries,
                           int32_t *out_count, int32_t *out_active);

/* ---- Bluetooth --------------------------------------------------------- */

/**
 * Read a battery percentage out of a flattened macOS attribute list.
 *
 * `keys` / `values` are parallel arrays of `count` NUL-terminated UTF-8
 * strings. Returns 0..100, or BATTBAR_ERROR_INVALID_ARGUMENT when absent.
 */
int32_t battbar_bluetooth_battery(int32_t count, const char *const *keys,
                                  const char *const *values);

/**
 * Charging flag from the same attribute list.
 *
 * Returns 1 (charging), 0 (not charging) or BATTBAR_ERROR_INVALID_ARGUMENT.
 */
int32_t battbar_bluetooth_charging(int32_t count, const char *const *keys,
                                   const char *const *values);

/** 1 when the name / minor type pair looks like a mouse, 0 otherwise. */
uint8_t battbar_bluetooth_is_likely_mouse(const char *name, const char *minor_type);

/**
 * Write the stable id for a macOS Bluetooth device into `out`.
 *
 * Returns the byte count written (excluding the NUL), or
 * BATTBAR_ERROR_INVALID_ARGUMENT when the buffer is too small.
 */
int32_t battbar_bluetooth_macos_id(const char *address, const char *name,
                                   char *out, size_t out_len);

/* ---- Low battery alerts ------------------------------------------------ */

/** Opaque alert manager state. */
typedef struct BattbarAlertManager BattbarAlertManager;

/** One device as far as alerting is concerned. */
typedef struct BattbarAlertDevice {
  /** Stable device id (NUL-terminated). */
  const char *id;
  /** Battery percentage, or a negative value when unknown. */
  int32_t battery;
  /** 1 charging, 0 not charging, negative unknown. */
  int32_t charging;
  /** Non-zero when the reading is a retained stale value. */
  uint8_t stale;
} BattbarAlertDevice;

/** Alert kind values written to `out_kinds`. */
#define BATTBAR_ALERT_NONE 0
#define BATTBAR_ALERT_LOW 1
#define BATTBAR_ALERT_CRITICAL 2

/** Create an alert manager. Returns NULL on allocation failure. */
BattbarAlertManager *battbar_alerts_new(void);

/** Release an alert manager created by battbar_alerts_new(). */
void battbar_alerts_free(BattbarAlertManager *manager);

/**
 * Evaluate one scan result.
 *
 * `out_kinds` receives one byte per device (BATTBAR_ALERT_*). Returns 0 on
 * success or BATTBAR_ERROR_INVALID_ARGUMENT.
 */
int32_t battbar_alerts_evaluate(BattbarAlertManager *manager,
                                const BattbarAlertDevice *devices, int32_t count,
                                uint8_t enabled, uint8_t *out_kinds);

/* ---- Helpers ----------------------------------------------------------- */

/**
 * Parse a percentage out of strings such as "75%".
 *
 * @return 0...100, or BATTBAR_ERROR_INVALID_ARGUMENT when unparseable.
 */
int32_t battbar_parse_percent(const char *text);

#ifdef __cplusplus
}
#endif

#endif /* BATTBAR_CORE_H */
