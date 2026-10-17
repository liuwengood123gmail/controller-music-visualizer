# 契约样例

Swift 核心与各平台（Android 的 Kotlin、以后 Windows 的 C#）之间用 JSON 交换的数据，以 Swift 的 `Codable` 为准。
这里的样例由两边的测试共同读取，防止字段名、默认值、夹值规则漂移：

- Swift：`Tests/ControllerCAPITests/ContractTests.swift`（经 C 接口解码 / 夹值 / 合并补丁 / 对账）
- Kotlin：`android/engine-api/src/test/.../ContractTest.kt`（`ControllerSettings` 的解码与 `SettingsPatch.apply`）

改数据结构时：先改这里的样例，再改两边代码，两边测试都要通过。
