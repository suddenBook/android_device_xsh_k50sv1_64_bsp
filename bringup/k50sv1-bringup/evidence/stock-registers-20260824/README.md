# Stock firmware, Dutch SIM, registered

**These captures are from STOCK, not from this port.** Check
`getprop.txt`: `ro.build.version.incremental=mp1V91221`, `ro.build.type=user`,
the same build as `factory_image/`. The owner reflashed stock and installed
Magisk while this was being investigated, so `adb root` is unavailable here and
the AT interrogation could not be repeated (`/dev/radio/atci1` is root-only).

The sibling directory `sim-mal-loop-20260824/` is the same handset and the same
SIM a few minutes earlier on THIS PORT
(`eng.desmon.20260824.005318`, userdebug), with the SIM badly seated.

| File | Holds |
|---|---|
| `getprop.txt` | the stock property set, registered |
| `telephony-registry.txt` | `mVoiceRegState=0(IN_SERVICE)`, `registrationState=HOME` |
| `data-connectivity.txt` | `ccmni0` address and a cellular ping |
| `logcat-radio.txt` | captured across the transition, so it spans both ROMs |
| `dmesg.txt`, `at-interrogation.txt` | EMPTY: no root on stock |
