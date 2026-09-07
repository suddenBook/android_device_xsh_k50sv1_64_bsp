package local.k50.sensorprobe;

import android.app.Activity;
import android.hardware.Sensor;
import android.hardware.SensorEvent;
import android.hardware.SensorEventListener;
import android.hardware.SensorManager;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.Process;
import android.os.SystemClock;
import android.util.Log;
import android.view.WindowManager;
import android.widget.TextView;
import java.util.List;

/** Bounded sampling, stop and restart check; never records individual samples. */
public final class SensorProbeActivity extends Activity implements SensorEventListener {
    private static final String TAG = "K50SensorProbe";
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final int[] counts = new int[2];
    private SensorManager manager;
    private Sensor sensor;
    private int phase;
    private int stray;
    private long timestamp;
    private double minNorm = Double.POSITIVE_INFINITY;
    private double maxNorm;
    private boolean valid = true;
    private boolean started;
    private boolean listening;
    private volatile boolean finished;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        TextView text = new TextView(this);
        text.setText("Checking accelerometer sampling and restart");
        setContentView(text);
        manager = (SensorManager) getSystemService(SENSOR_SERVICE);
    }

    @Override public void onResume() {
        super.onResume();
        if (started) return;
        started = true;
        new Thread(() -> {
            SystemClock.sleep(7000);
            if (!finished) Log.e(TAG, "WATCHDOG result=FAIL");
            Process.killProcess(Process.myPid());
        }, "SensorProbeDeadline").start();
        List<Sensor> sensors = manager.getSensorList(Sensor.TYPE_ACCELEROMETER);
        Log.i(TAG, "START pid=" + Process.myPid() + " accelerometers=" + sensors.size());
        if (sensors.size() != 1) {
            valid = false;
            finishProbe();
            return;
        }
        sensor = sensors.get(0);
        beginPhase();
    }

    private void beginPhase() {
        int period = phase == 0 ? 20000 : 100000;
        listening = manager.registerListener(this, sensor, period, 100000, handler);
        valid &= listening;
        Log.i(TAG, "REGISTER phase=" + phase + " period_us=" + period + " result=" + listening);
        handler.postDelayed(() -> {
            manager.unregisterListener(this);
            listening = false;
            Log.i(TAG, "STOP phase=" + phase + " events=" + counts[phase]);
            valid &= counts[phase] >= 5;
            handler.postDelayed(() -> {
                if (phase == 0) {
                    phase = 1;
                    beginPhase();
                } else {
                    finishProbe();
                }
            }, 400);
        }, 2000);
    }

    @Override public void onSensorChanged(SensorEvent event) {
        if (!listening) {
            stray++;
            return;
        }
        counts[phase]++;
        valid &= event.timestamp > timestamp && event.values.length >= 3;
        timestamp = event.timestamp;
        double squared = 0;
        for (int index = 0; index < Math.min(3, event.values.length); index++) {
            float value = event.values[index];
            valid &= Float.isFinite(value);
            squared += (double) value * value;
        }
        double norm = Math.sqrt(squared);
        minNorm = Math.min(minNorm, norm);
        maxNorm = Math.max(maxNorm, norm);
    }

    @Override public void onAccuracyChanged(Sensor sensor, int accuracy) {}

    private void finishProbe() {
        if (finished) return;
        manager.unregisterListener(this);
        listening = false;
        finished = true;
        boolean passed = valid && stray == 0 && counts[0] >= 5 && counts[1] >= 5
                && Double.isFinite(minNorm) && maxNorm > 0;
        Log.i(TAG, "SUMMARY result=" + (passed ? "PASS" : "FAIL")
                + " phase0=" + counts[0] + " phase1=" + counts[1]
                + " callbacks_after_stop=" + stray + " valid_monotonic=" + valid
                + " min_norm=" + minNorm + " max_norm=" + maxNorm);
        finishAndRemoveTask();
    }

    @Override public void onDestroy() {
        handler.removeCallbacksAndMessages(null);
        if (!finished) {
            valid = false;
            finishProbe();
        }
        super.onDestroy();
    }
}
