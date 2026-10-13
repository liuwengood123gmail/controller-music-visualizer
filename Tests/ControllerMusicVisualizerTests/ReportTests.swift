import XCTest
@testable import ControllerMusicVisualizer

final class ReportTests: XCTestCase {
    func testCRC32KnownValue() {
        XCTAssertEqual(DualSenseReport.crc32(Array("123456789".utf8)), 0xCBF4_3926)
    }

    func testUSBReportLayout() {
        var s = DualSenseOutputState()
        s.motorLeft = 10; s.motorRight = 20
        s.rgb = (1, 2, 3)
        s.playerLEDs = 0b00100
        let r = DualSenseReport.usb(s)
        XCTAssertEqual(r.count, 48)
        XCTAssertEqual(r[0], 0x02)
        XCTAssertEqual(r[1] & 0x03, 0x03)        // 马达强度生效 + 兼容震动
        XCTAssertEqual(r[1] & 0x0C, 0x0C)        // 两个扳机
        XCTAssertEqual(r[1 + 2], 20)             // 右马达
        XCTAssertEqual(r[1 + 3], 10)             // 左马达
        XCTAssertEqual(r[1 + 38], 0x04)          // 新固件兼容震动开关
        XCTAssertEqual(r[1 + 43], 0b00100 | 0x20)
        XCTAssertEqual(Array(r[(1 + 44)...(1 + 46)]), [1, 2, 3])
    }

    func testHDClearsVibrationFlags() {
        var s = DualSenseOutputState()
        s.hd = true
        s.triggers = false
        let c = DualSenseReport.common(s)
        XCTAssertEqual(c[0], 0)        // 两位都清零 = HD 模式
        XCTAssertEqual(c[38], 0)
    }

    func testRumbleLeftToGameOnlySetsBit1() {
        var s = DualSenseOutputState()
        s.rumble = false
        s.triggers = false
        s.lights = false
        let c = DualSenseReport.common(s)
        XCTAssertEqual(c[0], 0x02)
        XCTAssertEqual(c[1], 0)        // 灯光交给游戏：生效标志位不置
    }

    func testTriggersLeftToGameDoNotSetEffect() {
        var s = DualSenseOutputState()
        s.triggers = false
        s.resistance = 200
        let c = DualSenseReport.common(s)
        XCTAssertEqual(c[0] & 0x0C, 0)
        XCTAssertEqual(c[10], 0)
        XCTAssertEqual(c[21], 0)
    }

    func testResistanceWritesBothTriggers() {
        var s = DualSenseOutputState()
        s.resistance = 128
        let c = DualSenseReport.common(s)
        for base in [10, 21] {
            XCTAssertEqual(Array(c[base...(base + 2)]), [0x01, 0x08, 128])
        }
    }

    func testReleasedDefaults() {
        // 交出控制权时发默认值：马达 0、扳机关、灯条默认蓝
        var s = DualSenseOutputState()
        s.rgb = (0, 64, 255)
        let c = DualSenseReport.common(s)
        XCTAssertEqual(c[2], 0); XCTAssertEqual(c[3], 0)
        XCTAssertEqual(c[10], 0)
        XCTAssertEqual(Array(c[44...46]), [0, 64, 255])
        XCTAssertEqual(c[43], 0b00100 | 0x20)
    }

    func testBluetoothReportHasValidCRC() {
        var s = DualSenseOutputState()
        s.motorLeft = 77
        let r = DualSenseReport.bluetooth(s, seq: 3)
        XCTAssertEqual(r.count, 78)
        XCTAssertEqual(r[0], 0x31)
        XCTAssertEqual(r[1], 3 << 4)
        XCTAssertEqual(r[2], 0x10)
        let crc = DualSenseReport.crc32([0xA2] + r[0..<74])
        let stored = (0..<4).reduce(UInt32(0)) { $0 | UInt32(r[74 + $1]) << (8 * UInt32($1)) }
        XCTAssertEqual(crc, stored)
    }

    // MARK: - 输入报告

    private func usbInput(l2: UInt8, r2: UInt8, status: UInt8) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 64)
        b[0] = 0x01; b[5] = l2; b[6] = r2; b[53] = status
        return b
    }

    func testParseUSBInput() throws {
        let s = try XCTUnwrap(DualSenseReport.parseInput(reportID: 0x01, bytes: usbInput(l2: 255, r2: 0, status: 0x09)))
        XCTAssertEqual(s.l2, 1, accuracy: 0.001)
        XCTAssertEqual(s.r2, 0)
        XCTAssertEqual(s.batteryLevel, 95)
        XCTAssertFalse(s.charging)
    }

    func testParseUSBInputWithoutReportIDByte() throws {
        let bytes = Array(usbInput(l2: 0, r2: 51, status: 0x14).dropFirst())
        let s = try XCTUnwrap(DualSenseReport.parseInput(reportID: 0x01, bytes: bytes))
        XCTAssertEqual(s.r2, 0.2, accuracy: 0.001)
        XCTAssertTrue(s.charging)
        XCTAssertEqual(s.batteryLevel, 45)
    }

    func testParseBluetoothInputIsShiftedByOne() throws {
        var b = [UInt8](repeating: 0, count: 78)
        b[0] = 0x31; b[6] = 128; b[7] = 255; b[54] = 0x2A   // 已充满
        let s = try XCTUnwrap(DualSenseReport.parseInput(reportID: 0x31, bytes: b))
        XCTAssertEqual(s.l2, 128.0 / 255, accuracy: 0.001)
        XCTAssertEqual(s.r2, 1, accuracy: 0.001)
        XCTAssertEqual(s.batteryLevel, 100)
    }

    func testParseRejectsShortOrUnknownReports() {
        XCTAssertNil(DualSenseReport.parseInput(reportID: 0x01, bytes: [0x01, 0, 0]))
        XCTAssertNil(DualSenseReport.parseInput(reportID: 0x77, bytes: [UInt8](repeating: 0, count: 64)))
    }
}
