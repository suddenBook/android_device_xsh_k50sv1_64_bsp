package local.k50.p2pprobe;

import android.app.Activity;
import android.net.wifi.p2p.WifiP2pManager;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.util.Log;
import android.widget.TextView;

public final class P2pProbeActivity extends Activity {
    private static final String TAG = "K50P2pProbe";
    private final Handler handler = new Handler(Looper.getMainLooper());
    private WifiP2pManager manager;
    private WifiP2pManager.Channel channel;
    private long deadline;
    private boolean created;
    private boolean formed;
    private boolean removing;
    private boolean finished;
    private boolean failed;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        TextView view = new TextView(this);
        view.setText("Local Wi-Fi Direct group test. Stops automatically.");
        setContentView(view);
        manager = (WifiP2pManager) getSystemService(WIFI_P2P_SERVICE);
        if (manager == null) {
            complete(false, "service_missing");
            return;
        }
        channel = manager.initialize(this, getMainLooper(), () -> {
            failed = true;
            complete(false, "channel_lost");
        });
        if (channel == null) {
            complete(false, "channel_missing");
            return;
        }
        deadline = SystemClock.elapsedRealtime() + 20000;
        handler.postDelayed(() -> {
            if (!finished) {
                failed = true;
                Log.e(TAG, "watchdog_cleanup");
                remove();
            }
        }, 25000);
        handler.postDelayed(() -> complete(false, "watchdog_timeout"), 30000);
        // Refuse to replace a group that existed before this probe.
        manager.requestGroupInfo(channel, group -> {
            if (finished) return;
            if (group != null) {
                complete(false, "existing_group");
                return;
            }
            manager.createGroup(channel, new WifiP2pManager.ActionListener() {
                @Override public void onSuccess() {
                    created = true;
                    Log.i(TAG, "create_accepted");
                    pollFormed();
                }
                @Override public void onFailure(int reason) {
                    complete(false, "create_failed_" + reason);
                }
            });
        });
    }

    private void pollFormed() {
        if (finished || removing) return;
        manager.requestGroupInfo(channel, group -> {
            if (finished || removing) return;
            if (group == null) {
                if (SystemClock.elapsedRealtime() < deadline) {
                    handler.postDelayed(this::pollFormed, 500);
                } else {
                    failed = true;
                    Log.e(TAG, "formation_timeout");
                    remove();
                }
                return;
            }
            if (!group.isGroupOwner() || !group.getClientList().isEmpty()) {
                failed = true;
                Log.e(TAG, "unexpected_group_role_or_clients");
                remove();
                return;
            }
            manager.requestConnectionInfo(channel, info -> {
                if (finished || removing) return;
                formed = info.groupFormed && info.isGroupOwner;
                failed |= !formed;
                Log.i(TAG, "formed=" + formed + " owner=" + info.isGroupOwner
                        + " clients=0");
                handler.postDelayed(this::remove, 4000);
            });
        });
    }

    private void remove() {
        if (finished || removing) return;
        removing = true;
        if (!created) {
            complete(false, "no_owned_group");
            return;
        }
        manager.removeGroup(channel, new WifiP2pManager.ActionListener() {
            @Override public void onSuccess() {
                Log.i(TAG, "remove_accepted");
                pollRemoved(12);
            }
            @Override public void onFailure(int reason) {
                complete(false, "remove_failed_" + reason);
            }
        });
    }

    private void pollRemoved(int remaining) {
        if (finished) return;
        manager.requestGroupInfo(channel, group -> {
            if (finished) return;
            if (group == null) {
                manager.requestConnectionInfo(channel, info -> {
                    if (finished) return;
                    if (!info.groupFormed) {
                        created = false;
                        complete(formed && !failed, "group_removed");
                    } else if (remaining > 0) {
                        handler.postDelayed(() -> pollRemoved(remaining - 1), 250);
                    } else {
                        complete(false, "connection_state_retained");
                    }
                });
            } else if (remaining > 0) {
                handler.postDelayed(() -> pollRemoved(remaining - 1), 250);
            } else {
                complete(false, "group_retained");
            }
        });
    }

    private void complete(boolean pass, String reason) {
        if (finished) return;
        finished = true;
        handler.removeCallbacksAndMessages(null);
        Log.i(TAG, "RESULT " + (pass ? "PASS" : "FAIL") + " reason=" + reason
                + " formed=" + formed + " cleanup_pending=" + created);
        // A failed cleanup requires the operator to inspect/cycle Wi-Fi.
        if (created && channel != null) manager.removeGroup(channel, null);
        if (channel != null) channel.close();
        finishAndRemoveTask();
    }

    @Override public void onDestroy() {
        if (!finished) complete(false, "activity_destroyed");
        super.onDestroy();
    }
}
