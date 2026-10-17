// JNI 薄层：把 Kotlin 的 NativeCore 调用转给 Swift 核心的 C 接口；另含手柄 4 声道输出的 AAudio 流。
// 这里不放任何业务逻辑。
#include <jni.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdatomic.h>
#include <aaudio/AAudio.h>
#include <android/log.h>
#include "controller_core.h"

#define TAG "cv-native"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, TAG, __VA_ARGS__)

#define FN(name) Java_app_cmv_engine_android_NativeCore_##name
#define P(x) ((void *)(intptr_t)(x))
#define J(x) ((jlong)(intptr_t)(x))

// MARK: - 核心

JNIEXPORT jint JNICALL FN(apiVersion)(JNIEnv *e, jobject o) { return cv_api_version(); }
JNIEXPORT jlong JNICALL FN(coreCreate)(JNIEnv *e, jobject o, jfloat hp) { return J(cv_core_create(hp)); }
JNIEXPORT void JNICALL FN(coreDestroy)(JNIEnv *e, jobject o, jlong h) { cv_core_destroy(P(h)); }
JNIEXPORT void JNICALL FN(coreReset)(JNIEnv *e, jobject o, jlong h) { cv_core_reset(P(h)); }

JNIEXPORT void JNICALL FN(coreProcess)(JNIEnv *e, jobject o, jlong h, jfloatArray data, jint frames, jfloat sr) {
    jfloat *p = (*e)->GetPrimitiveArrayCritical(e, data, NULL);
    if (!p) return;
    cv_core_process(P(h), p, frames, sr);
    (*e)->ReleasePrimitiveArrayCritical(e, data, p, JNI_ABORT);
}

// MARK: - 会话

JNIEXPORT jlong JNICALL FN(sessionCreate)(JNIEnv *e, jobject o) { return J(cv_session_create()); }
JNIEXPORT void JNICALL FN(sessionDestroy)(JNIEnv *e, jobject o, jlong h) { cv_session_destroy(P(h)); }
JNIEXPORT void JNICALL FN(sessionReset)(JNIEnv *e, jobject o, jlong h) { cv_session_reset(P(h)); }

JNIEXPORT jint JNICALL FN(sessionSetSettings)(JNIEnv *e, jobject o, jlong h, jstring json) {
    const char *s = (*e)->GetStringUTFChars(e, json, NULL);
    jint r = cv_session_set_settings(P(h), s);
    (*e)->ReleaseStringUTFChars(e, json, s);
    return r;
}

JNIEXPORT void JNICALL FN(sessionTick)(JNIEnv *e, jobject o, jlong h, jlong core, jint flags, jfloat tl, jfloat tr,
                                       jfloat dt, jdouble align, jfloatArray out) {
    float buf[CV_TICK_COUNT];
    cv_session_tick(P(h), P(core), (uint32_t)flags, tl, tr, dt, align, buf);
    (*e)->SetFloatArrayRegion(e, out, 0, CV_TICK_COUNT, buf);
}

JNIEXPORT jdouble JNICALL FN(alignDelayMs)(JNIEnv *e, jobject o, jboolean hd, jboolean spk, jdouble margin,
                                           jdouble ctrl, jdouble override) {
    return cv_align_delay_ms(hd, spk, margin, ctrl, override);
}

// MARK: - DualSense 报告

JNIEXPORT jlong JNICALL FN(dsCreate)(JNIEnv *e, jobject o, jboolean bt) { return J(cv_ds_create(bt)); }
JNIEXPORT void JNICALL FN(dsDestroy)(JNIEnv *e, jobject o, jlong h) { cv_ds_destroy(P(h)); }
JNIEXPORT void JNICALL FN(dsSetControls)(JNIEnv *e, jobject o, jlong h, jboolean r, jboolean t, jboolean l) { cv_ds_set_controls(P(h), r, t, l); }
JNIEXPORT void JNICALL FN(dsSetHd)(JNIEnv *e, jobject o, jlong h, jboolean on) { cv_ds_set_hd(P(h), on); }
JNIEXPORT void JNICALL FN(dsSetSpeaker)(JNIEnv *e, jobject o, jlong h, jboolean on, jint vol, jint pre) { cv_ds_set_speaker(P(h), on, vol, pre); }
JNIEXPORT void JNICALL FN(dsSetTriggerResistance)(JNIEnv *e, jobject o, jlong h, jfloat v) { cv_ds_set_trigger_resistance(P(h), v); }
JNIEXPORT void JNICALL FN(dsSetLight)(JNIEnv *e, jobject o, jlong h, jfloat r, jfloat g, jfloat b) { cv_ds_set_light(P(h), r, g, b); }
JNIEXPORT void JNICALL FN(dsSetPlayerLeds)(JNIEnv *e, jobject o, jlong h, jint m) { cv_ds_set_player_leds(P(h), m); }
JNIEXPORT void JNICALL FN(dsSetMotors)(JNIEnv *e, jobject o, jlong h, jfloat l, jfloat r) { cv_ds_set_motors(P(h), l, r); }
JNIEXPORT void JNICALL FN(dsSend)(JNIEnv *e, jobject o, jlong h) { cv_ds_send(P(h)); }
JNIEXPORT void JNICALL FN(dsStop)(JNIEnv *e, jobject o, jlong h) { cv_ds_stop(P(h)); }

JNIEXPORT jint JNICALL FN(dsTakeReport)(JNIEnv *e, jobject o, jlong h, jbyteArray out) {
    uint8_t buf[128];
    jint n = cv_ds_take_report(P(h), buf, sizeof buf);
    if (n > 0) (*e)->SetByteArrayRegion(e, out, 0, n, (const jbyte *)buf);
    return n;
}

JNIEXPORT jboolean JNICALL FN(dsParseInput)(JNIEnv *e, jobject o, jint id, jbyteArray bytes, jint len, jfloatArray out) {
    jbyte *p = (*e)->GetByteArrayElements(e, bytes, NULL);
    float r[4];
    jint ok = cv_ds_parse_input(id, (const uint8_t *)p, len, r);
    (*e)->ReleaseByteArrayElements(e, bytes, p, JNI_ABORT);
    if (ok) (*e)->SetFloatArrayRegion(e, out, 0, 4, r);
    return ok != 0;
}

// MARK: - 渲染器

JNIEXPORT jlong JNICALL FN(rendererCreate)(JNIEnv *e, jobject o, jlong core, jfloat sr, jboolean haptics,
                                           jdouble bufferMs, jdouble hapticsDelayMs) {
    return J(cv_renderer_create(P(core), sr, haptics, bufferMs, hapticsDelayMs));
}
JNIEXPORT void JNICALL FN(rendererDestroy)(JNIEnv *e, jobject o, jlong h) { cv_renderer_destroy(P(h)); }
JNIEXPORT void JNICALL FN(rendererSet)(JNIEnv *e, jobject o, jlong h, jfloat l, jfloat r, jfloat f, jboolean m) { cv_renderer_set(P(h), l, r, f, m); }
JNIEXPORT void JNICALL FN(rendererSetSpeakerVolume)(JNIEnv *e, jobject o, jlong h, jfloat v) { cv_renderer_set_speaker_volume(P(h), v); }
JNIEXPORT void JNICALL FN(rendererMute)(JNIEnv *e, jobject o, jlong h) { cv_renderer_mute(P(h)); }
JNIEXPORT jboolean JNICALL FN(rendererSpeakerAudible)(JNIEnv *e, jobject o, jlong h) { return cv_renderer_speaker_audible(P(h)) != 0; }
JNIEXPORT void JNICALL FN(rendererStats)(JNIEnv *e, jobject o, jlong h, jdoubleArray out) {
    double s[2];
    cv_renderer_stats(P(h), s);
    (*e)->SetDoubleArrayRegion(e, out, 0, 2, s);
}

// MARK: - 字符串接口

typedef int32_t (*StrFn2)(const char *, const char *, char *, int32_t);

static jstring callStr(JNIEnv *e, StrFn2 fn, jstring a, jstring b) {
    const char *sa = a ? (*e)->GetStringUTFChars(e, a, NULL) : NULL;
    const char *sb = b ? (*e)->GetStringUTFChars(e, b, NULL) : NULL;
    int32_t cap = 4096;
    char *buf = malloc(cap);
    int32_t n = fn(sa, sb, buf, cap);
    if (n < 0) { cap = -n; buf = realloc(buf, cap); n = fn(sa, sb, buf, cap); }
    jstring r = (*e)->NewStringUTF(e, n >= 0 ? buf : "null");
    free(buf);
    if (sa) (*e)->ReleaseStringUTFChars(e, a, sa);
    if (sb) (*e)->ReleaseStringUTFChars(e, b, sb);
    return r;
}

static int32_t reconcile2(const char *a, const char *b, char *out, int32_t cap) { return cv_reconcile(a, out, cap); }

JNIEXPORT jstring JNICALL FN(settingsInitial)(JNIEnv *e, jobject o, jstring remembered, jstring copying) {
    return callStr(e, cv_settings_initial, remembered, copying);
}
JNIEXPORT jstring JNICALL FN(settingsApplyPatch)(JNIEnv *e, jobject o, jstring s, jstring p) {
    return callStr(e, cv_settings_apply_patch, s, p);
}
JNIEXPORT jstring JNICALL FN(reconcile)(JNIEnv *e, jobject o, jstring json) { return callStr(e, reconcile2, json, NULL); }

// MARK: - 手柄 4 声道音频（AAudio）

typedef struct {
    AAudioStream *stream;
    void *renderer;
    int32_t channels;
    atomic_int disconnected;
} CVAudio;

static aaudio_data_callback_result_t audioCallback(AAudioStream *s, void *user, void *data, int32_t frames) {
    CVAudio *a = user;
    cv_renderer_render(a->renderer, (float *)data, a->channels, frames);
    return AAUDIO_CALLBACK_RESULT_CONTINUE;
}

static void errorCallback(AAudioStream *s, void *user, aaudio_result_t err) {
    CVAudio *a = user;
    LOGW("audio stream error %d", err);
    atomic_store(&a->disconnected, 1);
}

/// 打开手柄的音频输出：要求 4 声道（扬声器 ch1/2 + HD ch3/4）。info = [实际声道数, 采样率, 缓冲帧数, 每次回调帧数]
/// 声道数不是 4 时返回 0（这时 HD / 扬声器都不可用；不能把触觉写进 2 声道，那是扬声器）
JNIEXPORT jlong JNICALL FN(audioOpen)(JNIEnv *e, jobject o, jlong renderer, jint deviceId, jint sampleRate, jintArray info) {
    AAudioStreamBuilder *b = NULL;
    if (AAudio_createStreamBuilder(&b) != AAUDIO_OK) return 0;
    CVAudio *a = calloc(1, sizeof(CVAudio));
    a->renderer = P(renderer);
    AAudioStreamBuilder_setDeviceId(b, deviceId);
    AAudioStreamBuilder_setDirection(b, AAUDIO_DIRECTION_OUTPUT);
    AAudioStreamBuilder_setSharingMode(b, AAUDIO_SHARING_MODE_SHARED);
    AAudioStreamBuilder_setPerformanceMode(b, AAUDIO_PERFORMANCE_MODE_LOW_LATENCY);
    AAudioStreamBuilder_setFormat(b, AAUDIO_FORMAT_PCM_FLOAT);
    AAudioStreamBuilder_setChannelCount(b, 4);
    if (sampleRate > 0) AAudioStreamBuilder_setSampleRate(b, sampleRate);
    AAudioStreamBuilder_setDataCallback(b, audioCallback, a);
    AAudioStreamBuilder_setErrorCallback(b, errorCallback, a);
    aaudio_result_t r = AAudioStreamBuilder_openStream(b, &a->stream);
    AAudioStreamBuilder_delete(b);
    if (r != AAUDIO_OK) { LOGW("openStream failed %d", r); free(a); return 0; }
    a->channels = AAudioStream_getChannelCount(a->stream);
    int32_t burst = AAudioStream_getFramesPerBurst(a->stream);
    // 低延迟：缓冲压到 2 个 burst
    if (burst > 0) AAudioStream_setBufferSizeInFrames(a->stream, burst * 2);
    jint vals[4] = { a->channels, AAudioStream_getSampleRate(a->stream), AAudioStream_getBufferSizeInFrames(a->stream), burst };
    (*e)->SetIntArrayRegion(e, info, 0, 4, vals);
    LOGI("controller audio: device %d, %d ch, %d Hz, buffer %d, burst %d", deviceId, vals[0], vals[1], vals[2], vals[3]);
    if (a->channels != 4 || AAudioStream_getFormat(a->stream) != AAUDIO_FORMAT_PCM_FLOAT) {
        AAudioStream_close(a->stream); free(a); return 0;
    }
    if (AAudioStream_requestStart(a->stream) != AAUDIO_OK) { AAudioStream_close(a->stream); free(a); return 0; }
    return J(a);
}

/// state = [是否已断开, 欠载次数, 缓冲帧数]
JNIEXPORT void JNICALL FN(audioState)(JNIEnv *e, jobject o, jlong h, jintArray state) {
    CVAudio *a = P(h);
    jint vals[3] = { atomic_load(&a->disconnected), AAudioStream_getXRunCount(a->stream),
                     AAudioStream_getBufferSizeInFrames(a->stream) };
    (*e)->SetIntArrayRegion(e, state, 0, 3, vals);
}

JNIEXPORT void JNICALL FN(audioClose)(JNIEnv *e, jobject o, jlong h) {
    CVAudio *a = P(h);
    if (!a) return;
    AAudioStream_requestStop(a->stream);
    AAudioStream_close(a->stream);
    free(a);
}
