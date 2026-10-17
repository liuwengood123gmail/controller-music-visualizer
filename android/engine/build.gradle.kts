// 真实引擎：前台服务 + 平台适配（采集、系统震动 / 灯光、USB 直连、Android 17 HID、4 声道音频）+ JNI 桥 + Swift 核心（.so）
plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "app.cmv.engine.android"
    // Android 17（37.2）才有 HidManager；运行时按版本判断，minSdk 仍是 29
    compileSdk = 37
    compileSdkMinor = 2
    defaultConfig {
        minSdk = 29
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        // 默认只打 arm64（手机 / 平板）；模拟器测试用 -Pcv.abis=arm64-v8a,x86_64
        ndk { abiFilters += (findProperty("cv.abis") as String? ?: "arm64-v8a").split(",") }
        externalNativeBuild { cmake { arguments += "-DANDROID_STL=c++_shared" } }
    }
    ndkVersion = "27.3.13750724"
    externalNativeBuild { cmake { path = file("src/main/cpp/CMakeLists.txt") } }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }

dependencies {
    api(project(":engine-api"))
    implementation("androidx.core:core-ktx:1.17.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
}
