import XCTest
@testable import ControllerCore

final class ReconcilerTests: XCTestCase {
    let dsUSB = ControllerIdentity.dualSense(locationID: 0x1120000, serial: nil)
    let dsUSB2 = ControllerIdentity.dualSense(locationID: 0x1130000, serial: nil)
    let dsBT = ControllerIdentity.dualSense(locationID: nil, serial: "aa-bb")
    let pro = ControllerIdentity.gamepad(vendor: "Pro Controller", category: "Switch Pro Controller", index: 0)

    func testNothingChanged() {
        let p = SessionReconciler.plan(existing: [dsUSB, pro], found: [pro, dsUSB])
        XCTAssertEqual(p.slots, [.keep(session: 0, found: 1), .keep(session: 1, found: 0)])
        XCTAssertEqual(p.removed, [])
        XCTAssertFalse(p.changed)
    }

    func testAddKeepsOrderNewAtEnd() {
        let p = SessionReconciler.plan(existing: [pro], found: [dsUSB, pro])
        XCTAssertEqual(p.slots, [.keep(session: 0, found: 1), .add(found: 0)])
        XCTAssertTrue(p.changed)
    }

    func testRemove() {
        let p = SessionReconciler.plan(existing: [dsUSB, pro], found: [pro])
        XCTAssertEqual(p.slots, [.keep(session: 1, found: 0)])
        XCTAssertEqual(p.removed, [0])
        XCTAssertTrue(p.changed)
    }

    func testUSBToBluetoothMigratesSameSession() {
        let p = SessionReconciler.plan(existing: [dsUSB, pro], found: [pro, dsBT])
        XCTAssertEqual(p.slots, [.migrate(session: 0, found: 1), .keep(session: 1, found: 0)])
        XCTAssertEqual(p.removed, [])
        XCTAssertFalse(p.changed)    // 会话列表没变（同一个会话换了连接方式）
    }

    func testNoMigrationWhenAmbiguous() {
        // 两台 DualSense 消失、一台出现：无法确定是哪台，不迁移
        let p = SessionReconciler.plan(existing: [dsUSB, dsUSB2], found: [dsBT])
        XCTAssertEqual(p.slots, [.add(found: 0)])
        XCTAssertEqual(p.removed, [0, 1])
    }

    func testGamepadNeverMigrates() {
        let pro2 = ControllerIdentity.gamepad(vendor: "Xbox", category: "Xbox One", index: 0)
        let p = SessionReconciler.plan(existing: [pro], found: [pro2])
        XCTAssertEqual(p.slots, [.add(found: 0)])
        XCTAssertEqual(p.removed, [0])
    }
}
