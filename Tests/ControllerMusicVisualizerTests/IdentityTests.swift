import XCTest
@testable import ControllerMusicVisualizer

final class IdentityTests: XCTestCase {
    func testDualSenseUSBUsesLocationID() {
        let id = ControllerIdentity.dualSense(locationID: 0x1120000, serial: nil)
        XCTAssertEqual(id.key, "ds:loc:1120000")
        XCTAssertEqual(id.kind, .dualSense)
    }

    func testDualSenseBluetoothPrefersSerial() {
        let id = ControllerIdentity.dualSense(locationID: 0x1120000, serial: "aa-bb-cc-dd-ee-ff")
        XCTAssertEqual(id.key, "ds:sn:aa-bb-cc-dd-ee-ff")
        XCTAssertEqual(ControllerIdentity.dualSense(locationID: 0x10, serial: "").key, "ds:loc:10")
    }

    func testTwoDualSensesHaveDifferentIdentities() {
        XCTAssertNotEqual(ControllerIdentity.dualSense(locationID: 0x1120000, serial: nil),
                          ControllerIdentity.dualSense(locationID: 0x1130000, serial: nil))
    }

    func testGamepadIdentityIncludesIndex() {
        let a = ControllerIdentity.gamepad(vendor: "Pro Controller", category: "Switch Pro Controller", index: 0)
        let b = ControllerIdentity.gamepad(vendor: "Pro Controller", category: "Switch Pro Controller", index: 1)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.kind, .gamepad)
    }

    // 实测数据（USB 下的 DualSense）：LocationID 0x1120000
    private let output = "AppleUSBAudioEngine:Sony Interactive Entertainment:DualSense Wireless Controller:1120000:1"
    private let input = "AppleUSBAudioEngine:Sony Interactive Entertainment:DualSense Wireless Controller:1120000:2"

    func testAudioOutputMatchesLocationID() {
        XCTAssertTrue(DualSenseAudioMatch.matches(uid: output, locationID: 0x1120000))
    }

    func testAudioInputDeviceIsNotMatched() {
        XCTAssertFalse(DualSenseAudioMatch.matches(uid: input, locationID: 0x1120000))
    }

    func testOtherControllerIsNotMatched() {
        XCTAssertFalse(DualSenseAudioMatch.matches(uid: output, locationID: 0x1130000))
        // 后缀相似但位置不同：0x120000 不应匹配 1120000
        XCTAssertFalse(DualSenseAudioMatch.matches(uid: output, locationID: 0x120000))
    }
}
