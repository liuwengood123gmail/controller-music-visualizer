// 方向 A：CoreHaptics 的「音频事件」能不能经由 GameController 的手柄引擎从 DualSense 扬声器出声？
//
// 要验证什么：
//   对每个触觉位置（default / handles / leftHandle / rightHandle / 扳机），创建手柄的 CHHapticEngine，
//   注册一段很轻的 880Hz 提示音（0.3 秒、振幅 0.05），再用 .audioCustom 事件播放。
//   看每一步是否报错、报什么错（4097 = 手柄的触觉服务不支持该操作，之前对 AdvancedPatternPlayer 就是这个错）。
//
// 怎么运行：手柄蓝牙或 USB 连接，关掉本项目 App；
//   swiftc -swift-version 5 -O corehaptics-audio-probe.swift -o ch-audio && ./ch-audio
//
// 怎么解读输出：
//   所有位置都在「注册音频资源」或「播放」处报错 → Apple 没有公开的「手柄扬声器音频」入口（方向 A 的这条路不通）。
//   某个位置没有报错 → 仔细听手柄扬声器是否发出 0.3 秒的轻微提示音，并回报是哪个位置、蓝牙还是 USB。
//   同时请在运行期间用 PacketLogger 抓包（见 bluetooth-audio-local-checklist.md 第 3 步），
//   看蓝牙下 CoreHaptics 播放期间手柄收到的是什么报告、多快。
//
// 安全：声音很轻、很短；不修改手柄任何配置。
import Foundation
import GameController
import CoreHaptics
setvbuf(stdout, nil, _IONBF, 0)

GCController.shouldMonitorBackgroundEvents = true
GCController.startWirelessControllerDiscovery {}
RunLoop.main.run(until: Date().addingTimeInterval(1.5))

guard let pad = GCController.controllers().first(where: { $0.extendedGamepad is GCDualSenseGamepad }) else {
  print("没有找到 DualSense（GameController 看不到它）"); exit(1)
}
guard let haptics = pad.haptics else { print("pad.haptics == nil：此手柄没有提供触觉信息"); exit(1) }
print("手柄：\(pad.vendorName ?? "?")，支持的触觉位置：\(haptics.supportedLocalities.map { $0.rawValue })")

/// 写一段 16 位单声道 48kHz 的 880Hz 提示音 WAV
func makeTone() -> URL {
  let rate = 48000, n = 14400   // 0.3 秒
  var pcm = [Int16](repeating: 0, count: n)
  for i in 0..<n {
    let env = min(1, Double(i) / 480) * min(1, Double(n - i) / 480)   // 10ms 淡入淡出
    pcm[i] = Int16(0.05 * env * sin(2 * .pi * 880 * Double(i) / Double(rate)) * 32767)
  }
  var d = Data()
  func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
  func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
  d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + n * 2)); d.append("WAVEfmt ".data(using: .ascii)!)
  u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
  d.append("data".data(using: .ascii)!); u32(UInt32(n * 2))
  pcm.withUnsafeBytes { d.append(contentsOf: $0) }
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("ch-audio-probe-tone.wav")
  try? d.write(to: url)
  return url
}
let tone = makeTone()

let localities: [(String, GCHapticsLocality)] = [("default", .default), ("handles", .handles),
                                                  ("leftHandle", .leftHandle), ("rightHandle", .rightHandle),
                                                  ("leftTrigger", .leftTrigger), ("rightTrigger", .rightTrigger)]
var engines: [CHHapticEngine] = []
for (name, loc) in localities {
  guard haptics.supportedLocalities.contains(loc) else { print("[\(name)] 手柄不支持此位置，跳过"); continue }
  guard let engine = haptics.createEngine(withLocality: loc) else { print("[\(name)] createEngine 返回 nil"); continue }
  engines.append(engine)
  do { try engine.start() } catch { print("[\(name)] 引擎启动失败：\(error)"); continue }
  print("[\(name)] 引擎已启动，playsHapticsOnly=\(engine.playsHapticsOnly)")
  let id: CHHapticAudioResourceID
  do { id = try engine.registerAudioResource(tone, options: [:]); print("[\(name)] 注册音频资源成功：\(id)") }
  catch { print("[\(name)] 注册音频资源失败：\(error)"); continue }
  do {
    let event = CHHapticEvent(audioResourceID: id, parameters: [CHHapticEventParameter(parameterID: .audioVolume, value: 0.5)], relativeTime: 0)
    let pattern = try CHHapticPattern(events: [event], parameters: [])
    let player = try engine.makePlayer(with: pattern)
    try player.start(atTime: CHHapticTimeImmediate)
    print("[\(name)] 播放已开始（请听手柄扬声器 0.3 秒）")
  } catch { print("[\(name)] 播放失败：\(error)") }
  RunLoop.main.run(until: Date().addingTimeInterval(0.8))
}
engines.forEach { $0.stop() }
print("完成。解读见文件开头注释。")
