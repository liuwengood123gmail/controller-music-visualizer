import Foundation

/// 设备列表变化时，现有会话与新发现的手柄如何对上（与平台无关，只看身份）。
/// 规则（从 macOS 版 ControllerRegistry.refresh 原样抽出）：
/// 1. 身份相同 → 沿用原会话（连接方式没变的会话完全不会被动）；
/// 2. 同一台 DualSense 在 USB ↔ 蓝牙之间切换时身份会变（USB 没有序列号）：
///    恰好一台 DualSense 消失、同时恰好出现一台新的，就当作同一台，沿用它的会话和设置；
/// 3. 其余新发现的 → 新建会话（设置：有记忆用记忆，否则复制选中手柄的，D5）；
/// 4. 其余消失的 → 记住设置、停止并释放。
/// 结果保持原有顺序，新手柄排在后面。
public enum SessionReconciler {
    public enum Slot: Equatable, Sendable {
        /// 现有会话 `session` 对应新发现的 `found`（身份相同）
        case keep(session: Int, found: Int)
        /// 现有会话 `session` 迁移到身份不同的 `found`（USB ↔ 蓝牙）
        case migrate(session: Int, found: Int)
        /// 为 `found` 新建会话
        case add(found: Int)
    }

    public struct Plan: Equatable, Sendable {
        /// 新的会话列表（按显示顺序）
        public var slots: [Slot]
        /// 要移除的现有会话下标
        public var removed: [Int]
        /// 会话列表（成员或顺序）是否变化
        public var changed: Bool
    }

    public static func plan(existing: [ControllerIdentity], found: [ControllerIdentity]) -> Plan {
        var remaining = Array(existing.indices)
        var unmatched: [Int] = []
        var result: [Slot] = []

        for (fi, f) in found.enumerated() {
            if let k = remaining.firstIndex(where: { existing[$0] == f }) {
                result.append(.keep(session: remaining.remove(at: k), found: fi))
            } else {
                unmatched.append(fi)
            }
        }

        let goneDualSense = remaining.filter { existing[$0].kind == .dualSense }
        let newDualSense = unmatched.filter { found[$0].kind == .dualSense }
        if goneDualSense.count == 1, newDualSense.count == 1 {
            let s = goneDualSense[0], f = newDualSense[0]
            result.append(.migrate(session: s, found: f))
            remaining.removeAll { $0 == s }
            unmatched.removeAll { $0 == f }
        }

        for f in unmatched { result.append(.add(found: f)) }

        // 保持原有顺序，新手柄排在后面
        func order(_ slot: Slot) -> Int {
            switch slot {
            case .keep(let s, _), .migrate(let s, _): return s
            case .add: return Int.max
            }
        }
        let sorted = result.enumerated().sorted { a, b in
            let oa = order(a.element), ob = order(b.element)
            return oa != ob ? oa < ob : a.offset < b.offset
        }.map(\.element)

        let kept = sorted.compactMap { slot -> Int? in
            if case .keep(let s, _) = slot { return s }
            if case .migrate(let s, _) = slot { return s }
            return nil
        }
        let changed = kept != Array(existing.indices) || sorted.count != existing.count
        return Plan(slots: sorted, removed: remaining, changed: changed)
    }
}
