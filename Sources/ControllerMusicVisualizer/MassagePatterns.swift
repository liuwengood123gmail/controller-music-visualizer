import Foundation

/// 内置按摩效果：输入时间（已乘速度），输出左右强度 0...1、灯条颜色、HD 载波频率范围
enum MassagePreset: String, Codable, CaseIterable, Identifiable {
    case knead = "揉捏"
    case tap = "敲击"
    case pat = "拍打"
    case shiatsu = "指压"
    case wave = "波浪"
    case heartbeat = "心跳"
    case crescendo = "渐强"
    case roll = "滚压"
    case steady = "持续"
    case pound = "捶背"
    case gun = "按摩枪"
    case breathe = "呼吸"
    case raindrop = "雨滴"
    case random = "随机"
    var id: Self { self }

    var title: String {
        switch self {
        case .knead: L("揉捏", "Knead")
        case .tap: L("敲击", "Tap")
        case .pat: L("拍打", "Pat")
        case .shiatsu: L("指压", "Shiatsu")
        case .wave: L("波浪", "Wave")
        case .heartbeat: L("心跳", "Heartbeat")
        case .crescendo: L("渐强", "Crescendo")
        case .roll: L("滚压", "Roll")
        case .steady: L("持续", "Steady")
        case .pound: L("捶背", "Pound")
        case .gun: L("按摩枪", "Gun")
        case .breathe: L("呼吸", "Breathe")
        case .raindrop: L("雨滴", "Rain")
        case .random: L("随机", "Random")
        }
    }

    var icon: String {
        switch self {
        case .knead: "hand.raised"
        case .tap: "hand.point.up"
        case .pat: "hands.clap"
        case .shiatsu: "hand.thumbsup"
        case .wave: "water.waves"
        case .heartbeat: "heart"
        case .crescendo: "chart.line.uptrend.xyaxis"
        case .roll: "arrow.left.and.right"
        case .steady: "minus"
        case .pound: "hammer"
        case .gun: "bolt"
        case .breathe: "wind"
        case .raindrop: "cloud.rain"
        case .random: "shuffle"
        }
    }

    // MARK: - 对外接口（随机会委托给当前轮播到的预设）

    /// 左右强度 0...1
    func sample(_ t: Double) -> (left: Float, right: Float) {
        guard self == .random else { return baseSample(t) }
        let (a, b, w) = Self.playlist(t)
        let x = a.baseSample(t), y = b.baseSample(t)
        return (x.left + (y.left - x.left) * w, x.right + (y.right - x.right) * w)
    }

    /// 灯条颜色（色相 0...1）
    func hue(_ t: Double) -> Float {
        guard self == .random else { return baseHue(t) }
        let (a, b, w) = Self.playlist(t)
        var ha = a.baseHue(t), hb = b.baseHue(t)
        if hb - ha > 0.5 { ha += 1 } else if ha - hb > 0.5 { hb += 1 }   // 沿色环最短路径过渡
        let h = ha + (hb - ha) * w
        return h - floorf(h)
    }

    /// HD 载波频率范围（Hz）：震动弱时用 high（细腻），强时降到 low（有劲）
    func carrierRange(_ t: Double) -> (low: Float, high: Float) {
        guard self == .random else { return baseCarrierRange }
        let (a, b, w) = Self.playlist(t)
        let x = a.baseCarrierRange, y = b.baseCarrierRange
        return (x.low + (y.low - x.low) * w, x.high + (y.high - x.high) * w)
    }

    /// 随机模式当前正在播放的预设（其他预设返回自身）
    func current(_ t: Double) -> MassagePreset {
        guard self == .random else { return self }
        let (a, b, w) = Self.playlist(t)
        return w < 0.5 ? a : b
    }

    // MARK: - 随机轮播

    /// 随机：每段 8–14 秒随机换一种预设（不与上一段重复），段尾 1.2 秒交叉淡入淡出
    /// 返回 (当前段预设, 下一段预设, 下一段的混合权重 0...1)
    private static func playlist(_ t: Double) -> (MassagePreset, MassagePreset, Float) {
        // 预先按段长累加找到当前段（段长由段序号哈希决定，保证同一时刻结果稳定）
        var start = 0.0, index = 0
        while true {
            let length = segmentLength(index)
            if t < start + length {
                let remain = start + length - t
                let w = remain < 1.2 ? Float(1 - remain / 1.2) : 0
                let s = w * w * (3 - 2 * w)
                return (pick(index), pick(index + 1), s)
            }
            start += length
            index += 1
        }
    }

    private static let candidates = allCases.filter { $0 != .random }

    private static func segmentLength(_ i: Int) -> Double { 8 + 6 * Double(hash(i, seed: 3)) }

    private static func rawPick(_ i: Int) -> Int {
        Int(hash(i, seed: 11) * Float(candidates.count)) % candidates.count
    }

    /// 与上一段的原始选择相同时顺延一个（不递归，长时间运行也是常数开销）
    private static func pick(_ i: Int) -> MassagePreset {
        var k = rawPick(i)
        if i > 0 && k == rawPick(i - 1) { k = (k + 1) % candidates.count }
        return candidates[k]
    }

    // MARK: - 各预设

    /// 实测马达在 50–65Hz 最有劲，低于 50Hz 反而变弱，所以 low 都不低于 50
    private var baseCarrierRange: (low: Float, high: Float) {
        switch self {
        case .knead: (55, 90)
        case .tap: (65, 180)
        case .pat: (55, 120)
        case .shiatsu: (50, 80)
        case .wave: (55, 110)
        case .heartbeat: (50, 65)
        case .crescendo: (55, 140)
        case .roll: (55, 90)
        case .steady: (55, 100)
        case .pound: (50, 70)
        case .gun: (55, 90)
        case .breathe: (55, 100)
        case .raindrop: (70, 200)
        case .random: (55, 120)
        }
    }

    private func baseHue(_ t: Double) -> Float {
        switch self {
        case .knead: 0.08                                        // 橙
        case .tap: 0.5                                           // 青
        case .pat: 0.14                                          // 黄
        case .shiatsu: 0.78                                      // 紫
        case .wave: 0.55 + 0.08 * Float(sin(2 * .pi * t / 3))    // 蓝绿来回
        case .heartbeat: 0.0                                     // 红
        case .crescendo: 0.33 * (1 - Float(frac(t / 6)))         // 绿 → 红
        case .roll: 0.62                                         // 蓝
        case .steady: 0.92                                       // 粉
        case .pound: 0.03                                        // 红橙
        case .gun: 0.42                                          // 青绿
        case .breathe: 0.7                                       // 靛
        case .raindrop: 0.56                                     // 天蓝
        case .random: Float(frac(t / 8))
        }
    }

    private func baseSample(_ t: Double) -> (left: Float, right: Float) {
        switch self {
        case .knead:
            // 左右交替的慢速起伏，周期 2 秒
            let s = Float(sin(2 * .pi * t / 2))
            return (0.5 + 0.5 * s, 0.5 - 0.5 * s)

        case .tap:
            // 每秒 8 下，短促点按
            let v: Float = frac(t * 8) < 0.3 ? 1 : 0
            return (v, v)

        case .pat:
            // 重-轻-中-轻 的节奏，每拍快速衰减
            let accents: [Float] = [1, 0.45, 0.75, 0.45]
            let beat = t * 3
            let v = accents[Int(beat) % 4] * expf(-Float(frac(beat)) * 6)
            return (v, v)

        case .shiatsu:
            // 4 秒一周期：按下 1s → 保持 1.5s → 松开 1s → 休息 0.5s，左右轮流
            let cycle = Int(t / 4)
            let p = t.truncatingRemainder(dividingBy: 4)
            let v: Float = p < 1 ? Float(p) : p < 2.5 ? 1 : p < 3.5 ? Float(3.5 - p) : 0
            return cycle % 2 == 0 ? (v, v * 0.3) : (v * 0.3, v)

        case .wave:
            // 从左到右扫过去，周期 3 秒
            let ph = 2 * Double.pi * t / 3
            return (Float(max(0, sin(ph))), Float(max(0, sin(ph - .pi / 2))))

        case .heartbeat:
            // 咚-咚 …… 每分钟约 70 下
            let p = frac(t * 1.15)
            let v = expf(-Float(p) * 40) + 0.7 * (p > 0.22 ? expf(-Float(p - 0.22) * 40) : 0)
            return (v, v)

        case .crescendo:
            // 6 秒从弱到强，循环
            let v = Float(pow(frac(t / 6), 1.5))
            return (v, v)

        case .roll:
            // 持续的压力在左右之间慢慢滚动，周期 4 秒，始终保留底压
            let pos = Float(0.5 + 0.5 * sin(2 * .pi * t / 4))
            return (0.35 + 0.65 * (1 - pos), 0.35 + 0.65 * pos)

        case .steady:
            // 稳定的持续震动，带一点缓慢起伏
            let v = 0.85 + 0.1 * Float(sin(2 * .pi * t / 2))
            return (v, v)

        case .pound:
            // 左左右右地捶，每秒 2.5 下，每下快速衰减
            let beat = t * 2.5
            let v = expf(-Float(frac(beat)) * 9)
            return (Int(beat) % 4 < 2) ? (v, v * 0.15) : (v * 0.15, v)

        case .gun:
            // 按摩枪：每秒 20 次快速冲击
            let v: Float = frac(t * 20) < 0.5 ? 1 : 0.15
            return (v, v)

        case .breathe:
            // 6 秒一呼一吸
            let v = Float(pow(0.5 - 0.5 * cos(2 * .pi * t / 6), 1.5))
            return (v, v)

        case .raindrop:
            // 每 0.15 秒一个时间格，约 40% 的格子落下一滴，随机左右、随机轻重
            let slot = Int(floor(t / 0.15))
            let age = Float(t - Double(slot) * 0.15)
            guard Self.hash(slot, seed: 21) < 0.4 else { return (0, 0) }
            let strength = 0.4 + 0.6 * Self.hash(slot, seed: 22)
            let v = strength * expf(-age * 25)
            let side = Self.hash(slot, seed: 23)
            return side < 0.4 ? (v, v * 0.2) : side < 0.8 ? (v * 0.2, v) : (v, v)

        case .random:
            return (0, 0)   // 由 sample(_:) 委托给轮播中的预设
        }
    }

    private func frac(_ x: Double) -> Double { x - floor(x) }

    /// 整数哈希 → 0...1
    private static func hash(_ i: Int, seed: Int) -> Float {
        var h = UInt32(truncatingIfNeeded: i &* 374761393 &+ seed &* 668265263)
        h = (h ^ (h >> 13)) &* 1274126177
        h ^= h >> 16
        return Float(h & 0xFFFF) / 65536
    }
}
