import XCTest
@testable import ControllerMusicVisualizer

final class AnalyzerTests: XCTestCase {
    private let sr: Float = 48000

    /// 喂 seconds 秒音频，每块 480 帧（10ms），返回每块之后的分析结果
    private func run(_ analyzer: MusicAnalyzer, seconds: Float, gain: (Float) -> Float,
                     signal: (Int) -> Float) -> [MusicFrame] {
        let block = 480
        var frames: [MusicFrame] = []
        var n = 0
        for b in 0..<Int(seconds * 100) {
            let t = Float(b) * 0.01
            let g = gain(t)
            var buf = [Float](repeating: 0, count: block)
            for i in 0..<block { buf[i] = g * signal(n + i) }
            n += block
            buf.withUnsafeBufferPointer { p in
                analyzer.process(left: p.baseAddress!, right: p.baseAddress!, frames: block, sampleRate: sr)
            }
            frames.append(analyzer.current)
        }
        return frames
    }

    private func sine(_ hz: Float) -> (Int) -> Float {
        { i in sinf(2 * .pi * hz * Float(i) / 48000) }
    }

    func testSilenceGivesZeroEverything() {
        let a = MusicAnalyzer()
        let last = run(a, seconds: 1, gain: { _ in 0 }, signal: { _ in 0 }).last!
        XCTAssertEqual(last.bass.0, 0)
        XCTAssertEqual(last.bassRelative.0, 0)
        XCTAssertEqual(last.fullRelative.0, 0)
        XCTAssertEqual(last.light.0, 0, accuracy: 1e-3)
    }

    func testBassSineIsDetectedAsBass() {
        let a = MusicAnalyzer()
        let last = run(a, seconds: 1, gain: { _ in 0.5 }, signal: sine(60)).last!
        XCTAssertGreaterThan(last.bass.0, 0.5)
        XCTAssertLessThanOrEqual(last.bass.0, 1)
    }

    func testHighSineGivesLittleBass() {
        let a = MusicAnalyzer()
        let last = run(a, seconds: 1, gain: { _ in 0.5 }, signal: sine(6000)).last!
        XCTAssertLessThan(last.bassRelative.0, 0.2)
        XCTAssertGreaterThan(last.color.b, last.color.r)   // 高频 → 蓝
    }

    func testAllOutputsStayInRange() {
        let a = MusicAnalyzer()
        // 底鼓：每 0.5 秒一次衰减的 55Hz
        let frames = run(a, seconds: 4, gain: { _ in 1 }, signal: { i in
            let t = Float(i) / 48000
            let phase = t.truncatingRemainder(dividingBy: 0.5)
            return expf(-phase * 12) * sinf(2 * .pi * 55 * t)
        })
        for f in frames {
            for v in [f.bass.0, f.bass.1, f.bassRelative.0, f.bassRelative.1, f.fullRelative.0, f.fullRelative.1,
                      f.light.0, f.light.1, f.meter.0, f.meter.1, f.color.r, f.color.g, f.color.b] {
                XCTAssertTrue(v.isFinite)
                XCTAssertGreaterThanOrEqual(v, 0)
                XCTAssertLessThanOrEqual(v, 1.0001)
            }
        }
    }

    // MARK: - 每个手柄自己的整形

    /// 合成底鼓序列，返回 beat 模式下的震动峰值
    private func beatPeak(sensitivity: Float) -> Float {
        let a = MusicAnalyzer()
        var shaper = VibrationShaper()
        shaper.sensitivity = sensitivity
        var peak: Float = 0
        let frames = run(a, seconds: 4, gain: { _ in 1 }, signal: { i in
            let t = Float(i) / 48000
            let phase = t.truncatingRemainder(dividingBy: 0.5)
            return expf(-phase * 12) * sinf(2 * .pi * 55 * t)
        })
        for f in frames {
            let v = shaper.update(f, mode: .beat, dt: 0.01)
            peak = max(peak, v.0, v.1)
        }
        return peak
    }

    func testBeatModeFiresOnKickDrum() {
        XCTAssertGreaterThan(beatPeak(sensitivity: 0.5), 0.5)
    }

    func testBeatModeIsSilentOnSilence() {
        var shaper = VibrationShaper()
        for _ in 0..<200 {
            let v = shaper.update(MusicFrame(), mode: .beat, dt: 0.01)
            XCTAssertEqual(v.0, 0); XCTAssertEqual(v.1, 0)
        }
    }

    func testTwoShapersCanUseDifferentModesOnTheSameFrame() {
        var frame = MusicFrame()
        frame.bass = (0.8, 0.8)
        frame.bassRelative = (0.9, 0.9)
        frame.fullRelative = (0.1, 0.1)
        var bass = VibrationShaper(), env = VibrationShaper()
        var b: (Float, Float) = (0, 0), e: (Float, Float) = (0, 0)
        for _ in 0..<100 {
            b = bass.update(frame, mode: .bass, dt: 0.01)
            e = env.update(frame, mode: .envelope, dt: 0.01)
        }
        XCTAssertEqual(b.0, 0.81, accuracy: 0.02)   // 相对强度平方
        XCTAssertEqual(e.0, 0.01, accuracy: 0.02)
    }

    func testResponsivenessControlsFallSpeed() {
        func afterFall(_ responsiveness: Float) -> Float {
            var s = VibrationShaper()
            s.responsiveness = responsiveness
            var loud = MusicFrame(); loud.bassRelative = (1, 1)
            for _ in 0..<100 { _ = s.update(loud, mode: .bass, dt: 0.01) }
            var v: (Float, Float) = (0, 0)
            for _ in 0..<10 { v = s.update(MusicFrame(), mode: .bass, dt: 0.01) }
            return v.0
        }
        XCTAssertLessThan(afterFall(1), afterFall(0))   // 越灵敏，落得越快
    }

    func testLightShaperLatchesColorWhileLit() {
        var s = LightShaper()
        s.lightSpeed = 1
        var color: (r: Float, g: Float, b: Float) = (1, 0, 0)
        var out = s.update(level: (1, 1), color: color, dt: 0.01)
        for _ in 0..<20 { out = s.update(level: (1, 1), color: color, dt: 0.01) }
        XCTAssertEqual(out.color.r, 1, accuracy: 1e-4)
        color = (0, 0, 1)    // 亮着时不换色
        out = s.update(level: (1, 1), color: color, dt: 0.01)
        XCTAssertEqual(out.color.r, 1, accuracy: 1e-4)
        XCTAssertEqual(out.color.b, 0, accuracy: 1e-4)
        // 暗下去之后再亮起，按新的颜色锁定
        for _ in 0..<100 { out = s.update(level: (0, 0), color: color, dt: 0.01) }
        for _ in 0..<20 { out = s.update(level: (1, 1), color: color, dt: 0.01) }
        XCTAssertEqual(out.color.b, 1, accuracy: 1e-4)
    }

    func testPlayerLEDMeter() {
        var m = PlayerLEDMeter()
        XCTAssertEqual(m.mask(left: 0, right: 0), 0)
        XCTAssertEqual(m.mask(left: 0.3, right: 0.3), 0b00100)
        XCTAssertEqual(m.mask(left: 1, right: 0), 0b00111)
        XCTAssertEqual(m.mask(left: 0, right: 1) & 0b11000, 0b11000)
    }
}
