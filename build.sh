#!/usr/bin/env bash
# Build the experimental module in a new directory on an x86-64 Linux host.
set -euo pipefail

RELEASE=6.18.0-g83913f38113c
COMMIT=83913f38113c4d55ccf4036c9c1d61d05443828e
SOURCE_URL=${SOURCE_URL:-https://github.com/evlaV/deckard-linux-no-oopsies.git}
HEADERS_URL=https://steamdeck-packages.steamos.cloud/archlinux-deckard-hotfixes/release/0.5.x/linux-618-deckard-headers-6.18.0%2Bg83913f38113c-3-aarch64.pkg.tar.zst
GCC_URL=https://mirrors.edge.kernel.org/pub/tools/crosstool/files/bin/x86_64/15.1.0/x86_64-gcc-15.1.0-nolibc-aarch64-linux.tar.xz
HEADERS_SHA=6e0a89ca9a9963c437a18a7a88799e8bc95ac5310e416dcb8ef7ab814e30ea5c
GCC_SHA=b36edb14d5fe6942dadeee2146ab278eab76924c0a7746b1e20b3b0afcc9be73
PATCH_SHA=bb955c8f2ca4bbe54615c7a6c3b3697c85141cd0c5b9b44e40ffd33e75d08e21
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

if [[ $# != 1 || $1 == --help ]]; then
    echo 'Usage: bash build.sh NEW_WORK_DIRECTORY'
    echo 'Requires x86-64 Linux, git, curl, GCC, make, binutils, kmod, tar, zstd and xz.'
    echo 'Optional offline inputs: SOURCE_URL, HEADERS_ARCHIVE, GCC_ARCHIVE; JOBS defaults to 12.'
    exit 0
fi
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || die 'Use an x86-64 Linux build host.'
for tool in git curl gcc make ld modinfo tar zstd xz sha256sum realpath; do
    command -v "$tool" >/dev/null || die "Missing command: $tool"
done
[[ ! -e $1 ]] || die 'Choose a new work directory; existing directories are preserved.'
[[ $1 != *[[:space:]]* ]] || die 'The kernel build directory must not contain whitespace.'
printf '%s  %s\n' "$PATCH_SHA" "$HERE/iris-av1.patch" | sha256sum -c -
mkdir -p -- "$1"
WORK=$(realpath -- "$1")
[[ $WORK != *[[:space:]]* ]] || die 'The resolved build directory must not contain whitespace.'
exec > >(tee "$WORK/build.log") 2>&1

fetch_archive() {
    local url=$1 cached=$2 destination=$3 expected=$4
    if [[ -n $cached ]]; then
        cp -- "$cached" "$destination"
    else
        curl --fail --location --connect-timeout 20 --retry 3 --output "$destination" "$url"
    fi
    printf '%s  %s\n' "$expected" "$destination" | sha256sum -c -
}
fetch_archive "$HEADERS_URL" "${HEADERS_ARCHIVE:-}" "$WORK/headers.pkg.tar.zst" "$HEADERS_SHA"
fetch_archive "$GCC_URL" "${GCC_ARCHIVE:-}" "$WORK/gcc.tar.xz" "$GCC_SHA"
mkdir "$WORK/headers" "$WORK/toolchain" "$WORK/artifacts"
tar --zstd -xf "$WORK/headers.pkg.tar.zst" -C "$WORK/headers"
tar -xJf "$WORK/gcc.tar.xz" -C "$WORK/toolchain"
export PATH="$WORK/toolchain/gcc-15.1.0-nolibc/aarch64-linux/bin:$PATH"
command -v aarch64-linux-gcc >/dev/null || die 'Cross compiler was not extracted at the expected path.'

git init -q "$WORK/source"
git -C "$WORK/source" fetch --depth=1 "$SOURCE_URL" "$COMMIT"
git -C "$WORK/source" checkout -q --detach FETCH_HEAD
[[ $(git -C "$WORK/source" rev-parse HEAD) == "$COMMIT" ]] || die 'Unexpected source revision.'
git -C "$WORK/source" apply --check "$HERE/iris-av1.patch"
git -C "$WORK/source" apply "$HERE/iris-av1.patch"

HEADERS="$WORK/headers/usr/lib/modules/$RELEASE/build"
DRIVER="$WORK/source/drivers/media/platform/qcom/vcodec/iris"
[[ $(cat "$HEADERS/include/config/kernel.release") == "$RELEASE" ]] || die 'Header release mismatch.'
sha256sum "$HEADERS/.config" "$HEADERS/Module.symvers" > "$WORK/header-inputs.sha256"

# Rebuild only the host executables, using the package's target-generated files.
# Do not run olddefconfig/modules_prepare against the matching header tree.
gcc -O2 -I "$HEADERS/scripts/include" \
    "$HEADERS/scripts/basic/fixdep.c" -o "$HEADERS/scripts/basic/fixdep"
gcc -O2 -I "$HEADERS/scripts/include" -I "$HEADERS/scripts/mod" \
    "$HEADERS/scripts/mod/modpost.c" "$HEADERS/scripts/mod/file2alias.c" \
    "$HEADERS/scripts/mod/sumversion.c" "$HEADERS/scripts/mod/symsearch.c" \
    -o "$HEADERS/scripts/mod/modpost"
mkdir -p "$HEADERS/drivers/media/platform/qcom/vcodec/iris"
cp "$DRIVER/trace.h" "$HEADERS/drivers/media/platform/qcom/vcodec/iris/trace.h"
# Keep the reference image, but skip optional external-module BTF generation.
if [[ -f $HEADERS/vmlinux ]]; then
    mv "$HEADERS/vmlinux" "$HEADERS/vmlinux.reference"
fi
make -j"${JOBS:-12}" -C "$HEADERS" ARCH=arm64 CROSS_COMPILE=aarch64-linux- \
    M="$DRIVER" modules
sha256sum -c "$WORK/header-inputs.sha256"
[[ $(modinfo -F name "$DRIVER/iris.ko") == iris ]] || die 'Unexpected module name.'
vermagic=$(modinfo -F vermagic "$DRIVER/iris.ko")
[[ ${vermagic%% *} == "$RELEASE" ]] || die 'Built module has the wrong release.'

cp "$DRIVER/iris.ko" "$WORK/artifacts/iris-av1-poc.ko"
cp "$HERE/load-temporary.sh" "$WORK/artifacts/"
cp "$HERE/iris-av1.patch" "$WORK/artifacts/"
sha256sum "$HEADERS/.config" | cut -d' ' -f1 > "$WORK/artifacts/kernel-config.sha256"
printf 'release=%s\nsource=%s\ncommit=%s\ncompiler=%s\nvermagic=%s\n' \
    "$RELEASE" "$SOURCE_URL" "$COMMIT" "$(aarch64-linux-gcc -dumpfullversion)" \
    "$vermagic" > "$WORK/artifacts/build-info.txt"
(
    cd "$WORK/artifacts"
    sha256sum iris-av1-poc.ko kernel-config.sha256 iris-av1.patch > SHA256SUMS
)
printf '\nBuild complete: %s/artifacts\nCopy that directory to the headset. Nothing was installed or loaded.\n' "$WORK"
