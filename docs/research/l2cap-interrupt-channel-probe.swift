// 方向 C：能不能通过 IOBluetooth 直接打开 DualSense 的 HID L2CAP 通道（Linux 的做法），绕开系统 HID 驱动。
//
// 要验证什么：
//   1. 系统自己打开 HID 通道时，IOBluetooth 的「通道打开通知」能不能看到（说明能不能拿到系统已经打开的通道）。
//   2. 在系统 HID 驱动已经持有控制 / 中断通道（PSM 0x11 / 0x13）的情况下，再打开一条同 PSM 的通道会得到什么错误码。
//   3. 如果某条通道打开成功：用 writeSync 按 10.667ms 节奏写「空」0x36 报告（前缀 0xA2 = HIDP DATA|Output），
//      统计吞吐量，与 IOHIDDeviceSetReport 的 ~5 KB/s 对比。
//
// 怎么运行：手柄蓝牙连接，关掉本项目 App；
//   swiftc -swift-version 5 -O l2cap-interrupt-channel-probe.swift -framework IOBluetooth -o l2cap-probe && ./l2cap-probe
//   首次运行 macOS 可能弹出「蓝牙」权限提示，请允许终端使用蓝牙。
//
// 怎么解读输出：
//   「PSM 0x13 打开失败：…」  → 系统 HID 驱动独占了中断通道，方向 C 在不让出 HID 驱动的前提下走不通；
//                              把错误码贴回 findings。
//   「PSM 0x13 已打开」且吞吐量 ≫ 5 KB/s（≥ 30 KB/s）→ 方向 C 可行，立刻回报（这是最重要的结果）。
//   「PSM 0x13 已打开」但吞吐量仍 ≈ 5 KB/s → 瓶颈在链路层（sniff / 单时隙包），与通道无关 → 去做 PacketLogger 抓包。
//
// 安全：只写「空」0x36 报告（没有任何子包，手柄不会有反应）。额外打开 HID 通道可能让手柄断开蓝牙连接——
//       发生时按一下手柄 PS 键重新连接即可。程序结束前会关闭它打开的通道。
import Foundation
import IOBluetooth
setvbuf(stdout, nil, _IONBF, 0)

let crcTable: [UInt32] = (0..<256).map { i in var c = UInt32(i); for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }; return c }
func crc32(_ b: [UInt8]) -> UInt32 { var c: UInt32 = 0xFFFF_FFFF; for x in b { c = crcTable[Int((c ^ UInt32(x)) & 0xFF)] ^ (c >> 8) }; return c ^ 0xFFFF_FFFF }
/// 空的 0x36 报告（398 字节，只有报告头和 CRC），前面加 0xA2（HIDP：DATA | Output）
func empty36(_ seq: UInt8) -> [UInt8] {
  var r = [UInt8](repeating: 0, count: 398); r[0] = 0x36; r[1] = seq << 4
  let c = crc32([0xA2] + r[0..<394]); for i in 0..<4 { r[394 + i] = UInt8(truncatingIfNeeded: c >> (8 * UInt32(i))) }
  return [0xA2] + r
}

final class Probe: NSObject {
  var token: IOBluetoothUserNotification?
  var openStatus: [UInt16: IOReturn] = [:]
  @objc func channelOpened(_ note: IOBluetoothUserNotification!, _ channel: IOBluetoothL2CAPChannel!) {
    print("[通知] 有 L2CAP 通道打开：PSM 0x\(String(channel.psm, radix: 16))，本地 CID \(channel.localChannelID)，"
          + "远端 CID \(channel.remoteChannelID)，outgoing MTU \(channel.outgoingMTU)，\(channel.isIncoming() ? "入站" : "出站")")
  }
  @objc func l2capChannelOpenComplete(_ l2capChannel: IOBluetoothL2CAPChannel!, status error: IOReturn) {
    print("[委托] 通道打开完成：PSM 0x\(String(l2capChannel.psm, radix: 16))，状态 0x\(String(UInt32(bitPattern: error), radix: 16))")
  }
  @objc func l2capChannelData(_ l2capChannel: IOBluetoothL2CAPChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
    // 必须有「接收数据」的委托通道才会完成配置；这里只是丢弃
  }
  @objc func l2capChannelClosed(_ l2capChannel: IOBluetoothL2CAPChannel!) {
    print("[委托] 通道已关闭：PSM 0x\(String(l2capChannel.psm, radix: 16))")
  }
}

func hex(_ r: IOReturn) -> String { "0x" + String(UInt32(bitPattern: r), radix: 16) }

let probe = Probe()
// 1. 监听任何 L2CAP 通道的打开（PSM 传 0 = 不限）
probe.token = IOBluetoothL2CAPChannel.register(forChannelOpenNotifications: probe, selector: #selector(Probe.channelOpened(_:_:)),
                                               withPSM: 0, direction: kIOBluetoothUserNotificationChannelDirectionAny)
print("已注册通道打开通知：\(probe.token != nil ? "成功" : "失败")")

guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice],
      let pad = devices.first(where: { ($0.name ?? "").contains("Wireless Controller") && $0.isConnected() }) else {
  print("没有找到已连接的 DualSense（名称应包含 Wireless Controller）。已配对设备：")
  for d in (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? [] { print("  \(d.nameOrAddress ?? "?") 已连接=\(d.isConnected())") }
  exit(1)
}
print("找到 \(pad.nameOrAddress ?? "?")，地址 \(pad.addressString ?? "?")，连接句柄 \(pad.connectionHandle)，"
      + "链路类型 \(pad.getLinkType())，加密模式 \(pad.getEncryptionMode())，RSSI \(pad.rawRSSI())")
RunLoop.main.run(until: Date().addingTimeInterval(1))

// 2. 尝试打开 HID 控制通道 0x11 / 中断通道 0x13
var channels: [UInt16: IOBluetoothL2CAPChannel] = [:]
for psm: UInt16 in [0x13, 0x11] {
  var ch: IOBluetoothL2CAPChannel?
  let r = pad.openL2CAPChannelSync(&ch, withPSM: BluetoothL2CAPPSM(psm), delegate: probe)
  if r == kIOReturnSuccess, let ch {
    print("PSM 0x\(String(psm, radix: 16)) 已打开：outgoing MTU \(ch.outgoingMTU)，incoming MTU \(ch.incomingMTU)")
    channels[psm] = ch
  } else {
    print("PSM 0x\(String(psm, radix: 16)) 打开失败：\(hex(r))")
  }
  RunLoop.main.run(until: Date().addingTimeInterval(0.5))
}

// 3. 对打开成功的中断通道（0x13）测吞吐量
if let intr = channels[0x13] {
  var seq: UInt8 = 0, ok = 0, fail = 0
  var worst = 0.0
  let interval = 512.0 / 48000.0
  let start = Date(); var next = start
  while Date().timeIntervalSince(start) < 5 {
    var pkt = empty36(seq); seq = (seq + 1) & 0x0F
    let t = Date()
    let r = intr.writeSync(&pkt, length: UInt16(pkt.count))
    worst = max(worst, Date().timeIntervalSince(t) * 1000)
    if r == kIOReturnSuccess { ok += 1 } else { fail += 1 }
    next = next.addingTimeInterval(interval)
    RunLoop.main.run(until: next)
  }
  let secs = Date().timeIntervalSince(start)
  print(String(format: "中断通道 writeSync（398 字节空 0x36，目标 94 包/秒）：成功 %d、失败 %d，%.1f 包/秒，约 %.1f KB/s，单次最长 %.1f ms",
               ok, fail, Double(ok) / secs, Double(ok) * 399 / 1024 / secs, worst))
} else {
  print("没有可用的中断通道，跳过吞吐量测试。")
}

for (_, ch) in channels { _ = ch.close() }
RunLoop.main.run(until: Date().addingTimeInterval(0.5))
print("完成。解读见文件开头注释。")
