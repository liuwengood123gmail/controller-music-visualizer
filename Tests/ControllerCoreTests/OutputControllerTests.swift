import XCTest
@testable import ControllerCore

final class OutputControllerTests: XCTestCase {
    private var now = 0.0
    private var sent: [[UInt8]] = []

    private func make(bluetooth: Bool = false) -> DualSenseOutputController {
        DualSenseOutputController(bluetooth: bluetooth, clock: { [unowned self] in self.now }) { [unowned self] r in
            self.sent.append(r); return true
        }
    }

    /// USB 报告里 common 段第 i 字节
    private func c(_ r: [UInt8], _ i: Int) -> UInt8 { r[1 + i] }

    func testFirstSendAndKeepAlive() {
        let o = make()
        XCTAssertTrue(o.send())
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].count, 48)
        XCTAssertEqual(sent[0][0], 0x02)
        // 状态不变、未到 0.1 秒：不重发
        now = 0.05; o.set(left: 0, right: 0)
        XCTAssertEqual(sent.count, 1)
        // 超过 0.1 秒：定期重发
        now = 0.16; o.set(left: 0, right: 0)
        XCTAssertEqual(sent.count, 2)
    }

    func testChangesAreSentOnNextTick() {
        let o = make()
        o.send()
        o.setLight(1, 0, 0)
        o.setTriggerResistance(0.5)
        o.setPlayerLEDs(0b11111)
        XCTAssertEqual(sent.count, 1)            // 只改状态，不立即发
        now = 0.01; o.set(left: 1, right: 0.5)   // tick
        XCTAssertEqual(sent.count, 2)
        let r = sent[1]
        XCTAssertEqual(c(r, 3), 255)             // 左马达
        XCTAssertEqual(c(r, 2), 128)             // 右马达
        XCTAssertEqual(c(r, 44), 255); XCTAssertEqual(c(r, 45), 0); XCTAssertEqual(c(r, 46), 0)
        XCTAssertEqual(c(r, 12), 128)            // 扳机阻尼
        XCTAssertEqual(c(r, 43), 0b11111 | 0x20)
    }

    func testHandingOverRumbleSendsDefaultsOnceThenOnlyBit1() {
        let o = make()
        o.send()
        o.set(left: 1, right: 1)                 // 状态变了：这个 tick 就发
        XCTAssertEqual(sent.count, 2)
        o.controlsRumble = false                 // 交出震动：立即发一次默认值
        XCTAssertEqual(sent.count, 3)
        XCTAssertEqual(c(sent[2], 0) & 0x03, 0x03)
        XCTAssertEqual(c(sent[2], 2), 0); XCTAssertEqual(c(sent[2], 3), 0)
        now = 0.2; o.set(left: 1, right: 1)      // 之后震动交给游戏：只置 bit1
        XCTAssertEqual(c(sent[3], 0) & 0x03, 0x02)
    }

    func testEverythingLeftToGameSendsNothing() {
        let o = make()
        o.controlsRumble = false; o.controlsTriggers = false; o.controlsLights = false
        let before = sent.count
        now = 1; o.set(left: 1, right: 1)
        now = 2; XCTAssertTrue(o.send())
        XCTAssertEqual(sent.count, before)
    }

    func testHDModeClearsVibrationBits() {
        let o = make()
        o.hdHaptics = true
        o.send()
        XCTAssertEqual(c(sent[0], 0) & 0x03, 0)
        XCTAssertEqual(c(sent[0], 38), 0)
    }

    func testSpeakerOnThenOffSendsPathZeroOnce() {
        let o = make()
        o.send()
        o.setSpeaker(true, hwVolume: 0x64, preamp: 2)
        XCTAssertEqual(c(sent.last!, 7), 0x30)
        XCTAssertEqual(c(sent.last!, 37), 2)
        o.setSpeaker(false)
        XCTAssertEqual(c(sent.last!, 0) & 0x80, 0x80)
        XCTAssertEqual(c(sent.last!, 7), 0)
        now = 1; o.set(left: 0, right: 0)
        XCTAssertEqual(c(sent.last!, 0) & 0x80, 0)    // 之后不再碰扬声器
    }

    func testStopRestoresDefaults() {
        let o = make()
        o.hdHaptics = true
        o.setLight(1, 1, 1); o.setTriggerResistance(1); o.setPlayerLEDs(0b11111)
        o.setSpeaker(true)
        o.stop()
        let r = sent.last!
        XCTAssertEqual(Array(r[(1 + 44)...(1 + 46)]), [0, 64, 255])
        XCTAssertEqual(c(r, 43), 0b00100 | 0x20)
        XCTAssertEqual(c(r, 10), 0)               // 扳机效果关
        XCTAssertEqual(c(r, 0) & 0x03, 0x03)      // 回到兼容震动
        XCTAssertEqual(c(r, 7), 0)                // 扬声器路径 0
    }

    func testBluetoothSequenceAndCRC() {
        let o = make(bluetooth: true)
        o.send(); now = 1; o.set(left: 0, right: 0); now = 2; o.set(left: 0, right: 0)
        XCTAssertEqual(sent.map { $0[0] }, [0x31, 0x31, 0x31])
        XCTAssertEqual(sent.map { $0[1] >> 4 }, [0, 1, 2])
        for r in sent {
            let crc = DualSenseReport.crc32([0xA2] + r[0..<74])
            let stored = (0..<4).reduce(UInt32(0)) { $0 | UInt32(r[74 + $1]) << (8 * UInt32($1)) }
            XCTAssertEqual(crc, stored)
        }
    }
}
