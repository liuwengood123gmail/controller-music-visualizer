// 蓝牙 DualSense 输出报告发送速率测试（只发「空报告」：所有生效标志位为 0，手柄不会有任何反应）
// 用途：测量 macOS 通过 IOHIDDeviceSetReport 向蓝牙 DualSense 发送各种大小报告的速率 / 吞吐量。
// 运行：手柄蓝牙连接，App 停止；swiftc -swift-version 5 -O bt-send-rate-probe.swift -o probe && ./probe
// 2026-10 本机结果见 docs/bluetooth-audio-research.md §2：吞吐量约 5 KB/s，与报告大小无关。
import Foundation
import IOKit.hid
setvbuf(stdout, nil, _IONBF, 0)
let crcTable: [UInt32] = (0..<256).map { i in var c = UInt32(i); for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }; return c }
func crc32(_ b: ArraySlice<UInt8>) -> UInt32 { var c: UInt32 = 0xFFFF_FFFF; for x in b { c = crcTable[Int((c ^ UInt32(x)) & 0xFF)] ^ (c >> 8) }; return c ^ 0xFFFF_FFFF }
func withCRC(_ r: inout [UInt8]) { let n = r.count - 4; let c = crc32(([0xA2] + r[0..<n])[...]); for i in 0..<4 { r[n + i] = UInt8(truncatingIfNeeded: c >> (8 * UInt32(i))) } }

let mgr = IOHIDManagerCreate(kCFAllocatorDefault, 0)
IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: 0x054C, kIOHIDProductIDKey: 0x0CE6] as CFDictionary)
IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
IOHIDManagerOpen(mgr, 0)
RunLoop.main.run(until: Date().addingTimeInterval(0.5))   // 挂到事件循环后，设备要等事件循环跑一下才出现
guard let dev = (IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>)?.first(where: { ((IOHIDDeviceGetProperty($0, kIOHIDTransportKey as CFString) as? String) ?? "").localizedCaseInsensitiveContains("Bluetooth") }) else {
  print("没有找到蓝牙连接的 DualSense（请拔掉 USB 线，按一下 PS 键）"); exit(1) }
IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

// 空报告：0x31（78 字节，所有「生效」标志位为 0，不改变任何东西）；0x36（398 字节，只有报告头，不含任何子包）
func empty31(_ seq: UInt8) -> [UInt8] { var r = [UInt8](repeating: 0, count: 78); r[0] = 0x31; r[1] = seq << 4; r[2] = 0x10; withCRC(&r); return r }
func empty36(_ seq: UInt8) -> [UInt8] { var r = [UInt8](repeating: 0, count: 398); r[0] = 0x36; r[1] = seq << 4; withCRC(&r); return r }

func syncTest(_ name: String, _ make: (UInt8) -> [UInt8]) {
  var seq: UInt8 = 0, ok = 0, fail = 0; var maxMs = 0.0
  let end = Date().addingTimeInterval(3)
  while Date() < end {
    let r = make(seq); seq = (seq + 1) & 0x0F
    let t = Date()
    if IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, CFIndex(r[0]), r, r.count) == kIOReturnSuccess { ok += 1 } else { fail += 1 }
    maxMs = max(maxMs, Date().timeIntervalSince(t) * 1000)
  }
  print(String(format: "同步 %@：每秒 %.0f 包（失败 %d），单次最长 %.1f ms", name, Double(ok) / 3, fail, maxMs))
}

final class Ctx { var done = 0; var fail = 0; var inflight = 0 }
let ctx = Ctx()
let cb: IOHIDReportCallback = { context, result, _, _, _, _, _ in
  let c = Unmanaged<Ctx>.fromOpaque(context!).takeUnretainedValue()
  c.inflight -= 1
  if result == kIOReturnSuccess { c.done += 1 } else { c.fail += 1 }
}
func asyncTest(_ name: String, _ make: (UInt8) -> [UInt8]) {
  ctx.done = 0; ctx.fail = 0; ctx.inflight = 0
  var seq: UInt8 = 0, submitted = 0, rejected = 0
  var buffers: [UnsafeMutablePointer<UInt8>] = []
  let interval = 512.0 / 48000.0   // 按真实节奏：每 10.667ms 提交一包
  var next = Date()
  let end = Date().addingTimeInterval(3)
  while Date() < end {
    RunLoop.main.run(until: next)
    next = next.addingTimeInterval(interval)
    if ctx.inflight > 16 { continue }   // 防止无限堆积
    let r = make(seq); seq = (seq + 1) & 0x0F
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: r.count); buf.initialize(from: r, count: r.count); buffers.append(buf)
    let s = IOHIDDeviceSetReportWithCallback(dev, kIOHIDReportTypeOutput, CFIndex(r[0]), buf, r.count, 1.0, cb, Unmanaged.passUnretained(ctx).toOpaque())
    if s == kIOReturnSuccess { submitted += 1; ctx.inflight += 1 } else { rejected += 1 }
  }
  RunLoop.main.run(until: Date().addingTimeInterval(1))
  print(String(format: "异步 %@（目标每秒 94 包）：提交 %d、完成 %d（每秒 %.0f）、失败 %d、提交被拒 %d、积压 %d", name, submitted, ctx.done, Double(ctx.done) / 3, ctx.fail, rejected, ctx.inflight))
  buffers.forEach { $0.deallocate() }
}

print("各种大小的空报告，同步发送各 2 秒：")
let sizes: [(UInt8, Int)] = [(0x31, 78), (0x32, 142), (0x33, 206), (0x34, 270), (0x35, 334), (0x36, 398), (0x37, 462), (0x38, 526), (0x39, 547)]
for (id, n) in sizes {
  var seq: UInt8 = 0, ok = 0
  let end = Date().addingTimeInterval(2)
  while Date() < end {
    var r = [UInt8](repeating: 0, count: n); r[0] = id; r[1] = seq << 4; if id == 0x31 { r[2] = 0x10 }; withCRC(&r); seq = (seq + 1) & 0x0F
    if IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, CFIndex(id), r, r.count) == kIOReturnSuccess { ok += 1 }
  }
  let rate = Double(ok) / 2
  print(String(format: "  0x%02X %3d 字节：每秒 %5.1f 包，约 %4.1f KB/s", id, n, rate, rate * Double(n) / 1024))
}
