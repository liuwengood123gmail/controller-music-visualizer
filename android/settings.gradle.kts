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
include(":engine-api", ":engine-fake", ":engine", ":ui", ":app")
