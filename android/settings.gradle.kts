pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "ControllerMusicVisualizer"

// 依赖方向（docs/cross-platform-design.md §7.1）：ui 只依赖 engine-api；engine / engine-fake 实现 engine-api；app 组装
// -PdesktopOnly：不配置 Android 模块，没装 Android SDK 的 Windows 机器也能编（docs/windows-plan.md W3）
val desktopOnly = providers.gradleProperty("desktopOnly").isPresent
include(":engine-api", ":engine-fake", ":ui", ":desktop")
if (!desktopOnly) include(":engine", ":app")
