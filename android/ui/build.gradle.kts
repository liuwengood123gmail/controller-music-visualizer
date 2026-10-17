// Compose 界面：手机 / 平板 / 桌面自适应、双语。只依赖 engine-api（不认识任何具体引擎）
// Android 和桌面（Windows）共用 src/shared；平台部分在 src/androidMain、src/desktopMain 的 Platform.kt（同名函数）。
// 不用 commonMain：两个目标都是 JVM，共享代码直接用 JVM 库（engine-api、String.format、java.util.Locale）。
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.plugin.KotlinDependencyHandler

plugins {
    id("org.jetbrains.kotlin.multiplatform")
    id("org.jetbrains.compose")
    id("org.jetbrains.kotlin.plugin.compose")
}

val desktopOnly = providers.gradleProperty("desktopOnly").isPresent
if (!desktopOnly) {
    pluginManager.apply("com.android.library")
    extensions.configure<com.android.build.gradle.LibraryExtension> {
        namespace = "app.cmv.ui"
        compileSdk = 36
        defaultConfig { minSdk = 29 }
        buildFeatures { compose = true }
        compileOptions {
            sourceCompatibility = JavaVersion.VERSION_17
            targetCompatibility = JavaVersion.VERSION_17
        }
    }
}

kotlin {
    if (!desktopOnly) androidTarget { compilerOptions { jvmTarget.set(JvmTarget.JVM_17) } }
    jvm("desktop") { compilerOptions { jvmTarget.set(JvmTarget.JVM_17) } }

    sourceSets {
        val shared = "src/shared/kotlin"
        val common: KotlinDependencyHandler.() -> Unit = {
            api(project(":engine-api"))
            implementation("org.jetbrains.compose.runtime:runtime:1.12.2")
            implementation("org.jetbrains.compose.foundation:foundation:1.12.2")
            implementation("org.jetbrains.compose.ui:ui:1.12.2")
            implementation("org.jetbrains.compose.material3:material3:1.9.0")
        }
        if (!desktopOnly) {
            androidMain {
                kotlin.srcDir(shared)
                dependencies {
                    common()
                    implementation("androidx.activity:activity-compose:1.12.4")
                    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.10.0")
                }
            }
        }
        val desktopMain by getting {
            kotlin.srcDir(shared)
            dependencies { common() }
        }
    }
}
