import Foundation
import GameController

/// 发现手柄、识别身份、维护会话列表。
///
/// 一个手柄在系统里会出现为 GCController / IOHIDDevice / 音频设备三种东西：
/// - DualSense 以 HID 设备为准（USB 用 LocationID，蓝牙用序列号），输出、扳机、电量都走 HID；
///   音频设备按 UID 里的 LocationID 精确匹配（见 `DualSenseAudioMatch`）
/// - 其他手柄只用 GCController，身份 = 厂商名 + 类别 + 同类序号
/// - GameController 里的 DualSense 不会再作为「其他手柄」出现，避免同一台手柄有两个会话
@MainActor
final class ControllerRegistry {
    private let store: SettingsStore
    private let waveform: HapticWaveform
    private let feed: SpeakerFeed
    private let tuning: SpeakerTuning
    private let tapTiming: () -> DeviceTiming?

    private(set) var sessions: [ControllerSession] = []

    /// 当前选中手柄的设置：新手柄第一次连上时复制它（D5）
    var selectedSettings: () -> ControllerSettings? = { nil }
    /// 调试参数（--massage 等）对新建会话的修改
    var adjustNew: (inout ControllerSettings) -> Void = { _ in }
    /// 列表变化：新增的、移除的会话
    var onChange: (_ added: [ControllerSession], _ removed: [ControllerSession]) -> Void = { _, _ in }

    init(store: SettingsStore, waveform: HapticWaveform, feed: SpeakerFeed, tuning: SpeakerTuning,
         tapTiming: @escaping () -> DeviceTiming?) {
        self.store = store
        self.waveform = waveform
        self.feed = feed
        self.tuning = tuning
        self.tapTiming = tapTiming
    }

    struct Found {
        let identity: ControllerIdentity
        let hid: DualSenseInfo?
        let gc: GCController?
    }

    func discover() -> [Found] {
        let infos = DualSenseHID.enumerate()
        let controllers = GCController.controllers()
        let gcDualSense = controllers.filter { $0.extendedGamepad is GCDualSenseGamepad }
        let others = controllers.filter { !($0.extendedGamepad is GCDualSenseGamepad) }

        var found: [Found] = []
        for info in infos {
            // 只有一台 DualSense 时才能确定它对应哪个 GCController（只用来后备读电量）
            let gc = infos.count == 1 && gcDualSense.count == 1 ? gcDualSense[0] : nil
            found.append(Found(identity: info.identity, hid: info, gc: gc))
        }
        // HID 打不开的 DualSense：退回只用 GameController
        if gcDualSense.count > infos.count {
            for i in infos.count..<gcDualSense.count {
                found.append(Found(identity: .dualSenseGameController(index: i), hid: nil, gc: gcDualSense[i]))
            }
        }
        var counts: [String: Int] = [:]
        for gc in others {
            let vendor = gc.vendorName ?? "Controller", category = gc.productCategory
            let group = "\(vendor)|\(category)"
            let index = counts[group, default: 0]
            counts[group] = index + 1
            found.append(Found(identity: .gamepad(vendor: vendor, category: category, index: index), hid: nil, gc: gc))
        }
        return found
    }

    /// 对照当前连接情况更新会话列表。可以频繁调用：连接方式没变化的会话完全不会被动。
    func refresh() {
        let found = discover()
        var remaining = sessions
        var unmatched: [Found] = []
        var result: [ControllerSession] = []

        for f in found {
            if let i = remaining.firstIndex(where: { $0.identity == f.identity }) {
                let s = remaining.remove(at: i)
                s.update(identity: f.identity, hid: f.hid, gc: f.gc)
                result.append(s)
            } else {
                unmatched.append(f)
            }
        }

        // 同一台 DualSense 在 USB ↔ 蓝牙之间切换时身份会变（USB 没有序列号）：
        // 一台 DualSense 消失、同时恰好出现一台新的，就当作同一台，沿用它的设置
        let goneDualSense = remaining.filter { $0.identity.kind == .dualSense }
        let newDualSense = unmatched.filter { $0.identity.kind == .dualSense }
        if goneDualSense.count == 1, newDualSense.count == 1,
           let s = goneDualSense.first, let f = newDualSense.first {
            store.save(s.settings, for: s.identity)
            s.update(identity: f.identity, hid: f.hid, gc: f.gc)
            remaining.removeAll { $0 === s }
            unmatched.removeAll { $0.identity == f.identity }
            result.append(s)
        }

        var added: [ControllerSession] = []
        for f in unmatched {
            var settings = ControllerSettings.initial(remembered: store.load(f.identity),
                                                      copying: selectedSettings())
            adjustNew(&settings)
            let s = ControllerSession(identity: f.identity, hid: f.hid, gc: f.gc,
                                      settings: settings, waveform: waveform, feed: feed,
                                      tuning: tuning, tapTiming: tapTiming)
            added.append(s)
            result.append(s)
        }

        // 手柄断开：记住它的设置，停止并释放
        for s in remaining {
            store.save(s.settings, for: s.identity)
            s.retire()
        }

        // 保持原有顺序，新手柄排在后面
        let order = Dictionary(uniqueKeysWithValues: sessions.enumerated().map { ($1.id, $0) })
        result = result.enumerated().sorted { a, b in
            let oa = order[a.element.id] ?? Int.max, ob = order[b.element.id] ?? Int.max
            return oa != ob ? oa < ob : a.offset < b.offset
        }.map(\.element)

        let changed = result.map(\.id) != sessions.map(\.id)
        sessions = result
        if changed { onChange(added, remaining) }
    }

    func saveAll() {
        for s in sessions { store.save(s.settings, for: s.identity) }
    }
}
