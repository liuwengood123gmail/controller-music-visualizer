// W1 hardware probe (docs/windows-plan.md §4 W1). One-off tool, not shipped.
// Usage: probe [list|hid|hd|speaker]
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <initguid.h>
#include <mmreg.h>
#include <ks.h>
#include <ksmedia.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <endpointvolume.h>
#include <functiondiscoverykeys_devpkey.h>
#include <devpkey.h>
#include <setupapi.h>
#include <cfgmgr32.h>
#include <hidsdi.h>
#include <stdio.h>
#include <stdint.h>
#include <math.h>
#include <string>
#include <vector>
#include <algorithm>
#include <functional>

#pragma comment(lib, "setupapi.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "cfgmgr32.lib")
#pragma comment(lib, "hid.lib")

static const USHORT SONY_VID = 0x054C;
static const USHORT DS_PID = 0x0CE6;
static const USHORT DS_EDGE_PID = 0x0DF2;
static const double PI = 3.14159265358979323846;

static std::string Utf8(const wchar_t* w) {
    if (!w) return "";
    int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
    std::string s(n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w, -1, &s[0], n, NULL, NULL);
    s.resize(n > 0 ? n - 1 : 0);
    return s;
}

static std::string GuidStr(const GUID& g) {
    wchar_t buf[64];
    StringFromGUID2(g, buf, 64);
    return Utf8(buf);
}

static std::string Lower(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) { return (char)tolower(c); });
    return s;
}

// ---------------------------------------------------------------- audio endpoints

struct Endpoint {
    IMMDevice* dev = NULL;
    std::string name;
    bool isDefault = false;
    bool hasContainer = false;
    GUID container{};
    int channels = 0, rate = 0, bits = 0;
    bool isFloat = false;
    DWORD mask = 0;
};

static bool IsFloatFormat(const WAVEFORMATEX* f) {
    if (f->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) return true;
    if (f->wFormatTag == WAVE_FORMAT_EXTENSIBLE)
        return IsEqualGUID(((const WAVEFORMATEXTENSIBLE*)f)->SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT) != 0;
    return false;
}

static std::vector<Endpoint> ListEndpoints() {
    std::vector<Endpoint> out;
    IMMDeviceEnumerator* en = NULL;
    if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), NULL, CLSCTX_ALL, IID_PPV_ARGS(&en)))) return out;

    std::wstring defaultId;
    IMMDevice* def = NULL;
    if (SUCCEEDED(en->GetDefaultAudioEndpoint(eRender, eConsole, &def))) {
        LPWSTR id = NULL;
        def->GetId(&id);
        if (id) { defaultId = id; CoTaskMemFree(id); }
        def->Release();
    }

    IMMDeviceCollection* col = NULL;
    if (SUCCEEDED(en->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, &col))) {
        UINT count = 0;
        col->GetCount(&count);
        for (UINT i = 0; i < count; i++) {
            Endpoint e;
            col->Item(i, &e.dev);
            LPWSTR id = NULL;
            e.dev->GetId(&id);
            if (id) { e.isDefault = defaultId == id; CoTaskMemFree(id); }

            IPropertyStore* ps = NULL;
            if (SUCCEEDED(e.dev->OpenPropertyStore(STGM_READ, &ps))) {
                PROPVARIANT v;
                PropVariantInit(&v);
                if (SUCCEEDED(ps->GetValue(PKEY_Device_FriendlyName, &v)) && v.vt == VT_LPWSTR) e.name = Utf8(v.pwszVal);
                PropVariantClear(&v);

                PROPERTYKEY ck;
                memcpy(&ck, &DEVPKEY_Device_ContainerId, sizeof(ck));
                if (SUCCEEDED(ps->GetValue(ck, &v)) && v.vt == VT_CLSID && v.puuid) {
                    e.container = *v.puuid;
                    e.hasContainer = true;
                }
                PropVariantClear(&v);
                ps->Release();
            }

            IAudioClient* ac = NULL;
            if (SUCCEEDED(e.dev->Activate(__uuidof(IAudioClient), CLSCTX_ALL, NULL, (void**)&ac))) {
                WAVEFORMATEX* f = NULL;
                if (SUCCEEDED(ac->GetMixFormat(&f))) {
                    e.channels = f->nChannels;
                    e.rate = (int)f->nSamplesPerSec;
                    e.bits = f->wBitsPerSample;
                    e.isFloat = IsFloatFormat(f);
                    if (f->wFormatTag == WAVE_FORMAT_EXTENSIBLE) e.mask = ((WAVEFORMATEXTENSIBLE*)f)->dwChannelMask;
                    CoTaskMemFree(f);
                }
                ac->Release();
            }
            out.push_back(e);
        }
        col->Release();
    }
    en->Release();
    return out;
}

static void ReleaseEndpoints(std::vector<Endpoint>& eps) {
    for (auto& e : eps) if (e.dev) e.dev->Release();
    eps.clear();
}

// ---------------------------------------------------------------- HID

struct HidInfo {
    std::wstring path;
    USHORT pid = 0;
    bool bluetooth = false;
    bool hasContainer = false;
    GUID container{};
    USHORT inLen = 0, outLen = 0;
};

static std::vector<HidInfo> ListDualSense() {
    std::vector<HidInfo> out;
    GUID hidGuid;
    HidD_GetHidGuid(&hidGuid);
    HDEVINFO set = SetupDiGetClassDevsW(&hidGuid, NULL, NULL, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    if (set == INVALID_HANDLE_VALUE) return out;

    SP_DEVICE_INTERFACE_DATA ifd{sizeof(ifd)};
    for (DWORD i = 0; SetupDiEnumDeviceInterfaces(set, NULL, &hidGuid, i, &ifd); i++) {
        DWORD need = 0;
        SetupDiGetDeviceInterfaceDetailW(set, &ifd, NULL, 0, &need, NULL);
        std::vector<BYTE> buf(need);
        auto detail = (PSP_DEVICE_INTERFACE_DETAIL_DATA_W)buf.data();
        detail->cbSize = sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W);
        SP_DEVINFO_DATA dev{sizeof(dev)};
        if (!SetupDiGetDeviceInterfaceDetailW(set, &ifd, detail, need, NULL, &dev)) continue;

        // Access 0 = query only, works even when another app holds the device.
        HANDLE h = CreateFileW(detail->DevicePath, 0, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
        if (h == INVALID_HANDLE_VALUE) continue;
        HIDD_ATTRIBUTES attr{sizeof(attr)};
        if (HidD_GetAttributes(h, &attr) && attr.VendorID == SONY_VID &&
            (attr.ProductID == DS_PID || attr.ProductID == DS_EDGE_PID)) {
            HidInfo info;
            info.path = detail->DevicePath;
            info.pid = attr.ProductID;
            info.bluetooth = Lower(Utf8(detail->DevicePath)).find("00001124-0000-1000-8000-00805f9b34fb") != std::string::npos;
            PHIDP_PREPARSED_DATA pp = NULL;
            if (HidD_GetPreparsedData(h, &pp)) {
                HIDP_CAPS caps;
                if (HidP_GetCaps(pp, &caps) == HIDP_STATUS_SUCCESS) {
                    info.inLen = caps.InputReportByteLength;
                    info.outLen = caps.OutputReportByteLength;
                }
                HidD_FreePreparsedData(pp);
            }
            DEVPROPTYPE type = 0;
            ULONG size = sizeof(GUID);
            if (CM_Get_DevNode_PropertyW(dev.DevInst, &DEVPKEY_Device_ContainerId, &type, (PBYTE)&info.container, &size, 0) == CR_SUCCESS)
                info.hasContainer = true;
            out.push_back(info);
        }
        CloseHandle(h);
    }
    SetupDiDestroyDeviceInfoList(set);
    return out;
}

struct Hid {
    HANDLE h = INVALID_HANDLE_VALUE;
    USHORT inLen = 0, outLen = 0;
    OVERLAPPED ro{}, wo{};

    bool Open(const HidInfo& info) {
        h = CreateFileW(info.path.c_str(), GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                        OPEN_EXISTING, FILE_FLAG_OVERLAPPED, NULL);
        if (h == INVALID_HANDLE_VALUE) return false;
        inLen = info.inLen;
        outLen = info.outLen;
        ro.hEvent = CreateEventW(NULL, TRUE, FALSE, NULL);
        wo.hEvent = CreateEventW(NULL, TRUE, FALSE, NULL);
        return true;
    }
    ~Hid() {
        if (h != INVALID_HANDLE_VALUE) { CancelIoEx(h, NULL); CloseHandle(h); }
        if (ro.hEvent) CloseHandle(ro.hEvent);
        if (wo.hEvent) CloseHandle(wo.hEvent);
    }
    bool Write(const std::vector<uint8_t>& report) {
        std::vector<uint8_t> buf(outLen, 0);
        memcpy(buf.data(), report.data(), std::min(report.size(), buf.size()));
        ResetEvent(wo.hEvent);
        DWORD n = 0;
        if (!WriteFile(h, buf.data(), (DWORD)buf.size(), NULL, &wo)) {
            if (GetLastError() != ERROR_IO_PENDING) return false;
            if (WaitForSingleObject(wo.hEvent, 200) != WAIT_OBJECT_0) {
                CancelIoEx(h, &wo);
                GetOverlappedResult(h, &wo, &n, TRUE);
                return false;
            }
        }
        return GetOverlappedResult(h, &wo, &n, FALSE) && n == buf.size();
    }
    // Returns bytes read, 0 on timeout, -1 on error.
    int Read(uint8_t* buf, DWORD timeoutMs) {
        ResetEvent(ro.hEvent);
        DWORD n = 0;
        if (!ReadFile(h, buf, inLen, NULL, &ro)) {
            if (GetLastError() != ERROR_IO_PENDING) return -1;
            if (WaitForSingleObject(ro.hEvent, timeoutMs) != WAIT_OBJECT_0) {
                CancelIoEx(h, &ro);
                GetOverlappedResult(h, &ro, &n, TRUE);
                return 0;
            }
        }
        if (!GetOverlappedResult(h, &ro, &n, FALSE)) return -1;
        return (int)n;
    }
};

// Mirrors DualSenseReport.common / usb in Sources/ControllerCore/DualSenseReport.swift
struct OutState {
    bool hd = false;
    uint8_t motorLeft = 0, motorRight = 0;
    uint8_t r = 0, g = 64, b = 255;
    enum { Untouched, On, Off } speaker = Untouched;
    uint8_t volume = 0x64, preamp = 2;
};

static std::vector<uint8_t> UsbReport(const OutState& s) {
    std::vector<uint8_t> rep(48, 0);
    rep[0] = 0x02;
    uint8_t* c = &rep[1];
    c[0] = s.hd ? 0 : 0x01 | 0x02;
    c[38] = s.hd ? 0 : 0x04;
    c[0] |= 0x04 | 0x08;
    c[1] = 0x04 | 0x10;
    c[2] = s.motorRight;
    c[3] = s.motorLeft;
    c[43] = 0b00100 | 0x20;
    c[44] = s.r; c[45] = s.g; c[46] = s.b;
    if (s.speaker == OutState::On) {
        c[0] |= 0x20 | 0x80;
        c[1] |= 0x80;
        c[5] = s.volume;
        c[7] = 3 << 4;
        c[37] = s.preamp & 0x07;
    } else if (s.speaker == OutState::Off) {
        c[0] |= 0x80;
        c[7] = 0;
    }
    return rep;
}

static bool OpenFirstDualSense(Hid& hid, HidInfo& info) {
    auto list = ListDualSense();
    if (list.empty()) { printf("No DualSense found.\n"); return false; }
    info = list[0];
    if (info.bluetooth) { printf("DualSense is on Bluetooth; this test needs USB.\n"); return false; }
    if (!hid.Open(info)) {
        printf("Cannot open DualSense for read/write (error %lu). Is Steam / DS4Windows / DSX / HidHide holding it?\n", GetLastError());
        return false;
    }
    return true;
}

// ---------------------------------------------------------------- commands

static void CmdList() {
    printf("=== W1.1 Audio output endpoints ===\n");
    auto eps = ListEndpoints();
    for (size_t i = 0; i < eps.size(); i++) {
        auto& e = eps[i];
        printf("\n[%zu] %s%s\n", i, e.name.c_str(), e.isDefault ? "  (DEFAULT)" : "");
        printf("    mix format : %d ch, %d Hz, %d-bit %s, channelMask=0x%lX\n", e.channels, e.rate, e.bits,
               e.isFloat ? "float" : "int", e.mask);
        printf("    containerId: %s\n", e.hasContainer ? GuidStr(e.container).c_str() : "(none)");
    }

    printf("\n=== W1.2 Sony DualSense HID ===\n");
    auto hids = ListDualSense();
    if (hids.empty()) printf("No DualSense found.\n");
    for (size_t i = 0; i < hids.size(); i++) {
        auto& h = hids[i];
        printf("\n[%zu] PID 0x%04X  bus=%s\n", i, h.pid, h.bluetooth ? "bluetooth" : "usb");
        printf("    path       : %s\n", Utf8(h.path.c_str()).c_str());
        printf("    report len : in=%u out=%u\n", h.inLen, h.outLen);
        printf("    containerId: %s\n", h.hasContainer ? GuidStr(h.container).c_str() : "(none)");
        bool matched = false;
        for (auto& e : eps)
            if (h.hasContainer && e.hasContainer && IsEqualGUID(h.container, e.container)) {
                printf("    -> matches audio endpoint \"%s\" (%d ch)\n", e.name.c_str(), e.channels);
                matched = true;
            }
        if (!matched) printf("    -> no audio endpoint with the same containerId\n");
    }
    ReleaseEndpoints(eps);
}

static void CmdHid() {
    printf("=== W1.3 HID output 0x02 + input rate ===\n");
    Hid hid;
    HidInfo info;
    if (!OpenFirstDualSense(hid, info)) return;

    OutState s;
    s.r = 255; s.g = 0; s.b = 0;
    s.motorLeft = 128; s.motorRight = 128;
    auto rep = UsbReport(s);

    printf("Sending: light bar RED + compat rumble 50%% for 3 s. Press L2 / R2 now.\n");
    std::vector<uint8_t> in(hid.inLen);
    int reports = 0, writeOk = 0, writeFail = 0;
    float maxL2 = 0, maxR2 = 0;
    int battery = -1;
    ULONGLONG start = GetTickCount64(), lastWrite = 0, lastPrint = start;
    while (GetTickCount64() - start < 3000) {
        ULONGLONG now = GetTickCount64();
        if (now - lastWrite >= 100) {
            if (hid.Write(rep)) writeOk++; else writeFail++;
            lastWrite = now;
        }
        int n = hid.Read(in.data(), 20);
        if (n > 0 && in[0] == 0x01 && n >= 64) {
            reports++;
            maxL2 = std::max(maxL2, in[5] / 255.0f);
            maxR2 = std::max(maxR2, in[6] / 255.0f);
            battery = in[53];
            if (now - lastPrint >= 500) {
                printf("  L2=%.2f R2=%.2f\n", in[5] / 255.0f, in[6] / 255.0f);
                lastPrint = now;
            }
        } else if (n < 0) {
            printf("  ReadFile error %lu\n", GetLastError());
            break;
        }
    }
    double secs = (GetTickCount64() - start) / 1000.0;
    printf("Writes ok=%d fail=%d\n", writeOk, writeFail);
    printf("Input reports: %d in %.1f s = %.0f /s\n", reports, secs, reports / secs);
    printf("Max L2=%.2f R2=%.2f  status byte=0x%02X\n", maxL2, maxR2, battery & 0xFF);

    hid.Write(UsbReport(OutState()));
    printf("Restored defaults (blue light bar, no rumble).\n");
    printf("Did the light bar turn red and the controller rumble? (tell Claude)\n");
}

static IMMDevice* FindDualSenseEndpoint(std::vector<Endpoint>& eps, const HidInfo& info, Endpoint** chosen) {
    for (auto& e : eps)
        if (info.hasContainer && e.hasContainer && IsEqualGUID(info.container, e.container)) { *chosen = &e; return e.dev; }
    for (auto& e : eps)
        if (Lower(e.name).find("dualsense") != std::string::npos) { *chosen = &e; return e.dev; }
    return NULL;
}

// fill(frameIndex, channel) -> sample in [-1, 1]
static bool Render(IMMDevice* dev, double seconds, const std::function<float(UINT64, int, int)>& fill,
                   const std::function<void()>& every100ms) {
    IAudioClient* ac = NULL;
    if (FAILED(dev->Activate(__uuidof(IAudioClient), CLSCTX_ALL, NULL, (void**)&ac))) { printf("Activate failed\n"); return false; }
    WAVEFORMATEX* f = NULL;
    ac->GetMixFormat(&f);
    bool isFloat = IsFloatFormat(f);
    int ch = f->nChannels, bits = f->wBitsPerSample, rate = (int)f->nSamplesPerSec;
    printf("Endpoint mix format: %d ch, %d Hz, %d-bit %s\n", ch, rate, bits, isFloat ? "float" : "int");
    if (ch < 4) printf("WARNING: fewer than 4 channels in shared mode; channels 3/4 do not exist.\n");
    if (!(isFloat && bits == 32) && bits != 16) {
        printf("Unsupported sample format for this probe.\n");
        CoTaskMemFree(f); ac->Release(); return false;
    }

    HRESULT hr = ac->Initialize(AUDCLNT_SHAREMODE_SHARED, 0, 2000000 /* 200 ms */, 0, f, NULL);
    if (FAILED(hr)) { printf("IAudioClient::Initialize failed 0x%08lX\n", hr); CoTaskMemFree(f); ac->Release(); return false; }
    UINT32 bufFrames = 0;
    ac->GetBufferSize(&bufFrames);
    IAudioRenderClient* rc = NULL;
    ac->GetService(IID_PPV_ARGS(&rc));

    UINT64 frame = 0;
    auto pump = [&]() {
        UINT32 pad = 0;
        ac->GetCurrentPadding(&pad);
        UINT32 avail = bufFrames - pad;
        if (!avail) return;
        BYTE* data = NULL;
        if (FAILED(rc->GetBuffer(avail, &data))) return;
        for (UINT32 i = 0; i < avail; i++, frame++)
            for (int c = 0; c < ch; c++) {
                float v = c < 4 ? fill(frame, c, rate) : 0.0f;
                if (isFloat) ((float*)data)[i * ch + c] = v;
                else ((int16_t*)data)[i * ch + c] = (int16_t)(v * 32767);
            }
        rc->ReleaseBuffer(avail, 0);
    };

    pump();
    ac->Start();
    ULONGLONG start = GetTickCount64(), last = 0;
    while (GetTickCount64() - start < (ULONGLONG)(seconds * 1000)) {
        ULONGLONG now = GetTickCount64();
        if (now - last >= 100) { every100ms(); last = now; }
        pump();
        Sleep(5);
    }
    ac->Stop();
    rc->Release();
    ac->Release();
    CoTaskMemFree(f);
    return true;
}

static void CmdAudio(bool speaker, float amp) {
    printf(speaker ? "=== W1.4b Speaker: 1 kHz tone on channels 1/2 ===\n"
                   : "=== W1.4a HD haptics: 80 Hz sine on channels 3/4 ===\n");
    Hid hid;
    HidInfo info;
    if (!OpenFirstDualSense(hid, info)) return;
    auto eps = ListEndpoints();
    Endpoint* ep = NULL;
    IMMDevice* dev = FindDualSenseEndpoint(eps, info, &ep);
    if (!dev) { printf("No DualSense audio endpoint found (run 'probe list').\n"); ReleaseEndpoints(eps); return; }
    printf("Using endpoint \"%s\"\n", ep->name.c_str());
    IAudioEndpointVolume* vol = NULL;
    float savedLevel = -1;
    BOOL savedMute = FALSE;
    if (SUCCEEDED(dev->Activate(__uuidof(IAudioEndpointVolume), CLSCTX_ALL, NULL, (void**)&vol))) {
        float db = 0;
        DWORD hw = 0;
        vol->GetMasterVolumeLevelScalar(&savedLevel);
        vol->GetMasterVolumeLevel(&db);
        vol->GetMute(&savedMute);
        vol->QueryHardwareSupport(&hw);
        printf("Windows endpoint volume: %.0f%% (%.1f dB)%s, hardware support=0x%lX\n", savedLevel * 100, db,
               savedMute ? "  MUTED" : "", hw);
        if (speaker) {
            vol->SetMasterVolumeLevelScalar(1.0f, NULL);
            vol->SetMute(FALSE, NULL);
            printf("Temporarily set endpoint volume to 100%% for this test.\n");
        }
    }
    printf("Test amplitude: %.2f\n", amp);

    OutState s;
    if (speaker) { s.speaker = OutState::On; s.r = 0; s.g = 255; s.b = 0; }
    else { s.hd = true; s.r = 160; s.g = 0; s.b = 255; }
    auto rep = UsbReport(s);
    hid.Write(rep);

    auto fill = [speaker, amp](UINT64 n, int c, int rate) -> float {
        double t = (double)n / rate;
        if (speaker) return (c == 0 || c == 1) ? amp * (float)sin(2 * PI * 1000 * t) : 0.0f;
        return (c == 2 || c == 3) ? amp * (float)sin(2 * PI * 80 * t) : 0.0f;
    };
    printf(speaker ? "Playing 3 s (light bar GREEN)... listen to the controller speaker.\n"
                   : "Playing 3 s (light bar PURPLE)... feel for a smooth 80 Hz buzz.\n");
    Render(dev, 3.0, fill, [&]() { hid.Write(rep); });

    OutState restore;
    if (speaker) restore.speaker = OutState::Off;
    hid.Write(UsbReport(restore));
    if (vol) {
        if (speaker && savedLevel >= 0) {
            vol->SetMasterVolumeLevelScalar(savedLevel, NULL);
            vol->SetMute(savedMute, NULL);
        }
        vol->Release();
    }
    printf("Restored defaults.\n");
    printf(speaker ? "Did you hear a tone from the controller speaker? (tell Claude)\n"
                   : "Did you feel HD vibration? (tell Claude)\n");
    ReleaseEndpoints(eps);
}

int main(int argc, char** argv) {
    SetConsoleOutputCP(CP_UTF8);
    CoInitializeEx(NULL, COINIT_MULTITHREADED);
    std::string cmd = argc > 1 ? argv[1] : "list";
    float amp = argc > 2 ? (float)atof(argv[2]) : -1;
    if (cmd == "list") CmdList();
    else if (cmd == "hid") CmdHid();
    else if (cmd == "hd") CmdAudio(false, amp > 0 ? amp : 0.7f);
    else if (cmd == "speaker") CmdAudio(true, amp > 0 ? amp : 0.2f);
    else printf("Usage: probe [list|hid|hd [amp]|speaker [amp]]\n");
    CoUninitialize();
    return 0;
}
