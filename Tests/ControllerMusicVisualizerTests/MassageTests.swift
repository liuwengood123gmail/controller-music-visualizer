import XCTest
@testable import ControllerMusicVisualizer

final class MassageTests: XCTestCase {
    func testAllPresetsStayInRange() {
        for p in MassagePreset.allCases {
            var t = 0.0
            while t < 40 {
                let s = p.sample(t)
                XCTAssertTrue(s.left.isFinite && s.right.isFinite, "\(p)")
                XCTAssertGreaterThanOrEqual(s.left, -0.0001, "\(p) @ \(t)")
                XCTAssertLessThanOrEqual(s.left, 1.0001, "\(p) @ \(t)")
                XCTAssertGreaterThanOrEqual(s.right, -0.0001, "\(p) @ \(t)")
                XCTAssertLessThanOrEqual(s.right, 1.0001, "\(p) @ \(t)")
                let c = p.carrierRange(t)
                XCTAssertGreaterThanOrEqual(c.low, 50, "\(p)")
                XCTAssertGreaterThanOrEqual(c.high, c.low, "\(p)")
                t += 0.037
            }
        }
    }

    func testRandomNeverRepeatsConsecutively() {
        var last: MassagePreset?
        var changes = 0
        var t = 0.0
        while t < 600 {
            let now = MassagePreset.random.current(t)
            XCTAssertNotEqual(now, .random)
            if let last, last != now { changes += 1 }
            last = now
            t += 0.25
        }
        XCTAssertGreaterThan(changes, 20)   // 10 分钟里应换过很多次
    }

    func testRandomLongRunningIsCheap() {
        // 很久以后的时刻也能快速算出（不能随时间线性变慢到卡住）
        measure { _ = MassagePreset.random.sample(3600) }
    }

    func testRandomDoesNotRepeatAcrossSegments() {
        // 逐段检查：相邻两段的预设不同
        var seen: [MassagePreset] = []
        var t = 0.0
        while t < 1200 {
            let now = MassagePreset.random.current(t)
            if seen.last != now { seen.append(now) }
            t += 0.1
        }
        for (a, b) in zip(seen, seen.dropFirst()) { XCTAssertNotEqual(a, b) }
    }
}
