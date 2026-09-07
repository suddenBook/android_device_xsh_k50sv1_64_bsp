package local.k50.cameraprobe;

import android.app.Activity;
import android.graphics.BitmapFactory;
import android.graphics.ImageFormat;
import android.graphics.SurfaceTexture;
import android.hardware.Camera;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.util.Log;
import android.view.TextureView;
import android.view.WindowManager;

/** Bounded preview/JPEG test; logs metadata and never saves camera pixels. */
@SuppressWarnings("deprecation")
public final class CameraProbeActivity extends Activity
        implements TextureView.SurfaceTextureListener {
    private static final String TAG = "K50CameraProbe";
    private final Handler handler = new Handler(Looper.getMainLooper());
    private TextureView texture;
    private Camera camera;
    private int cameraCount;
    private int cameraIndex;
    private int completed;
    private int frames;
    private int textureUpdates;
    private int malformed;
    private int expectedBytes;
    private int width;
    private int height;
    private int facing;
    private int pictureWidth;
    private int pictureHeight;
    private boolean testJpeg;
    private long previousTimestamp;
    private long started;
    private boolean monotonic;
    private boolean resumed;
    private boolean capturing;
    private boolean finished;
    private boolean passed = true;

    @Override public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        texture = new TextureView(this);
        texture.setSurfaceTextureListener(this);
        setContentView(texture);
        cameraCount = Camera.getNumberOfCameras();
        testJpeg = getIntent().getBooleanExtra("jpeg", false);
        Log.i(TAG, "BEGIN cameraCount=" + cameraCount);
        handler.postDelayed(() -> finishProbe("watchdog"), 15000);
    }

    @Override public void onResume() {
        super.onResume();
        resumed = true;
        startIfReady();
    }

    private void startIfReady() {
        if (!resumed || !texture.isAvailable() || camera != null || finished) return;
        if (cameraCount < 1 || cameraCount > 4) {
            finishProbe("unexpected-camera-count");
            return;
        }
        if (cameraIndex == cameraCount) {
            finishProbe(null);
            return;
        }
        try {
            camera = Camera.open(cameraIndex);
            Camera.CameraInfo info = new Camera.CameraInfo();
            Camera.getCameraInfo(cameraIndex, info);
            facing = info.facing;
            Camera.Parameters parameters = camera.getParameters();
            StringBuilder pictureSizes = new StringBuilder();
            for (Camera.Size size : parameters.getSupportedPictureSizes()) {
                if (pictureSizes.length() != 0) pictureSizes.append(',');
                pictureSizes.append(size.width).append('x').append(size.height);
            }
            Camera.Size pictureDefault = parameters.getPictureSize();
            Log.i(TAG, "CAPABILITIES id=" + cameraIndex + " pictureSizes=" + pictureSizes
                    + " pictureDefault=" + pictureDefault.width + "x" + pictureDefault.height
                    + " focusModes=" + parameters.getSupportedFocusModes()
                    + " flashModes=" + parameters.getSupportedFlashModes());
            Camera.Size selected = null;
            for (Camera.Size size : parameters.getSupportedPreviewSizes()) {
                if (selected == null || size.width * size.height < selected.width * selected.height) {
                    selected = size;
                }
                if (size.width == 640 && size.height == 480) {
                    selected = size;
                    break;
                }
            }
            if (selected == null || !parameters.getSupportedPreviewFormats().contains(ImageFormat.NV21)) {
                finishProbe("unsupported-preview-contract");
                return;
            }
            parameters.setPreviewFormat(ImageFormat.NV21);
            parameters.setPreviewSize(selected.width, selected.height);
            if (testJpeg) {
                String requested = getIntent().getStringExtra("picture_size_" + cameraIndex);
                if (requested != null) {
                    String[] dimensions = requested.split("x");
                    if (dimensions.length != 2) throw new IllegalArgumentException("picture-size");
                    int requestedWidth = Integer.parseInt(dimensions[0]);
                    int requestedHeight = Integer.parseInt(dimensions[1]);
                    boolean supported = false;
                    for (Camera.Size size : parameters.getSupportedPictureSizes()) {
                        supported |= size.width == requestedWidth && size.height == requestedHeight;
                    }
                    if (!supported) throw new IllegalArgumentException("unsupported-picture-size");
                    parameters.setPictureSize(requestedWidth, requestedHeight);
                }
                parameters.setPictureFormat(ImageFormat.JPEG);
                parameters.setRotation(0);
                if (parameters.getSupportedFlashModes() != null &&
                        parameters.getSupportedFlashModes().contains(Camera.Parameters.FLASH_MODE_OFF)) {
                    parameters.setFlashMode(Camera.Parameters.FLASH_MODE_OFF);
                }
                Camera.Size picture = parameters.getPictureSize();
                pictureWidth = picture.width;
                pictureHeight = picture.height;
            }
            camera.setParameters(parameters);
            if (testJpeg) {
                Camera.Size accepted = camera.getParameters().getPictureSize();
                if (accepted.width != pictureWidth || accepted.height != pictureHeight) {
                    finishProbe("picture-size-not-accepted");
                    return;
                }
            }
            Camera.Size actual = camera.getParameters().getPreviewSize();
            width = actual.width;
            height = actual.height;
            expectedBytes = width * height * ImageFormat.getBitsPerPixel(ImageFormat.NV21) / 8;
            frames = textureUpdates = malformed = 0;
            previousTimestamp = 0;
            monotonic = true;
            camera.setPreviewTexture(texture.getSurfaceTexture());
            camera.setErrorCallback((error, source) -> finishProbe("camera-error-" + error));
            camera.setPreviewCallbackWithBuffer((data, source) -> {
                if (!capturing || source != camera) return;
                long now = SystemClock.elapsedRealtimeNanos();
                if (previousTimestamp != 0 && now <= previousTimestamp) monotonic = false;
                previousTimestamp = now;
                frames++;
                if (data == null || data.length != expectedBytes) malformed++;
                if (data != null) source.addCallbackBuffer(data);
            });
            for (int i = 0; i < 3; i++) camera.addCallbackBuffer(new byte[expectedBytes]);
            capturing = true;
            started = SystemClock.elapsedRealtime();
            camera.startPreview();
            handler.postDelayed(this::finishCamera, 2200);
        } catch (Exception error) {
            finishProbe("start-" + error.getClass().getSimpleName());
        }
    }

    private void finishCamera() {
        if (finished || !capturing) return;
        boolean streamPassed = frames >= 10 && textureUpdates >= 5 && malformed == 0 && monotonic;
        passed &= streamPassed;
        Log.i(TAG, "CAMERA_RESULT id=" + cameraIndex + " facing=" + facing
                + " width=" + width + " height=" + height + " format=NV21"
                + " frames=" + frames + " textureUpdates=" + textureUpdates
                + " malformed=" + malformed + " monotonic=" + monotonic
                + " elapsedMs=" + (SystemClock.elapsedRealtime() - started)
                + " status=" + (streamPassed ? "PASS" : "FAIL"));
        if (testJpeg) {
            capturing = false;
            try {
                camera.setPreviewCallbackWithBuffer(null);
                camera.takePicture(null, null, (data, source) -> {
                    if (finished || source != camera) return;
                    BitmapFactory.Options bounds = new BitmapFactory.Options();
                    bounds.inJustDecodeBounds = true;
                    if (data != null) BitmapFactory.decodeByteArray(data, 0, data.length, bounds);
                    boolean jpegPassed = bounds.outWidth == pictureWidth && bounds.outHeight == pictureHeight;
                    passed &= jpegPassed;
                    Log.i(TAG, "JPEG_RESULT id=" + cameraIndex
                            + " requested=" + pictureWidth + "x" + pictureHeight
                            + " encoded=" + bounds.outWidth + "x" + bounds.outHeight
                            + " bytes=" + (data == null ? 0 : data.length)
                            + " status=" + (jpegPassed ? "PASS" : "FAIL"));
                    advanceCamera();
                });
            } catch (RuntimeException error) {
                finishProbe("jpeg-" + error.getClass().getSimpleName());
            }
            return;
        }
        advanceCamera();
    }

    private void advanceCamera() {
        completed++;
        closeCamera();
        cameraIndex++;
        handler.postDelayed(this::startIfReady, 250);
    }

    private void closeCamera() {
        capturing = false;
        Camera closing = camera;
        camera = null;
        if (closing == null) return;
        try {
            closing.setPreviewCallbackWithBuffer(null);
            closing.stopPreview();
        } catch (RuntimeException error) {
            passed = false;
            Log.e(TAG, "CLEANUP_FAIL " + error.getClass().getSimpleName());
        } finally {
            try {
                closing.release();
            } catch (RuntimeException error) {
                passed = false;
                Log.e(TAG, "RELEASE_FAIL " + error.getClass().getSimpleName());
            }
        }
    }

    private void finishProbe(String error) {
        if (finished) return;
        finished = true;
        handler.removeCallbacksAndMessages(null);
        if (error != null) passed = false;
        closeCamera();
        Log.i(TAG, "SUMMARY status=" + (passed && completed == cameraCount ? "PASS" : "FAIL")
                + " completed=" + completed + " cameraCount=" + cameraCount
                + " error=" + (error == null ? "none" : error));
        finish();
    }

    @Override public void onPause() {
        resumed = false;
        finishProbe("activity-paused");
        super.onPause();
    }

    @Override public void onSurfaceTextureAvailable(SurfaceTexture surface, int width, int height) {
        startIfReady();
    }

    @Override public void onSurfaceTextureSizeChanged(SurfaceTexture surface, int width, int height) {}

    @Override public boolean onSurfaceTextureDestroyed(SurfaceTexture surface) {
        finishProbe("surface-destroyed");
        return true;
    }

    @Override public void onSurfaceTextureUpdated(SurfaceTexture surface) {
        if (capturing) textureUpdates++;
    }
}
