#!/bin/bash
# ============================================================================
# setup-nvidia-arch.sh   (Arch, Xorg, hybrid laptop: iGPU + NVIDIA RTX)
#
# Add-on script. Run as your normal user (NOT sudo), after configure-arch.sh.
# Safe to re-run. Reboot afterwards.
#
#   - installs the open kernel modules (required for RTX 50-series / Blackwell)
#   - enables DRM modesetting + fbdev
#   - fixes suspend/resume with the NVIDIA services
#   - sets up PRIME render offload (prime-run)
#   - optional: runtime power management so the dGPU sleeps when idle
#       ENABLE_RTD3=1 ./setup-nvidia-arch.sh
# ============================================================================

set -e

if [ "$EUID" -eq 0 ]; then
    echo "Don't run this as root/sudo — it'll ask for sudo when it needs it."
    exit 1
fi

echo "=== 1/5: Driver packages ==="
# Pick the open-module package that matches your kernel.
if pacman -Qq linux &> /dev/null; then
    DRIVER_PKGS="nvidia-open"
elif pacman -Qq linux-lts &> /dev/null; then
    DRIVER_PKGS="nvidia-open-lts"
else
    KERNEL_PKG=$(pacman -Qqo "/usr/lib/modules/$(uname -r)" 2>/dev/null | head -n1)
    DRIVER_PKGS="nvidia-open-dkms ${KERNEL_PKG:-linux}-headers"
fi
echo "  Driver: $DRIVER_PKGS"

sudo pacman -S --needed --noconfirm \
    $DRIVER_PKGS \
    nvidia-utils \
    nvidia-settings \
    nvidia-prime \
    vulkan-icd-loader \
    nvtop

# 32-bit libs (Steam/Proton). Only works if [multilib] is enabled in /etc/pacman.conf.
if pacman -Si lib32-nvidia-utils &> /dev/null; then
    sudo pacman -S --needed --noconfirm lib32-nvidia-utils lib32-vulkan-icd-loader
else
    echo "  Skipping 32-bit libs: enable [multilib] in /etc/pacman.conf, then re-run."
fi

# Hardware video decode in browsers/players (package name may differ — non-fatal).
sudo pacman -S --needed --noconfirm libva-nvidia-driver || \
    echo "  libva-nvidia-driver not found; check: pacman -Ss nvidia vaapi"

echo "=== 2/5: Kernel module options ==="
sudo tee /etc/modprobe.d/nvidia.conf > /dev/null << 'EOF'
# Required for PRIME offload, tear-free output and suspend handling
options nvidia_drm modeset=1 fbdev=1
# Keep VRAM contents across suspend (used with the nvidia-suspend/resume services)
options nvidia NVreg_PreserveVideoMemoryAllocations=1
EOF

echo "=== 3/5: Suspend / resume / hibernate services ==="
sudo systemctl enable nvidia-suspend.service nvidia-resume.service nvidia-hibernate.service

echo "=== 4/5: Optional runtime power management (ENABLE_RTD3=1) ==="
if [ "$ENABLE_RTD3" = "1" ]; then
    echo 'options nvidia NVreg_DynamicPowerManagement=0x02' | sudo tee /etc/modprobe.d/nvidia-rtd3.conf > /dev/null
    sudo tee /etc/udev/rules.d/80-nvidia-pm.rules > /dev/null << 'EOF'
ACTION=="bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030000", TEST=="power/control", ATTR{power/control}="auto"
ACTION=="bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030200", TEST=="power/control", ATTR{power/control}="auto"
ACTION=="unbind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030000", TEST=="power/control", ATTR{power/control}="on"
ACTION=="unbind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030200", TEST=="power/control", ATTR{power/control}="on"
EOF
    echo "  Enabled. Undo by deleting those two files and rebooting."
else
    echo "  Skipped (run with ENABLE_RTD3=1 to let the dGPU sleep when idle)."
fi

echo "=== 5/5: Rebuild initramfs ==="
sudo mkinitcpio -P

cat << 'INSTRUCTIONS'

============================================================
 Done. Reboot, then verify:

   nvidia-smi                                   # driver loaded
   cat /sys/module/nvidia_drm/parameters/modeset   # should print Y
   glxinfo | grep "OpenGL renderer"             # should show the iGPU (desktop)
   prime-run glxinfo | grep "OpenGL renderer"   # should show the NVIDIA GPU
   cat /sys/bus/pci/devices/*/power/runtime_status # RTD3: dGPU "suspended" when idle

 Running things on the NVIDIA GPU:
   Terminal:  prime-run <command>
   Steam:     Launch options ->  prime-run %command%

 If EVERYTHING renders on the NVIDIA GPU on Xorg (battery drain), check
 /usr/share/X11/xorg.conf.d/10-nvidia-drm-outputclass.conf and comment out
 the PrimaryGPU option there.

 If your laptop has a BIOS/MUX "dGPU only" mode, offload isn't needed there.
============================================================
INSTRUCTIONS
