// 组装：界面 + 真实引擎（默认）/ 假引擎（右上角菜单切换，调试用）
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "app.cmv"
    compileSdk = 37
    compileSdkMinor = 2
    defaultConfig {
        applicationId = "app.cmv"
        minSdk = 29
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0-preview"
        // 默认只打 arm64（手机 / 平板）；模拟器测试用 -Pcv.abis=arm64-v8a,x86_64
        ndk { abiFilters += (findProperty("cv.abis") as String? ?: "arm64-v8a").split(",") }
    }
    buildFeatures { compose = true }
    buildTypes {
        release {
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // 测试版：用 debug 签名，方便直接安装
            signingConfig = signingConfigs.getByName("debug")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    // 压缩原生库（Swift 运行库 + ICU 约 80MB，压缩后小很多；代价是安装时解压）
    packaging { jniLibs { useLegacyPackaging = true } }
}

kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }

dependencies {
    implementation(project(":ui"))
    implementation(project(":engine"))
    implementation(project(":engine-fake"))
    val bom = platform("androidx.compose:compose-bom:2026.06.01")
    implementation(bom)
    implementation("androidx.compose.material3:material3")
    implementation("androidx.activity:activity-compose:1.12.4")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.10.0")
}
