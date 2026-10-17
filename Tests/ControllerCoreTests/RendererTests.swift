import XCTest
@testable import ControllerCore

final class RendererTests: XCTestCase {
    private func render(_ r: ControllerAudioRenderer, frames n: Int = 256) -> [[Float]] {
        let p = (0..<4).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: n) }
        defer { p.forEach { $0.deallocate() } }
        p.forEach { $0.initialize(repeating: 9, count: n) }
        r.render(speakerLeft: p[0], speakerRight: p[1], hapticLeft: p[2], hapticRight: p[3], frames: n)
        return p.map { Array(UnsafeBufferPointer(start: $0, count: n)) }
    }

    func testSilentWhenNothingSet() {
        let r = ControllerAudioRenderer(sampleRate: 48000, waveform: nil, feed: nil, haptics: true, tuning: SpeakerTuning())
        let out = render(r)
        for c in out { XCTAssertTrue(c.allSatisfy { $0 == 0 }) }   // 未清零的缓冲也被写成 0
    }

    func testHapticChannelsCarrySine() {
        let r = ControllerAudioRenderer(sampleRate: 48000, waveform: nil, feed: nil, haptics: true, tuning: SpeakerTuning())
        r.set(left: 1, right: 0, freq: 100, useMusic: false)
        var out = render(r)
        for _ in 0..<10 { out = render(r) }   // 等 3ms 平滑结束
        XCTAssertGreaterThan(out[2].map(abs).max()!, 0.9)
        XCTAssertLessThan(out[3].map(abs).max()!, 0.01)
        XCTAssertTrue(out[0].allSatisfy { $0 == 0 })
    }

    func testHapticsOffWritesZeros() {
        let r = ControllerAudioRenderer(sampleRate: 48000, waveform: nil, feed: nil, haptics: false, tuning: SpeakerTuning())
        r.set(left: 1, right: 1, freq: 100, useMusic: false)
        let out = render(r)
        XCTAssertTrue(out[2].allSatisfy { $0 == 0 })
        XCTAssertTrue(out[3].allSatisfy { $0 == 0 })
    }

    func testSpeakerPlaysFeedOnBothChannels() {
        let feed = SpeakerFeed()
        let r = ControllerAudioRenderer(sampleRate: 48000, waveform: nil, feed: feed, haptics: false, tuning: SpeakerTuning())
        r.setSpeakerGain(1)
        XCTAssertTrue(r.speakerAudible)
        var t = 0
        let tone: (Int) -> [Float] = { n in
            (0..<n).map { i in sinf(2 * .pi * 1000 * Float(t + i) / 48000) * 0.5 }
        }
        var peak: Float = 0
        for _ in 0..<200 {
            let x = tone(256); t += 256
            x.withUnsafeBufferPointer { p in feed.write(left: p.baseAddress!, right: p.baseAddress!, frames: 256, sampleRate: 48000) }
            let out = render(r)
            XCTAssertEqual(out[0], out[1])
            peak = max(peak, out[0].map(abs).max()!)
        }
        XCTAssertGreaterThan(peak, 0.1)
        XCTAssertGreaterThan(r.marginMs, 0)
        r.setSpeakerGain(0)
        for _ in 0..<20 { _ = render(r) }
        XCTAssertFalse(r.speakerAudible)
    }
}
