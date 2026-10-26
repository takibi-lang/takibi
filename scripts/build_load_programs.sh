#!/usr/bin/env bash
# Build the stage-1 multicore load programs of GitHub issue #742 --
# stress-ng and hackbench, statically linked against musl for AArch64 --
# and copy them to OUTDIR.
#
# Nothing here is a Takibi program: the load is unmodified upstream source,
# built with a published musl cross toolchain (Bootlin), so the kernel meets
# what a Linux distribution ships. Downloads and builds live outside the
# repository, in TAKIBI_LOAD_CACHE (default
# ~/.takibi-sessions/cache/load-programs); every download is pinned by
# SHA-256. A second run with the cache warm copies the binaries and builds
# nothing.
#
# With --host, the same sources are built for this machine instead (host
# gcc, static PIE against its own C library) and Alpine's x86_64
# busybox-static of the same version as the rootfs's is added: the programs
# of the runner's Linux reference column, the same load run under Linux on
# the same machine (scripts/run_kernel_load.py --reference).
#
# Usage: scripts/build_load_programs.sh [--host] OUTDIR
set -euo pipefail

target=aarch64
if [ "${1:-}" = --host ]; then
    target=host
    shift
fi
if [ "$#" -ne 1 ]; then
    echo "usage: $0 [--host] OUTDIR" >&2
    exit 2
fi
out=$1
cache=${TAKIBI_LOAD_CACHE:-$HOME/.takibi-sessions/cache/load-programs}

toolchain=aarch64--musl--stable-2025.08-1
toolchain_url=https://toolchains.bootlin.com/downloads/releases/toolchains/aarch64/tarballs/$toolchain.tar.xz
toolchain_sha=defba831ffa1175236f137069333e21ed46d4d19feb5080a90cf248b6fc2cb08
stress_ng=stress-ng-0.20.01
stress_ng_url=https://codeload.github.com/ColinIanKing/stress-ng/tar.gz/refs/tags/V0.20.01
stress_ng_sha=f974863d1861e7e7b5d19e381a17f22d653dcafa12096ac96d11b2e62a22ea77
rt_tests=rt-tests-2.9
rt_tests_url=https://www.kernel.org/pub/linux/utils/rt-tests/$rt_tests.tar.xz
rt_tests_sha=fbe9fcf7bac930e2b789afd24f8a2206ac42a4acd5017d72b106cfbccdb43a00
host_busybox=busybox-static-x86_64-1.37.0-r31
host_busybox_url=https://dl-cdn.alpinelinux.org/alpine/v3.24/main/x86_64/busybox-static-1.37.0-r31.apk
host_busybox_sha=b0d6cfc585d7fdd12df359cc5d38d5e45894e9e9e78c4059eb41577d022ec734

src=$cache/src
[ "$target" = aarch64 ] || src=$cache/src-$target
mkdir -p "$cache/dl" "$src" "$out"

fetch() {
    local url=$1 file=$2 sha=$3
    if [ ! -f "$cache/dl/$file" ]; then
        echo "[load-programs] fetching $url" >&2
        curl -sSfL -o "$cache/dl/$file.tmp" "$url"
        mv "$cache/dl/$file.tmp" "$cache/dl/$file"
    fi
    if ! echo "$sha  $cache/dl/$file" | sha256sum -c --quiet -; then
        echo "[load-programs] $file does not match its pinned SHA-256" >&2
        exit 1
    fi
}

fetch "$stress_ng_url" "$stress_ng.tar.gz" "$stress_ng_sha"
fetch "$rt_tests_url" "$rt_tests.tar.xz" "$rt_tests_sha"

if [ "$target" = aarch64 ]; then
    fetch "$toolchain_url" "$toolchain.tar.xz" "$toolchain_sha"
    if [ ! -x "$cache/$toolchain/bin/aarch64-linux-gcc" ]; then
        tar -C "$cache" -xJf "$cache/dl/$toolchain.tar.xz"
    fi
    cc=$cache/$toolchain/bin/aarch64-linux-gcc
    strip=$cache/$toolchain/bin/aarch64-linux-strip
    # stress-ng probes optional C++ features (Eigen) with $(CXX) and, once
    # one C++ object exists, links with $(CXX). Left unset, CXX is the
    # host's g++: on a host with Eigen headers (libeigen3-dev) it compiles
    # stress-eigen-ops.cpp for the host and then links the AArch64 objects
    # with the host linker ("Relocations in generic ELF (EM: 183)"). The
    # cross g++ keeps every probe on the target's sysroot; without one,
    # `false` makes the C++ probes fail and the link stay with $(CC).
    cxx=$cache/$toolchain/bin/aarch64-linux-g++
    [ -x "$cxx" ] || cxx=false
else
    fetch "$host_busybox_url" "$host_busybox.apk" "$host_busybox_sha"
    # Alpine packages carry APK-TOOLS pax headers GNU tar names and skips.
    tar -xOzf "$cache/dl/$host_busybox.apk" bin/busybox.static \
        >"$out/busybox" 2>/dev/null
    chmod +x "$out/busybox"
    cc=gcc
    cxx=g++
    strip=strip
fi

# A build is reused only while the recipe that made it is unchanged: each
# records its flags in a stamp, and a different stamp rebuilds from a clean
# extraction.
stress_flags="CXX=${cxx##*/} CFLAGS=-fPIE -DBUILD_STATIC LDFLAGS=-static-pie -Wl,--gc-sections"
hackbench_flags='-static-pie -fPIE -O2 -Wno-incompatible-pointer-types -D_GNU_SOURCE -DVERSION=2.9'
stress_bin=$src/$stress_ng/stress-ng
if [ ! -x "$stress_bin" ] ||
   [ "$(cat "$src/$stress_ng.stamp" 2>/dev/null)" != "$stress_flags" ]; then
    rm -rf "$src/$stress_ng"
    tar -C "$src" -xzf "$cache/dl/$stress_ng.tar.gz"
    # A static PIE, as Alpine builds its static packages (busybox-static
    # too): the kernel maps ET_DYN images only. stress-ng's own STATIC=1
    # adds a plain -static, which would win over -static-pie, so its other
    # half (-DBUILD_STATIC) is passed by hand. Its configure step probes the
    # toolchain, so optional libraries the cross sysroot lacks (libbsd,
    # libjpeg, ...) are simply left out.
    make -C "$src/$stress_ng" CC="$cc" CXX="$cxx" \
        CFLAGS="-fPIE -DBUILD_STATIC" LDFLAGS="-static-pie -Wl,--gc-sections" \
        -j"$(nproc)" >"$src/$stress_ng.build.log" 2>&1 || {
        echo "[load-programs] stress-ng build failed; see $src/$stress_ng.build.log" >&2
        exit 1
    }
    printf '%s\n' "$stress_flags" >"$src/$stress_ng.stamp"
fi

hackbench_bin=$src/$rt_tests/hackbench
if [ ! -x "$hackbench_bin" ] ||
   [ "$(cat "$src/$rt_tests.stamp" 2>/dev/null)" != "$hackbench_flags" ]; then
    rm -rf "$src/$rt_tests"
    tar -C "$src" -xJf "$cache/dl/$rt_tests.tar.xz"
    # hackbench is one file; rt-tests' Makefile would build every tool and
    # needs libnuma for some of them. GCC 14 makes its sockaddr_in casts
    # errors, and they are upstream's.
    # $hackbench_flags is split into words on purpose.
    # shellcheck disable=SC2086
    "$cc" $hackbench_flags -I"$src/$rt_tests/src/include" \
        -o "$hackbench_bin" "$src/$rt_tests/src/hackbench/hackbench.c" -lpthread
    printf '%s\n' "$hackbench_flags" >"$src/$rt_tests.stamp"
fi

"$strip" -o "$out/stress-ng" "$stress_bin"
"$strip" -o "$out/hackbench" "$hackbench_bin"
for program in stress-ng hackbench; do
    # `file` calls a static PIE "static-pie linked"; anything else is
    # either dynamic or an ET_EXEC the kernel would not map.
    if ! file "$out/$program" | grep -q 'static-pie linked'; then
        echo "[load-programs] $program is not a static PIE" >&2
        exit 1
    fi
done
