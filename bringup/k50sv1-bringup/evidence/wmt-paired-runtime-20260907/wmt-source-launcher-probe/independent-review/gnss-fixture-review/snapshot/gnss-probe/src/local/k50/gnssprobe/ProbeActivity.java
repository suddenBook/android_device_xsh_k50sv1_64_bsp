package local.k50.gnssprobe;

import android.app.Activity;
import android.location.GnssStatus;
import android.location.Location;
import android.location.LocationListener;
import android.location.LocationManager;
import android.os.Bundle;
import android.os.Handler;
import android.os.SystemClock;
import android.util.Log;
import android.view.WindowManager;
import android.widget.TextView;

/** Bounded foreground GPS request. Logs counts and timing, never coordinates. */
public final class ProbeActivity extends Activity implements LocationListener {
    private static final String TAG = "K50GnssProbe";
    private final Handler handler = new Handler();
    private LocationManager manager;
    private long start;
    private int locations;
    private int statuses;
    private int maxSatellites;
    private int maxUsed;
    private boolean started;
    private boolean stopped;
    private boolean cleaned;
    private final GnssStatus.Callback callback = new GnssStatus.Callback() {
        @Override public void onStarted() { started = true; log("gnss_started"); }
        @Override public void onStopped() { stopped = true; log("gnss_stopped"); }
        @Override public void onFirstFix(int milliseconds) { log("first_fix_ms=" + milliseconds); }
        @Override public void onSatelliteStatusChanged(GnssStatus status) {
            statuses++;
            int used = 0;
            for (int i = 0; i < status.getSatelliteCount(); ++i) {
                if (status.usedInFix(i)) used++;
            }
            maxSatellites = Math.max(maxSatellites, status.getSatelliteCount());
            maxUsed = Math.max(maxUsed, used);
            if (statuses <= 3 || statuses % 20 == 0) {
                log("satellite_status count=" + status.getSatelliteCount() + " used=" + used);
            }
        }
    };

    private void log(String text) {
        Log.i(TAG, "elapsed_ms=" + (SystemClock.elapsedRealtime() - start) + " " + text);
    }

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        start = SystemClock.elapsedRealtime();
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        TextView view = new TextView(this);
        view.setText("GPS driver test — stops automatically after two minutes.\nNo coordinates are saved.");
        setContentView(view);
        manager = (LocationManager) getSystemService(LOCATION_SERVICE);
        try {
            log("request provider_enabled=" + manager.isProviderEnabled(LocationManager.GPS_PROVIDER));
            if (!manager.registerGnssStatusCallback(callback, handler)) {
                throw new IllegalStateException("GNSS status registration failed");
            }
            manager.requestLocationUpdates(LocationManager.GPS_PROVIDER, 1000, 0, this);
            handler.postDelayed(() -> {
                manager.removeUpdates(this);
                log("location_request_removed");
                handler.postDelayed(() -> { cleanup(); finish(); }, 5000);
            }, 120000);
        } catch (RuntimeException error) {
            Log.e(TAG, "request failed", error);
            cleanup();
            finish();
        }
    }

    private void cleanup() {
        if (cleaned) return;
        cleaned = true;
        handler.removeCallbacksAndMessages(null);
        if (manager != null) {
            manager.removeUpdates(this);
            manager.unregisterGnssStatusCallback(callback);
        }
        log("summary started=" + started + " stopped=" + stopped + " fixes=" + locations
                + " status_callbacks=" + statuses + " max_satellites=" + maxSatellites
                + " max_used=" + maxUsed);
    }

    @Override public void onLocationChanged(Location location) {
        locations++;
        if (locations <= 3 || locations % 20 == 0) {
            long ageMs = (SystemClock.elapsedRealtimeNanos() - location.getElapsedRealtimeNanos()) / 1000000;
            log("gps_fix count=" + locations + " age_ms=" + ageMs
                    + " accuracy_m=" + location.getAccuracy());
        }
    }
    @Override public void onProviderDisabled(String provider) { log("provider_disabled=" + provider); }
    @Override public void onProviderEnabled(String provider) { log("provider_enabled=" + provider); }
    @Override public void onStatusChanged(String provider, int status, Bundle extras) { log("provider_status=" + status); }
    @Override public void onDestroy() { cleanup(); super.onDestroy(); }
}
