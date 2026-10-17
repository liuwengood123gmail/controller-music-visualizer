import Foundation

public enum Source: String, Codable, CaseIterable, Identifiable, Sendable {
    case music = "跟随音乐"
    case massage = "按摩"
    public var id: Self { self }

    public var title: String { self == .music ? L("跟随音乐", "Music") : L("按摩", "Massage") }
}

/// 一个手柄的全部设置（可持久化）。键 = `ControllerIdentity.key`
public struct ControllerSettings: Codable, Equatable, Sendable {
    /// 勾选 = 由 App 控制这个手柄；取消 = App 完全不碰（等同于震动、扳机、灯光都交给游戏）
    public var enabled = true
    public var source: Source = .music
    public var musicMode: MusicMode = .beat
    public var sensitivity: Float = 0.5
    public var responsiveness: Float = 0.7
    public var preset: MassagePreset = .knead
    public var speed: Double = 1
    /// 0...3：超过 1 时把中低强度整体拉高（顶端削平在硬件上限）
    public var intensity: Float = 1

    // 以下三项：勾选 = 由 App 控制；取消 = 交给游戏（App 完全不设置这一项），方便边玩游戏边用
    public var vibrationEnabled = true
    /// HD 震动（仅 USB DualSense）
    public var hdEnabled = true
    public var triggersEnabled = true
    public var triggerResistance: Float = 0.5
    public var lightEffects = true
    public var lightSpeed: Float = 0.3
    /// 灯条亮暗变化幅度：1 = 鼓点间完全暗掉，越小保留的底亮度越高
    public var lightRange: Float = 1
    /// 手柄扬声器同步播放（仅 USB DualSense）：Mac 音响照常播放，手柄内置扬声器额外同步播放。默认关
    public var speakerEnabled = false
    /// 扬声器音量 0...1（按分贝曲线映射），默认 30%，要轻
    public var speakerVolume: Float = SpeakerVolume.defaultVolume

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, source, musicMode, sensitivity, responsiveness, preset, speed, intensity
        case vibrationEnabled, hdEnabled, triggersEnabled, triggerResistance
        case lightEffects, lightSpeed, lightRange
        case speakerEnabled, speakerVolume
    }

    /// 缺字段或字段无效时用默认值，保证旧版本保存的设置也能读出来
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        enabled = value(.enabled, enabled)
        source = value(.source, source)
        musicMode = value(.musicMode, musicMode)
        sensitivity = value(.sensitivity, sensitivity)
        responsiveness = value(.responsiveness, responsiveness)
        preset = value(.preset, preset)
        speed = value(.speed, speed)
        intensity = value(.intensity, intensity)
        vibrationEnabled = value(.vibrationEnabled, vibrationEnabled)
        hdEnabled = value(.hdEnabled, hdEnabled)
        triggersEnabled = value(.triggersEnabled, triggersEnabled)
        triggerResistance = value(.triggerResistance, triggerResistance)
        lightEffects = value(.lightEffects, lightEffects)
        lightSpeed = value(.lightSpeed, lightSpeed)
        lightRange = value(.lightRange, lightRange)
        speakerEnabled = value(.speakerEnabled, speakerEnabled)
        speakerVolume = value(.speakerVolume, speakerVolume)
        self = sanitized
    }

    /// 把数值夹回合法范围（防止损坏的存档）
    public var sanitized: ControllerSettings {
        var s = self
        func unit(_ v: Float) -> Float { v.isFinite ? min(max(v, 0), 1) : 0.5 }
        s.sensitivity = unit(sensitivity)
        s.responsiveness = unit(responsiveness)
        s.triggerResistance = unit(triggerResistance)
        s.lightSpeed = unit(lightSpeed)
        s.lightRange = unit(lightRange)
        s.speakerVolume = unit(speakerVolume)
        s.intensity = intensity.isFinite ? min(max(intensity, 0), 3) : 1
        s.speed = speed.isFinite ? min(max(speed, 0.5), 2) : 1
        return s
    }

    /// 三项都交给游戏时 App 不碰手柄，等同于停止
    public var allLeftToGame: Bool { !vibrationEnabled && !triggersEnabled && !lightEffects && !speakerEnabled }

    /// 新手柄连上时的初始设置（D5）：有记忆用记忆；否则复制当前选中手柄的设置；都没有用默认值
    public static func initial(remembered: ControllerSettings?, copying selected: ControllerSettings?) -> ControllerSettings {
        if let remembered { return remembered }
        guard var copy = selected else { return ControllerSettings() }
        copy.enabled = true
        return copy
    }
}

/// 按手柄身份把设置存进键值存储（所有手柄合成一个 JSON，键 controllerSettings.v1）
public struct SettingsStore {
    public static let storageKey = "controllerSettings.v1"
    public let defaults: KeyValueStore

    public init(defaults: KeyValueStore) { self.defaults = defaults }

    private func loadAll() -> [String: ControllerSettings] {
        guard let data = defaults.storedData(forKey: Self.storageKey),
              let all = try? JSONDecoder().decode([String: ControllerSettings].self, from: data) else { return [:] }
        return all
    }

    public func load(_ identity: ControllerIdentity) -> ControllerSettings? { loadAll()[identity.key] }

    public func save(_ settings: ControllerSettings, for identity: ControllerIdentity) {
        var all = loadAll()
        all[identity.key] = settings
        if let data = try? JSONEncoder().encode(all) { defaults.store(data: data, forKey: Self.storageKey) }
    }
}
