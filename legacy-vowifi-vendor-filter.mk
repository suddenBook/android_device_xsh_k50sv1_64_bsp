# The extracted ePDG stack embeds strongSwan 5.1.2. It is retained only on the
# two controlled diagnostic tiers while a modern source-compatible replacement
# is developed. Tier 3 must not install any executable, dependency or config
# from that remotely exposed legacy tunnel. Keep this exact list synchronized
# with the `vowifi` section of proprietary-files.txt; setup-makefiles.sh makes
# the generated vendor product include this filter after defining its copies.

K50SV1_LEGACY_VOWIFI_COPY_FILES := \
    vendor/xsh/k50sv1_64_bsp/proprietary/vendor/bin/charon:$(TARGET_COPY_OUT_VENDOR)/bin/charon \
    vendor/xsh/k50sv1_64_bsp/proprietary/vendor/bin/epdg_wod:$(TARGET_COPY_OUT_VENDOR)/bin/epdg_wod \
    vendor/xsh/k50sv1_64_bsp/proprietary/vendor/bin/starter:$(TARGET_COPY_OUT_VENDOR)/bin/starter \
    vendor/xsh/k50sv1_64_bsp/proprietary/vendor/bin/stroke:$(TARGET_COPY_OUT_VENDOR)/bin/stroke \
    vendor/xsh/k50sv1_64_bsp/proprietary/vendor/bin/wfca:$(TARGET_COPY_OUT_VENDOR)/bin/wfca \
    vendor/xsh/k50sv1_64_bsp/proprietary/vendor/lib/libmal_epdga.so:$(TARGET_COPY_OUT_VENDOR)/lib/libmal_epdga.so \
    vendor/xsh/k50sv1_64_bsp/proprietary/vendor/lib/libwo.so:$(TARGET_COPY_OUT_VENDOR)/lib/libwo.so \
    vendor/xsh/k50sv1_64_bsp/proprietary/vendor/lib64/libcharon-ss.so:$(TARGET_COPY_OUT_VENDOR)/lib64/libcharon-ss.so \
    vendor/xsh/k50sv1_64_bsp/proprietary/vendor/lib64/libcrypto-ss.so:$(TARGET_COPY_OUT_VENDOR)/lib64/libcrypto-ss.so \
    vendor/xsh/k50sv1_64_bsp/proprietary/vendor/lib64/libcurl-ss.so:$(TARGET_COPY_OUT_VENDOR)/lib64/libcurl-ss.so \
    vendor/xsh/k50sv1_64_bsp/proprietary/vendor/lib64/libhydra.so:$(TARGET_COPY_OUT_VENDOR)/lib64/libhydra.so \
    vendor/xsh/k50sv1_64_bsp/proprietary/vendor/lib64/libsimaka.so:$(TARGET_COPY_OUT_VENDOR)/lib64/libsimaka.so \
    vendor/xsh/k50sv1_64_bsp/proprietary/vendor/lib64/libssl-ss.so:$(TARGET_COPY_OUT_VENDOR)/lib64/libssl-ss.so \
    vendor/xsh/k50sv1_64_bsp/proprietary/vendor/lib64/libstrongswan.so:$(TARGET_COPY_OUT_VENDOR)/lib64/libstrongswan.so \
    vendor/xsh/k50sv1_64_bsp/proprietary/vendor/lib64/libwo.so:$(TARGET_COPY_OUT_VENDOR)/lib64/libwo.so \
    vendor/xsh/k50sv1_64_bsp/proprietary/vendor/etc/ipsec/ipsec.conf:$(TARGET_COPY_OUT_VENDOR)/etc/ipsec/ipsec.conf \
    vendor/xsh/k50sv1_64_bsp/proprietary/vendor/etc/ipsec/ipsec.d/cacerts/Entrust.net_Certification_Authority_2048.cer:$(TARGET_COPY_OUT_VENDOR)/etc/ipsec/ipsec.d/cacerts/Entrust.net_Certification_Authority_2048.cer \
    vendor/xsh/k50sv1_64_bsp/proprietary/vendor/etc/ipsec/ipsec.d/cacerts/GeoTrust_PCA_G3_Root.der:$(TARGET_COPY_OUT_VENDOR)/etc/ipsec/ipsec.d/cacerts/GeoTrust_PCA_G3_Root.der \
    vendor/xsh/k50sv1_64_bsp/proprietary/vendor/etc/ipsec/ipsec.d/cacerts/GeoTrust_Primary_CA.der:$(TARGET_COPY_OUT_VENDOR)/etc/ipsec/ipsec.d/cacerts/GeoTrust_Primary_CA.der \
    vendor/xsh/k50sv1_64_bsp/proprietary/vendor/etc/ipsec/ipsec.d/cacerts/GeoTrust_Primary_CA_G2_ECC.der:$(TARGET_COPY_OUT_VENDOR)/etc/ipsec/ipsec.d/cacerts/GeoTrust_Primary_CA_G2_ECC.der \
    vendor/xsh/k50sv1_64_bsp/proprietary/vendor/etc/ipsec/ipsec.d/cacerts/VeriSignClass3G4.der:$(TARGET_COPY_OUT_VENDOR)/etc/ipsec/ipsec.d/cacerts/VeriSignClass3G4.der \
    vendor/xsh/k50sv1_64_bsp/proprietary/vendor/etc/ipsec/ipsec.d/cacerts/VeriSignClass3G5.der:$(TARGET_COPY_OUT_VENDOR)/etc/ipsec/ipsec.d/cacerts/VeriSignClass3G5.der \
    vendor/xsh/k50sv1_64_bsp/proprietary/vendor/etc/ipsec/ipsec.d/cacerts/VeriSignUniversalRootCertification.der:$(TARGET_COPY_OUT_VENDOR)/etc/ipsec/ipsec.d/cacerts/VeriSignUniversalRootCertification.der \
    vendor/xsh/k50sv1_64_bsp/proprietary/vendor/etc/ipsec/ipsec.d/cacerts/gold.cer:$(TARGET_COPY_OUT_VENDOR)/etc/ipsec/ipsec.d/cacerts/gold.cer \
    vendor/xsh/k50sv1_64_bsp/proprietary/vendor/etc/ipsec/ipsec.d/cacerts/thawte.der:$(TARGET_COPY_OUT_VENDOR)/etc/ipsec/ipsec.d/cacerts/thawte.der \
    vendor/xsh/k50sv1_64_bsp/proprietary/vendor/etc/ipsec/ssl/openssl.cnf:$(TARGET_COPY_OUT_VENDOR)/etc/ipsec/ssl/openssl.cnf \
    vendor/xsh/k50sv1_64_bsp/proprietary/vendor/etc/ipsec/strongswan.conf:$(TARGET_COPY_OUT_VENDOR)/etc/ipsec/strongswan.conf \
    vendor/xsh/k50sv1_64_bsp/proprietary/vendor/etc/ipsec/wod_cust.conf:$(TARGET_COPY_OUT_VENDOR)/etc/ipsec/wod_cust.conf \
    vendor/xsh/k50sv1_64_bsp/proprietary/vendor/etc/ipsec/wod_optr.conf:$(TARGET_COPY_OUT_VENDOR)/etc/ipsec/wod_optr.conf

K50SV1_LEGACY_VOWIFI_MATCHES := $(filter \
    $(K50SV1_LEGACY_VOWIFI_COPY_FILES),$(PRODUCT_COPY_FILES))
ifneq ($(words $(K50SV1_LEGACY_VOWIFI_MATCHES)),29)
$(error Expected 29 generated legacy-VoWiFi copies, found $(words $(K50SV1_LEGACY_VOWIFI_MATCHES)); regenerate/review the exact Tier-3 exclusion)
endif

ifeq ($(K50SV1_BUILD_TIER),3)
PRODUCT_COPY_FILES := $(filter-out \
    $(K50SV1_LEGACY_VOWIFI_COPY_FILES),$(PRODUCT_COPY_FILES))
endif

K50SV1_LEGACY_VOWIFI_MATCHES :=
K50SV1_LEGACY_VOWIFI_COPY_FILES :=
