// libopus 的 opus_encoder_ctl 是 C 可变参数函数，Swift 不能直接调用，所以包一层固定参数的函数。
// 本头文件不依赖 opus.h（只声明原型），实现见 opus-shim.c（需要 brew install opus）。
#ifndef OPUS_SHIM_H
#define OPUS_SHIM_H
typedef struct OpusEncoder OpusEncoder;
OpusEncoder *shim_encoder_create(int sampleRate, int channels, int *error);
int shim_set_bitrate(OpusEncoder *enc, int bitsPerSecond);
int shim_set_vbr(OpusEncoder *enc, int on);
/// pcm：交错的 16 位采样，frameSize = 每声道采样数；返回编码后的字节数，负数为错误
int shim_encode(OpusEncoder *enc, const short *pcm, int frameSize, unsigned char *out, int maxBytes);
void shim_destroy(OpusEncoder *enc);
#endif
