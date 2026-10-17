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
    // 预览版固定签名：CI 从仓库 Secrets 解出密钥库（CV_KEYSTORE 指向文件），每次打包签名相同，可以直接覆盖安装。
    // 没有提供（本地构建、外部 PR）时退回 debug 签名
    val previewKeystore = System.getenv("CV_KEYSTORE")?.takeIf { it.isNotEmpty() && file(it).exists() }
    signingConfigs {
        if (previewKeystore != null) create("preview") {
            storeFile = file(previewKeystore)
            storeType = "pkcs12"
            storePassword = System.getenv("CV_KEYSTORE_PASSWORD")
            keyAlias = "preview"
            keyPassword = System.getenv("CV_KEYSTORE_PASSWORD")
        }
    }
    buildTypes {
        release {
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.getByName(if (previewKeystore != null) "preview" else "debug")
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
