Steam Frame Iris AV1 proof of concept

This package builds and temporarily loads an experimental Iris module for
SteamOS kernel 6.18.0-g83913f38113c on aarch64. It performs no persistent module
installation, firmware replacement, service enable/disable, initramfs update,
or reboot. A different kernel needs a matching source/header port.

BUILD ON AN X86-64 LINUX HOST

Dependencies (Debian/Ubuntu package names):
  build-essential git curl kmod zstd xz-utils

Keep build.sh, load-temporary.sh and iris-av1.patch together. Run:
  bash build.sh "$HOME/iris-av1-poc-build"

Choose a directory that does not exist. The build downloads source, Valve's
matching headers and GCC 15.1.0. It verifies both archive checksums, fetches
the exact source commit, and applies the included patch. Allow several GB
for the source checkout and build files. No root access is needed to build.

Source repository:
  https://github.com/evlaV/deckard-linux-no-oopsies.git
Source revision:
  83913f38113c4d55ccf4036c9c1d61d05443828e
Driver directory:
  drivers/media/platform/qcom/vcodec/iris
Headers:
  linux-618-deckard-headers-6.18.0+g83913f38113c-3-aarch64.pkg.tar.zst

The build preserves the package's generated configuration and Module.symvers.
It recompiles the two required host tools for x86-64 and skips optional BTF.
GCC 15.1.0 produces a compiler-version warning because Valve used GCC 15.1.1.
The included patch contains the AV1 backport and the IRQF_NO_AUTOEN correction
used in the successful tests. The AV1 buffer formulas retain Qualcomm's
attribution and GPL-2.0-only identifier.

Optional offline/cache inputs, with the same archive checksum verification:
  HEADERS_ARCHIVE=/path/to/headers.pkg.tar.zst
  GCC_ARCHIVE=/path/to/gcc-aarch64.tar.xz
  SOURCE_URL=/path/to/local/kernel/git/repository
Set these environment variables when invoking build.sh. JOBS defaults to 12.

COPY AND CHECK ON THE HEADSET

Copy the entire generated artifacts directory to the headset. For example,
from the Linux build host (replace HEADSET with its SSH hostname/address):
  scp -r "$HOME/iris-av1-poc-build/artifacts" steamos@HEADSET:~/iris-av1-poc

Then, in an SSH session on the headset:
  cd ~/iris-av1-poc
  bash load-temporary.sh --check ./iris-av1-poc.ko

The read-only check verifies the archive manifest, module name, full vermagic,
running kernel configuration, original decoder formats, and idle module state.
The manifest detects accidental file changes; it is not a publisher signature.

TEMPORARY LOAD

Close video playback first, then run on the headset:
  sudo bash load-temporary.sh --load ./iris-av1-poc.ko

The loader repeats its checks, saves diagnostics under /run, stops the rebind
service for this session if active, unloads idle Iris without force flags, and
loads the experimental module. It verifies AV01 appears and the installed
module checksum stays unchanged. The password is entered through sudo; no
password is embedded in the scripts.

On an ordinary load error, the script attempts to reload the installed module
if no Iris module remains loaded, and restore the service's active state.
If the experimental module loaded but a later check failed, it leaves that
module and diagnostics in place for inspection. It never forces an unload.

The successful path leaves the experimental module active and the rebind
service stopped until the user ends the session. Reboot the headset yourself
when finished to restore the installed driver. The scripts do not reboot.

Experimental kernel code can fault or hang. Our initial build hit an IRQ
initialization race and required a physical power cycle; this package includes
the correction used in later successful loads. Shell error recovery cannot
recover a hung kernel.

WHAT WAS TESTED WITH THE PATCH

Existing vpu33_4v.mbn firmware, unchanged:
  320x240 AV1: four frames, full-frame MD5 matching libdav1d.
  3840x2160 at 60 fps: 120 seconds, 7200/7200 frames.
  7680x4320 at 30 fps: 120 seconds, 3600/3600 frames.
  7680x4320 at 60 fps: no source-change event; startup failure unresolved.
The sustained runs used looped 2-second, 8-bit synthetic interframe clips and
768 sampled Y/U/V bytes per frame. Zero missing frames, buffer errors or
sample mismatches. Chromium integration, 10-bit/HDR and film grain untested.
Loading the module only checks AV1 format exposure; it does not run a decode.

Upstream reference: Qualcomm Iris AV1 v9, December 9, 2025, especially
patch 4/5 (capabilities/properties) and patch 5/5 (buffer calculations).
Message IDs:
  20251209-av1d_stateful_v3-v9-4-718e3b3934b1@oss.qualcomm.com
  20251209-av1d_stateful_v3-v9-5-718e3b3934b1@oss.qualcomm.com
