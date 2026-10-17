import XCTest
@testable import ControllerCore

final class SessionEngineTests: XCTestCase {
    private func flags(vibration: Bool = true, triggers: Bool = true, lights: Bool = true,
                       adaptive: Bool = true, leds: Bool = true, hd: Bool = false) -> SessionFlags {
        SessionFlags(vibration: vibration, triggers: triggers, lights: lights, adaptiveTriggers: adaptive,
                     playerLEDs: leds, hdActive: hd)
    }

    private func loud() -> MusicFrame {
        var m = MusicFrame()
        m.bass = (1, 1); m.bassRelative = (1, 1); m.fullRelative = (1, 1)
        m.light = (1, 1); m.meter = (1, 1); m.color = (1, 0, 0)
        return m
    }

    private func input(_ s: ControllerSettings, _ f: SessionFlags, music: MusicFrame = MusicFrame(),
                       triggers: (Float, Float) = (0, 0), align: Double = 0) -> SessionTickInput {
        SessionTickInput(settings: s, flags: f, music: music, triggers: triggers, dt: 0.01, alignDelayMs: align)
    }

    func testCompatMotorsFollowMassage() {
        var s = ControllerSettings(); s.source = .massage; s.preset = .pound
        var e = SessionEngine()
        var peak: Float = 0
        for _ in 0..<300 {
            let c = e.tick(input(s, flags()))
            XCTAssertNil(c.hd)
            XCTAssertEqual(c.motors.left, c.level.left, accuracy: 1e-6)
            peak = max(peak, c.motors.left, c.motors.right)
        }
        XCTAssertGreaterThan(peak, 0.3)
    }

    func testHDActiveZerosMotorsAndGivesCarrier() {
        var s = ControllerSettings(); s.source = .massage; s.preset = .pound
        var e = SessionEngine()
        var sawHD = false
        for _ in 0..<200 {
            let c = e.tick(input(s, flags(hd: true)))
            XCTAssertEqual(c.motors.left, 0); XCTAssertEqual(c.motors.right, 0)
            let hd = try! XCTUnwrap(c.hd)
            XCTAssertFalse(hd.useMusic)
            XCTAssertGreaterThanOrEqual(hd.freq, 50)
            if hd.left > 0.1 { sawHD = true }
        }
        XCTAssertTrue(sawHD)
    }

    func testVibrationOffGivesZeroLevel() {
        var s = ControllerSettings(); s.source = .massage
        var e = SessionEngine()
        for _ in 0..<100 {
            let c = e.tick(input(s, flags(vibration: false)))
            XCTAssertEqual(c.level.left, 0); XCTAssertEqual(c.motors.right, 0)
        }
    }

    func testTriggersAdjustIntensity() {
        let s = ControllerSettings()
        var e = SessionEngine()
        let up = e.tick(input(s, flags(), triggers: (0, 1)))
        XCTAssertEqual(try XCTUnwrap(up.intensity), 1.01, accuracy: 1e-5)
        XCTAssertEqual(up.triggerResistance, s.triggerResistance)
        let none = e.tick(input(s, flags(), triggers: (0.02, 0.02)))   // 死区
        XCTAssertNil(none.intensity)
        let off = e.tick(input(s, flags(triggers: false), triggers: (0, 1)))
        XCTAssertNil(off.intensity); XCTAssertNil(off.triggerResistance)
        let noAdaptive = e.tick(input(s, flags(adaptive: false)))
        XCTAssertNil(noAdaptive.triggerResistance)
    }

    func testIntensityIsClamped() {
        var s = ControllerSettings(); s.intensity = 2.999
        var e = SessionEngine()
        XCTAssertEqual(e.tick(input(s, flags(), triggers: (0, 1))).intensity, 3)
        s.intensity = 0.001
        XCTAssertEqual(e.tick(input(s, flags(), triggers: (1, 0))).intensity, 0)
    }

    func testLightsAndPlayerLEDs() {
        let s = ControllerSettings()
        var e = SessionEngine()
        var c = SessionCommands()
        for _ in 0..<50 { c = e.tick(input(s, flags(), music: loud())) }
        let light = try! XCTUnwrap(c.light)
        XCTAssertGreaterThan(light.r, light.b)
        XCTAssertNotNil(c.playerLEDs)
        c = e.tick(input(s, flags(leds: false), music: loud()))
        XCTAssertNotNil(c.light); XCTAssertNil(c.playerLEDs)
        c = e.tick(input(s, flags(lights: false), music: loud()))
        XCTAssertNil(c.light); XCTAssertNil(c.playerLEDs)
    }

    func testRandomNowOnlyForRandomPreset() {
        var s = ControllerSettings(); s.source = .massage; s.preset = .random
        var e = SessionEngine()
        XCTAssertNotNil(e.tick(input(s, flags())).randomNow)
        s.preset = .knead
        XCTAssertNil(e.tick(input(s, flags())).randomNow)
    }

    func testAlignDelayShiftsOutput() {
        var s = ControllerSettings(); s.source = .massage; s.preset = .pound
        var a = SessionEngine(), b = SessionEngine()
        var direct: [Float] = [], delayed: [Float] = []
        for _ in 0..<300 {
            direct.append(a.tick(input(s, flags())).motors.left)
            delayed.append(b.tick(input(s, flags(), align: 50)).motors.left)
        }
        // 50ms = 5 个 tick
        for i in 20..<300 { XCTAssertEqual(delayed[i], direct[i - 5], accuracy: 0.02) }
    }

    func testHDFrequency() {
        XCTAssertEqual(SessionEngine.hdFrequency((60, 200), amplitude: 0), 200)
        XCTAssertEqual(SessionEngine.hdFrequency((60, 200), amplitude: 1), 60)
        XCTAssertEqual(SessionEngine.hdFrequency((20, 200), amplitude: 1), 50)
    }

    func testResetRestartsMassageClock() {
        var s = ControllerSettings(); s.source = .massage; s.preset = .pound
        var e = SessionEngine()
        let first = (0..<30).map { _ in e.tick(input(s, flags())).motors.left }
        e.reset()
        let again = (0..<30).map { _ in e.tick(input(s, flags())).motors.left }
        XCTAssertEqual(first, again)
    }
}
