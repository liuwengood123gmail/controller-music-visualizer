#include <opus/opus.h>
#include "opus-shim.h"

OpusEncoder *shim_encoder_create(int sampleRate, int channels, int *error) {
    return opus_encoder_create(sampleRate, channels, OPUS_APPLICATION_AUDIO, error);
}
int shim_set_bitrate(OpusEncoder *enc, int bps) { return opus_encoder_ctl(enc, OPUS_SET_BITRATE(bps)); }
int shim_set_vbr(OpusEncoder *enc, int on) { return opus_encoder_ctl(enc, OPUS_SET_VBR(on)); }
int shim_encode(OpusEncoder *enc, const short *pcm, int frameSize, unsigned char *out, int maxBytes) {
    return opus_encode(enc, pcm, frameSize, out, maxBytes);
}
void shim_destroy(OpusEncoder *enc) { opus_encoder_destroy(enc); }
