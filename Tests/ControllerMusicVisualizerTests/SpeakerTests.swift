import XCTest
@testable import ControllerMusicVisualizer

final class SpeakerDSPTests: XCTestCase {
    private let sr: Float = 48000

    private func sine(_ hz: Float, _ n: Int, amp: Float = 1) -> [Float] {
        (0..<n).map { amp * sinf(2 * .pi * hz * Float($0) / 48000) }
    }

    private func rms(_ x: ArraySlice<Float>) -> Float { sqrtf(x.reduce(0) { $0 + $1 * $1 } / Float(x.count)) }

    // MARK: 高通

    private func highpassGain(_ hz: Float) -> Float {
        var f = Biquad.highpass(hz: 200, sampleRate: sr)
        let x = sine(hz, 48000)
        let y = x.map { f.process($0) }
        return rms(y[24000...]) / rms(x[24000...])
    }

    func testHighpassAttenuatesLowFrequencies() {
        XCTAssertLessThan(highpassGain(50), 0.1)      // 50Hz 明显衰减（二阶，约 -24dB）
        XCTAssertLessThan(highpassGain(20), highpassGain(50))
    }

    func testHighpassPassesMidFrequencies() {
        XCTAssertEqual(highpassGain(1000), 1, accuracy: 0.03)
        XCTAssertEqual(highpassGain(4000), 1, accuracy: 0.01)
    }

    func testHighpassCutoffIsMinus3dB() {
        XCTAssertEqual(highpassGain(200), 0.7071, accuracy: 0.03)
    }

    // MARK: 单声道混合

    func testMonoMixOfOppositeChannelsIsSilent() {
        let feed = SpeakerFeed()
        let l = sine(1000, 4800), r = l.map { -$0 }
        l.withUnsafeBufferPointer { lp in r.withUnsafeBufferPointer { rp in
            feed.write(left: lp.baseAddress!, right: rp.baseAddress!, frames: 4800, sampleRate: sr)
        } }
        let peak = (0..<4800).map { abs(feed.buffer[$0]) }.max()!
        XCTAssertLessThan(peak, 1e-4)
        XCTAssertEqual(feed.written.pointee, 4800)
        XCTAssertEqual(feed.lastChunk.pointee, 4800)
    }

    func testMonoMixOfIdenticalChannelsKeepsLevel() {
        let feed = SpeakerFeed()
        let x = sine(1000, 9600, amp: 0.5)
        x.withUnsafeBufferPointer { p in
            feed.write(left: p.baseAddress!, right: p.baseAddress!, frames: 9600, sampleRate: sr)
        }
        let peak = (4800..<9600).map { abs(feed.buffer[$0]) }.max()!
        XCTAssertEqual(peak, 0.5, accuracy: 0.02)
    }

    // MARK: 音量 / 限幅 / 渐变

    func testVolumeCurve() {
        XCTAssertEqual(SpeakerVolume.gain(0), 0)            // 0% = 完全静音
        XCTAssertEqual(SpeakerVolume.gain(1), 1, accuracy: 1e-6)   // 100% = 0dB，不放大
        XCTAssertEqual(SpeakerVolume.gain(0.3), powf(10, -21.0 / 20), accuracy: 1e-4)   // 默认 30% = -21dB
        var last: Float = 0
        for i in 1...100 {
            let g = SpeakerVolume.gain(Float(i) / 100)
            XCTAssertGreaterThan(g, last)
            last = g
        }
        XCTAssertEqual(SpeakerVolume.defaultVolume, 0.3)
    }

    func testFullVolumeDoesNotClip() {
        // 100% 音量下最大幅度的输入也不超过 ±1，且小信号基本不变
        XCTAssertLessThanOrEqual(abs(SoftLimiter.process(1 * SpeakerVolume.gain(1))), 1)
        XCTAssertLessThanOrEqual(abs(SoftLimiter.process(50)), 1)
        XCTAssertLessThanOrEqual(abs(SoftLimiter.process(-50)), 1)
        XCTAssertEqual(SoftLimiter.process(0.01), 0.01, accuracy: 1e-4)
    }

    func testFadeInIsSmoothAndFast() {
        var ramp = GainRamp()
        let k = GainRamp.coefficient(sampleRate: 48000)
        var previous: Float = 0
        var maxStep: Float = 0
        var reached20ms = false
        for i in 0..<2400 {
            let v = ramp.step(target: 1, k: k)
            XCTAssertGreaterThanOrEqual(v, previous)
            maxStep = max(maxStep, v - previous)
            previous = v
            if i == 960 { reached20ms = v > 0.98 }   // 20ms 内基本到位
        }
        XCTAssertTrue(reached20ms)
        XCTAssertLessThan(maxStep, 0.001)            // 相邻采样的跳变很小 = 没有咔哒声
        // 淡出也平滑
        var down: Float = 1
        for _ in 0..<2400 {
            let v = ramp.step(target: 0, k: k)
            XCTAssertLessThanOrEqual(v, down + 1e-6)
            down = v
        }
        XCTAssertLessThan(down, 0.001)
    }

    // MARK: 环形缓冲游标

    /// 模拟：写端每 chunk 帧到达一块（时钟偏差 ppm），读端每 block 帧读一块。返回 (欠载, 积压, 最终 lag)
    private func simulate(chunk: Int, block: Int, targetFrames: Double, ppm: Double, seconds: Double)
        -> (underruns: Int, overruns: Int, minLag: Double, maxLag: Double) {
        var cursor = RingCursor()
        var written = 0.0
        let writeRate = 48000.0 * (1 + ppm / 1e6)
        let writeDt = Double(chunk) / writeRate, readDt = Double(block) / 48000
        var tw = 0.0, tr = 0.0013   // 读写相位错开
        var minLag = Double.infinity, maxLag = -Double.infinity
        while min(tw, tr) < seconds {
            if tw <= tr {
                written += Double(chunk); tw += writeDt
            } else {
                let step = cursor.prepare(written: written, frames: block, nominalStep: 1,
                                          target: targetFrames, blockSeconds: readDt)
                if tr > 2 { minLag = min(minLag, written - cursor.readPos); maxLag = max(maxLag, written - cursor.readPos) }
                cursor.readPos += Double(block) * step
                tr += readDt
            }
        }
        return (cursor.underruns, cursor.overruns, minLag, maxLag)
    }

    func testCursorStaysLockedWithoutUnderrunsAcrossClockDrift() {
        let chunk = 256, block = 256
        let target = LatencyModel.minMarginMs(chunkFrames: chunk, outBlockFrames: Double(block), sampleRate: 48000) * 48
        for ppm in [-300.0, -100.0, 0, 100, 300] {
            let r = simulate(chunk: chunk, block: block, targetFrames: target, ppm: ppm, seconds: 300)
            XCTAssertEqual(r.underruns, 0, "ppm \(ppm)")
            XCTAssertEqual(r.overruns, 0, "ppm \(ppm)")
            XCTAssertGreaterThanOrEqual(r.minLag, Double(block), "ppm \(ppm)")
        }
    }

    func testCursorResyncsAndCountsWhenMarginTooSmall() {
        // 余量比一个块还小：必然欠载
        let r = simulate(chunk: 512, block: 256, targetFrames: 100, ppm: 0, seconds: 5)
        XCTAssertGreaterThan(r.underruns, 0)
    }

    func testCursorCatchesUpAfterBacklog() {
        var cursor = RingCursor()
        _ = cursor.prepare(written: 1000, frames: 256, nominalStep: 1, target: 480, blockSeconds: 0.005)
        let before = cursor.readPos
        // 写端突然跑出去很远（例如读端被挂起）
        _ = cursor.prepare(written: 100_000, frames: 256, nominalStep: 1, target: 480, blockSeconds: 0.005)
        XCTAssertEqual(cursor.overruns, 1)
        XCTAssertGreaterThan(cursor.readPos, before)
        XCTAssertEqual(100_000 - cursor.readPos, 480, accuracy: 1)
    }

    func testAdaptiveMarginGrowsOnUnderrunAndDecaysWhenStable() {
        var m = AdaptiveMargin()
        m.update(underrun: true, dt: 0.005)
        m.update(underrun: true, dt: 0.005)
        XCTAssertEqual(m.extraMs, 4)
        for _ in 0..<20 { m.update(underrun: true, dt: 0.005) }
        XCTAssertEqual(m.extraMs, 20)                      // 上限
        for _ in 0..<(31 * 200) { m.update(underrun: false, dt: 0.005) }
        XCTAssertEqual(m.extraMs, 19)                      // 稳定 30 秒后收回 1ms
        for _ in 0..<(600 * 200) { m.update(underrun: false, dt: 0.005) }
        XCTAssertEqual(m.extraMs, 0)
    }

    // MARK: 延迟线

    func testDelayLineInterpolates() {
        var d = DelayLine()
        for i in 0..<10 { d.push(time: Double(i) * 0.01, Float(i), Float(i) * 2) }
        XCTAssertEqual(d.value(at: 0.09).0, 9, accuracy: 1e-5)            // 延迟 0：就是最新值
        XCTAssertEqual(d.value(at: 0.085).0, 8.5, accuracy: 1e-4)         // 延迟 5ms：两个 tick 之间插值
        XCTAssertEqual(d.value(at: 0.085).1, 17, accuracy: 1e-4)
        XCTAssertEqual(d.value(at: 0.08).0, 8, accuracy: 1e-5)            // 延迟 10ms：上一个 tick
        XCTAssertEqual(d.value(at: -1).0, 0, accuracy: 1e-5)              // 早于所有记录：最旧的
        XCTAssertEqual(d.value(at: 5).0, 9, accuracy: 1e-5)               // 晚于所有记录：最新的
    }

    func testDelayLineWrapsAround() {
        var d = DelayLine()
        for i in 0..<500 { d.push(time: Double(i) * 0.01, Float(i), 0) }
        XCTAssertEqual(d.value(at: 4.99 - 0.005).0, 498.5, accuracy: 1e-3)
    }

    func testEmptyDelayLine() {
        XCTAssertEqual(DelayLine().value(at: 1).0, 0)
    }
}

final class LatencyTests: XCTestCase {
    func testDeviceTimingTotal() {
        let t = DeviceTiming(sampleRate: 48000, bufferFrames: 256, safetyOffset: 24, deviceLatency: 0, streamLatency: 0)
        XCTAssertEqual(t.totalFrames, 280)
        XCTAssertEqual(t.ms, 280.0 / 48 , accuracy: 1e-9)
    }

    func testBreakdownAndExtraDelay() {
        let tap = DeviceTiming(sampleRate: 48000, bufferFrames: 256, safetyOffset: 0, deviceLatency: 0, streamLatency: 0)
        let pad = DeviceTiming(sampleRate: 48000, bufferFrames: 256, safetyOffset: 64, deviceLatency: 0, streamLatency: 0)
        let mac = DeviceTiming(sampleRate: 48000, bufferFrames: 512, safetyOffset: 144, deviceLatency: 0, streamLatency: 0)
        let b = LatencyModel.breakdown(tapInput: tap, marginMs: 10, controller: pad, macOutput: mac)
        XCTAssertEqual(b.tapCaptureMs, 256.0 / 48, accuracy: 1e-9)
        XCTAssertEqual(b.controllerOutputMs, 320.0 / 48, accuracy: 1e-9)
        XCTAssertEqual(b.controllerTotalMs, 256.0 / 48 + 10 + 320.0 / 48, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(b.extraMs), b.controllerTotalMs - 656.0 / 48, accuracy: 1e-9)
        XCTAssertNil(LatencyModel.breakdown(tapInput: tap, marginMs: 10, controller: pad, macOutput: nil).extraMs)
    }

    func testMinimumMargin() {
        // 256 帧一块的写端 + 256 帧一块的读端 @48k：(128 + 256) / 48 + 1.5 = 9.5ms
        XCTAssertEqual(LatencyModel.minMarginMs(chunkFrames: 256, outBlockFrames: 256, sampleRate: 48000), 9.5, accuracy: 1e-9)
        // 缓冲越小余量越小
        XCTAssertLessThan(LatencyModel.minMarginMs(chunkFrames: 128, outBlockFrames: 128, sampleRate: 48000),
                          LatencyModel.minMarginMs(chunkFrames: 256, outBlockFrames: 256, sampleRate: 48000))
    }

    func testCompatHapticDelay() {
        // 扬声器路径 10 + 6 = 16ms，兼容震动 5 + 4 = 9ms：差 7ms → 取 5ms 整数倍 = 5
        XCTAssertEqual(LatencyModel.compatHapticDelayMs(marginMs: 10, controllerOutputMs: 6), 5)
        // 扬声器反而更快：不为负
        XCTAssertEqual(LatencyModel.compatHapticDelayMs(marginMs: 2, controllerOutputMs: 2), 0)
        // 有上限
        XCTAssertEqual(LatencyModel.compatHapticDelayMs(marginMs: 100, controllerOutputMs: 100), 20)
    }

    func testHDEnvelopeDelay() {
        XCTAssertEqual(LatencyModel.hdEnvelopeDelayMs(marginMs: 10), 5)
        XCTAssertEqual(LatencyModel.hdEnvelopeDelayMs(marginMs: 3), 0)
        XCTAssertEqual(LatencyModel.hdEnvelopeDelayMs(marginMs: 200), 20)
    }
}

final class SpeakerTuningTests: XCTestCase {
    private func defaults() -> (UserDefaults, () -> Void) {
        let suite = "test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        return (d, { d.removePersistentDomain(forName: suite) })
    }

    func testDefaultsWhenNothingSet() {
        let (d, cleanup) = defaults(); defer { cleanup() }
        let t = SpeakerTuning.load(from: d)
        XCTAssertEqual(t, SpeakerTuning())
        XCTAssertEqual(t.hwVolume, 0x64)
        XCTAssertEqual(t.preamp, 0)
        XCTAssertEqual(t.highpassHz, 200)
        XCTAssertNil(t.bufferMs)
        XCTAssertNil(t.hapticsDelayMs)
    }

    func testValuesAreReadAndClamped() {
        let (d, cleanup) = defaults(); defer { cleanup() }
        d.set(10, forKey: "speaker.hwVolume")          // 低于有效范围 → 夹到 0x3d
        d.set(99, forKey: "speaker.preamp")
        d.set(300, forKey: "speaker.highpassHz")
        d.set(12.5, forKey: "speaker.bufferMs")
        d.set(128, forKey: "speaker.ioFrames")
        d.set(-8, forKey: "speaker.hapticsDelayMs")
        let t = SpeakerTuning.load(from: d)
        XCTAssertEqual(t.hwVolume, 0x3d)
        XCTAssertEqual(t.preamp, 7)
        XCTAssertEqual(t.highpassHz, 300)
        XCTAssertEqual(t.bufferMs, 12.5)
        XCTAssertEqual(t.ioFrames, 128)
        XCTAssertEqual(t.hapticsDelayMs, -8)
    }

    func testZeroBufferMeansAuto() {
        let (d, cleanup) = defaults(); defer { cleanup() }
        d.set(0, forKey: "speaker.bufferMs")
        XCTAssertNil(SpeakerTuning.load(from: d).bufferMs)
    }
}

final class SpeakerReportTests: XCTestCase {
    private func common(_ configure: (inout DualSenseOutputState) -> Void) -> [UInt8] {
        var s = DualSenseOutputState()
        configure(&s)
        return DualSenseReport.common(s)
    }

    func testUntouchedSpeakerSetsNothing() {
        let c = common { $0.speaker = .untouched }
        XCTAssertEqual(c[0] & 0xA0, 0)
        XCTAssertEqual(c[1] & 0x80, 0)
        XCTAssertEqual(c[5], 0); XCTAssertEqual(c[7], 0); XCTAssertEqual(c[37], 0)
    }

    func testSpeakerOnFieldsAndFlags() {
        let c = common { $0.speaker = .on(volume: 0x64, preamp: 2) }
        XCTAssertEqual(c[0] & 0xA0, 0xA0)       // 音量、路径生效
        XCTAssertEqual(c[1] & 0x80, 0x80)       // 前置放大生效
        XCTAssertEqual(c[5], 0x64)
        XCTAssertEqual(c[7], 0x30)              // 路径 3
        XCTAssertEqual(c[37], 2)
    }

    func testSpeakerOffSendsPathZero() {
        let c = common { $0.speaker = .off }
        XCTAssertEqual(c[0] & 0x80, 0x80)
        XCTAssertEqual(c[0] & 0x20, 0)
        XCTAssertEqual(c[7], 0)
    }

    func testSpeakerDoesNotDisturbVibrationModeBits() {
        // HD 模式：bit0/bit1 都清零，扬声器字段不能把它们置回来
        let hd = common { $0.hd = true; $0.speaker = .on(volume: 0x64, preamp: 0) }
        XCTAssertEqual(hd[0] & 0x03, 0)
        XCTAssertEqual(hd[38], 0)
        // 兼容震动
        let compat = common { $0.speaker = .on(volume: 0x64, preamp: 0) }
        XCTAssertEqual(compat[0] & 0x03, 0x03)
        XCTAssertEqual(compat[38], 0x04)
        // 震动交给游戏：只置 bit1
        let game = common { $0.rumble = false; $0.speaker = .on(volume: 0x64, preamp: 0) }
        XCTAssertEqual(game[0] & 0x03, 0x02)
        // 关闭扬声器同样不影响
        let off = common { $0.hd = true; $0.speaker = .off }
        XCTAssertEqual(off[0] & 0x03, 0)
    }

    func testSpeakerKeepsOtherFlags() {
        let base = common { _ in }
        let withSpeaker = common { $0.speaker = .on(volume: 0x64, preamp: 0) }
        XCTAssertEqual(withSpeaker[0] & 0x5F, base[0] & 0x5F)   // 震动、扳机标志不变
        XCTAssertEqual(withSpeaker[1] & 0x7F, base[1] & 0x7F)   // 灯光标志不变
        XCTAssertEqual(Array(withSpeaker[8...36]), Array(base[8...36]))
        XCTAssertEqual(Array(withSpeaker[43...46]), Array(base[43...46]))
    }

    func testSpeakerAppearsInUSBAndBluetoothReports() {
        var s = DualSenseOutputState()
        s.speaker = .on(volume: 0x64, preamp: 0)
        let usb = DualSenseReport.usb(s)
        XCTAssertEqual(usb[1 + 5], 0x64)
        let bt = DualSenseReport.bluetooth(s, seq: 0)
        XCTAssertEqual(bt[3 + 5], 0x64)
        let crc = DualSenseReport.crc32([0xA2] + bt[0..<74])
        let stored = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bt[74 + $1]) << (8 * UInt32($1)) }
        XCTAssertEqual(crc, stored)
    }

    func testStateEquality() {
        var a = DualSenseOutputState(), b = DualSenseOutputState()
        XCTAssertEqual(a, b)
        a.speaker = .on(volume: 1, preamp: 0)
        XCTAssertNotEqual(a, b)
        b.speaker = .on(volume: 1, preamp: 0)
        XCTAssertEqual(a, b)
    }
}

final class SpeakerSettingsTests: XCTestCase {
    func testDefaultsAreOffAndQuiet() {
        let s = ControllerSettings()
        XCTAssertFalse(s.speakerEnabled)
        XCTAssertEqual(s.speakerVolume, 0.3)
    }

    func testRoundTripAndOldSettingsWithoutSpeakerFields() throws {
        var s = ControllerSettings(); s.speakerEnabled = true; s.speakerVolume = 0.55
        XCTAssertEqual(try JSONDecoder().decode(ControllerSettings.self, from: JSONEncoder().encode(s)), s)
        let old = try JSONDecoder().decode(ControllerSettings.self, from: #"{"intensity": 2}"#.data(using: .utf8)!)
        XCTAssertFalse(old.speakerEnabled)
        XCTAssertEqual(old.speakerVolume, 0.3)
    }

    func testSpeakerAloneIsNotLeftToGame() {
        var s = ControllerSettings()
        s.vibrationEnabled = false; s.triggersEnabled = false; s.lightEffects = false
        XCTAssertTrue(s.allLeftToGame)
        s.speakerEnabled = true
        XCTAssertFalse(s.allLeftToGame)
    }

    func testVolumeIsClampedOnLoad() throws {
        let s = try JSONDecoder().decode(ControllerSettings.self, from: #"{"speakerVolume": 7}"#.data(using: .utf8)!)
        XCTAssertEqual(s.speakerVolume, 1)
    }
}

/// §5.2 的离线对齐基线：同一个底鼓脉冲，分别经过「扬声器链路」和「震动链路」的处理代码，
/// 比较两路输出出现的时刻（只算软件部分，不含任何缓冲和设备延迟）
final class AlignmentTests: XCTestCase {
    private let sr: Float = 48000

    /// 底鼓：起始 2ms 的宽带「咔」声 + 60Hz 衰减正弦。0.1 秒处开始
    private func kick(seconds: Float) -> [Float] {
        let n = Int(seconds * sr)
        var seed: UInt32 = 12345
        return (0..<n).map { i in
            let t = Float(i) / sr - 0.1
            guard t >= 0 else { return 0 }
            seed = seed &* 1664525 &+ 1013904223
            let noise = Float(Int32(bitPattern: seed)) / Float(Int32.max)
            let click: Float = t < 0.002 ? 0.6 * noise : 0
            return click + 0.8 * expf(-t * 18) * sinf(2 * .pi * 60 * t)
        }
    }

    func testSpeakerAndVibrationPeaksAreCloseInSoftware() {
        let x = kick(seconds: 0.6)
        let block = 480   // 10ms
        let analyzer = MusicAnalyzer()
        let feed = SpeakerFeed()
        var shaper = VibrationShaper()
        var speakerOut: [Float] = []
        var vibration: [Float] = []

        for b in 0..<(x.count / block) {
            let chunk = Array(x[(b * block)..<((b + 1) * block)])
            chunk.withUnsafeBufferPointer { p in
                analyzer.process(left: p.baseAddress!, right: p.baseAddress!, frames: block, sampleRate: sr)
                feed.write(left: p.baseAddress!, right: p.baseAddress!, frames: block, sampleRate: sr)
            }
            // 扬声器链路：缓冲 × 默认音量 → 软限幅
            let g = SpeakerVolume.gain(SpeakerVolume.defaultVolume)
            let end = feed.written.pointee
            for i in (end - block)..<end { speakerOut.append(SoftLimiter.process(feed.buffer[i & SpeakerFeed.mask] * g)) }
            // 震动链路：分析器 → 整形（beat 模式）。每 10ms 采样一次，和主循环一样
            let v = shaper.update(analyzer.current, mode: .beat, dt: 0.01)
            vibration.append(max(v.0, v.1))
        }

        // 扬声器：声音首次超过峰值一半的时刻（秒）
        let sMax = speakerOut.map { abs($0) }.max()!
        let sIdx = speakerOut.firstIndex { abs($0) > 0.5 * sMax }!
        let speakerTime = Double(sIdx) / Double(sr)
        // 震动：强度首次超过峰值一半的时刻（该 10ms 块的结束时刻）
        let vMax = vibration.max()!
        let vIdx = vibration.firstIndex { $0 > 0.5 * vMax }!
        let vibrationTime = Double(vIdx + 1) * 0.01

        let diffMs = (vibrationTime - speakerTime) * 1000
        print("ALIGNMENT speaker onset \(speakerTime * 1000) ms, vibration onset \(vibrationTime * 1000) ms, diff \(diffMs) ms")
        XCTAssertGreaterThan(vMax, 0.3)
        XCTAssertGreaterThan(sMax, 0.001)
        // 软件部分的差值：震动最多晚一个分析块（10ms）加一点平滑，不应超过 25ms，也不应比声音早
        XCTAssertLessThan(abs(diffMs), 25)
    }
}
