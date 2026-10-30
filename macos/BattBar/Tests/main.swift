import Foundation

var failures = 0
var checks = 0

func check(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition {
        failures += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    check(actual == expected, "\(message) (actual: \(actual), expected: \(expected))")
}

func bytes(_ hex: String) -> [UInt8] {
    var result: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        result.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
    }
    return result
}

// MARK: ATK

let atkRequest = ATKProtocol.batteryRequest()
checkEqual(atkRequest.count, 17, "ATK 请求长度包含 report ID")
checkEqual(Array(atkRequest.prefix(2)), [0x08, 0x04], "ATK 请求头")
checkEqual(atkRequest.last, 0x49, "ATK 电量请求校验和")
var atkSum = 0
for byte in atkRequest.dropLast() { atkSum += Int(byte) }
checkEqual(atkRequest.last, UInt8((0x55 - (atkSum & 0xff)) & 0xff), "ATK 校验和公式")

let atkSample = bytes("0804000000026401107200000000000060")
if case .success(let reading)? = ATKProtocol.decode(reportID: 8, bytes: atkSample) {
    checkEqual(reading.battery, 100, "ATK 电量解析")
    check(reading.charging, "ATK 充电状态解析")
} else {
    check(false, "ATK 正常响应应可解析")
}
if case .success(let reading)? = ATKProtocol.decode(reportID: 8, bytes: Array(atkSample.dropFirst())) {
    checkEqual(reading.battery, 100, "ATK 无 report ID 前缀时也能解析")
} else {
    check(false, "ATK 无 report ID 前缀应可解析")
}
if case .failure(.invalidStatus(1))? = ATKProtocol.decode(reportID: 8, bytes: [0x04, 0x01, 0, 0, 0, 50, 0]) {
    check(true, "ATK 状态码解析")
} else {
    check(false, "ATK 非零状态码应报错")
}
check(ATKProtocol.decode(reportID: 9, bytes: [0x09, 0x04, 0, 0, 0, 50, 0]) == nil, "ATK 忽略其他 report ID")
// Clamping now lives in the core; verify it through the decoder instead of a
// local helper.
if case .success(let low)? = ATKProtocol.decode(reportID: 8, bytes: [0x04, 0, 0, 0, 0, 0, 0]) {
    checkEqual(low.battery, 0, "电量下限")
} else {
    check(false, "电量下限应可解析")
}
if case .success(let high)? = ATKProtocol.decode(reportID: 8, bytes: [0x04, 0, 0, 0, 0, 250, 0]) {
    checkEqual(high.battery, 100, "电量上限（核心钳制到 100）")
} else {
    check(false, "电量上限应可解析")
}

// MARK: Razer

let razerBatteryRequest = RazerProtocol.request(
    commandClass: RazerProtocol.commandClass,
    commandID: RazerProtocol.batteryCommand
)
checkEqual(razerBatteryRequest.count, 90, "Razer 报告长度")
checkEqual(razerBatteryRequest[1], 0x1F, "Razer 事务 ID")
checkEqual(razerBatteryRequest[5], 2, "Razer data size")
checkEqual(razerBatteryRequest[6], 0x07, "Razer command class")
checkEqual(razerBatteryRequest[7], 0x80, "Razer 电量命令")
checkEqual(razerBatteryRequest[88], RazerProtocol.crc(razerBatteryRequest), "Razer CRC")
checkEqual(razerBatteryRequest[88], 0x85, "Razer 电量请求 CRC 向量")
var expectedCRC: UInt8 = 0
for index in 2..<88 { expectedCRC ^= razerBatteryRequest[index] }
checkEqual(razerBatteryRequest[88], expectedCRC, "Razer CRC 为 bytes[2..87] 异或")

var razerResponse = [UInt8](repeating: 0, count: 90)
razerResponse[0] = 0x02
razerResponse[1] = 0x1F
razerResponse[6] = 0x07
razerResponse[7] = 0x80
razerResponse[9] = 128
checkEqual(RazerProtocol.battery(from: razerResponse), 50, "Razer 电量缩放")
razerResponse[7] = 0x84
razerResponse[9] = 1
checkEqual(RazerProtocol.charging(from: razerResponse), true, "Razer 充电状态")
razerResponse[9] = 0
checkEqual(RazerProtocol.charging(from: razerResponse), false, "Razer 放电状态")

// MARK: Bluetooth

let bluetoothJSON = """
{
  "SPBluetoothDataType": [
    {
      "device_connected": [
        {
          "MX Master 3S": {
            "device_minorType": "Mouse",
            "device_batteryLevelMain": "75%",
            "device_address": "AA-BB-CC-DD-EE-FF",
            "device_charging": "Yes"
          },
          "Magic Keyboard": {
            "device_minorType": "Keyboard",
            "device_batteryLevelMain": "90%"
          },
          "AirPods Pro": {
            "device_minorType": "Headphones",
            "device_batteryLevelMain": "80%"
          }
        }
      ]
    }
  ]
}
"""
let bluetoothProvider = BluetoothProvider()
if let payload = try? JSONSerialization.jsonObject(with: Data(bluetoothJSON.utf8)) as? [String: Any] {
    let devices = bluetoothProvider.parseBluetoothPayload(payload)
    checkEqual(devices.count, 1, "蓝牙只保留鼠标")
    if let device = devices.first {
        checkEqual(device.battery, 75, "蓝牙电量解析")
        checkEqual(device.charging, true, "蓝牙充电状态")
        checkEqual(device.id, "bt-macos:aa-bb-cc-dd-ee-ff", "蓝牙稳定 ID")
        checkEqual(device.connection, .bluetooth, "蓝牙连接类型")
    }
} else {
    check(false, "蓝牙示例 JSON 应可解析")
}

let bluetoothObjectJSON = """
{
  "SPBluetoothDataType": {
    "device_connected": {
      "Razer Viper V3 Pro": {
        "device_minorType": "Mouse",
        "device_batteryLevelMain": "35%"
      }
    }
  }
}
"""
if let payload = try? JSONSerialization.jsonObject(with: Data(bluetoothObjectJSON.utf8)) as? [String: Any] {
    let devices = bluetoothProvider.parseBluetoothPayload(payload)
    checkEqual(devices.count, 1, "蓝牙 object 形式也能解析")
    checkEqual(devices.first?.battery, 35, "蓝牙 object 形式电量")
} else {
    check(false, "蓝牙 object 示例 JSON 应可解析")
}

// MARK: Settings

let suite = "battbar.tests.\(UUID().uuidString)"
if let defaults = UserDefaults(suiteName: suite) {
    defaults.removePersistentDomain(forName: suite)
    var settings = AppSettings()
    settings.refreshInterval = 45
    settings.selectedDeviceID = String(repeating: "x", count: 600)
    settings.sanitize()
    checkEqual(settings.refreshInterval, 60, "非法刷新间隔回落到 60")
    checkEqual(settings.selectedDeviceID, nil, "超长设备 ID 被清理")

    let store = SettingsStore(defaults: defaults)
    store.update { value in
        value.refreshInterval = 120
        value.selectedDeviceID = "atk:373b:101a:test"
        value.lowBatteryAlerts = false
    }
    let reloaded = SettingsStore(defaults: defaults)
    checkEqual(reloaded.settings.refreshInterval, 120, "设置持久化刷新间隔")
    checkEqual(reloaded.settings.selectedDeviceID, "atk:373b:101a:test", "设置持久化设备 ID")
    checkEqual(reloaded.settings.lowBatteryAlerts, false, "设置持久化提醒开关")
    defaults.removePersistentDomain(forName: suite)
} else {
    check(false, "无法创建测试 UserDefaults")
}

// MARK: Retry policy

checkEqual(
    CoreBridge.retryDelayMilliseconds(hasStaleDevice: true, alreadyRetried: false),
    15_000,
    "掉一次读数后 15 秒重试一次"
)
checkEqual(
    CoreBridge.retryDelayMilliseconds(hasStaleDevice: true, alreadyRetried: true),
    nil as Int?,
    "重试本身失败不再重试"
)
checkEqual(
    CoreBridge.retryDelayMilliseconds(hasStaleDevice: false, alreadyRetried: false),
    nil as Int?,
    "读数正常时不重试"
)

// MARK: Naming (the rule lives in the core, reached through the C ABI)

let dongle = CoreBridge.atkDisplayName(product: "ATK Mouse 1K Dongle")
checkEqual(dongle.name, "ATK 无线鼠标", "接收器产品串回退为品牌 + 无线鼠标")
checkEqual(dongle.subtitle, "ATK Mouse 1K Dongle", "原始产品串保留为副标题")
checkEqual(CoreBridge.atkDisplayName(product: "VXE R1 Pro Dongle").name, "VXE 无线鼠标", "VXE 接收器品牌")
checkEqual(CoreBridge.atkDisplayName(product: "MAD R 8K").name, "MAD R 8K", "没有 dongle 字样的产品串原样显示")
checkEqual(
    CoreBridge.atkDisplayName(product: "ATK Mouse 2K 接收器").name,
    "ATK 无线鼠标",
    "中文「接收器」也按接收器处理"
)
let atkEmpty = CoreBridge.atkDisplayName(product: "")
checkEqual(atkEmpty.name, "ATK 无线鼠标", "空产品串回退")
checkEqual(atkEmpty.subtitle, "ATK HID", "空产品串的副标题")

checkEqual(
    CoreBridge.razerDisplayName(product: "Razer DeathAdder V3 Pro", productID: 0x1234).name,
    "Razer DeathAdder V3 Pro",
    "已知 Razer 产品串原样显示"
)
checkEqual(
    CoreBridge.razerDisplayName(product: "Razer HyperPolling Wireless Dongle", productID: 0x00C1).name,
    "Razer Viper V3 Pro",
    "按 PID 认出 Viper V3 Pro"
)
let razerEmpty = CoreBridge.razerDisplayName(product: "", productID: 0x1234)
checkEqual(razerEmpty.name, "Razer 无线鼠标", "空 Razer 产品串回退")
checkEqual(razerEmpty.subtitle, "Razer HyperPolling", "空 Razer 产品串的副标题")

// MARK: Device ids (also a core rule: same format as the legacy app)

checkEqual(
    CoreBridge.atkDeviceID(
        vendorID: 0x373b,
        productID: 0x101a,
        serialNumber: "ABC",
        product: "ATK Mouse 1K Dongle"
    ),
    "atk:373b:101a:ABC",
    "ATK 有序列号时用序列号"
)
checkEqual(
    CoreBridge.atkDeviceID(
        vendorID: 0x373b,
        productID: 0x101a,
        serialNumber: "",
        product: "ATK Mouse 1K Dongle"
    ),
    "atk:373b:101a:536b2ba7",
    "ATK 无序列号时用产品指纹"
)
checkEqual(
    CoreBridge.razerDeviceID(vendorID: 0x1532, productID: 0x00C1),
    "razer:1532:c1",
    "Razer 用十六进制 vid:pid"
)

if failures == 0 {
    print("PASS \(checks) checks")
    exit(0)
} else {
    print("FAILED \(failures)/\(checks) checks")
    exit(1)
}
