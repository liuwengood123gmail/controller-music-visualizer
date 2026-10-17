import XCTest
import ControllerCore
@testable import ControllerCAPI

final class CAPITests: XCTestCase {
    func testStringBufferTooSmall() {
        var small = [CChar](repeating: 0, count: 4)
        let n = small.withUnsafeMutableBufferPointer { cv_settings_initial(nil, nil, $0.baseAddress, 4) }
        XCTAssertLessThan(n, 0)
        var big = [CChar](repeating: 0, count: Int(-n))
        let m = big.withUnsafeMutableBufferPointer { cv_settings_initial(nil, nil, $0.baseAddress, Int32($0.count)) }
        XCTAssertEqual(m, -n - 1)
    }

    func testInitialCopiesSelected() {
        let out = ContractTests.call { cv_settings_initial(nil, "{\"enabled\":false,\"intensity\":2}", $0, $1) }
        let o = ContractTests.object(out)
        XCTAssertEqual(o["enabled"] as? Bool, true)
        XCTAssertEqual((o["intensity"] as? NSNumber)?.floatValue, 2)
    }

    func testSessionTickMatchesSessionEngine() {
        let core = cv_core_create(200)
        defer { cv_core_destroy(core) }
        let s = cv_session_create()
        defer { cv_session_destroy(s) }
        XCTAssertEqual(cv_session_set_settings(s, "{\"source\":\"按摩\",\"preset\":\"捶背\"}"), 0)
        XCTAssertEqual(cv_session_set_settings(s, "not json"), -1)

        var reference = SessionEngine()
        var settings = ControllerSettings(); settings.source = .massage; settings.preset = .pound
        let flags = CVFlag.vibration | CVFlag.triggers | CVFlag.lights | CVFlag.adaptiveTriggers | CVFlag.playerLEDs
        var out = [Float](repeating: 0, count: CVTick.count)
        for i in 0..<500 {
            let rt: Float = i < 100 ? 1 : 0
            out.withUnsafeMutableBufferPointer { cv_session_tick(s, core, flags, 0, rt, 0.01, 0, $0.baseAddress!) }
            let c = reference.tick(SessionTickInput(
                settings: settings,
                flags: SessionFlags(vibration: true, triggers: true, lights: true, adaptiveTriggers: true,
                                    playerLEDs: true, hdActive: false),
                music: MusicFrame(), triggers: (0, rt), dt: 0.01, alignDelayMs: 0))
            if let v = c.intensity { settings.intensity = v }
            XCTAssertEqual(out[CVTick.motorLeft], c.motors.left)
            XCTAssertEqual(out[CVTick.motorRight], c.motors.right)
            XCTAssertEqual(out[CVTick.resistance], 0.5)
            XCTAssertEqual(out[CVTick.hd], 0)
            XCTAssertEqual(out[CVTick.light], 1)
            XCTAssertEqual(out[CVTick.red], c.light!.r)
            XCTAssertEqual(out[CVTick.playerLEDs], Float(c.playerLEDs!))
            if let v = c.intensity { XCTAssertEqual(out[CVTick.intensity], v) } else { XCTAssertTrue(out[CVTick.intensity].isNaN) }
            XCTAssertEqual(out[CVTick.randomNow], -1)
        }
        XCTAssertGreaterThan(settings.intensity, 1.5)   // R2 按住 1 秒
    }

    func testSessionTickHD() {
        let s = cv_session_create()
        defer { cv_session_destroy(s) }
        _ = cv_session_set_settings(s, "{\"source\":\"按摩\",\"preset\":\"随机\"}")
        var out = [Float](repeating: 0, count: CVTick.count)
        out.withUnsafeMutableBufferPointer { cv_session_tick(s, nil, CVFlag.vibration | CVFlag.hdActive, 0, 0, 0.01, 0, $0.baseAddress!) }
        XCTAssertEqual(out[CVTick.hd], 1)
        XCTAssertEqual(out[CVTick.motorLeft], 0)
        XCTAssertGreaterThanOrEqual(out[CVTick.hdFreq], 50)
        XCTAssertEqual(out[CVTick.hdMusic], 0)
        XCTAssertEqual(out[CVTick.light], 0)
        XCTAssertGreaterThanOrEqual(out[CVTick.randomNow], 0)
        XCTAssertTrue(out[CVTick.resistance].isNaN)
    }

    func testDualSenseReportsQueue() {
        let h = cv_ds_create(0)
        defer { cv_ds_destroy(h) }
        var buf = [UInt8](repeating: 0, count: 128)
        func take() -> [UInt8]? {
            let n = buf.withUnsafeMutableBufferPointer { cv_ds_take_report(h, $0.baseAddress!, 128) }
            return n > 0 ? Array(buf[0..<Int(n)]) : nil
        }
        XCTAssertNil(take())
        cv_ds_send(h)
        let first = take()!
        XCTAssertEqual(first.count, 48); XCTAssertEqual(first[0], 0x02)
        cv_ds_set_light(h, 1, 0, 0)
        cv_ds_set_motors(h, 1, 0)
        let r = take()!
        XCTAssertEqual(r[1 + 3], 255); XCTAssertEqual(r[1 + 44], 255)
        XCTAssertNil(take())
        cv_ds_stop(h)
        XCTAssertNotNil(take())

        let bt = cv_ds_create(1)
        defer { cv_ds_destroy(bt) }
        cv_ds_send(bt)
        let n = buf.withUnsafeMutableBufferPointer { cv_ds_take_report(bt, $0.baseAddress!, 128) }
        XCTAssertEqual(n, 78); XCTAssertEqual(buf[0], 0x31)
        var small = [UInt8](repeating: 0, count: 10)
        cv_ds_send(bt)
        XCTAssertEqual(small.withUnsafeMutableBufferPointer { cv_ds_take_report(bt, $0.baseAddress!, 10) }, -1)
    }

    func testParseInput() {
        var r = [UInt8](repeating: 0, count: 64)
        r[0] = 0x01; r[5] = 255; r[6] = 128
        var out = [Float](repeating: 0, count: 4)
        let ok = r.withUnsafeBufferPointer { b in out.withUnsafeMutableBufferPointer { cv_ds_parse_input(1, b.baseAddress!, 64, $0.baseAddress!) } }
        XCTAssertEqual(ok, 1)
        XCTAssertEqual(out[0], 1, accuracy: 0.01)
        XCTAssertEqual(out[1], 0.5, accuracy: 0.01)
    }

    func testRendererInterleavesFourChannels() {
        let core = cv_core_create(200)
        defer { cv_core_destroy(core) }
        let r = cv_renderer_create(core, 48000, 1, .nan, .nan)
        defer { cv_renderer_destroy(r) }
        cv_renderer_set(r, 1, 0, 100, 0)
        var out = [Float](repeating: 9, count: 4 * 3000)
        for _ in 0..<3 { out.withUnsafeMutableBufferPointer { cv_renderer_render(r, $0.baseAddress!, 4, 3000) } }
        var peakL: Float = 0, peakR: Float = 0, spk: Float = 0
        for i in 0..<3000 {
            spk = max(spk, abs(out[4 * i]), abs(out[4 * i + 1]))
            peakL = max(peakL, abs(out[4 * i + 2])); peakR = max(peakR, abs(out[4 * i + 3]))
        }
        XCTAssertEqual(spk, 0); XCTAssertGreaterThan(peakL, 0.9); XCTAssertEqual(peakR, 0)

        // 6 声道：多余声道写 0；2 声道：只有 HD
        var six = [Float](repeating: 9, count: 6 * 100)
        six.withUnsafeMutableBufferPointer { cv_renderer_render(r, $0.baseAddress!, 6, 100) }
        XCTAssertTrue((0..<100).allSatisfy { six[6 * $0 + 4] == 0 && six[6 * $0 + 5] == 0 })
        var two = [Float](repeating: 9, count: 2 * 100)
        two.withUnsafeMutableBufferPointer { cv_renderer_render(r, $0.baseAddress!, 2, 100) }
        XCTAssertGreaterThan((0..<100).map { abs(two[2 * $0]) }.max()!, 0.5)

        // 扬声器：采集喂进核心后能播出来
        cv_renderer_set_speaker_volume(r, 1)
        XCTAssertEqual(cv_renderer_speaker_audible(r), 1)
        var t = 0
        var peak: Float = 0
        for _ in 0..<100 {
            var x = [Float](repeating: 0, count: 2 * 256)
            for i in 0..<256 { let v = sinf(2 * .pi * 1000 * Float(t + i) / 48000) * 0.5; x[2 * i] = v; x[2 * i + 1] = v }
            t += 256
            x.withUnsafeBufferPointer { cv_core_process(core, $0.baseAddress!, 256, 48000) }
            var o = [Float](repeating: 0, count: 4 * 256)
            o.withUnsafeMutableBufferPointer { cv_renderer_render(r, $0.baseAddress!, 4, 256) }
            peak = max(peak, (0..<256).map { abs(o[4 * $0]) }.max()!)
        }
        XCTAssertGreaterThan(peak, 0.1)
        var stats = [Double](repeating: 0, count: 2)
        stats.withUnsafeMutableBufferPointer { cv_renderer_stats(r, $0.baseAddress!) }
        XCTAssertGreaterThan(stats[0], 0)
    }

    func testAlignDelay() {
        XCTAssertEqual(cv_align_delay_ms(1, 0, 8, 4, .nan), LatencyModel.hdEnvelopeDelayMs(marginMs: 8))
        XCTAssertEqual(cv_align_delay_ms(0, 1, 8, 4, .nan),
                       max(LatencyModel.compatHapticDelayMs(marginMs: 8, controllerOutputMs: 4), 0))
        XCTAssertEqual(cv_align_delay_ms(0, 1, 8, 4, 12), 12)
        XCTAssertEqual(cv_align_delay_ms(0, 0, 8, 4, .nan), 0)
    }

    func testVersion() { XCTAssertEqual(cv_api_version(), 1) }
}
