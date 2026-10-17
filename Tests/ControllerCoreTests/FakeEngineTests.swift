import XCTest
@testable import ControllerCore

// Linux 的 XCTest 发现测试时不认 @MainActor 的方法（会崩），所以测试方法本身不隔离，
// 里面用 MainActor.assumeIsolated（XCTest 在主线程跑测试）
final class FakeEngineTests: XCTestCase {
    func testSubscribeGetsStateImmediatelyAndCancelStops() {
        MainActor.assumeIsolated {
            let e = FakeControllerEngine(scenario: .multi)
            var states = 0, meters = 0
            var sub: EngineSubscription? = e.subscribe { u in
                switch u {
                case .state: states += 1
                case .meters: meters += 1
                case .event: break
                }
            }
            XCTAssertEqual(states, 1); XCTAssertEqual(meters, 1)
            e.start()
            XCTAssertEqual(states, 2)
            XCTAssertNotNil(sub)
            sub = nil
            e.stop()
            XCTAssertEqual(states, 2)
        }
    }

    func testStartActivatesAndMetersFlow() {
        MainActor.assumeIsolated {
            let e = FakeControllerEngine(scenario: .multi)
            XCTAssertTrue(e.state.canStart)
            e.start()
            XCTAssertTrue(e.state.running)
            XCTAssertEqual(e.state.capture, .running)
            XCTAssertTrue(e.state.controllers.allSatisfy { $0.status.isActive })
            XCTAssertNil(e.state.controller("fake-ds-usb")?.latency)   // 默认没开扬声器
            e.advance(by: 0.033)
            XCTAssertEqual(e.meters.count, 3)
            e.stop()
            XCTAssertTrue(e.meters.isEmpty)
            XCTAssertFalse(e.state.controllers.contains { $0.status.isActive })
        }
    }

    func testUpdateSettingsAppliesOnlyPatchedFields() {
        MainActor.assumeIsolated {
            let e = FakeControllerEngine(scenario: .singleUSB)
            var p = SettingsPatch(); p.speakerEnabled = true; p.intensity = 9
            e.updateSettings("fake-ds-usb", p)
            let s = e.state.controller("fake-ds-usb")!.settings
            XCTAssertTrue(s.speakerEnabled)
            XCTAssertEqual(s.intensity, 3)          // 补丁也经过 sanitized
            XCTAssertEqual(s.musicMode, ControllerSettings().musicMode)
            e.start()
            XCTAssertNotNil(e.state.controller("fake-ds-usb")?.latency)
        }
    }

    func testNoControllersCannotStart() {
        MainActor.assumeIsolated {
            let e = FakeControllerEngine(scenario: .none)
            XCTAssertFalse(e.state.canStart)
            e.start()
            XCTAssertFalse(e.state.running)
            XCTAssertNotNil(e.state.error)
        }
    }

    func testCaptureDenied() {
        MainActor.assumeIsolated {
            let e = FakeControllerEngine(scenario: .captureDenied)
            e.start()
            if case .failed = e.state.capture {} else { XCTFail("capture should fail") }
        }
    }

    func testDisconnectEvent() {
        MainActor.assumeIsolated {
            let e = FakeControllerEngine(scenario: .multi)
            var events: [EngineEvent] = []
            let sub = e.subscribe { if case .event(let ev) = $0 { events.append(ev) } }
            e.simulateDisconnect("fake-8bitdo")
            XCTAssertEqual(events, [.controllerDisconnected("fake-8bitdo")])
            XCTAssertEqual(e.state.controllers.count, 2)
            _ = sub
        }
    }

    func testGlobalOptions() {
        MainActor.assumeIsolated {
            let e = FakeControllerEngine()
            e.setGlobalOptions(GlobalOptionsPatch(blockHomeButton: false))
            XCTAssertFalse(e.state.options.blockHomeButton)
            e.setGlobalOptions(GlobalOptionsPatch())
            XCTAssertFalse(e.state.options.blockHomeButton)
        }
    }

    func testEngineStateCodableRoundTrip() throws {
        try MainActor.assumeIsolated {
            let e = FakeControllerEngine(scenario: .multi)
            var p = SettingsPatch(); p.speakerEnabled = true
            e.updateSettings("fake-ds-usb", p)
            e.start()
            var s = e.state
            s.notice = Bilingual(zh: "提示", en: "Notice")
            s.capture = .failed(Bilingual(zh: "失败", en: "Failed"))
            let data = try JSONEncoder().encode(s)
            XCTAssertEqual(try JSONDecoder().decode(EngineState.self, from: data), s)
        }
    }
}
