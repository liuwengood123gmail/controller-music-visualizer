// ControllerCore 的 C 接口（Swift 实现：Sources/ControllerCAPI/ControllerCAPI.swift，两边一一对应）
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int32_t cv_api_version(void);

// 核心：音乐分析 + 扬声器 / HD 音乐波形的共享缓冲
void *cv_core_create(float highpassHz);
void cv_core_destroy(void *core);
void cv_core_reset(void *core);
void cv_core_process(void *core, const float *interleavedStereo, int32_t frames, float sampleRate);

// 会话
enum {
    CV_FLAG_VIBRATION = 1 << 0, CV_FLAG_TRIGGERS = 1 << 1, CV_FLAG_LIGHTS = 1 << 2,
    CV_FLAG_ADAPTIVE_TRIGGERS = 1 << 3, CV_FLAG_PLAYER_LEDS = 1 << 4, CV_FLAG_HD_ACTIVE = 1 << 5,
};
#define CV_TICK_COUNT 17
void *cv_session_create(void);
void cv_session_destroy(void *s);
void cv_session_reset(void *s);
int32_t cv_session_set_settings(void *s, const char *json);
void cv_session_tick(void *s, void *core, uint32_t flags, float triggerLeft, float triggerRight, float dt,
                     double alignDelayMs, float *out);
double cv_align_delay_ms(int32_t hdActive, int32_t speakerOn, double marginMs, double controllerOutputMs,
                         double hapticsDelayOverrideMs);

// DualSense 输出报告
void *cv_ds_create(int32_t bluetooth);
void cv_ds_destroy(void *h);
void cv_ds_set_controls(void *h, int32_t rumble, int32_t triggers, int32_t lights);
void cv_ds_set_hd(void *h, int32_t on);
void cv_ds_set_speaker(void *h, int32_t on, int32_t hwVolume, int32_t preamp);
void cv_ds_set_trigger_resistance(void *h, float v);
void cv_ds_set_light(void *h, float r, float g, float b);
void cv_ds_set_player_leds(void *h, int32_t mask);
void cv_ds_set_motors(void *h, float l, float r);
void cv_ds_send(void *h);
void cv_ds_stop(void *h);
int32_t cv_ds_take_report(void *h, uint8_t *out, int32_t cap);
int32_t cv_ds_parse_input(int32_t reportID, const uint8_t *bytes, int32_t length, float *out);

// 4 声道渲染
void *cv_renderer_create(void *core, float sampleRate, int32_t haptics, double bufferMs, double hapticsDelayMs);
void cv_renderer_destroy(void *h);
void cv_renderer_set(void *h, float l, float r, float freq, int32_t useMusic);
void cv_renderer_set_speaker_volume(void *h, float volume);
void cv_renderer_mute(void *h);
int32_t cv_renderer_speaker_audible(void *h);
void cv_renderer_render(void *h, float *out, int32_t channels, int32_t frames);
void cv_renderer_stats(void *h, double *out);

// 设置 / 对账（JSON，字符串写进调用方缓冲区）
int32_t cv_settings_sanitize(const char *json, char *out, int32_t cap);
int32_t cv_settings_initial(const char *remembered, const char *copying, char *out, int32_t cap);
int32_t cv_settings_apply_patch(const char *settings, const char *patch, char *out, int32_t cap);
int32_t cv_reconcile(const char *json, char *out, int32_t cap);

#ifdef __cplusplus
}
#endif
