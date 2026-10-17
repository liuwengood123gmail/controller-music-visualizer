import ControllerCore
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
    /// 怎么对上（沿用 / USB ↔ 蓝牙迁移 / 新建 / 移除）由 ControllerCore 的 `SessionReconciler` 决定
    func refresh() {
        let found = discover()
        let plan = SessionReconciler.plan(existing: sessions.map(\.identity), found: found.map(\.identity))
        var result: [ControllerSession] = []
        var added: [ControllerSession] = []

        for slot in plan.slots {
            switch slot {
            case .keep(let i, let fi):
                let s = sessions[i], f = found[fi]
                s.update(identity: f.identity, hid: f.hid, gc: f.gc)
                result.append(s)
            case .migrate(let i, let fi):
                // 同一台 DualSense 换了连接方式：记住旧身份下的设置，会话沿用
                let s = sessions[i], f = found[fi]
                store.save(s.settings, for: s.identity)
                s.update(identity: f.identity, hid: f.hid, gc: f.gc)
                result.append(s)
            case .add(let fi):
                let f = found[fi]
                var settings = ControllerSettings.initial(remembered: store.load(f.identity),
                                                          copying: selectedSettings())
                adjustNew(&settings)
                let s = ControllerSession(identity: f.identity, hid: f.hid, gc: f.gc,
                                          settings: settings, waveform: waveform, feed: feed,
                                          tuning: tuning, tapTiming: tapTiming)
                added.append(s)
                result.append(s)
            }
        }

        // 手柄断开：记住它的设置，停止并释放
        let removed = plan.removed.map { sessions[$0] }
        for s in removed {
            store.save(s.settings, for: s.identity)
            s.retire()
        }

        sessions = result
        if plan.changed { onChange(added, removed) }
    }

    func saveAll() {
        for s in sessions { store.save(s.settings, for: s.identity) }
    }
}
