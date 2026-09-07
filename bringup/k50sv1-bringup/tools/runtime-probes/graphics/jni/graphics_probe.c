#include <android/log.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>
#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <errno.h>
#include <inttypes.h>
#include <jni.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <time.h>

#define TAG "K50GraphicsProbe"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)
#define FRAME_COUNT 24

_Static_assert(sizeof(void *) == 4, "The graphics probe must be a 32-bit process");
#if !defined(__arm__) || __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error "This fixture requires little-endian armeabi-v7a"
#endif

static atomic_bool stop_requested = false;

JNIEXPORT void JNICALL
Java_local_k50_graphicsprobe_GraphicsProbeActivity_nativeRequestStop(JNIEnv *env, jclass clazz) {
    (void)env;
    (void)clazz;
    atomic_store_explicit(&stop_requested, true, memory_order_relaxed);
}

static const char *phase_name(int frame) {
    return frame < 8 ? "red" : (frame < 16 ? "green" : "checkerboard");
}

static uint32_t tile_color(int frame, int tile) {
    // RGBA_8888 memory is R,G,B,A. These words are written on little-endian ARM.
    if (frame < 8) {
        return UINT32_C(0xff2020e0);
    }
    if (frame < 16) {
        return UINT32_C(0xff20c020);
    }
    return (tile & 1) == 0 ? UINT32_C(0xff2020e0) : UINT32_C(0xffe0c020);
}

JNIEXPORT jint JNICALL
Java_local_k50_graphicsprobe_GraphicsProbeActivity_nativeRender(JNIEnv *env, jclass clazz,
                                                               jobject surface) {
    (void)clazz;
    int32_t result = 0;
    int posted = 0;
    LOGI("NATIVE_START pointer_bits=%zu compiled_abi=armeabi-v7a api=%d expected_frames=%d",
         sizeof(void *) * 8, __ANDROID_API__, FRAME_COUNT);
    ANativeWindow *window = ANativeWindow_fromSurface(env, surface);
    if (window == NULL) {
        LOGE("ERROR operation=fromSurface code=%d", -EINVAL);
        return -EINVAL;
    }
    LOGI("WINDOW width=%" PRId32 " height=%" PRId32 " format=%" PRId32,
         ANativeWindow_getWidth(window), ANativeWindow_getHeight(window),
         ANativeWindow_getFormat(window));
    result = ANativeWindow_setBuffersGeometry(window, 0, 0, WINDOW_FORMAT_RGBA_8888);
    if (result != 0) {
        LOGE("ERROR operation=setBuffersGeometry code=%" PRId32, result);
        goto done;
    }

    for (int frame = 0; frame < FRAME_COUNT; frame++) {
        if (atomic_load_explicit(&stop_requested, memory_order_relaxed)) {
            result = -ECANCELED;
            LOGE("ERROR operation=cancel frame=%d code=%" PRId32, frame, result);
            break;
        }
        ANativeWindow_Buffer buffer = {0};
        result = ANativeWindow_lock(window, &buffer, NULL);
        if (result != 0) {
            LOGE("ERROR operation=lock frame=%d code=%" PRId32, frame, result);
            break;
        }
        LOGI("BUFFER frame=%d phase=%s width=%" PRId32 " height=%" PRId32
             " stride=%" PRId32 " format=%" PRId32 " pointer_bits=32",
             frame, phase_name(frame), buffer.width, buffer.height, buffer.stride, buffer.format);
        if (buffer.bits == NULL || buffer.width <= 0 || buffer.height <= 0
                || buffer.width > 16384 || buffer.height > 16384 || buffer.stride < buffer.width
                || buffer.format != WINDOW_FORMAT_RGBA_8888
                || (size_t)buffer.stride > SIZE_MAX / sizeof(uint32_t) / (size_t)buffer.height) {
            LOGE("ERROR operation=validate_buffer frame=%d code=%d", frame, -EINVAL);
            int32_t unlock_result = ANativeWindow_unlockAndPost(window);
            if (unlock_result != 0) {
                LOGE("ERROR operation=unlock_invalid_buffer code=%" PRId32, unlock_result);
            }
            result = -EINVAL;
            break;
        }
        uint32_t *pixels = buffer.bits;
        for (int32_t y = 0; y < buffer.height; y++) {
            uint32_t *row = pixels + (size_t)y * (size_t)buffer.stride;
            const int tile_y = y * 8 / buffer.height;
            for (int tile_x = 0; tile_x < 8; tile_x++) {
                const uint32_t color = tile_color(frame, tile_x + tile_y);
                const int32_t start = (tile_x * buffer.width + 7) / 8;
                const int32_t end = ((tile_x + 1) * buffer.width + 7) / 8;
                for (int32_t x = start; x < end; x++) {
                    row[x] = color;
                }
            }
        }
        result = ANativeWindow_unlockAndPost(window);
        if (result != 0) {
            LOGE("ERROR operation=unlockAndPost frame=%d code=%" PRId32, frame, result);
            break;
        }
        posted++;
        LOGI("POST frame=%d result=0", frame);
        if (frame + 1 < FRAME_COUNT) {
            struct timespec delay = {.tv_sec = 0, .tv_nsec = 100000000};
            while (nanosleep(&delay, &delay) == -1) {
                if (errno != EINTR) {
                    result = -errno;
                    LOGE("ERROR operation=nanosleep code=%" PRId32, result);
                    goto done;
                }
                if (atomic_load_explicit(&stop_requested, memory_order_relaxed)) {
                    break;
                }
            }
        }
    }

done:
    ANativeWindow_release(window);
    if (result == 0 && posted == FRAME_COUNT) {
        LOGI("NATIVE_SUMMARY result=PASS posted=%d expected=%d errors=0 pointer_bits=32",
             posted, FRAME_COUNT);
    } else {
        if (result == 0) {
            result = -EIO;
        }
        LOGE("NATIVE_SUMMARY result=FAIL posted=%d expected=%d rc=%" PRId32 " pointer_bits=32",
             posted, FRAME_COUNT, result);
    }
    return result;
}

static bool egl_ok(EGLBoolean success, const char *operation) {
    if (!success) {
        LOGE("ERROR api=EGL operation=%s code=0x%04x", operation, eglGetError());
    }
    return success == EGL_TRUE;
}

static bool gl_ok(const char *operation) {
    GLenum error = glGetError();
    if (error != GL_NO_ERROR) {
        LOGE("ERROR api=GLES2 operation=%s code=0x%04x", operation, error);
    }
    return error == GL_NO_ERROR;
}

static GLuint compile_shader(GLenum type, const char *source) {
    GLuint shader = glCreateShader(type);
    if (shader == 0) {
        LOGE("ERROR operation=create_shader type=0x%x", type);
        gl_ok("create_shader");
        return 0;
    }
    glShaderSource(shader, 1, &source, NULL);
    glCompileShader(shader);
    GLint compiled = GL_FALSE;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
    if (!gl_ok("compile_shader") || compiled != GL_TRUE) {
        char info[512] = {0};
        glGetShaderInfoLog(shader, sizeof(info), NULL, info);
        LOGE("ERROR operation=compile_shader type=0x%x log=%s", type, info);
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

static GLuint create_program(void) {
    static const char vertex_source[] =
        "#version 100\n"
        "attribute vec2 position;\n"
        "void main() { gl_Position = vec4(position, 0.0, 1.0); }\n";
    static const char fragment_source[] =
        "#version 100\n"
        "precision mediump float;\n"
        "uniform vec2 size;\n"
        "uniform int phase;\n"
        "void main() {\n"
        "  vec3 red = vec3(224.0, 32.0, 32.0) / 255.0;\n"
        "  vec3 green = vec3(32.0, 192.0, 32.0) / 255.0;\n"
        "  vec3 cyan = vec3(32.0, 192.0, 224.0) / 255.0;\n"
        // Convert GL's lower-left origin to the CPU pattern's top-left origin.
        "  vec2 tile = floor(vec2(gl_FragCoord.x, size.y - gl_FragCoord.y) * 8.0 / size);\n"
        "  vec3 checker = mod(tile.x + tile.y, 2.0) < 1.0 ? red : cyan;\n"
        "  gl_FragColor = vec4(phase == 0 ? red : (phase == 1 ? green : checker), 1.0);\n"
        "}\n";
    GLuint vertex = compile_shader(GL_VERTEX_SHADER, vertex_source);
    if (vertex == 0) {
        return 0;
    }
    GLuint fragment = compile_shader(GL_FRAGMENT_SHADER, fragment_source);
    if (fragment == 0) {
        glDeleteShader(vertex);
        return 0;
    }
    GLuint program = glCreateProgram();
    if (program != 0) {
        glAttachShader(program, vertex);
        glAttachShader(program, fragment);
        glBindAttribLocation(program, 0, "position");
        glLinkProgram(program);
        GLint linked = GL_FALSE;
        glGetProgramiv(program, GL_LINK_STATUS, &linked);
        if (!gl_ok("link_program") || linked != GL_TRUE) {
            char info[512] = {0};
            glGetProgramInfoLog(program, sizeof(info), NULL, info);
            LOGE("ERROR operation=link_program log=%s", info);
            glDeleteProgram(program);
            program = 0;
        }
    } else {
        LOGE("ERROR operation=create_program");
        gl_ok("create_program");
    }
    glDeleteShader(vertex);
    glDeleteShader(fragment);
    return program;
}

static bool check_gl_pixels(int frame, EGLint width, EGLint height) {
    bool matched = true;
    for (int sample = 0; sample < 4; sample++) {
        int column = sample & 1;
        int row = sample / 2;
        GLint x = width * (column * 2 + 1) / 16;
        GLint y = height - 1 - height * (row * 2 + 1) / 16;
        uint8_t actual[4] = {0};
        uint32_t expected = tile_color(frame, column + row);
        glReadPixels(x, y, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, actual);
        if (!gl_ok("read_pixels")) {
            return false;
        }
        bool sample_matched = true;
        for (int channel = 0; channel < 4; channel++) {
            int difference = (int)actual[channel] - (int)((expected >> (channel * 8)) & 255);
            sample_matched &= difference >= -12 && difference <= 12;
        }
        matched &= sample_matched;
        LOGI("GL_PIXEL frame=%d sample=%d x=%d y=%d rgba=%02x%02x%02x%02x"
             " expected_rgba=%02x%02x%02x%02x result=%s tolerance=12",
             frame, sample, x, y, actual[0], actual[1], actual[2], actual[3],
             expected & 255, (expected >> 8) & 255, (expected >> 16) & 255, expected >> 24,
             sample_matched ? "PASS" : "MISMATCH");
    }
    if (matched) {
        LOGI("GL_READBACK frame=%d phase=%s result=PASS samples=4", frame, phase_name(frame));
    } else {
        LOGE("ERROR operation=gl_readback frame=%d phase=%s result=PIXEL_MISMATCH",
             frame, phase_name(frame));
    }
    return matched;
}

JNIEXPORT jint JNICALL
Java_local_k50_graphicsprobe_GraphicsProbeActivity_nativeRenderEgl(JNIEnv *env, jclass clazz,
                                                                  jobject surface) {
    (void)clazz;
    int result = -EIO;
    int posted = 0;
    int readbacks = 0;
    EGLDisplay display = EGL_NO_DISPLAY;
    EGLSurface egl_surface = EGL_NO_SURFACE;
    EGLContext context = EGL_NO_CONTEXT;
    bool initialized = false;
    bool current = false;
    bool cleanup_ok = true;
    GLuint program = 0;
    GLuint vertices = 0;
    LOGI("NATIVE_START pointer_bits=%zu compiled_abi=armeabi-v7a api=%d expected_frames=%d mode=egl",
         sizeof(void *) * 8, __ANDROID_API__, FRAME_COUNT);
    ANativeWindow *window = ANativeWindow_fromSurface(env, surface);
    if (window == NULL) {
        LOGE("ERROR operation=fromSurface code=%d", -EINVAL);
        result = -EINVAL;
        goto done;
    }
    display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (display == EGL_NO_DISPLAY) {
        egl_ok(EGL_FALSE, "get_display");
        goto done;
    }
    EGLint major = 0, minor = 0;
    if (!egl_ok(eglInitialize(display, &major, &minor), "initialize")) {
        goto done;
    }
    initialized = true;
    const char *egl_vendor = eglQueryString(display, EGL_VENDOR);
    const char *egl_version = eglQueryString(display, EGL_VERSION);
    if (egl_vendor == NULL || egl_version == NULL) {
        egl_ok(EGL_FALSE, "query_identity");
        goto done;
    }
    LOGI("EGL_IDENTITY major=%d minor=%d vendor=\"%s\" version=\"%s\"",
         major, minor, egl_vendor, egl_version);
    if (!egl_ok(eglBindAPI(EGL_OPENGL_ES_API), "bind_api")) {
        goto done;
    }
    static const EGLint config_attributes[] = {
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_DEPTH_SIZE, 0, EGL_STENCIL_SIZE, 0, EGL_NONE
    };
    EGLConfig config;
    EGLint configs = 0, format = 0;
    if (!egl_ok(eglChooseConfig(display, config_attributes, &config, 1, &configs), "choose_config")) {
        goto done;
    }
    if (configs != 1) {
        LOGE("ERROR operation=choose_config matching_configs=%d", configs);
        goto done;
    }
    if (!egl_ok(eglGetConfigAttrib(display, config, EGL_NATIVE_VISUAL_ID, &format), "native_visual_id")) {
        goto done;
    }
    int32_t geometry_result = ANativeWindow_setBuffersGeometry(window, 0, 0, format);
    if (geometry_result != 0) {
        LOGE("ERROR operation=setBuffersGeometry code=%" PRId32, geometry_result);
        result = geometry_result;
        goto done;
    }
    egl_surface = eglCreateWindowSurface(display, config, window, NULL);
    if (egl_surface == EGL_NO_SURFACE) {
        egl_ok(EGL_FALSE, "create_window_surface");
        goto done;
    }
    static const EGLint context_attributes[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
    context = eglCreateContext(display, config, EGL_NO_CONTEXT, context_attributes);
    if (context == EGL_NO_CONTEXT) {
        egl_ok(EGL_FALSE, "create_context");
        goto done;
    }
    if (!egl_ok(eglMakeCurrent(display, egl_surface, egl_surface, context), "make_current")) {
        goto done;
    }
    current = true;
    const char *vendor = (const char *)glGetString(GL_VENDOR);
    const char *renderer = (const char *)glGetString(GL_RENDERER);
    const char *version = (const char *)glGetString(GL_VERSION);
    const char *glsl = (const char *)glGetString(GL_SHADING_LANGUAGE_VERSION);
    if (!gl_ok("query_identity") || vendor == NULL || renderer == NULL || version == NULL || glsl == NULL) {
        LOGE("ERROR operation=gl_identity missing_or_invalid_string=1");
        goto done;
    }
    LOGI("GL_IDENTITY vendor=\"%s\" renderer=\"%s\" version=\"%s\" glsl=\"%s\""
         " requested_client_version=2 native_format=%d", vendor, renderer, version, glsl, format);
    program = create_program();
    if (program == 0) {
        goto done;
    }
    glUseProgram(program);
    GLint size_uniform = glGetUniformLocation(program, "size");
    GLint phase_uniform = glGetUniformLocation(program, "phase");
    if (size_uniform < 0 || phase_uniform < 0) {
        LOGE("ERROR operation=uniform_locations size=%d phase=%d", size_uniform, phase_uniform);
        goto done;
    }
    static const GLfloat quad[] = {-1, -1, 1, -1, -1, 1, 1, 1};
    glGenBuffers(1, &vertices);
    glBindBuffer(GL_ARRAY_BUFFER, vertices);
    glBufferData(GL_ARRAY_BUFFER, sizeof(quad), quad, GL_STATIC_DRAW);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, NULL);
    glEnableVertexAttribArray(0);
    glDisable(GL_DITHER);
    if (!gl_ok("setup_quad") || vertices == 0) {
        LOGE("ERROR operation=setup_quad buffer=%u", vertices);
        goto done;
    }
    for (int frame = 0; frame < FRAME_COUNT; frame++) {
        if (atomic_load_explicit(&stop_requested, memory_order_relaxed)) {
            result = -ECANCELED;
            LOGE("ERROR operation=cancel frame=%d code=%d", frame, result);
            goto done;
        }
        EGLint width = 0, height = 0;
        if (!egl_ok(eglQuerySurface(display, egl_surface, EGL_WIDTH, &width), "query_width")
                || !egl_ok(eglQuerySurface(display, egl_surface, EGL_HEIGHT, &height), "query_height")) {
            goto done;
        }
        if (width < 16 || height < 16 || width > 16384 || height > 16384) {
            LOGE("ERROR operation=surface_size width=%d height=%d", width, height);
            goto done;
        }
        glViewport(0, 0, width, height);
        glUniform2f(size_uniform, (GLfloat)width, (GLfloat)height);
        glUniform1i(phase_uniform, frame / 8);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        if (!gl_ok("draw_arrays")) {
            goto done;
        }
        // Read the rendered back buffer before swap; its later contents are not guaranteed.
        if (frame % 8 == 7) {
            if (!check_gl_pixels(frame, width, height)) {
                goto done;
            }
            readbacks++;
        }
        if (!egl_ok(eglSwapBuffers(display, egl_surface), "swap_buffers")) {
            goto done;
        }
        posted++;
        LOGI("EGL_POST frame=%d phase=%s width=%d height=%d result=0", frame, phase_name(frame), width, height);
        if (frame + 1 < FRAME_COUNT) {
            struct timespec delay = {.tv_sec = 0, .tv_nsec = 100000000};
            while (nanosleep(&delay, &delay) == -1) {
                if (errno != EINTR) {
                    result = -errno;
                    LOGE("ERROR operation=nanosleep code=%d", result);
                    goto done;
                }
                if (atomic_load_explicit(&stop_requested, memory_order_relaxed)) {
                    break;
                }
            }
        }
    }
    result = 0;

done:
    if (current) {
        glDeleteBuffers(1, &vertices);
        glUseProgram(0);
        if (program != 0) {
            glDeleteProgram(program);
        }
        cleanup_ok &= gl_ok("cleanup");
        cleanup_ok &= egl_ok(eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT), "unbind");
    }
    if (context != EGL_NO_CONTEXT) {
        cleanup_ok &= egl_ok(eglDestroyContext(display, context), "destroy_context");
    }
    if (egl_surface != EGL_NO_SURFACE) {
        cleanup_ok &= egl_ok(eglDestroySurface(display, egl_surface), "destroy_surface");
    }
    if (initialized) {
        cleanup_ok &= egl_ok(eglTerminate(display), "terminate");
    }
    if (display != EGL_NO_DISPLAY) {
        cleanup_ok &= egl_ok(eglReleaseThread(), "release_thread");
    }
    if (window != NULL) {
        ANativeWindow_release(window);
    }
    if (result == 0 && (!cleanup_ok || posted != FRAME_COUNT || readbacks != 3)) {
        result = -EIO;
    }
    if (result == 0) {
        LOGI("NATIVE_SUMMARY result=PASS posted=%d expected=%d errors=0 pointer_bits=32 mode=egl gl_readbacks=%d",
             posted, FRAME_COUNT, readbacks);
    } else {
        LOGE("NATIVE_SUMMARY result=FAIL posted=%d expected=%d rc=%d pointer_bits=32 mode=egl gl_readbacks=%d",
             posted, FRAME_COUNT, result, readbacks);
    }
    return result;
}
