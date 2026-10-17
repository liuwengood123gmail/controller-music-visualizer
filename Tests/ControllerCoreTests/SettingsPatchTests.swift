import XCTest
@testable import ControllerCore

final class SettingsPatchTests: XCTestCase {
    func testDiffAndApply() {
        let old = ControllerSettings()
        var new = old
        new.musicMode = .bass
        new.speakerVolume = 0.8
        let patch = SettingsPatch(from: old, to: new)
        XCTAssertEqual(patch.musicMode, .bass)
        XCTAssertEqual(patch.speakerVolume, 0.8)
        XCTAssertNil(patch.intensity)
        XCTAssertEqual(patch.apply(to: old), new)
    }

    func testPatchDoesNotOverwriteOtherFields() {
        // 引擎里 L2/R2 把强度改成了 2.0，界面发来只改模式的补丁，强度不能被覆盖
        var engine = ControllerSettings(); engine.intensity = 2
        var p = SettingsPatch(); p.musicMode = .envelope
        let merged = p.apply(to: engine)
        XCTAssertEqual(merged.intensity, 2)
        XCTAssertEqual(merged.musicMode, .envelope)
    }

    func testApplyClampsValues() {
        var p = SettingsPatch(); p.intensity = 9; p.speed = 0
        let s = p.apply(to: ControllerSettings())
        XCTAssertEqual(s.intensity, 3)
        XCTAssertEqual(s.speed, 0.5)
    }

    func testEmptyAndCodable() throws {
        XCTAssertTrue(SettingsPatch().isEmpty)
        var p = SettingsPatch(); p.source = .massage; p.preset = .random
        let back = try JSONDecoder().decode(SettingsPatch.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back, p)
        XCTAssertFalse(back.isEmpty)
    }
}
