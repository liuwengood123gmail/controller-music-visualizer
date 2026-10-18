// 系统声音采集：WASAPI 共享模式环回（默认输出设备的混音）→ 交错立体声 float → cv_core_process。
// 采集线程只在 C++ 里跑，不进 JVM；Kotlin 只启停和读状态。另含高精度定时（timeBeginPeriod）。
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <initguid.h>
#include <mmreg.h>
#include <ks.h>
#include <ksmedia.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <avrt.h>
#include <timeapi.h>
#include <jni.h>
#include <atomic>
#include <thread>
#include <vector>
#include "controller_core.h"

#define FN(name) Java_app_cmv_engine_windows_NativeCore_##name

namespace {

struct Capture {
    void *core = nullptr;
    std::thread thread;
    std::atomic<bool> stop{false};
    std::atomic<bool> defaultChanged{false};
    std::atomic<int> running{0}, sampleRate{0}, channels{0}, restarts{0};
    std::atomic<long> lastError{0};
};

// 默认输出设备变了（用户切换耳机 / 音箱）就重开环回
class DeviceNotify final : public IMMNotificationClient {
public:
    explicit DeviceNotify(std::atomic<bool> *flag) : flag_(flag) {}
    ULONG STDMETHODCALLTYPE AddRef() override { return InterlockedIncrement(&ref_); }
    ULONG STDMETHODCALLTYPE Release() override {
        ULONG r = InterlockedDecrement(&ref_);
        if (r == 0) delete this;
        return r;
    }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **out) override {
        if (iid == __uuidof(IUnknown) || iid == __uuidof(IMMNotificationClient)) {
            *out = static_cast<IMMNotificationClient *>(this);
            AddRef();
            return S_OK;
        }
        *out = nullptr;
        return E_NOINTERFACE;
    }
    HRESULT STDMETHODCALLTYPE OnDefaultDeviceChanged(EDataFlow flow, ERole role, LPCWSTR) override {
        if (flow == eRender && role == eConsole) flag_->store(true);
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE OnDeviceStateChanged(LPCWSTR, DWORD) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE OnDeviceAdded(LPCWSTR) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE OnDeviceRemoved(LPCWSTR) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE OnPropertyValueChanged(LPCWSTR, const PROPERTYKEY) override { return S_OK; }

private:
    LONG ref_ = 1;
    std::atomic<bool> *flag_;
};

enum class Format { Float32, Int16, Int32, Unsupported };

Format DetectFormat(const WAVEFORMATEX *f) {
    WORD tag = f->wFormatTag;
    if (tag == WAVE_FORMAT_EXTENSIBLE) {
        auto ext = reinterpret_cast<const WAVEFORMATEXTENSIBLE *>(f);
        if (IsEqualGUID(ext->SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT)) tag = WAVE_FORMAT_IEEE_FLOAT;
        else if (IsEqualGUID(ext->SubFormat, KSDATAFORMAT_SUBTYPE_PCM)) tag = WAVE_FORMAT_PCM;
    }
    if (tag == WAVE_FORMAT_IEEE_FLOAT && f->wBitsPerSample == 32) return Format::Float32;
    if (tag == WAVE_FORMAT_PCM && f->wBitsPerSample == 16) return Format::Int16;
    if (tag == WAVE_FORMAT_PCM && f->wBitsPerSample == 32) return Format::Int32;
    return Format::Unsupported;
}

// 只取前两声道（单声道复制到两边）
void ToStereo(const BYTE *src, UINT32 frames, int ch, Format fmt, std::vector<float> &out) {
    out.resize(static_cast<size_t>(frames) * 2);
    for (UINT32 i = 0; i < frames; i++) {
        for (int c = 0; c < 2; c++) {
            size_t idx = static_cast<size_t>(i) * ch + (ch == 1 ? 0 : c);
            float v = 0;
            switch (fmt) {
            case Format::Float32: v = reinterpret_cast<const float *>(src)[idx]; break;
            case Format::Int16: v = reinterpret_cast<const int16_t *>(src)[idx] / 32768.0f; break;
            case Format::Int32: v = reinterpret_cast<const int32_t *>(src)[idx] / 2147483648.0f; break;
            default: break;
            }
            out[static_cast<size_t>(i) * 2 + c] = v;
        }
    }
}

// 打开当前默认设备的环回并一直读，直到停止、默认设备变化或出错。返回 false = 出错（调用方稍后重试）
bool RunOnce(Capture *c, IMMDeviceEnumerator *en) {
    IMMDevice *dev = nullptr;
    IAudioClient *ac = nullptr;
    IAudioCaptureClient *cc = nullptr;
    WAVEFORMATEX *fmt = nullptr;
    bool ok = false;
    HRESULT hr = en->GetDefaultAudioEndpoint(eRender, eConsole, &dev);
    if (SUCCEEDED(hr)) hr = dev->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, reinterpret_cast<void **>(&ac));
    if (SUCCEEDED(hr)) hr = ac->GetMixFormat(&fmt);
    Format f = fmt ? DetectFormat(fmt) : Format::Unsupported;
    if (SUCCEEDED(hr) && f == Format::Unsupported) hr = AUDCLNT_E_UNSUPPORTED_FORMAT;
    if (SUCCEEDED(hr)) hr = ac->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK, 1000000 /* 100 ms */, 0, fmt, nullptr);
    if (SUCCEEDED(hr)) hr = ac->GetService(IID_PPV_ARGS(&cc));
    if (SUCCEEDED(hr)) hr = ac->Start();

    if (SUCCEEDED(hr)) {
        int ch = fmt->nChannels;
        float rate = static_cast<float>(fmt->nSamplesPerSec);
        c->sampleRate = static_cast<int>(fmt->nSamplesPerSec);
        c->channels = ch;
        c->running = 1;
        std::vector<float> stereo;
        while (!c->stop && !c->defaultChanged) {
            UINT32 packet = 0;
            hr = cc->GetNextPacketSize(&packet);
            while (SUCCEEDED(hr) && packet > 0) {
                BYTE *data = nullptr;
                UINT32 frames = 0;
                DWORD flags = 0;
                hr = cc->GetBuffer(&data, &frames, &flags, nullptr, nullptr);
                if (FAILED(hr)) break;
                if (flags & AUDCLNT_BUFFERFLAGS_SILENT) stereo.assign(static_cast<size_t>(frames) * 2, 0.0f);
                else ToStereo(data, frames, ch, f, stereo);
                cv_core_process(c->core, stereo.data(), static_cast<int32_t>(frames), rate);
                cc->ReleaseBuffer(frames);
                hr = cc->GetNextPacketSize(&packet);
            }
            if (FAILED(hr)) break;
            Sleep(5);
        }
        ac->Stop();
        ok = SUCCEEDED(hr);
    }
    c->running = 0;
    if (FAILED(hr)) c->lastError = hr;
    if (fmt) CoTaskMemFree(fmt);
    if (cc) cc->Release();
    if (ac) ac->Release();
    if (dev) dev->Release();
    return ok;
}

void CaptureThread(Capture *c) {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    DWORD taskIndex = 0;
    HANDLE task = AvSetMmThreadCharacteristicsW(L"Pro Audio", &taskIndex);
    IMMDeviceEnumerator *en = nullptr;
    DeviceNotify *notify = new DeviceNotify(&c->defaultChanged);
    if (SUCCEEDED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&en)))) {
        en->RegisterEndpointNotificationCallback(notify);
        bool first = true;
        while (!c->stop) {
            if (!first) c->restarts++;
            first = false;
            c->defaultChanged = false;
            if (!RunOnce(c, en) && !c->stop) Sleep(500);
        }
        en->UnregisterEndpointNotificationCallback(notify);
        en->Release();
    }
    notify->Release();
    if (task) AvRevertMmThreadCharacteristics(task);
    CoUninitialize();
}

}  // namespace

extern "C" {

JNIEXPORT jlong JNICALL FN(captureStart)(JNIEnv *, jobject, jlong core) {
    auto *c = new Capture();
    c->core = reinterpret_cast<void *>(static_cast<intptr_t>(core));
    c->thread = std::thread(CaptureThread, c);
    return reinterpret_cast<jlong>(c);
}

/// state = [运行中, 采样率, 声道数, 重开次数, 最后一次错误 HRESULT]
JNIEXPORT void JNICALL FN(captureState)(JNIEnv *e, jobject, jlong h, jintArray state) {
    auto *c = reinterpret_cast<Capture *>(h);
    jint v[5] = {c->running, c->sampleRate, c->channels, c->restarts, static_cast<jint>(c->lastError.load())};
    e->SetIntArrayRegion(state, 0, 5, v);
}

JNIEXPORT void JNICALL FN(captureStop)(JNIEnv *, jobject, jlong h) {
    auto *c = reinterpret_cast<Capture *>(h);
    if (!c) return;
    c->stop = true;
    if (c->thread.joinable()) c->thread.join();
    delete c;
}

/// Windows 默认计时精度约 15.6ms，10ms 主循环需要 1ms 精度
JNIEXPORT void JNICALL FN(highResTimer)(JNIEnv *, jobject, jboolean enable) {
    if (enable) timeBeginPeriod(1);
    else timeEndPeriod(1);
}

}  // extern "C"
