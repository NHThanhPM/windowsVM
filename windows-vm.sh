#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Windows QEMU/KVM launcher
# ============================================================
#
# Usage:
#   TPM=1 ./windows-vm.sh       # TPM 2.0 enabled
#   TPM=0 ./windows-vm.sh       # No TPM
#
# Optional:
#   RAM=12G CPUS=8 TPM=1 ./windows-vm.sh
#
# ============================================================

# ---------------- CONFIG ----------------

VM_NAME="windows"

RAM="${RAM:-8G}"
CPUS="${CPUS:-8}"
TPM="${TPM:-1}"

DISK="./windows.qcow2"
DISK_SIZE="128G"

WINDOWS_ISO="./windows.iso"
VIRTIO_ISO="./virtio-win.iso"

VM_DIR="./vm-data"
OVMF_VARS="$VM_DIR/OVMF_VARS.fd"

TPM_DIR="$VM_DIR/tpm"
TPM_SOCKET="$TPM_DIR/swtpm.sock"

# ---------------- CHECKS ----------------

mkdir -p "$VM_DIR"

if [[ ! -e /dev/kvm ]]; then
    echo "ERROR: /dev/kvm does not exist."
    echo "Enable Intel VT-x / AMD-V in BIOS/UEFI."
    exit 1
fi

if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
    echo "ERROR: You do not have permission to use /dev/kvm."
    echo "Try:"
    echo "  sudo usermod -aG kvm \$USER"
    echo "Then log out and back in."
    exit 1
fi

# ---------------- FIND OVMF ----------------

OVMF_CODE=""

for f in \
    /usr/share/OVMF/OVMF_CODE_4M.fd \
    /usr/share/OVMF/OVMF_CODE.fd
do
    if [[ -f "$f" ]]; then
        OVMF_CODE="$f"
        break
    fi
done

if [[ -z "$OVMF_CODE" ]]; then
    echo "ERROR: OVMF firmware not found."
    echo "Install it with:"
    echo "  sudo apt install ovmf"
    exit 1
fi

# Find matching VARS file

if [[ "$OVMF_CODE" == *"4M"* ]]; then
    OVMF_VARS_TEMPLATE="/usr/share/OVMF/OVMF_VARS_4M.fd"
else
    OVMF_VARS_TEMPLATE="/usr/share/OVMF/OVMF_VARS.fd"
fi

if [[ ! -f "$OVMF_VARS" ]]; then
    cp "$OVMF_VARS_TEMPLATE" "$OVMF_VARS"
fi

# ---------------- CREATE DISK ----------------

if [[ ! -f "$DISK" ]]; then
    echo "Creating $DISK_SIZE virtual disk..."

    qemu-img create \
        -f qcow2 \
        -o preallocation=metadata \
        "$DISK" "$DISK_SIZE"
fi

# ---------------- QEMU OPTIONS ----------------

QEMU_ARGS=(

    -name "$VM_NAME"

    # Hardware acceleration
    -enable-kvm

    # Modern virtual chipset
    -machine q35,accel=kvm

    # Give Windows direct access to host CPU features
    -cpu host

    -smp "$CPUS"
    -m "$RAM"

    # UEFI
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
    -drive "if=pflash,format=raw,file=$OVMF_VARS"

    # Main disk
    #
    # virtio gives substantially better performance than emulated SATA.
    -drive "file=$DISK,if=virtio,format=qcow2,cache=none,aio=native,discard=unmap"

    # Network
    -netdev "user,id=net0"
    -device "virtio-net-pci,netdev=net0"

    # USB 3
    -device qemu-xhci

    # Tablet avoids weird mouse capture/position problems
    -device usb-tablet

    # Audio
    -device ich9-intel-hda
    -device hda-duplex

    # Display
    -device virtio-vga

    # Reasonable memory balloon support
    -device virtio-balloon-pci

    # RTC settings Windows generally expects
    -rtc base=localtime,clock=host

    # Don't reboot immediately if Windows crashes
    -no-reboot
)

# ---------------- INSTALLATION ISOs ----------------

if [[ -f "$WINDOWS_ISO" ]]; then
    QEMU_ARGS+=(
        -drive "file=$WINDOWS_ISO,media=cdrom,readonly=on"
    )
fi

if [[ -f "$VIRTIO_ISO" ]]; then
    QEMU_ARGS+=(
        -drive "file=$VIRTIO_ISO,media=cdrom,readonly=on"
    )
fi

# ---------------- TPM 2.0 ----------------

SWTPM_PID=""

cleanup() {
    if [[ -n "${SWTPM_PID:-}" ]]; then
        kill "$SWTPM_PID" 2>/dev/null || true
    fi
}

trap cleanup EXIT INT TERM

if [[ "$TPM" == "1" ]]; then

    if ! command -v swtpm >/dev/null; then
        echo "ERROR: TPM requested but swtpm isn't installed."
        echo
        echo "Install:"
        echo "  sudo apt install swtpm swtpm-tools"
        exit 1
    fi

    mkdir -p "$TPM_DIR"

    rm -f "$TPM_SOCKET"

    echo "Starting virtual TPM 2.0..."

    swtpm socket \
        --tpm2 \
        --tpmstate "dir=$TPM_DIR" \
        --ctrl "type=unixio,path=$TPM_SOCKET" \
        --flags startup-clear &

    SWTPM_PID=$!

    # Give swtpm a moment to create its socket.
    for _ in {1..50}; do
        [[ -S "$TPM_SOCKET" ]] && break
        sleep 0.05
    done

    if [[ ! -S "$TPM_SOCKET" ]]; then
        echo "ERROR: swtpm failed to create TPM socket."
        exit 1
    fi

    QEMU_ARGS+=(
        -chardev "socket,id=chrtpm,path=$TPM_SOCKET"
        -tpmdev "emulator,id=tpm0,chardev=chrtpm"
        -device "tpm-tis,tpmdev=tpm0"
    )

    echo "TPM 2.0: ENABLED"

else
    echo "TPM: DISABLED"
fi

# ---------------- START ----------------

echo
echo "Starting Windows VM"
echo "RAM:  $RAM"
echo "CPUs: $CPUS"
echo "Disk: $DISK"
echo

exec qemu-system-x86_64 "${QEMU_ARGS[@]}"