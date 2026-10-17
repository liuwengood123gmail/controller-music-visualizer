import XCTest
import ControllerCore
@testable import ControllerCAPI

/// contract/fixtures 的样例经 C 接口跑一遍（Kotlin 端的 ContractTest 读同一组文件）
final class ContractTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("contract/fixtures")

    static func load(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: fixtures.appendingPathComponent(name))
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    static func json(_ v: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]), as: UTF8.self)
    }

    /// 调用一个「写字符串到缓冲区」的 C 函数
    static func call(_ f: (UnsafeMutablePointer<CChar>?, Int32) -> Int32) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = buf.withUnsafeMutableBufferPointer { f($0.baseAddress, Int32($0.count)) }
        XCTAssertGreaterThanOrEqual(n, 0)
        return String(cString: buf)
    }

    static func object(_ s: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(s.utf8)) as! [String: Any]
    }

    /// 数字按 Float 精度比较
    static func assertSame(_ a: [String: Any], _ b: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Set(a.keys), Set(b.keys), file: file, line: line)
        for (k, va) in a {
            let vb = b[k]
            if let x = va as? NSNumber, let y = vb as? NSNumber, !(va is Bool) {
                XCTAssertEqual(x.doubleValue, y.doubleValue, accuracy: 1e-6, "\(k)", file: file, line: line)
            } else {
                XCTAssertEqual("\(va)", "\(vb ?? "nil")", "\(k)", file: file, line: line)
            }
        }
    }

    func testSettingsFixtures() throws {
        for name in ["settings-default.json", "settings-old-version.json", "settings-out-of-range.json"] {
            let f = try Self.load(name)
            let input = Self.json(f["input"]!)
            let out = Self.call { cv_settings_sanitize(input, $0, $1) }
            Self.assertSame(Self.object(out), f["expected"] as! [String: Any])
        }
    }

    func testPatchFixture() throws {
        let f = try Self.load("settings-patch.json")
        let s = Self.json(f["settings"]!), p = Self.json(f["patch"]!)
        let out = Self.call { cv_settings_apply_patch(s, p, $0, $1) }
        Self.assertSame(Self.object(out), f["expected"] as! [String: Any])
    }

    func testEnumsFixture() throws {
        let f = try Self.load("enums.json")
        XCTAssertEqual(f["source"] as! [String], Source.allCases.map(\.rawValue))
        XCTAssertEqual(f["musicMode"] as! [String], MusicMode.allCases.map(\.rawValue))
        XCTAssertEqual(f["preset"] as! [String], MassagePreset.allCases.map(\.rawValue))
    }

    func testReconcileFixture() throws {
        let f = try Self.load("reconcile.json")
        for c in f["cases"] as! [[String: Any]] {
            let input = Self.json(["existing": c["existing"]!, "found": c["found"]!])
            let out = Self.object(Self.call { cv_reconcile(input, $0, $1) })
            XCTAssertEqual(Self.json(out), Self.json(c["expected"]!))
        }
    }
}
