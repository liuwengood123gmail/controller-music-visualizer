import Foundation

/// 内置按摩效果：输入时间（已乘速度），输出左右强度 0...1
enum MassagePreset: String, CaseIterable, Identifiable {
    case knead = "揉捏"
    case tap = "敲击"
    case pat = "拍打"
    case shiatsu = "指压"
    case wave = "波浪"
    case heartbeat = "心跳"
    case crescendo = "渐强"
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
        case .random: "shuffle"
        }
    }

    /// 灯条颜色（色相 0...1），部分预设随时间变化
    func hue(_ t: Double) -> Float {
        switch self {
        case .knead: 0.08                                        // 橙
        case .tap: 0.5                                           // 青
        case .pat: 0.14                                          // 黄
        case .shiatsu: 0.78                                      // 紫
        case .wave: 0.55 + 0.08 * Float(sin(2 * .pi * t / 3))    // 蓝绿来回
        case .heartbeat: 0.0                                     // 红
        case .crescendo: 0.33 * (1 - Float(frac(t / 6)))         // 绿 → 红
        case .random: Float(frac(t / 8))                         // 彩虹慢转
        }
    }

    func sample(_ t: Double) -> (left: Float, right: Float) {
        switch self {
        case .knead:
            // 左右交替的慢速起伏，周期 2 秒
            let s = Float(sin(2 * .pi * t / 2))
            return (0.5 + 0.5 * s, 0.5 - 0.5 * s)

        case .tap:
            // 每秒 8 下，短促点按
            let p = frac(t * 8)
            let v: Float = p < 0.3 ? 1 : 0
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

        case .random:
            // 平滑噪声，左右独立
            return (noise(t * 1.5, seed: 1), noise(t * 1.5, seed: 7))
        }
    }

    private func frac(_ x: Double) -> Double { x - floor(x) }

    /// 1D 值噪声（平滑插值），0...1
    private func noise(_ x: Double, seed: Int) -> Float {
        func hash(_ i: Int) -> Float {
            var h = UInt32(truncatingIfNeeded: i &* 374761393 &+ seed &* 668265263)
            h = (h ^ (h >> 13)) &* 1274126177
            return Float(h & 0xFFFF) / 65535
        }
        let i = Int(floor(x)), f = Float(x - floor(x))
        let u = f * f * (3 - 2 * f)
        return hash(i) * (1 - u) + hash(i + 1) * u
    }
}
