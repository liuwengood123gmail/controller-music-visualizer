import XCTest
@testable import ControllerCore

/// 新旧实现逐 tick 对照（跨平台设计 §8 P1）：`OldTick` 是改造前 macOS `ControllerSession.tick` /
/// `updateLight` / `hdFrequency` 的原样拷贝（只把「发给设备」换成记录下来），与 `SessionEngine` 在
/// 同样的输入序列下逐 tick 比较全部输出
private struct OldTick {
    var vibration = VibrationShaper()
    var lightShaper = LightShaper()
    var ledMeter = PlayerLEDMeter()
    var align = DelayLine()
    var alignClock = 0.0
    var massageTime: Double = 0
    var randomNow: MassagePreset?

    struct Out: Equatable {
        var intensity: Float
        var resistance: Float?
        var motors: [Float]
        var hd: [Float]?
        var hdMusic: Bool?
        var light: [Float]?
        var leds: UInt8?
        var level: [Float]
        var randomNow: MassagePreset?
    }

    mutating func tick(settings: inout ControllerSettings, f: SessionFlags, music: MusicFrame,
                       triggers: (Float, Float), dt: Float, alignDelayMs: Double) -> Out {
        var o = Out(intensity: 0, resistance: nil, motors: [], hd: nil, hdMusic: nil, light: nil, leds: nil,
                    level: [], randomNow: nil)
        vibration.sensitivity = settings.sensitivity
        vibration.responsiveness = settings.responsiveness
        lightShaper.lightSpeed = settings.lightSpeed

        if f.triggers {
            if f.adaptiveTriggers { o.resistance = settings.triggerResistance }
            let (lt, rt) = triggers
            let dz: (Float) -> Float = { $0 < 0.05 ? 0 : $0 * $0 }
            let delta = (dz(rt) - dz(lt)) * 1.0 * dt
            if delta != 0 { settings.intensity = min(max(settings.intensity + delta, 0), 3) }
        }

        var l: Float, r: Float
        let lightLevel: (Float, Float), meterIn: (Float, Float)
        switch settings.source {
        case .music:
            (l, r) = vibration.update(music, mode: settings.musicMode, dt: dt)
            lightLevel = music.light
            meterIn = music.meter
        case .massage:
            massageTime += Double(dt) * settings.speed
            (l, r) = settings.preset.sample(massageTime)
            let now = settings.preset == .random ? settings.preset.current(massageTime) : nil
            if now != randomNow { randomNow = now }
            lightLevel = (l, r)
            meterIn = (l, r)
        }
        l = min(max(l * settings.intensity, 0), 1)
        r = min(max(r * settings.intensity, 0), 1)
        if !f.vibration { l = 0; r = 0 }
        o.level = [l, r]

        alignClock += Double(dt)
        if alignDelayMs > 0 {
            align.push(time: alignClock, l, r)
            (l, r) = align.value(at: alignClock - alignDelayMs / 1000)
        }
        if f.hdActive {
            let range = settings.source == .music ? settings.musicMode.carrierRange
                                                   : settings.preset.carrierRange(massageTime)
            o.hd = [l, r, max(range.high - (range.high - range.low) * powf(max(l, r), 0.7), 50)]
            o.hdMusic = settings.source == .music
            o.motors = [0, 0]
        } else {
            o.motors = [l, r]
        }

        if f.lights {
            let cr: Float, cg: Float, cb: Float
            switch settings.source {
            case .music:
                let bar = lightShaper.update(level: lightLevel, color: music.color, dt: dt)
                let v = (1 - settings.lightRange) + settings.lightRange * bar.brightness
                (cr, cg, cb) = (bar.color.r * v, bar.color.g * v, bar.color.b * v)
            case .massage:
                let v = (1 - settings.lightRange) + settings.lightRange * (0.15 + 0.85 * max(lightLevel.0, lightLevel.1))
                (cr, cg, cb) = hsv(settings.preset.hue(massageTime), 1, v)
            }
            o.light = [cr, cg, cb]
            if f.playerLEDs { o.leds = ledMeter.mask(left: meterIn.0, right: meterIn.1) }
        }
        o.intensity = settings.intensity
        // 旧代码只在按摩时更新 randomNow（切到音乐后保留旧值，界面在音乐页不显示它）
        o.randomNow = settings.source == .massage ? randomNow : nil
        return o
    }
}

final class SessionEquivalenceTests: XCTestCase {
    private struct RNG: RandomNumberGenerator {
        var s: UInt64
        mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s }
    }

    private func run(_ settings0: ControllerSettings, flags: SessionFlags, seed: UInt64, ticks: Int = 3000,
                     alignDelayMs: Double = 0, changeEvery: Int = 0) {
        var rng = RNG(s: seed)
        var old = OldTick(), new = SessionEngine()
        var oldSettings = settings0, newSettings = settings0
        for i in 0..<ticks {
            if changeEvery > 0 && i % changeEvery == 0 && i > 0 {
                // 运行中改设置（模拟用户拖滑块 / 切模式）
                var s = newSettings
                s.musicMode = MusicMode.allCases.randomElement(using: &rng)!
                s.preset = MassagePreset.allCases.randomElement(using: &rng)!
                s.sensitivity = Float.random(in: 0...1, using: &rng)
                s.responsiveness = Float.random(in: 0...1, using: &rng)
                s.lightSpeed = Float.random(in: 0...1, using: &rng)
                s.lightRange = Float.random(in: 0...1, using: &rng)
                s.speed = Double.random(in: 0.5...2, using: &rng)
                oldSettings = s; newSettings = s
            }
            var m = MusicFrame()
            let b = Float.random(in: 0...1, using: &rng)
            m.bass = (b, b * 0.8); m.bassRelative = (b, Float.random(in: 0...1, using: &rng))
            m.fullRelative = (Float.random(in: 0...1, using: &rng), Float.random(in: 0...1, using: &rng))
            m.light = (b, b); m.meter = m.fullRelative
            m.color = (Float.random(in: 0...1, using: &rng), Float.random(in: 0...1, using: &rng), Float.random(in: 0...1, using: &rng))
            let trig = (Float.random(in: 0...1, using: &rng) < 0.1 ? Float.random(in: 0...1, using: &rng) : 0,
                        Float.random(in: 0...1, using: &rng) < 0.1 ? Float.random(in: 0...1, using: &rng) : 0)
            let dt = Float.random(in: 0.008...0.013, using: &rng)

            let o = old.tick(settings: &oldSettings, f: flags, music: m, triggers: trig, dt: dt, alignDelayMs: alignDelayMs)
            let c = new.tick(SessionTickInput(settings: newSettings, flags: flags, music: m, triggers: trig,
                                              dt: dt, alignDelayMs: alignDelayMs))
            if let v = c.intensity { newSettings.intensity = v }
            let n = OldTick.Out(intensity: newSettings.intensity, resistance: c.triggerResistance,
                                motors: [c.motors.left, c.motors.right],
                                hd: c.hd.map { [$0.left, $0.right, $0.freq] }, hdMusic: c.hd?.useMusic,
                                light: c.light.map { [$0.r, $0.g, $0.b] }, leds: c.playerLEDs,
                                level: [c.level.left, c.level.right],
                                randomNow: newSettings.source == .massage ? c.randomNow : nil)
            XCTAssertEqual(o, n, "tick \(i)")
            if o != n { return }
        }
    }

    private let all = SessionFlags(vibration: true, triggers: true, lights: true, adaptiveTriggers: true,
                                   playerLEDs: true, hdActive: false)

    func testMusicCompat() {
        for mode in MusicMode.allCases {
            var s = ControllerSettings(); s.musicMode = mode
            run(s, flags: all, seed: 1)
        }
    }

    func testMusicHDWithAlignment() {
        var f = all; f.hdActive = true
        run(ControllerSettings(), flags: f, seed: 2, alignDelayMs: 12)
    }

    func testMassageAllPresets() {
        for p in MassagePreset.allCases {
            var s = ControllerSettings(); s.source = .massage; s.preset = p; s.speed = 1.5
            run(s, flags: all, seed: 3, ticks: 1500)
            var f = all; f.hdActive = true
            run(s, flags: f, seed: 4, ticks: 1500)
        }
    }

    func testPartialControlAndSettingChanges() {
        let variants = [
            SessionFlags(vibration: false, triggers: true, lights: true, adaptiveTriggers: true, playerLEDs: false, hdActive: false),
            SessionFlags(vibration: true, triggers: false, lights: false, adaptiveTriggers: false, playerLEDs: false, hdActive: false),
            SessionFlags(vibration: true, triggers: true, lights: true, adaptiveTriggers: false, playerLEDs: false, hdActive: false),
        ]
        for (k, f) in variants.enumerated() {
            run(ControllerSettings(), flags: f, seed: 10 + UInt64(k), alignDelayMs: 30, changeEvery: 400)
            var s = ControllerSettings(); s.source = .massage
            run(s, flags: f, seed: 20 + UInt64(k), changeEvery: 400)
        }
    }
}
