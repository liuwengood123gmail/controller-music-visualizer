import XCTest
import ControllerCore   // 故意不用 @testable：这里能编译通过，平台层（macOS App 等）就能用到这些接口

/// 只验证「平台层用得到」：覆盖 macOS App 用到的全部 ControllerCore 符号（类型、构造器、属性、方法）。
/// 行为本身在 ControllerCoreTests 里测
final class PublicAPITests: XCTestCase {
    func testSettingsAndStore() {
        var s = ControllerSettings()
        s.enabled = true; s.source = .music; s.musicMode = .beat; s.sensitivity = 0.5; s.responsiveness = 0.7
        s.preset = .knead; s.speed = 1; s.intensity = 1; s.vibrationEnabled = true; s.hdEnabled = true
        s.triggersEnabled = true; s.triggerResistance = 0.5; s.lightEffects = true; s.lightSpeed = 0.3
        s.lightRange = 1; s.speakerEnabled = false; s.speakerVolume = SpeakerVolume.defaultVolume
        XCTAssertFalse(s.allLeftToGame)
        _ = s.sanitized
        let store = SettingsStore(defaults: InMemoryStore())
        let id = ControllerIdentity.dualSense(locationID: 1, serial: nil)
        store.save(s, for: id)
        XCTAssertEqual(store.load(id), s)
        _ = ControllerSettings.initial(remembered: nil, copying: s)
        _ = SettingsStore(defaults: UserDefaults.standard)
        _ = Source.allCases.map { ($0.id, $0.title) }
        _ = MusicMode.allCases.map { ($0.id, $0.title, $0.carrierRange) }
        _ = MassagePreset.allCases.map { ($0.id, $0.title, $0.icon, $0.sample(0), $0.hue(0), $0.carrierRange(0), $0.current(0)) }
    }

    func testIdentity() {
        let a = ControllerIdentity.dualSense(locationID: 1, serial: "x")
        let b = ControllerIdentity.dualSenseGameController(index: 0)
        let c = ControllerIdentity.gamepad(vendor: "8BitDo", category: "Switch Pro", index: 0)
        XCTAssertEqual(a.kind, .dualSense)
        XCTAssertEqual(c.kind, .gamepad)
        _ = [a.key, b.key, c.key]
        _ = DualSenseAudioMatch.matches(uid: "", locationID: 1)
    }

    func testReportsAndOutputController() {
        _ = DualSenseReport.parseInput(reportID: 1, bytes: [])
        var input = DualSenseInputState()
        input.l2 = 0; input.r2 = 0
        _ = (input.batteryLevel, input.charging)
        let o = DualSenseOutputController(bluetooth: false) { _ in true }
        o.hdHaptics = true; o.controlsRumble = true; o.controlsTriggers = true; o.controlsLights = true
        _ = o.bluetooth
        o.setSpeaker(true, hwVolume: 0x64, preamp: 2)
        o.set(left: 0, right: 0); o.setTriggerResistance(0); o.setLight(0, 0, 0); o.setPlayerLEDs(0)
        XCTAssertTrue(o.send())
        o.stop()
    }

    func testAudioAndAnalysis() {
        let waveform = HapticWaveform()
        let feed = SpeakerFeed(highpassHz: 200)
        let analyzer = MusicAnalyzer()
        analyzer.waveform = waveform
        analyzer.reset()
        let zeros = [Float](repeating: 0, count: 64)
        zeros.withUnsafeBufferPointer { p in
            analyzer.process(left: p.baseAddress!, right: p.baseAddress!, frames: 64, sampleRate: 48000)
            feed.write(left: p.baseAddress!, right: p.baseAddress!, frames: 64, sampleRate: 48000)
        }
        _ = analyzer.current
        var tuning = SpeakerTuning.load(from: InMemoryStore())
        tuning = SpeakerTuning()
        _ = (tuning.hwVolume, tuning.preamp, tuning.highpassHz, tuning.bufferMs, tuning.ioFrames,
             tuning.tapFrames, tuning.hapticsDelayMs)
        let r = ControllerAudioRenderer(sampleRate: 48000, waveform: waveform, feed: feed, haptics: true, tuning: tuning)
        r.set(left: 0, right: 0, freq: 100, useMusic: true)
        r.setSpeakerGain(SpeakerVolume.gain(0.5))
        _ = (r.speakerAudible, r.marginMs, r.underruns)
        let p = UnsafeMutablePointer<Float>.allocate(capacity: 64)
        defer { p.deallocate() }
        r.render(speakerLeft: p, speakerRight: p, hapticLeft: p, hapticRight: p, frames: 64)
    }

    func testLatency() {
        var t = DeviceTiming()
        t.sampleRate = 48000; t.bufferFrames = 128; t.safetyOffset = 0; t.deviceLatency = 0; t.streamLatency = 0
        _ = (t.ms, t.totalFrames)
        let b = LatencyModel.breakdown(tapInput: t, marginMs: 5, controller: t, macOutput: nil)
        _ = (b.tapCaptureMs, b.marginMs, b.controllerOutputMs, b.extraMs, b.controllerTotalMs)
        _ = LatencyModel.minMarginMs(chunkFrames: 128, outBlockFrames: 128, sampleRate: 48000)
        _ = LatencyModel.compatHapticDelayMs(marginMs: 5, controllerOutputMs: 4)
        _ = LatencyModel.hdEnvelopeDelayMs(marginMs: 5)
    }

    func testSessionEngine() {
        var e = SessionEngine()
        e.reset()
        let flags = SessionFlags(vibration: true, triggers: true, lights: true, adaptiveTriggers: true,
                                 playerLEDs: true, hdActive: true)
        let c = e.tick(SessionTickInput(settings: ControllerSettings(), flags: flags, music: MusicFrame(),
                                        triggers: (0, 0), dt: 0.01, alignDelayMs: 0))
        _ = (c.intensity, c.triggerResistance, c.motors.left, c.hd?.freq, c.light?.r, c.playerLEDs, c.level.left, c.randomNow)
        if let hd = c.hd { _ = (hd.left, hd.right, hd.freq, hd.useMusic) }
    }

    func testReconciler() {
        let a = ControllerIdentity.dualSense(locationID: 1, serial: nil)
        let plan = SessionReconciler.plan(existing: [a], found: [a])
        for slot in plan.slots {
            switch slot {
            case .keep(let s, let f), .migrate(let s, let f): _ = (s, f)
            case .add(let f): _ = f
            }
        }
        _ = (plan.removed, plan.changed)
    }

    func testEngineAPI() {
        MainActor.assumeIsolated {
            let engine: ControllerEngine = FakeControllerEngine(scenario: .multi)
            XCTAssertEqual(engine.apiVersion, engineAPIVersion)
            let sub = engine.subscribe { update in
                switch update {
                case .state(let s): _ = (s.running, s.canStart, s.capture, s.notice, s.error, s.options.blockHomeButton)
                case .meters(let m): _ = m.values.map { ($0.left, $0.right) }
                case .event(let e): _ = e
                }
            }
            var p = SettingsPatch(from: ControllerSettings(), to: ControllerSettings())
            XCTAssertTrue(p.isEmpty)
            p.intensity = 2
            let id = engine.state.controllers[0].id
            engine.updateSettings(id, p)
            engine.focus(id)
            engine.setGlobalOptions(GlobalOptionsPatch(blockHomeButton: false))
            engine.start()
            let c = engine.state.controller(id)!
            _ = (c.id, c.name, c.link?.title.text, c.battery?.level, c.battery?.charging, c.title, c.latency, c.audioStats, c.randomNow)
            _ = (c.capabilities.isDualSense, c.capabilities.hasLight, c.capabilities.hasAdaptiveTriggers,
                 c.capabilities.hasHD, c.capabilities.hasSpeaker, c.capabilities.canVibrate)
            _ = (c.status.isActive, c.status.engineName.text, c.status.error)
            engine.stop()
            _ = engine.meters[id] ?? .zero
            if let fake = engine as? FakeControllerEngine {
                fake.advance(by: 0.03)
                _ = FakeControllerEngine.Scenario(rawValue: "multi")
            }
            sub.cancel()

            // 平台引擎的组件
            let b = EngineBroadcaster()
            let s2 = b.subscribe { _ in }
            b.publish(.meters([:]))
            _ = b.hasSubscribers
            _ = s2
            _ = EngineState(running: false, canStart: false, capture: .off, controllers: [], notice: nil, error: nil,
                            options: GlobalOptions(blockHomeButton: true))
            _ = ControllerInfo(id: "x", name: "DualSense", link: .usb, battery: Battery(level: 1, charging: false),
                               capabilities: Capabilities(isDualSense: true, hasLight: true, hasAdaptiveTriggers: true,
                                                          hasHD: true, hasSpeaker: true, canVibrate: true),
                               settings: ControllerSettings(),
                               status: SessionStatus(isActive: false, engineName: Bilingual(zh: "—", en: "—"), error: nil),
                               latency: nil, audioStats: nil, randomNow: nil)
            _ = CaptureStatus.failed(Bilingual(zh: "", en: ""))
            _ = GlobalOptionsPatch(blockHomeButton: true).apply(to: GlobalOptions())
            _ = Meter(left: 0, right: 0)
        }
    }

    func testPlatformHelpers() {
        Language.store = InMemoryStore()
        _ = (Language.storageKey, Language.systemDefault.rawValue, Language.current, Language.allCases.map { ($0.id, $0.label) })
        _ = L("中", "en")
        _ = Bilingual(zh: "中", en: "en").text
        _ = hsv(0.5, 1, 1)
        let box = LockedBox(0)
        box.withLock { $0 += 1 }
        let kv: KeyValueStore = UserDefaults.standard
        _ = kv.storedBool(forKey: "x")
    }
}
