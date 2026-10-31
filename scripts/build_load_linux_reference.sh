#!/usr/bin/env bash
# The Linux side of #1158's QEMU column: a mainline arm64 kernel and an
# initramfs holding the very rootfs the Takibi side boots, so the same
# program, the same build and the same arguments run under Linux on the same
# QEMU virt machine.
#
# The kernel is Ubuntu's build of the unpatched mainline tag
# (kernel.ubuntu.com/mainline), pinned by SHA-256: this tree builds no Linux,
# and only the kernel image is needed, since the initramfs loads no module.
# The download lives outside the repository, in TAKIBI_LOAD_LINUX_CACHE
# (default ~/.takibi-sessions/cache/load-linux).
#
# Usage: scripts/build_load_linux_reference.sh EXT2_IMAGE OUTDIR
# Writes OUTDIR/Image, OUTDIR/initramfs.cpio and OUTDIR/kernel-version.
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: $0 EXT2_IMAGE OUTDIR" >&2
    exit 2
fi
image=$1
out=$2
cache=${TAKIBI_LOAD_LINUX_CACHE:-$HOME/.takibi-sessions/cache/load-linux}

version=6.12.0-061200-generic
deb=linux-image-unsigned-${version}_6.12.0-061200.202411220723_arm64.deb
url=https://kernel.ubuntu.com/mainline/v6.12/arm64/$deb
sha=a57ec147f75009d75c121edcb54e02b4ce897380f1afd36ef55ba8bceb88dada

mkdir -p "$cache" "$out"
if [ ! -f "$cache/$deb" ]; then
    echo "[load-linux] fetching $url" >&2
    curl -sSfL -o "$cache/$deb.tmp" "$url"
    mv "$cache/$deb.tmp" "$cache/$deb"
fi
if ! echo "$sha  $cache/$deb" | sha256sum -c --quiet -; then
    echo "[load-linux] $deb does not match its pinned SHA-256" >&2
    exit 1
fi

work=$(mktemp -d "$out/work.XXXXXX")
trap 'chmod -R u+rwx "$work"; rm -rf "$work"' EXIT
dpkg-deb --fsys-tarfile "$cache/$deb" |
    tar -x -C "$work" "./boot/vmlinuz-$version"
cp "$work/boot/vmlinuz-$version" "$out/Image"
echo "Linux $version (mainline v6.12, Ubuntu mainline build)" >"$out/kernel-version"

root=$work/root
mkdir -p "$root"
debugfs -R "rdump / $root" "$image" >/dev/null 2>&1
# The fixture holds deliberately unreadable files; the copy must still pack.
chmod -R u+rwX "$root"
[ -x "$root/bin/load.sh" ] || {
    echo "[load-linux] $image holds no /bin/load.sh" >&2
    exit 1
}
# /init runs what the kernel command line passes after `--`, and then powers
# the guest off. The directory load.sh makes is opened to the `load` user
# here: Linux enforces the modes Takibi does not model yet.
cat >"$root/init" <<'EOF'
#!/bin/sh
busybox mkdir -p /proc /sys /dev /tmp /load
busybox mount -t proc proc /proc
busybox mount -t sysfs sys /sys
busybox mount -t devtmpfs dev /dev
busybox chmod 1777 /load /tmp
echo "load: linux-kernel $(busybox uname -r)"
/bin/load.sh "$@" </dev/null
busybox poweroff -f
EOF
chmod 755 "$root/init"
(cd "$root" && find . -print0 | cpio --null -o -H newc -R 0:0 --quiet) \
    >"$out/initramfs.cpio.tmp"
mv "$out/initramfs.cpio.tmp" "$out/initramfs.cpio"
