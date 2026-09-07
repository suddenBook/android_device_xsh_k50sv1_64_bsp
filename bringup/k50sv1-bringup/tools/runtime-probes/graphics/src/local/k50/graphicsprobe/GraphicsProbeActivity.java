package local.k50.graphicsprobe;

import android.app.Activity;
import android.graphics.Bitmap;
import android.graphics.PixelFormat;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.Process;
import android.os.SystemClock;
import android.util.Log;
import android.view.PixelCopy;
import android.view.Surface;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.WindowManager;

import java.util.Arrays;
import java.util.Locale;

/** A bounded 32-bit Surface probe with CPU/PixelCopy and optional EGL/GLES2 modes. */
public final class GraphicsProbeActivity extends Activity implements SurfaceHolder.Callback {
    private static final String TAG = "K50GraphicsProbe";
    private static final int NOT_RUN = Integer.MIN_VALUE;
    private static final int COPY_SIZE = 64;
    private static final int RED = 0xffe02020;
    private static final int CYAN = 0xff20c0e0;

    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private SurfaceView surfaceView;
    private long startedAt;
    private boolean libraryLoaded;
    private boolean eglMode;
    private boolean renderStarted;
    private boolean closing;
    private volatile int nativeResult = NOT_RUN;
    private String readbackResult = "NOT_RUN";

    private static native int nativeRender(Surface surface);
    private static native int nativeRenderEgl(Surface surface);
    private static native void nativeRequestStop();

    @Override
    public void onCreate(Bundle state) {
        super.onCreate(state);
        startedAt = SystemClock.elapsedRealtime();
        eglMode = getIntent().getBooleanExtra("egl", false);
        Log.i(TAG, "START pid=" + Process.myPid()
                + " java_is64bit=" + Process.is64Bit()
                + " device_32bit_abis=" + Arrays.toString(Build.SUPPORTED_32_BIT_ABIS)
                + " duration_ms=5000 mode=" + (eglMode ? "egl" : "cpu"));
        mainHandler.postDelayed(() -> finishProbe("deadline"), 5000);
        new Thread(() -> {
            SystemClock.sleep(5500);
            Log.i(TAG, "WATCHDOG_EXIT pid=" + Process.myPid());
            Process.killProcess(Process.myPid());
        }, "K50Deadline").start();
        if (Process.is64Bit()) {
            Log.e(TAG, "ERROR operation=process_abi expected=32 actual=64");
            nativeResult = -1;
            return;
        }
        try {
            System.loadLibrary("graphicsprobe");
            libraryLoaded = true;
        } catch (UnsatisfiedLinkError error) {
            nativeResult = -1;
            Log.e(TAG, "ERROR operation=load_library", error);
            return;
        }
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        surfaceView = new SurfaceView(this);
        surfaceView.getHolder().setFormat(PixelFormat.RGBA_8888);
        surfaceView.getHolder().addCallback(this);
        setContentView(surfaceView);
    }

    @Override
    public void surfaceCreated(SurfaceHolder holder) {
        Log.i(TAG, "SURFACE created valid=" + holder.getSurface().isValid());
        if (renderStarted || closing) {
            return;
        }
        renderStarted = true;
        final Surface surface = holder.getSurface();
        new Thread(() -> {
            try {
                nativeResult = eglMode ? nativeRenderEgl(surface) : nativeRender(surface);
            } catch (RuntimeException | LinkageError error) {
                nativeResult = -1;
                Log.e(TAG, "ERROR operation=native_render", error);
            }
            mainHandler.post(() -> {
                Log.i(TAG, "RENDER_RETURN rc=" + nativeResult);
                if (!closing && nativeResult == 0) {
                    if (eglMode) {
                        // JNI succeeds only after all three pre-swap GL readbacks pass.
                        if ("NOT_RUN".equals(readbackResult)) {
                            readbackResult = "PASS";
                        }
                    } else {
                        requestReadback();
                    }
                }
            });
        }, "K50NativeDraw").start();
    }

    @Override
    public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {
        Log.i(TAG, "SURFACE changed width=" + width + " height=" + height + " format=" + format);
    }

    @Override
    public void surfaceDestroyed(SurfaceHolder holder) {
        Log.i(TAG, "SURFACE destroyed closing=" + closing);
        if (libraryLoaded) {
            nativeRequestStop();
        }
        if (!closing) {
            readbackResult = "SURFACE_LOST";
        }
    }

    private void requestReadback() {
        final Bitmap bitmap = Bitmap.createBitmap(COPY_SIZE, COPY_SIZE, Bitmap.Config.ARGB_8888);
        readbackResult = "PENDING";
        try {
            PixelCopy.request(surfaceView, bitmap, result -> {
                if (result != PixelCopy.SUCCESS) {
                    readbackResult = "ERROR_" + result;
                    Log.e(TAG, "ERROR operation=pixelcopy code=" + result);
                } else {
                    // Centers of the first four tiles in the native 8 x 8 checkerboard.
                    int[] actual = {
                        bitmap.getPixel(4, 4), bitmap.getPixel(12, 4),
                        bitmap.getPixel(4, 12), bitmap.getPixel(12, 12)
                    };
                    int[] expected = { RED, CYAN, CYAN, RED };
                    boolean matched = true;
                    for (int index = 0; index < actual.length; index++) {
                        matched &= colorMatches(actual[index], expected[index]);
                    }
                    readbackResult = matched ? "PASS" : "PIXEL_MISMATCH";
                    String details = String.format(Locale.ROOT,
                            "PIXELCOPY result=%s code=0 bitmap=64x64 samples_argb=%08x,%08x,%08x,%08x"
                                    + " expected_argb=ffe02020,ff20c0e0,ff20c0e0,ffe02020 tolerance=12",
                            readbackResult, actual[0], actual[1], actual[2], actual[3]);
                    if (matched) {
                        Log.i(TAG, details);
                    } else {
                        Log.e(TAG, details);
                    }
                }
                bitmap.recycle();
            }, mainHandler);
        } catch (IllegalArgumentException error) {
            bitmap.recycle();
            readbackResult = "REQUEST_ERROR";
            Log.e(TAG, "ERROR operation=pixelcopy_request", error);
        }
    }

    private static boolean colorMatches(int actual, int expected) {
        for (int shift = 0; shift <= 24; shift += 8) {
            if (Math.abs(((actual >>> shift) & 255) - ((expected >>> shift) & 255)) > 12) {
                return false;
            }
        }
        return true;
    }

    private void finishProbe(String reason) {
        if (closing) {
            return;
        }
        closing = true;
        if (libraryLoaded) {
            nativeRequestStop();
        }
        String result = nativeResult == 0 && "PASS".equals(readbackResult) ? "PASS" : "FAIL";
        String summary = "SUMMARY result=" + result + " native_rc=" + nativeResult
                + " pixelcopy=" + (eglMode ? "NOT_REQUESTED" : readbackResult)
                + " java_is64bit=" + Process.is64Bit()
                + " elapsed_ms=" + (SystemClock.elapsedRealtime() - startedAt) + " reason=" + reason
                + " mode=" + (eglMode ? "egl" : "cpu")
                + (eglMode ? " gl_readpixels=" + readbackResult : "");
        if ("PASS".equals(result)) {
            Log.i(TAG, summary);
        } else {
            Log.e(TAG, summary);
        }
        // The independent deadline thread ends this process even if teardown blocks.
        finishAndRemoveTask();
    }

    @Override
    protected void onDestroy() {
        if (!closing) {
            finishProbe("activity_destroyed");
        }
        super.onDestroy();
    }
}
