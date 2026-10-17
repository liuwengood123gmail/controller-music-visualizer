// Windows 桌面应用：Compose Desktop 窗口 + 托盘，组装 ui 和引擎（docs/windows-plan.md §2.5）
import org.jetbrains.compose.desktop.application.dsl.TargetFormat
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("org.jetbrains.kotlin.jvm")
    id("org.jetbrains.compose")
    id("org.jetbrains.kotlin.plugin.compose")
}

kotlin { compilerOptions { jvmTarget.set(JvmTarget.JVM_17) } }
java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

dependencies {
    implementation(project(":ui"))
    implementation(project(":engine-fake"))
    implementation(project(":engine-windows"))
    implementation(compose.desktop.currentOs)
    implementation("org.jetbrains.compose.material3:material3:1.9.0")
}

// 开发时从 native-win/out/x64 加载 cvwin.dll 等；打包后改从应用资源目录加载（W7）
val nativeDir = rootDir.resolve("../native-win/out/x64").normalize()
tasks.withType<JavaExec>().configureEach { systemProperty("cv.native.dir", nativeDir.absolutePath) }

compose.desktop {
    application {
        mainClass = "app.cmv.desktop.MainKt"
        // ./gradlew :desktop:run -PdesktopOnly -PappArgs="--fake-engine MULTI"
        providers.gradleProperty("appArgs").orNull?.let { args(*it.split(" ").filter(String::isNotBlank).toTypedArray()) }
        nativeDistributions {
            targetFormats(TargetFormat.Msi)
            packageName = "ControllerMusicVisualizer"
            packageVersion = "0.1.0"
            modules("java.prefs")
            windows {
                menuGroup = "Controller Music Visualizer"
                upgradeUuid = "5b0e9a52-6d4b-4f36-9a0e-3c1f2f6d8a71"
            }
        }
    }
}
