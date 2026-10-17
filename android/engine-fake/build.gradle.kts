// 假引擎：不连任何设备，按剧本给出手柄列表和模拟电平（界面开发、预览、测试用）
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
