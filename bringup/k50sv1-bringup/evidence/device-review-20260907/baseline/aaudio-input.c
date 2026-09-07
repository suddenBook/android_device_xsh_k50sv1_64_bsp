#include <aaudio/AAudio.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>

static int capture(aaudio_input_preset_t preset) {
    AAudioStreamBuilder *builder = NULL;
    AAudioStream *stream = NULL;
    aaudio_result_t result = AAudio_createStreamBuilder(&builder);
    if (result != AAUDIO_OK) {
        fprintf(stderr, "create: %s\n", AAudio_convertResultToText(result));
        return 1;
    }
    AAudioStreamBuilder_setDirection(builder, AAUDIO_DIRECTION_INPUT);
    AAudioStreamBuilder_setInputPreset(builder, preset);
    AAudioStreamBuilder_setFormat(builder, AAUDIO_FORMAT_PCM_I16);
    AAudioStreamBuilder_setSampleRate(builder, 16000);
    AAudioStreamBuilder_setChannelCount(builder, 1);
    AAudioStreamBuilder_setSharingMode(builder, AAUDIO_SHARING_MODE_SHARED);
    result = AAudioStreamBuilder_openStream(builder, &stream);
    AAudioStreamBuilder_delete(builder);
    if (result != AAUDIO_OK) {
        fprintf(stderr, "preset=%d open: %s\n", preset, AAudio_convertResultToText(result));
        return 1;
    }
    printf("requested=%d actual=%d rate=%d channels=%d format=%d device=%d\n",
        preset, AAudioStream_getInputPreset(stream), AAudioStream_getSampleRate(stream),
        AAudioStream_getChannelCount(stream), AAudioStream_getFormat(stream),
        AAudioStream_getDeviceId(stream));
    int failed = AAudioStream_getInputPreset(stream) != preset;
    result = AAudioStream_requestStart(stream);
    int frames = 0, zero = 0, clipped = 0, peak = 0;
    double sum = 0;
    for (int reads = 0; result >= 0 && reads < 320 && frames < 48000; ++reads) {
        int16_t buffer[160];
        result = AAudioStream_read(stream, buffer, 160, 100000000);
        if (result < 0) break;
        for (int j = 0; j < result; ++j) {
            int v = buffer[j], magnitude = v < 0 ? -v : v;
            sum += (double)v * v;
            zero += v == 0;
            clipped += v == -32768 || v == 32767;
            if (magnitude > peak) peak = magnitude;
        }
        frames += result;
    }
    if (result < 0) fprintf(stderr, "capture: %s\n", AAudio_convertResultToText(result));
    printf("preset=%d frames=%d zero=%d clipped=%d peak=%d rms=%.2f xruns=%d\n",
        preset, frames, zero, clipped, peak, frames ? sqrt(sum / frames) : 0,
        AAudioStream_getXRunCount(stream));
    failed |= result < 0 || frames != 48000 || zero == frames;
    result = AAudioStream_requestStop(stream);
    if (result < 0) failed = 1;
    result = AAudioStream_close(stream);
    if (result < 0) failed = 1;
    printf("preset=%d lifecycle=%s\n", preset, failed ? "FAIL" : "PASS");
    return failed;
}
int main(void) {
    int result = capture(AAUDIO_INPUT_PRESET_GENERIC);
    result |= capture(AAUDIO_INPUT_PRESET_VOICE_COMMUNICATION);
    return result;
}
