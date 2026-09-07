#define _POSIX_C_SOURCE 200809L

#include <aaudio/AAudio.h>
#include <inttypes.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>

#define NS_PER_MS INT64_C(1000000)
#define CHUNK_FRAMES 480

static volatile sig_atomic_t interrupted;

static void handle_signal(int signum) {
    if (signum == SIGALRM) {
        static const char message[] = "RESULT FAIL watchdog_timeout exit=124\n";
        (void)write(STDERR_FILENO, message, sizeof(message) - 1);
        _exit(124);
    }
    interrupted = signum;
}

static int64_t now_ns(void) {
    struct timespec time;
    if (clock_gettime(CLOCK_MONOTONIC, &time) != 0) {
        return -1;
    }
    return (int64_t)time.tv_sec * INT64_C(1000000000) + time.tv_nsec;
}

static bool result_ok(const char *operation, aaudio_result_t result) {
    printf("%s result=%" PRId32 " (%s)\n", operation, result,
           AAudio_convertResultToText(result));
    return result == AAUDIO_OK;
}

static void report_stream(AAudioStream *stream, const char *stage, int64_t accepted) {
    aaudio_stream_state_t state = AAudioStream_getState(stream);
    printf("%s state=%" PRId32 " (%s) accepted=%" PRId64
           " frames_written=%" PRId64 " frames_read=%" PRId64 " xruns=%" PRId32 "\n",
           stage, state, AAudio_convertStreamStateToText(state), accepted,
           AAudioStream_getFramesWritten(stream), AAudioStream_getFramesRead(stream),
           AAudioStream_getXRunCount(stream));
}

static bool wait_for_state(AAudioStream *stream, aaudio_stream_state_t wanted,
                           int64_t timeout_ns, bool cancelable) {
    int64_t start = now_ns();
    if (start < 0) {
        perror("clock_gettime");
        return false;
    }
    aaudio_stream_state_t state = AAudioStream_getState(stream);
    while (state != wanted) {
        if (cancelable && interrupted) {
            return false;
        }
        if (state == AAUDIO_STREAM_STATE_DISCONNECTED ||
            state == AAUDIO_STREAM_STATE_CLOSED) {
            fprintf(stderr, "wait_state unexpected=%s wanted=%s\n",
                    AAudio_convertStreamStateToText(state),
                    AAudio_convertStreamStateToText(wanted));
            return false;
        }
        int64_t now = now_ns();
        int64_t remaining = timeout_ns - (now - start);
        if (now < 0 || remaining <= 0) {
            fprintf(stderr, "wait_state timeout current=%s wanted=%s\n",
                    AAudio_convertStreamStateToText(state),
                    AAudio_convertStreamStateToText(wanted));
            return false;
        }
        int64_t slice = remaining < 100 * NS_PER_MS ? remaining : 100 * NS_PER_MS;
        aaudio_result_t result = AAudioStream_waitForStateChange(stream, state, &state, slice);
        if (result != AAUDIO_OK && result != AAUDIO_ERROR_TIMEOUT) {
            result_ok("wait_state", result);
            return false;
        }
    }
    return true;
}

int main(void) {
    AAudioStreamBuilder *builder = NULL;
    AAudioStream *stream = NULL;
    const int16_t silence[CHUNK_FRAMES * 2] = {0};
    int64_t accepted = 0;
    int64_t started_at = now_ns();
    int32_t target_frames = 0;
    int exit_code = 1;
    struct sigaction action = {0};

    setvbuf(stdout, NULL, _IONBF, 0);
    action.sa_handler = handle_signal;
    sigemptyset(&action.sa_mask);
    if (started_at < 0 || sigaction(SIGALRM, &action, NULL) != 0 ||
        sigaction(SIGINT, &action, NULL) != 0 || sigaction(SIGTERM, &action, NULL) != 0) {
        perror("probe_setup");
        puts("RESULT FAIL setup exit=2");
        return 2;
    }
    /* Bound open/close or Binder stalls too. The watchdog uses only signal-safe
     * calls; process death releases its file descriptors and Binder clients. */
    alarm(10);
    puts("AAudio silent output probe: requested rate=48000 channels=2 format=PCM_I16"
         " sharing=SHARED performance=NONE duration=1s watchdog=10s");

    if (!result_ok("create_builder", AAudio_createStreamBuilder(&builder))) {
        goto cleanup;
    }
    AAudioStreamBuilder_setDirection(builder, AAUDIO_DIRECTION_OUTPUT);
    AAudioStreamBuilder_setSampleRate(builder, 48000);
    AAudioStreamBuilder_setChannelCount(builder, 2);
    AAudioStreamBuilder_setFormat(builder, AAUDIO_FORMAT_PCM_I16);
    AAudioStreamBuilder_setSharingMode(builder, AAUDIO_SHARING_MODE_SHARED);
    AAudioStreamBuilder_setPerformanceMode(builder, AAUDIO_PERFORMANCE_MODE_NONE);
    AAudioStreamBuilder_setUsage(builder, AAUDIO_USAGE_MEDIA);
    AAudioStreamBuilder_setContentType(builder, AAUDIO_CONTENT_TYPE_MUSIC);
    if (interrupted || !result_ok("open_stream", AAudioStreamBuilder_openStream(builder, &stream))) {
        goto cleanup;
    }
    target_frames = AAudioStream_getSampleRate(stream);
    printf("negotiated rate=%" PRId32 " channels=%" PRId32 " format=%" PRId32
           " sharing=%" PRId32 " performance=%" PRId32 " direction=%" PRId32
           " device_id=%" PRId32 " burst_frames=%" PRId32
           " buffer_frames=%" PRId32 " capacity_frames=%" PRId32 "\n",
           target_frames, AAudioStream_getChannelCount(stream), AAudioStream_getFormat(stream),
           AAudioStream_getSharingMode(stream), AAudioStream_getPerformanceMode(stream),
           AAudioStream_getDirection(stream), AAudioStream_getDeviceId(stream),
           AAudioStream_getFramesPerBurst(stream), AAudioStream_getBufferSizeInFrames(stream),
           AAudioStream_getBufferCapacityInFrames(stream));
    report_stream(stream, "opened", accepted);
    if (target_frames <= 0 || AAudioStream_getChannelCount(stream) != 2 ||
        AAudioStream_getFormat(stream) != AAUDIO_FORMAT_PCM_I16 ||
        AAudioStream_getSharingMode(stream) != AAUDIO_SHARING_MODE_SHARED ||
        AAudioStream_getDirection(stream) != AAUDIO_DIRECTION_OUTPUT) {
        fputs("Unsupported negotiated format; no samples written.\n", stderr);
        goto cleanup;
    }

    /* Prefill silence without waiting, as recommended for output streams. */
    int32_t prefill = target_frames < CHUNK_FRAMES ? target_frames : CHUNK_FRAMES;
    aaudio_result_t written = AAudioStream_write(stream, silence, prefill, 0);
    if (written < 0 || written > prefill) {
        printf("prefill failed result=%" PRId32 " (%s)\n", written,
               AAudio_convertResultToText(written));
        goto cleanup;
    }
    accepted = written;
    printf("prefill accepted=%" PRId64 " timeout_ms=0\n", accepted);
    if (interrupted || !result_ok("request_start", AAudioStream_requestStart(stream)) ||
        !wait_for_state(stream, AAUDIO_STREAM_STATE_STARTED, 1000 * NS_PER_MS, true)) {
        goto cleanup;
    }
    report_stream(stream, "started", accepted);

    int64_t write_start = now_ns();
    while (accepted < target_frames) {
        int64_t now = now_ns();
        if (interrupted || write_start < 0 || now < 0 || now - write_start >= 5000 * NS_PER_MS) {
            fputs("write loop interrupted or exceeded 5-second deadline\n", stderr);
            goto cleanup;
        }
        int64_t remaining = target_frames - accepted;
        int32_t frames = remaining < CHUNK_FRAMES ? (int32_t)remaining : CHUNK_FRAMES;
        written = AAudioStream_write(stream, silence, frames, 100 * NS_PER_MS);
        if (written < 0 || written > frames) {
            printf("write failed result=%" PRId32 " (%s)\n", written,
                   AAudio_convertResultToText(written));
            goto cleanup;
        }
        accepted += written;
        if (written == 0) {
            const struct timespec backoff = {.tv_sec = 0, .tv_nsec = 1000000};
            (void)nanosleep(&backoff, NULL);
        }
    }
    exit_code = 0;

cleanup:
    if (stream != NULL) {
        report_stream(stream, "before_stop", accepted);
        aaudio_stream_state_t state = AAudioStream_getState(stream);
        if (state == AAUDIO_STREAM_STATE_DISCONNECTED || state == AAUDIO_STREAM_STATE_CLOSED) {
            exit_code = 1;
        } else if (state != AAUDIO_STREAM_STATE_OPEN && state != AAUDIO_STREAM_STATE_STOPPED) {
            if (!result_ok("request_stop", AAudioStream_requestStop(stream)) ||
                !wait_for_state(stream, AAUDIO_STREAM_STATE_STOPPED, 2000 * NS_PER_MS, false)) {
                exit_code = 1;
            }
        }
        report_stream(stream, "after_stop", accepted);
        if (!result_ok("close_stream", AAudioStream_close(stream))) {
            exit_code = 1;
        }
    }
    if (builder != NULL && !result_ok("delete_builder", AAudioStreamBuilder_delete(builder))) {
        exit_code = 1;
    }
    if (interrupted) {
        exit_code = 128 + interrupted;
    }
    int64_t ended_at = now_ns();
    printf("RESULT %s exit=%d accepted=%" PRId64 "/%" PRId32 " elapsed_ms=%" PRId64 "\n",
           exit_code == 0 ? "PASS" : "FAIL", exit_code, accepted, target_frames,
           ended_at < 0 ? -1 : (ended_at - started_at) / NS_PER_MS);
    alarm(0);
    return exit_code;
}
