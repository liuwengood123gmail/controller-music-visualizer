// 手柄 4 声道音频的 USB 直接输出（不经 Android 音频系统）。
//
// 为什么需要：Android 的 UsbAlsaManager 把 DualSense 判成「没有输出」（日志 hasOutput: false），
// AudioManager 里看不到它的扬声器 / 触觉声道，AAudio 打不开。内核其实认得播放端（pcmC1D0p）。
// 这里在 USB 直连已拿到的 usbdevfs 句柄上自己占用音频流接口（UsbDeviceConnection.claimInterface，Kotlin 侧），
// 用等时传输（isochronous URB）每 1ms 发一包：4 声道、16 位、48kHz（每包 48 帧 = 384 字节，端点最大 392）。
// 声道顺序与 macOS 的 AUHAL 相同：第 1/2 声道 = 扬声器，第 3/4 声道 = 左/右 HD 震动。
//
// 线程：一个专用线程循环「取回完成的 URB → 渲染下一块 → 重新提交」；URB 排队 urbs × packets 毫秒（即输出缓冲）。
#include <jni.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <linux/usbdevice_fs.h>
#include <android/log.h>
#include "controller_core.h"

#define TAG "cv-native"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, TAG, __VA_ARGS__)

#define FN(name) Java_app_cmv_engine_android_NativeCore_##name
#define P(x) ((void *)(intptr_t)(x))
#define J(x) ((jlong)(intptr_t)(x))

#define UA_CHANNELS 4
#define UA_MAX_URBS 8
#define UA_MAX_PACKETS 8

typedef struct {
    int fd;
    unsigned char endpoint;
    void *renderer;
    int sampleRate;
    int framesPerPacket;   // 1ms 一包
    int packets;           // 每个 URB 的包数
    int urbCount;
    struct usbdevfs_urb *urbs[UA_MAX_URBS];
    float *render;         // 渲染用的交错 float 缓冲
    pthread_t thread;
    atomic_int running;
    atomic_int disconnected;
    atomic_int gaps;       // 等时调度出现空档的次数（URB 没赶上，手柄那 1ms 没有数据）
    unsigned int nextFrame;
    int haveNextFrame;
} CVUsbAudio;

static int packetBytes(const CVUsbAudio *a) { return a->framesPerPacket * UA_CHANNELS * 2; }

/// 渲染一个 URB 的数据（float → 16 位）并填好包描述
static void fill(CVUsbAudio *a, struct usbdevfs_urb *u) {
    int frames = a->framesPerPacket * a->packets;
    cv_renderer_render(a->renderer, a->render, UA_CHANNELS, frames);
    int16_t *dst = u->buffer;
    for (int i = 0; i < frames * UA_CHANNELS; i++) {
        float v = a->render[i];
        v = v > 1 ? 1 : (v < -1 ? -1 : v);
        dst[i] = (int16_t)(v * 32767.0f);
    }
    u->type = USBDEVFS_URB_TYPE_ISO;
    u->endpoint = a->endpoint;
    u->flags = USBDEVFS_URB_ISO_ASAP;
    u->buffer_length = packetBytes(a) * a->packets;
    u->number_of_packets = a->packets;
    u->status = 0;
    u->actual_length = 0;
    u->error_count = 0;
    for (int i = 0; i < a->packets; i++) {
        u->iso_frame_desc[i].length = packetBytes(a);
        u->iso_frame_desc[i].actual_length = 0;
        u->iso_frame_desc[i].status = 0;
    }
}

static int submit(CVUsbAudio *a, struct usbdevfs_urb *u) {
    if (ioctl(a->fd, USBDEVFS_SUBMITURB, u) < 0) return -errno;
    // ISO_ASAP：内核在提交时填 start_frame。和上一个 URB 接不上就是出现了空档
    if (a->haveNextFrame && (unsigned int)u->start_frame != a->nextFrame) atomic_fetch_add(&a->gaps, 1);
    a->nextFrame = (unsigned int)u->start_frame + (unsigned int)a->packets;
    a->haveNextFrame = 1;
    return 0;
}

static void *loop(void *arg) {
    CVUsbAudio *a = arg;
    // 尽量提高线程优先级（相当于 THREAD_PRIORITY_URGENT_AUDIO；没有权限时忽略）
    if (setpriority(PRIO_PROCESS, gettid(), -19) != 0) LOGW("usb audio: setpriority failed (%d)", errno);

    int inflight = 0;
    for (int i = 0; i < a->urbCount; i++) {
        fill(a, a->urbs[i]);
        int r = submit(a, a->urbs[i]);
        if (r < 0) { LOGW("usb audio: first submit failed (%d)", -r); atomic_store(&a->disconnected, 1); break; }
        inflight++;
    }
    // 停止时不再重新提交，等在途的 URB 自然完成（等时传输每个 URB 只要几毫秒）
    while (inflight > 0) {
        struct usbdevfs_urb *u = NULL;
        if (ioctl(a->fd, USBDEVFS_REAPURB, &u) < 0) {
            if (errno == EINTR) continue;
            LOGW("usb audio: reap failed (%d)", errno);
            atomic_store(&a->disconnected, 1);
            break;
        }
        inflight--;
        if (!atomic_load(&a->running) || atomic_load(&a->disconnected)) continue;
        if (u->status == -ENODEV || u->status == -ESHUTDOWN) { atomic_store(&a->disconnected, 1); continue; }
        fill(a, u);
        int r = submit(a, u);
        if (r < 0) {
            LOGW("usb audio: submit failed (%d)", -r);
            if (r == -ENODEV || r == -ESHUTDOWN) atomic_store(&a->disconnected, 1);
            continue;
        }
        inflight++;
    }
    return NULL;
}

static void freeAudio(CVUsbAudio *a) {
    for (int i = 0; i < a->urbCount; i++) {
        if (a->urbs[i]) { free(a->urbs[i]->buffer); free(a->urbs[i]); }
    }
    free(a->render);
    free(a);
}

/// fd = UsbDeviceConnection.getFileDescriptor()（音频流接口已由 Kotlin 占用并切到带端点的备用设置）。
/// info = [声道数, 采样率, 缓冲帧数, 每个 URB 的帧数]
JNIEXPORT jlong JNICALL FN(usbAudioOpen)(JNIEnv *e, jobject o, jlong renderer, jint fd, jint endpoint, jint maxPacket,
                                         jint sampleRate, jint urbs, jint packets, jintArray info) {
    if (urbs < 2 || urbs > UA_MAX_URBS || packets < 1 || packets > UA_MAX_PACKETS || sampleRate % 1000 != 0) return 0;
    CVUsbAudio *a = calloc(1, sizeof(CVUsbAudio));
    a->fd = fd;
    a->endpoint = (unsigned char)endpoint;
    a->renderer = P(renderer);
    a->sampleRate = sampleRate;
    a->framesPerPacket = sampleRate / 1000;
    a->packets = packets;
    a->urbCount = urbs;
    if (packetBytes(a) > maxPacket) {
        LOGW("usb audio: %d bytes per packet > endpoint max %d", packetBytes(a), maxPacket);
        free(a);
        return 0;
    }
    a->render = calloc((size_t)a->framesPerPacket * packets * UA_CHANNELS, sizeof(float));
    for (int i = 0; i < urbs; i++) {
        struct usbdevfs_urb *u = calloc(1, sizeof(struct usbdevfs_urb) + packets * sizeof(struct usbdevfs_iso_packet_desc));
        u->buffer = calloc(1, (size_t)packetBytes(a) * packets);
        a->urbs[i] = u;
    }
    atomic_store(&a->running, 1);
    if (pthread_create(&a->thread, NULL, loop, a) != 0) { freeAudio(a); return 0; }

    jint vals[4] = { UA_CHANNELS, sampleRate, a->framesPerPacket * packets * urbs, a->framesPerPacket * packets };
    (*e)->SetIntArrayRegion(e, info, 0, 4, vals);
    LOGI("usb audio: endpoint 0x%02x, %d Hz, %d urbs x %d ms, %d bytes/packet", endpoint, sampleRate, urbs, packets, packetBytes(a));
    return J(a);
}

/// state = [是否已断开, 空档次数, 缓冲帧数]
JNIEXPORT void JNICALL FN(usbAudioState)(JNIEnv *e, jobject o, jlong h, jintArray state) {
    CVUsbAudio *a = P(h);
    jint vals[3] = { atomic_load(&a->disconnected), atomic_load(&a->gaps), a->framesPerPacket * a->packets * a->urbCount };
    (*e)->SetIntArrayRegion(e, state, 0, 3, vals);
}

JNIEXPORT void JNICALL FN(usbAudioClose)(JNIEnv *e, jobject o, jlong h) {
    CVUsbAudio *a = P(h);
    if (!a) return;
    atomic_store(&a->running, 0);
    pthread_join(a->thread, NULL);
    freeAudio(a);
}
