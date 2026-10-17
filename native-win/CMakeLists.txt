# cvwin.dll：JNI 绑定 + Windows 平台层（docs/windows-plan.md §2.2）。
# 先跑 scripts/build-swift.ps1 生成 out/x64/ControllerCAPI.lib；产物也放进 out/x64，和 Swift 运行库同一目录。
cmake_minimum_required(VERSION 3.20)
project(cvwin LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CV_OUT "${CMAKE_CURRENT_SOURCE_DIR}/out/x64" CACHE PATH "ControllerCAPI.lib 所在目录，也是 cvwin.dll 的输出目录")

if(NOT DEFINED ENV{JAVA_HOME})
    message(FATAL_ERROR "JAVA_HOME is not set")
endif()
file(TO_CMAKE_PATH "$ENV{JAVA_HOME}" JAVA_HOME)

add_library(cvwin SHARED src/cv_jni_core.c src/capture.cpp src/dllmain.cpp)
target_include_directories(cvwin PRIVATE
    "${JAVA_HOME}/include" "${JAVA_HOME}/include/win32"
    "${CMAKE_CURRENT_SOURCE_DIR}/../android/engine/src/main/cpp")   # controller_core.h（与 Android 共用）
target_compile_definitions(cvwin PRIVATE UNICODE _UNICODE)
target_compile_options(cvwin PRIVATE /W4 /utf-8)
set_source_files_properties(src/cv_jni_core.c PROPERTIES COMPILE_OPTIONS /wd4100)   # JNI 签名固定，env / this 常不用
target_link_libraries(cvwin PRIVATE "${CV_OUT}/ControllerCAPI.lib" ole32 avrt winmm delayimp)
target_link_options(cvwin PRIVATE /DELAYLOAD:ControllerCAPI.dll)
set_target_properties(cvwin PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CV_OUT}" RUNTIME_OUTPUT_DIRECTORY_RELEASE "${CV_OUT}")
