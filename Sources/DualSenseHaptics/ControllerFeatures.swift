import GameController

/// DualSense 的扳机阻尼、扳机读数、灯条（USB / 蓝牙都走 GameController）
@MainActor
final class ControllerFeatures {
    private weak var controller: GCController?
    private var lastColor: (Float, Float, Float) = (-1, -1, -1)
    private var lastResistance: Float = -1

    private var dualSense: GCDualSenseGamepad? { controller?.extendedGamepad as? GCDualSenseGamepad }

    func attach(_ c: GCController?) {
        if c !== controller { reset() }
        controller = c
        lastColor = (-1, -1, -1)
        lastResistance = -1
    }

    /// 扳机阻尼：0 = 关闭，1 = 最硬
    func setTriggerResistance(_ strength: Float) {
        guard let ds = dualSense, abs(strength - lastResistance) > 0.01 else { return }
        lastResistance = strength
        for t in [ds.leftTrigger, ds.rightTrigger] {
            if strength < 0.02 {
                t.setModeOff()
            } else {
                t.setModeFeedbackWithStartPosition(0.05, resistiveStrength: strength)
            }
        }
    }

    /// 两个扳机的按压深度 0...1
    var triggers: (left: Float, right: Float) {
        guard let pad = controller?.extendedGamepad else { return (0, 0) }
        return (pad.leftTrigger.value, pad.rightTrigger.value)
    }

    func setLight(_ r: Float, _ g: Float, _ b: Float) {
        guard let light = controller?.light else { return }
        // 变化太小就不发，避免刷爆手柄的输出报告
        if abs(r - lastColor.0) + abs(g - lastColor.1) + abs(b - lastColor.2) < 0.02 { return }
        lastColor = (r, g, b)
        light.color = GCColor(red: r, green: g, blue: b)
    }

    /// 下次调用时强制重发扳机和灯条设置（App 失去焦点时系统会把它们重置掉）
    func invalidate() {
        lastResistance = -1
        lastColor = (-1, -1, -1)
    }

    func reset() {
        if let ds = dualSense {
            ds.leftTrigger.setModeOff()
            ds.rightTrigger.setModeOff()
        }
        controller?.light?.color = GCColor(red: 0, green: 0.25, blue: 1)
        lastColor = (-1, -1, -1)
        lastResistance = -1
    }
}

/// HSV → RGB，h/s/v 都是 0...1
func hsv(_ h: Float, _ s: Float, _ v: Float) -> (Float, Float, Float) {
    let h6 = (h - floorf(h)) * 6
    let i = Int(h6) % 6, f = h6 - floorf(h6)
    let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
    switch i {
    case 0: return (v, t, p)
    case 1: return (q, v, p)
    case 2: return (p, v, t)
    case 3: return (p, q, v)
    case 4: return (t, p, v)
    default: return (v, p, q)
    }
}
