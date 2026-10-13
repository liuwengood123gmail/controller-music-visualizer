import XCTest
@testable import ControllerMusicVisualizer

final class SettingsTests: XCTestCase {
    func testRoundTrip() throws {
        var s = ControllerSettings()
        s.enabled = false
        s.source = .massage
        s.musicMode = .bass
        s.preset = .pound
        s.intensity = 2.5
        s.hdEnabled = false
        s.lightRange = 0.4
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(ControllerSettings.self, from: data), s)
    }

    func testMissingAndInvalidFieldsFallBackToDefaults() throws {
        let json = #"{"intensity": 99, "musicMode": "不存在", "enabled": false}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(ControllerSettings.self, from: json)
        XCTAssertEqual(s.intensity, 3)                 // 夹回上限
        XCTAssertEqual(s.musicMode, ControllerSettings().musicMode)
        XCTAssertFalse(s.enabled)
        XCTAssertEqual(s.sensitivity, ControllerSettings().sensitivity)
    }

    func testAllLeftToGame() {
        var s = ControllerSettings()
        XCTAssertFalse(s.allLeftToGame)
        s.vibrationEnabled = false; s.triggersEnabled = false; s.lightEffects = false
        XCTAssertTrue(s.allLeftToGame)
    }

    func testStoreSavesAndRestoresByIdentity() {
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        let a = ControllerIdentity.dualSense(locationID: 0x1120000, serial: nil)
        let b = ControllerIdentity.gamepad(vendor: "Pro Controller", category: "Switch Pro Controller", index: 0)
        XCTAssertNil(store.load(a))
        var sa = ControllerSettings(); sa.musicMode = .envelope
        var sb = ControllerSettings(); sb.source = .massage
        store.save(sa, for: a)
        store.save(sb, for: b)
        XCTAssertEqual(store.load(a), sa)
        XCTAssertEqual(store.load(b), sb)
    }

    func testNewControllerCopiesSelectedSettings() {
        var selected = ControllerSettings()
        selected.musicMode = .bass
        selected.enabled = false
        let copy = ControllerSettings.initial(remembered: nil, copying: selected)
        XCTAssertEqual(copy.musicMode, .bass)
        XCTAssertTrue(copy.enabled)   // 新手柄默认启用
    }

    func testRememberedSettingsWinOverCopy() {
        var remembered = ControllerSettings(); remembered.source = .massage; remembered.enabled = false
        var selected = ControllerSettings(); selected.musicMode = .bass
        XCTAssertEqual(ControllerSettings.initial(remembered: remembered, copying: selected), remembered)
    }

    func testNoSelectionGivesDefaults() {
        XCTAssertEqual(ControllerSettings.initial(remembered: nil, copying: nil), ControllerSettings())
    }
}
