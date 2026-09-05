Source: [LineageOS android_hardware_mediatek](https://github.com/LineageOS/android_hardware_mediatek/tree/3c04cf3997a30621966da9cf40f8b98ab453ebe3/wlan/wlan_assistant), revision `3c04cf3997a30621966da9cf40f8b98ab453ebe3`.

The device keeps its own `init.wmt.rc` service. This loader reads the existing factory WIFI record and passes it to `/dev/wmtWifi`; it does not replace firmware or calibration. The original service remains restartable and waits for the device and calibration file.
