import CoreHaptics
import GameController

/// 震动输出：左右强度 0...1
protocol HapticOutput: AnyObject {
    var name: String { get }
    func set(left: Float, right: Float)
    func stop()
}

// MARK: - GameController + CoreHaptics（蓝牙 / USB 都可用）
// 注：macOS 的驱动不开启 DualSense 的「音频驱动震动」，往 USB 音频第 3/4 声道写波形不会震，所以只用这条路

final class RumbleHapticOutput: HapticOutput {
    let name = "CoreHaptics 震动"

    /// 每个马达一个引擎 + 一个正在播放的长连续震动
    private final class Channel {
        let engine: CHHapticEngine
        var player: CHHapticPatternPlayer?
        var startedAt = Date.distantPast
        var value: Float = -1
        init(engine: CHHapticEngine) { self.engine = engine }
    }

    /// 单段连续震动的长度；快播完时重新开一段
    private static let segment: TimeInterval = 60
    private var channels: [Channel] = []

    init(controller: GCController) throws {
        guard let haptics = controller.haptics else { throw CAError(what: "手柄不支持震动", status: -1) }
        let split = haptics.supportedLocalities.contains(.leftHandle) && haptics.supportedLocalities.contains(.rightHandle)
        let localities: [GCHapticsLocality] = split ? [.leftHandle, .rightHandle] : [.default]
        for loc in localities {
            guard let engine = haptics.createEngine(withLocality: loc) else { continue }
            try engine.start()
            channels.append(Channel(engine: engine))
        }
        if channels.isEmpty { throw CAError(what: "创建震动引擎", status: -1) }
    }

    func set(left: Float, right: Float) {
        let values = channels.count == 2 ? [left, right] : [max(left, right)]
        for (i, ch) in channels.enumerated() {
            let v = values[i]
            // 手柄的震动服务不支持 CHHapticAdvancedPatternPlayer（会报 4097），
            // 只能用普通 player：播一段长连续震动，用 sendParameters 实时调强度
            if ch.player == nil || Date().timeIntervalSince(ch.startedAt) > Self.segment - 1 {
                try? ch.player?.stop(atTime: CHHapticTimeImmediate)
                ch.player = makeContinuousPlayer(ch.engine)
                ch.startedAt = Date()
                ch.value = -1
            }
            guard abs(v - ch.value) > 0.005, let player = ch.player else { continue }
            ch.value = v
            try? player.sendParameters(
                [CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: v, relativeTime: 0)],
                atTime: CHHapticTimeImmediate)
        }
    }

    private func makeContinuousPlayer(_ engine: CHHapticEngine) -> CHHapticPatternPlayer? {
        let event = CHHapticEvent(eventType: .hapticContinuous,
                                  parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                                               CHHapticEventParameter(parameterID: .hapticSharpness, value: 1)],
                                  relativeTime: 0, duration: Self.segment)
        let control = CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: 0, relativeTime: 0)
        guard let pattern = try? CHHapticPattern(events: [event], parameters: [control]) else { return nil }
        try? engine.start()   // 引擎被系统停掉时重新启动
        guard let player = try? engine.makePlayer(with: pattern) else { return nil }
        try? player.start(atTime: CHHapticTimeImmediate)
        return player
    }

    func stop() {
        for ch in channels {
            try? ch.player?.stop(atTime: CHHapticTimeImmediate)
            ch.engine.stop()
        }
        channels.removeAll()
    }
}
