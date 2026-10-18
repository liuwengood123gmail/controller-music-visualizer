// Windows 真实引擎（docs/windows-plan.md §2.3）：从 Android 引擎复制改写，平台调用走 cvwin.dll（native-win/）
plugins {
    id("org.jetbrains.kotlin.jvm")
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}
kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }

dependencies {
    api(project(":engine-api"))
    testImplementation(kotlin("test"))
}

/** cvwin.dll + ControllerCAPI.dll + Swift 运行库所在目录（native-win/scripts/build-swift.ps1、build-native.ps1 的输出） */
val nativeDir = rootDir.resolve("../native-win/out/x64").normalize()
tasks.test { systemProperty("cv.native.dir", nativeDir.absolutePath) }
