// DLL 加载顺序（docs/windows-plan.md §5.3）：cvwin.dll 延迟加载 ControllerCAPI.dll。
// JVM 载入 cvwin.dll 时，先按 cvwin.dll 所在目录的绝对路径加载 ControllerCAPI.dll，并让它的依赖（Swift 运行库）
// 也从这个目录找；之后延迟加载按模块名命中已加载的这一份，不会从 PATH 里拿到别的 Swift 版本。
#include <windows.h>
#include <jni.h>

extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *, void *) {
    HMODULE self = nullptr;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                            reinterpret_cast<LPCWSTR>(&JNI_OnLoad), &self))
        return JNI_ERR;
    wchar_t path[MAX_PATH];
    DWORD n = GetModuleFileNameW(self, path, MAX_PATH);
    if (n == 0 || n == MAX_PATH) return JNI_ERR;
    wchar_t *slash = wcsrchr(path, L'\\');
    if (!slash || wcscpy_s(slash + 1, MAX_PATH - (slash + 1 - path), L"ControllerCAPI.dll") != 0) return JNI_ERR;
    if (!LoadLibraryExW(path, nullptr, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS))
        return JNI_ERR;
    return JNI_VERSION_1_8;
}
