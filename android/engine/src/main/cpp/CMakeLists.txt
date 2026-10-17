cmake_minimum_required(VERSION 3.22)
project(cvjni C)

# Swift 核心（scripts/build-swift-android.sh 交叉编译后放进 jniLibs）
set(SWIFT_LIBS ${CMAKE_CURRENT_SOURCE_DIR}/../jniLibs/${ANDROID_ABI})
add_library(ControllerCAPI SHARED IMPORTED)
set_target_properties(ControllerCAPI PROPERTIES IMPORTED_LOCATION ${SWIFT_LIBS}/libControllerCAPI.so)

add_library(cvjni SHARED cv_jni.c)
target_compile_options(cvjni PRIVATE -Wall -O2)
target_link_libraries(cvjni ControllerCAPI aaudio log)
