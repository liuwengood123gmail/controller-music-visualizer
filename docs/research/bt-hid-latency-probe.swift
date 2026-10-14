// 蓝牙 DualSense：HID 输出报告 / 特征报告的单次调用耗时分布，以及输入报告的到达速率。
//
// 要验证什么（对应 docs/research/bluetooth-audio-findings.md 方向 B）：
//   1. 输出报告 0x31 每次 IOHIDDeviceSetReport 耗时是否集中在 ~14.4ms 的整数倍（= 链路每 ~14.4ms 才有一次发送机会，
//      典型的 sniff 模式表现）。
//   2. 特征报告 GetReport（走控制通道、必须等设备应答）的耗时，与输出报告对比：
//      两者耗时相同 → 输出报告很可能也走了需要应答的控制通道（SET_REPORT）；
//      输出报告明显更快 → 输出报告走的是中断通道（DATA），瓶颈在链路层。
//   3. 手柄 → Mac 的输入报告到达速率：DualSense 在活动（非 sniff）链路下输入报告通常是每秒 ~100–250 个；
//      如果这里只有 ~70/s（与 14.4ms 对应），说明 sniff 同时限制了两个方向。
//
// 怎么运行：手柄蓝牙连接，关掉本项目 App，拔掉 USB 线；
//   swiftc -swift-version 5 -O bt-hid-latency-probe.swift -o hid-latency && ./hid-latency
//   可选：对比 Wi-Fi 开 / 关（菜单栏关掉 Wi-Fi 再跑一次）。
//
// 怎么解读输出：
//   「输入报告」一行 < 100/s 且「输出 0x31」中位数 ≈ 14ms → sniff 嫌疑很大（去做 PacketLogger 抓包确认）。
//   「输入报告」≥ 200/s 但输出仍是 ~14ms 的整数倍 → 瓶颈在发送侧（控制通道握手 / 发送队列），不是 sniff。
//   「特征报告 0x20」中位数 ≈ 「输出 0x31」中位数 → 两者走同一类事务。
//
// 安全：只发「空」0x31 报告（所有生效标志位为 0），读的是固件信息 / 校准特征报告，不写任何配置。
import Foundation
import IOKit.hid
setvbuf(stdout, nil, _IONBF, 0)

let crcTable: [UInt32] = (0..<256).map { i in var c = UInt32(i); for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }; return c }
func crc32(_ b: [UInt8]) -> UInt32 { var c: UInt32 = 0xFFFF_FFFF; for x in b { c = crcTable[Int((c ^ UInt32(x)) & 0xFF)] ^ (c >> 8) }; return c ^ 0xFFFF_FFFF }
func empty31(_ seq: UInt8) -> [UInt8] {
  var r = [UInt8](repeating: 0, count: 78); r[0] = 0x31; r[1] = seq << 4; r[2] = 0x10
  let c = crc32([0xA2] + r[0..<74]); for i in 0..<4 { r[74 + i] = UInt8(truncatingIfNeeded: c >> (8 * UInt32(i))) }
  return r
}

let mgr = IOHIDManagerCreate(kCFAllocatorDefault, 0)
IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: 0x054C, kIOHIDProductIDKey: 0x0CE6] as CFDictionary)
IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
IOHIDManagerOpen(mgr, 0)
RunLoop.main.run(until: Date().addingTimeInterval(0.5))
guard let dev = (IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>)?.first(where: {
  ((IOHIDDeviceGetProperty($0, kIOHIDTransportKey as CFString) as? String) ?? "").localizedCaseInsensitiveContains("Bluetooth")
}) else { print("没有找到蓝牙连接的 DualSense（请拔掉 USB 线，按一下 PS 键）"); exit(1) }
IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

func summary(_ ms: [Double]) -> String {
  guard !ms.isEmpty else { return "没有成功的调用" }
  let s = ms.sorted()
  func p(_ q: Double) -> Double { s[min(Int(Double(s.count - 1) * q), s.count - 1)] }
  return String(format: "n=%d 中位数 %.1f ms，p10 %.1f，p90 %.1f，最大 %.1f", s.count, p(0.5), p(0.1), p(0.9), s.last!)
}
func histogram(_ ms: [Double], bucket: Double = 7.2) -> String {
  // 以 7.2ms（半个 14.4ms）为桶：如果耗时集中在 14.4 / 28.8 / 43.2 … 附近，会在对应桶里出现尖峰
  var counts: [Int: Int] = [:]
  for v in ms { counts[Int(v / bucket), default: 0] += 1 }
  return counts.keys.sorted().map { String(format: "  %5.1f–%5.1f ms: %d", Double($0) * bucket, Double($0 + 1) * bucket, counts[$0]!) }.joined(separator: "\n")
}

// 1. 输出报告 0x31（78 字节，空）
var out31: [Double] = []
var seq: UInt8 = 0
for _ in 0..<300 {
  let r = empty31(seq); seq = (seq + 1) & 0x0F
  let t = Date()
  if IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x31, r, r.count) == kIOReturnSuccess { out31.append(Date().timeIntervalSince(t) * 1000) }
}
print("输出 0x31（78 字节，空报告）单次调用耗时：" + summary(out31))
print(histogram(out31))

// 2. 特征报告（控制通道 GET_REPORT）：0x20 固件信息、0x05 校准数据
for id: UInt8 in [0x20, 0x05] {
  var ms: [Double] = []
  for _ in 0..<60 {
    var buf = [UInt8](repeating: 0, count: 64); var len: CFIndex = 64
    let t = Date()
    if IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, CFIndex(id), &buf, &len) == kIOReturnSuccess { ms.append(Date().timeIntervalSince(t) * 1000) }
  }
  print(String(format: "特征报告 0x%02X GetReport 单次耗时：", id) + summary(ms))
}

// 3. 输入报告到达速率（先静默 3 秒，再在持续发送输出报告时测 3 秒）
final class Counter { var n = 0 }
let counter = Counter()
let inBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 128)
IOHIDDeviceRegisterInputReportCallback(dev, inBuf, 128, { ctx, _, _, _, _, _, _ in
  Unmanaged<Counter>.fromOpaque(ctx!).takeUnretainedValue().n += 1
}, Unmanaged.passUnretained(counter).toOpaque())

counter.n = 0
RunLoop.main.run(until: Date().addingTimeInterval(3))
print(String(format: "输入报告到达速率（静默，没有输出流量）：%.0f 个/秒", Double(counter.n) / 3))

counter.n = 0
let end = Date().addingTimeInterval(3)
while Date() < end {
  let r = empty31(seq); seq = (seq + 1) & 0x0F
  _ = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x31, r, r.count)
  RunLoop.main.run(until: Date().addingTimeInterval(0.0005))
}
print(String(format: "输入报告到达速率（同时连续发送输出报告）：%.0f 个/秒", Double(counter.n) / 3))
print("解读见文件开头注释。把整段输出贴回 docs/research/bluetooth-audio-findings.md 的「本机数据」一节。")
