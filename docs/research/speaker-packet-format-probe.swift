// 蓝牙 DualSense 扬声器：数据包格式与「手柄接受什么样的 Opus 帧」的实验（方向 E 的核心，也验证 Linux 项目的格式在 macOS 上能不能用）。
//
// 要验证什么：
//   1. 按 Linux 项目（mdrv-ds-linux / LinuxAudio4Dualsense5）的格式构造扬声器报告，经 macOS 的 IOHIDDeviceSetReport 发给手柄，
//      手柄扬声器能不能出声（macOS 的发送速率只有 ~5 KB/s，声音会是断续的「嘀嘀」声——这里验证的是格式，不是连续性）。
//   2. 手柄是否接受不同的 Opus 帧长（10/20/40/60 ms）、不同码率（字节数）、不同大小的报告（0x32…0x36）。
//      能接受的组合决定了「在 ~5 KB/s 内省流播放」是否可行（见 findings 方向 E 的预算表）。
//
// 怎么编译运行（需要 libopus：brew install opus；蓝牙连接手柄；关掉本项目 App）：
//   cd docs/research
//   clang -c opus-shim.c -I/opt/homebrew/include -o opus-shim.o
//   swiftc -swift-version 5 -O -import-objc-header opus-shim.h speaker-packet-format-probe.swift opus-shim.o \
//          -L/opt/homebrew/lib -lopus -o speaker-probe
//   ./speaker-probe --report 35 --frame-ms 10 --bitrate 160000      # Linux 项目的参数
//   ./speaker-probe --report 33 --frame-ms 60 --bitrate 24000       # 省流参数：60ms 帧、24kbps（180 字节）
//   参数：--report 32|33|34|35|36   --frame-ms 10|20|40|60   --bitrate <bps>   --vbr   --seconds N   --tone-hz F
//         --interval-ms M（发送间隔，默认等于帧长）
//
// 怎么解读输出：
//   程序会打印每个编码帧的字节数、报告大小、实际发出的报告数。听手柄扬声器：
//   - 完全没有声音：格式不被接受（或扬声器通路没开）。换 --report 35 --frame-ms 10 --bitrate 160000 确认基线，
//     基线也没声 → 说明本程序的报告格式与手柄期望不一致（欢迎把现象贴回 findings）。
//   - 有断续的 440Hz 声音：格式被接受。再依次试表中的省流组合，记录哪些组合有声。
//   - 听到声音「变调 / 沙沙」：记录组合；帧长不被支持时常见。
//
// 安全：音量很小（音调幅度 0.1，手柄硬件音量 0x50），3 秒后自动发送「关闭扬声器」；不写任何固件 / 配置报告。
//
// 报告格式（来自 mdrv-ds-linux src/audio.rs audio_report / audio_report_036_bt 的公开代码，细节见 findings）：
//   [0] 报告 ID  [1] 序号<<4  [2] 0x91（控制子包，带长度） [3] 0x07  [4] 0xFE（音频段使能，bit0 清零 = 不开麦克风）
//   [5..9] 缓冲长度（64 ×5）  [10] 包计数
//   [11] 0x93（扬声器子包，带长度）  [12] Opus 字节数  [13..] Opus 帧   末 4 字节：CRC-32（种子 0xA2，小端）
import Foundation
import IOKit.hid
setvbuf(stdout, nil, _IONBF, 0)

// MARK: 参数
var reportID: UInt8 = 0x35, frameMs = 10, bitrate = 160_000, seconds = 3.0, toneHz = 440.0, vbr = false
var intervalMs: Double? = nil
var args = CommandLine.arguments.dropFirst()
while let a = args.popFirst() {
  switch a {
  case "--report": if let v = args.popFirst(), let n = UInt8(v, radix: 16) { reportID = n }
  case "--frame-ms": if let v = args.popFirst(), let n = Int(v) { frameMs = n }
  case "--bitrate": if let v = args.popFirst(), let n = Int(v) { bitrate = n }
  case "--seconds": if let v = args.popFirst(), let n = Double(v) { seconds = n }
  case "--tone-hz": if let v = args.popFirst(), let n = Double(v) { toneHz = n }
  case "--interval-ms": if let v = args.popFirst(), let n = Double(v) { intervalMs = n }
  case "--vbr": vbr = true
  default: print("未知参数 \(a)")
  }
}
let reportSizes: [UInt8: Int] = [0x32: 142, 0x33: 206, 0x34: 270, 0x35: 334, 0x36: 398, 0x37: 462, 0x38: 526, 0x39: 547]
guard let reportSize = reportSizes[reportID] else { print("不支持的报告 ID"); exit(1) }

// MARK: CRC
let crcTable: [UInt32] = (0..<256).map { i in var c = UInt32(i); for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }; return c }
func crc32(_ b: [UInt8]) -> UInt32 { var c: UInt32 = 0xFFFF_FFFF; for x in b { c = crcTable[Int((c ^ UInt32(x)) & 0xFF)] ^ (c >> 8) }; return c ^ 0xFFFF_FFFF }
func putCRC(_ r: inout [UInt8]) {
  let n = r.count - 4
  let c = crc32([0xA2] + r[0..<n]); for i in 0..<4 { r[n + i] = UInt8(truncatingIfNeeded: c >> (8 * UInt32(i))) }
}

// MARK: 0x31 报告：打开 / 关闭扬声器通路（与本项目 DualSenseReport 的 0x31 布局一致）
func report31(speakerOn: Bool, seq: UInt8) -> [UInt8] {
  var c = [UInt8](repeating: 0, count: 47)
  if speakerOn {
    c[0] = 0x20 | 0x80      // 扬声器音量、音频输出路径生效
    c[1] = 0x80             // 前置放大生效
    c[5] = 0x50             // 扬声器音量（mdrv 项目用 0x50）
    c[7] = 3 << 4           // 路径 3：耳机静音，扬声器 ← 右声道
    c[37] = 2               // 前置放大
  } else {
    c[0] = 0x80; c[7] = 0   // 路径 0：扬声器静音
  }
  var r = [0x31, seq << 4, 0x10] + c + [UInt8](repeating: 0, count: 24) + [0, 0, 0, 0]
  putCRC(&r)
  return r
}

// MARK: 扬声器报告
func audioReport(seq: UInt8, counter: UInt8, opus: [UInt8]) -> [UInt8]? {
  guard 13 + opus.count + 4 <= reportSize, opus.count < 256 else { return nil }
  var r = [UInt8](repeating: 0, count: reportSize)
  r[0] = reportID; r[1] = seq << 4
  r[2] = 0x91; r[3] = 0x07; r[4] = 0xFE
  for i in 5...9 { r[i] = 64 }
  r[10] = counter
  r[11] = 0x93; r[12] = UInt8(opus.count)
  for (i, b) in opus.enumerated() { r[13 + i] = b }
  putCRC(&r)
  return r
}

// MARK: 设备
let mgr = IOHIDManagerCreate(kCFAllocatorDefault, 0)
IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: 0x054C, kIOHIDProductIDKey: 0x0CE6] as CFDictionary)
IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
IOHIDManagerOpen(mgr, 0)
RunLoop.main.run(until: Date().addingTimeInterval(0.5))
guard let dev = (IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>)?.first(where: {
  ((IOHIDDeviceGetProperty($0, kIOHIDTransportKey as CFString) as? String) ?? "").localizedCaseInsensitiveContains("Bluetooth")
}) else { print("没有找到蓝牙连接的 DualSense"); exit(1) }
IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

func send(_ r: [UInt8]) -> Bool {
  IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, CFIndex(r[0]), r, r.count) == kIOReturnSuccess
}

// MARK: Opus 编码器
var err: Int32 = 0
guard let enc = shim_encoder_create(48000, 2, &err), err == 0 else { print("创建 Opus 编码器失败：\(err)"); exit(1) }
_ = shim_set_bitrate(enc, Int32(bitrate))
_ = shim_set_vbr(enc, vbr ? 1 : 0)
let frameSamples = 48 * frameMs
let pitch = toneHz * 48000 / 45000   // 手柄 DAC 实际按 45kHz 播放（mdrv 项目的音高补偿）
var phase = 0.0

func nextFrame() -> [UInt8]? {
  var pcm = [Int16](repeating: 0, count: frameSamples * 2)
  for i in 0..<frameSamples {
    let v = Int16(0.1 * sin(phase) * 32767)
    pcm[2 * i] = v; pcm[2 * i + 1] = v
    phase += 2 * .pi * pitch / 48000
  }
  var out = [UInt8](repeating: 0, count: 400)
  let n = shim_encode(enc, pcm, Int32(frameSamples), &out, 400)
  return n > 0 ? Array(out[0..<Int(n)]) : nil
}

// MARK: 实验
print("报告 0x\(String(reportID, radix: 16))（\(reportSize) 字节），帧长 \(frameMs)ms，目标码率 \(bitrate) bps，\(vbr ? "VBR" : "CBR")")
var seq: UInt8 = 0
for _ in 0..<3 { _ = send(report31(speakerOn: true, seq: seq)); seq = (seq + 1) & 0x0F; RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

let interval = (intervalMs ?? Double(frameMs)) / 1000
var sent = 0, failed = 0, tooBig = 0, counter: UInt8 = 0
var sizes = Set<Int>()
let start = Date(); var next = start
while Date().timeIntervalSince(start) < seconds {
  guard let frame = nextFrame() else { print("编码失败"); break }
  sizes.insert(frame.count)
  if let r = audioReport(seq: seq, counter: counter, opus: frame) {
    if send(r) { sent += 1 } else { failed += 1 }
    seq = (seq + 1) & 0x0F; counter &+= 1
  } else { tooBig += 1 }
  next = next.addingTimeInterval(interval)
  RunLoop.main.run(until: next)
}
let secs = Date().timeIntervalSince(start)
print("Opus 帧字节数：\(sizes.sorted())（CBR 应只有一个值）")
print(String(format: "发出报告 %d、失败 %d、Opus 帧放不进报告 %d；%.1f 报告/秒，音频占比 %.0f%%（每个报告承载 %d ms 音频）",
             sent, failed, tooBig, Double(sent) / secs, Double(sent) * Double(frameMs) / 10 / secs, frameMs))
_ = send(report31(speakerOn: false, seq: seq))
shim_destroy(enc)
print("已发送「关闭扬声器」。解读见文件开头注释。")
