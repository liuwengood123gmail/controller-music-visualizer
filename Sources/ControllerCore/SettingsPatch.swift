import Foundation

/// 设置补丁：只包含要改的字段（界面 → 引擎）。
/// 为什么不发整份设置：L2/R2 会在引擎里实时改 `intensity`，界面发来的整份旧设置会把它覆盖回去。
/// 引擎按「每个字段最后一次写入为准」合并。
public struct SettingsPatch: Equatable, Codable, Sendable {
    public var enabled: Bool?
    public var source: Source?
    public var musicMode: MusicMode?
    public var sensitivity: Float?
    public var responsiveness: Float?
    public var preset: MassagePreset?
    public var speed: Double?
    public var intensity: Float?
    public var vibrationEnabled: Bool?
    public var hdEnabled: Bool?
    public var triggersEnabled: Bool?
    public var triggerResistance: Float?
    public var lightEffects: Bool?
    public var lightSpeed: Float?
    public var lightRange: Float?
    public var speakerEnabled: Bool?
    public var speakerVolume: Float?

    public init() {}

    /// 两份设置之间的差异（界面用 Binding 改完一份本地副本后，算出补丁发给引擎）
    public init(from old: ControllerSettings, to new: ControllerSettings) {
        if old.enabled != new.enabled { enabled = new.enabled }
        if old.source != new.source { source = new.source }
        if old.musicMode != new.musicMode { musicMode = new.musicMode }
        if old.sensitivity != new.sensitivity { sensitivity = new.sensitivity }
        if old.responsiveness != new.responsiveness { responsiveness = new.responsiveness }
        if old.preset != new.preset { preset = new.preset }
        if old.speed != new.speed { speed = new.speed }
        if old.intensity != new.intensity { intensity = new.intensity }
        if old.vibrationEnabled != new.vibrationEnabled { vibrationEnabled = new.vibrationEnabled }
        if old.hdEnabled != new.hdEnabled { hdEnabled = new.hdEnabled }
        if old.triggersEnabled != new.triggersEnabled { triggersEnabled = new.triggersEnabled }
        if old.triggerResistance != new.triggerResistance { triggerResistance = new.triggerResistance }
        if old.lightEffects != new.lightEffects { lightEffects = new.lightEffects }
        if old.lightSpeed != new.lightSpeed { lightSpeed = new.lightSpeed }
        if old.lightRange != new.lightRange { lightRange = new.lightRange }
        if old.speakerEnabled != new.speakerEnabled { speakerEnabled = new.speakerEnabled }
        if old.speakerVolume != new.speakerVolume { speakerVolume = new.speakerVolume }
    }

    public var isEmpty: Bool { self == SettingsPatch() }

    /// 合并到一份设置上（结果再夹回合法范围）
    public func apply(to s: ControllerSettings) -> ControllerSettings {
        var s = s
        if let v = enabled { s.enabled = v }
        if let v = source { s.source = v }
        if let v = musicMode { s.musicMode = v }
        if let v = sensitivity { s.sensitivity = v }
        if let v = responsiveness { s.responsiveness = v }
        if let v = preset { s.preset = v }
        if let v = speed { s.speed = v }
        if let v = intensity { s.intensity = v }
        if let v = vibrationEnabled { s.vibrationEnabled = v }
        if let v = hdEnabled { s.hdEnabled = v }
        if let v = triggersEnabled { s.triggersEnabled = v }
        if let v = triggerResistance { s.triggerResistance = v }
        if let v = lightEffects { s.lightEffects = v }
        if let v = lightSpeed { s.lightSpeed = v }
        if let v = lightRange { s.lightRange = v }
        if let v = speakerEnabled { s.speakerEnabled = v }
        if let v = speakerVolume { s.speakerVolume = v }
        return s.sanitized
    }
}
