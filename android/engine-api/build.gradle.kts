// 纯 Kotlin：引擎接口、数据类、补丁类型。不依赖 Android SDK，可在 JVM 上单测（契约测试读 ../contract/fixtures）
plugins {
    id("org.jetbrains.kotlin.jvm")
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}
kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }

dependencies {
    api("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.2")
    api("org.jetbrains.kotlinx:kotlinx-serialization-json:1.10.0")
    testImplementation(kotlin("test"))
}

tasks.test {
    systemProperty("contract.dir", rootProject.projectDir.resolve("../contract/fixtures").absolutePath)
}
