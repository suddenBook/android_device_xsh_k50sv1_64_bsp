#!/usr/bin/env python3
"""Measure what keeps this handset out of suspend, as a delta over a window.

Reads the cumulative kernel power counters twice and reports the change, which
is the only form in which they mean anything: /d/wakeup_sources totals are
since boot, so a single read cannot distinguish "held for an hour last night"
from "held for the whole window you care about".

Suspend counters count attempts, not time asleep. Use BatteryStats' paired
screen-off realtime/uptime for the awake fraction. The battery counter on this
board is derived from integer UI SOC, not a raw coulomb measurement (E-187).

Usage:  measure-standby.py <adb-serial-or-host:port> [window_seconds]
        measure-standby.py <serial> --snapshot FILE      write one snapshot
        measure-standby.py --diff BEFORE AFTER           diff two snapshots

Take the cable OUT first. While a charger is attached the MTK battery driver
holds "battery suspend wakelock" and the gadget driver holds "USB.lock", the
handset never suspends at all, and every ratio below reads 100% awake.
"""
import subprocess, sys, time, json

# name -> (active_count, event_count, wakeup_count, expire_count,
#          active_since, total_time, max_time, last_change, prevent_suspend_time)
WS_FIELDS = 9


def sh(target, cmd, timeout=60):
    r = subprocess.run(["adb", "-s", target, "shell", cmd],
                       capture_output=True, text=True, timeout=timeout)
    return r.stdout


def snapshot(target):
    raw = sh(target, "cat /proc/uptime; echo '@@'; cat /d/wakeup_sources; echo '@@';"
                     " cat /sys/kernel/debug/suspend_stats; echo '@@';"
                     " cat /sys/class/power_supply/battery/charge_counter;"
                     " cat /sys/class/power_supply/battery/capacity;"
                     " cat /sys/class/power_supply/battery/status; echo '@@';"
                     " cat /sys/kernel/debug/cpuidle/idle_state | head -12")
    parts = raw.split("@@")
    up, idle = (float(x) for x in parts[0].split()[:2])

    ws = {}
    for ln in parts[1].splitlines()[1:]:
        t = ln.split()
        if len(t) < WS_FIELDS + 1:
            continue
        try:
            nums = [int(x) for x in t[-WS_FIELDS:]]
        except ValueError:
            continue
        # A name may contain spaces ("battery suspend wakelock"), and two
        # sources may share one name (three are called "[timerfd]"), so key on
        # name plus ordinal rather than name alone.
        name = " ".join(t[:-WS_FIELDS])
        k, n = name, 1
        while k in ws:
            n += 1
            k = "%s#%d" % (name, n)
        ws[k] = nums

    st = {}
    for ln in parts[2].splitlines():
        if ":" in ln:
            k, _, v = ln.partition(":")
            v = v.strip()
            if v.isdigit():
                st[k.strip()] = int(v)

    bat = [x.strip() for x in parts[3].split()]
    idle_states = {}
    for ln in parts[4].splitlines():
        for tok in ln.replace(",", " ").split():
            if "=" in tok and "[0]" in tok:
                k, _, v = tok.partition("=")
                if v.isdigit():
                    idle_states[k] = int(v)

    return {"t": time.time(), "uptime": up, "cpu_idle": idle, "ws": ws,
            "suspend": st, "battery": bat, "idle_states": idle_states}


def report(a, b):
    wall = b["uptime"] - a["uptime"]          # includes suspend
    if wall <= 0:
        print("window too short or device rebooted between snapshots")
        return 1

    # Every wakeup source's total_time only advances while the AP is awake, so
    # the longest-held source is a lower bound on awake time, not a measure of
    # it. Use the suspend counters for the real split.
    ok = b["suspend"].get("success", 0) - a["suspend"].get("success", 0)
    fail = b["suspend"].get("fail", 0) - a["suspend"].get("fail", 0)

    print("window            %.0f s wall" % wall)
    print("suspend           %d entered, %d aborted (%.0f%% of attempts failed)"
          % (ok, fail, 100.0 * fail / max(1, ok + fail)))
    if ok:
        print("suspend cycle     one every %.1f s" % (wall / ok))
    for k in ("failed_freeze", "failed_suspend", "failed_suspend_late",
              "failed_suspend_noirq"):
        d = b["suspend"].get(k, 0) - a["suspend"].get(k, 0)
        if d:
            print("  %-18s %d" % (k, d))

    ca, cb = a["battery"], b["battery"]
    if len(ca) >= 3 and len(cb) >= 3:
        try:
            duah = int(ca[0]) - int(cb[0])
            print("battery           %s%% -> %s%% (%s), UI-derived delta %d uAh"
                  % (ca[1], cb[1], cb[2], duah))
            print("                  integer SOC estimate; not measured charge/current")
        except ValueError:
            pass

    for k, v in sorted(b["idle_states"].items()):
        d = v - a["idle_states"].get(k, 0)
        if d:
            print("idle              %-16s +%d" % (k, d))

    rows = []
    for k, nb in b["ws"].items():
        na = a["ws"].get(k)
        if not na:
            continue
        rows.append((k, nb[5] - na[5], nb[0] - na[0], nb[1] - na[1], nb[2] - na[2]))
    rows.sort(key=lambda r: -r[1])

    print()
    print("%-34s %10s %8s %8s %8s" % ("wakeup source", "held_ms", "%window", "activate", "wakes"))
    print("-" * 74)
    for name, held, act, ev, wake in rows[:18]:
        if held <= 0 and act <= 0:
            continue
        print("%-34s %10d %7.1f%% %8d %8d"
              % (name[:34], held, 100.0 * held / (wall * 1000.0), act, wake))
    return 0


def main():
    if sys.argv[1:2] == ["--diff"]:
        a = json.load(open(sys.argv[2]))
        b = json.load(open(sys.argv[3]))
        return report(a, b)

    target = sys.argv[1]
    if "--snapshot" in sys.argv:
        path = sys.argv[sys.argv.index("--snapshot") + 1]
        json.dump(snapshot(target), open(path, "w"))
        print("wrote", path)
        return 0

    window = int(sys.argv[2]) if len(sys.argv) > 2 else 600
    a = snapshot(target)
    print("baseline taken, sleeping %d s -- leave the handset alone" % window)
    time.sleep(window)
    return report(a, snapshot(target))


if __name__ == "__main__":
    sys.exit(main())
