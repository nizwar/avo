# Avo: AOSP arm64 for crosvm on Apple Silicon (Hypervisor.framework).
#
# Built on Cuttlefish's arm64-only phone product, the AOSP target closest to
# Avo's engine: crosvm, virtio-gpu with gfxstream, virtio-vsock, virtio-input,
# virtio-snd and virtio-balloon (spec: "Kernel dikonfigurasi untuk virtio").
# Apple Silicon has no AArch32, so the image is 64-bit only.

$(call inherit-product, device/google/cuttlefish/vsoc_arm64_only/phone/aosp_cf.mk)

PRODUCT_NAME := avo_arm64
PRODUCT_DEVICE := vsoc_arm64_only
PRODUCT_BRAND := Avo
PRODUCT_MANUFACTURER := Avo
PRODUCT_MODEL := Avo Virtual Device

# No launcher, no recents (spec §1): Avo's HomeActivity is the only HOME.
PRODUCT_PACKAGES := $(filter-out Launcher3QuickStep Launcher3 QuickSearchBox,$(PRODUCT_PACKAGES))
PRODUCT_PACKAGES += \
    AvoBridgeAgent \
    avo_init

# Root (spec §7): the host attaches one of two system overlays at boot (the
# avo_overlay block device): stock, or rooted with KernelSU. The overlays are
# produced after the main build (see ../README.md); the KernelSU build is GPL
# and published separately (spec: "Komponen GPL dipisahkan dengan jelas").

PRODUCT_PRODUCT_PROPERTIES += \
    ro.avo.image.version=16.0.0 \
    ro.lockscreen.disable.default=true \
    ro.setupwizard.mode=DISABLED \
    qemu.hw.mainkeys=1

# adbd only on vsock (spec: "ADB tidak pernah diekspos ke jaringan"), with
# authentication: the host's key arrives through the avo_config disk.
PRODUCT_VENDOR_PROPERTIES += \
    service.adb.listen_addrs=vsock:5555 \
    ro.adb.secure=1

DEVICE_PACKAGE_OVERLAYS += device/avo/avo_arm64/overlay

BOARD_SEPOLICY_DIRS += device/avo/avo_arm64/sepolicy

PRODUCT_COPY_FILES += \
    device/avo/avo_arm64/init.avo.rc:$(TARGET_COPY_OUT_SYSTEM_EXT)/etc/init/init.avo.rc

# Avo's system feature (docs/for-game-developers.md): apps call
# PackageManager.hasSystemFeature("com.avodroid.feature.MAC"). The same file as
# AvoIdentity.permissionsFile in AvoKit.
PRODUCT_COPY_FILES += \
    device/avo/avo_arm64/com.avodroid.feature.mac.xml:$(TARGET_COPY_OUT_PRODUCT)/etc/permissions/com.avodroid.feature.mac.xml
