// JNI 薄层：把 Kotlin 的 app.cmv.engine.windows.NativeCore 调用转给 Swift 核心的 C 接口。
// 从 android/engine/src/main/cpp/cv_jni.c 原样搬来（核心 / 会话 / 报告 / 渲染器 / 字符串几段），只改了 FN 前缀；
// 改 Android 那份时同步这里。平台部分（采集、手柄音频、HID）在别的文件。
#include <jni.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "controller_core.h"

#define FN(name) Java_app_cmv_engine_windows_NativeCore_##name
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
