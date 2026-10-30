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
The included patch contains the AV1 backport, the IRQF_NO_AUTOEN correction,
and the AV1 decoded-format mask correction used in the successful tests.
The AV1 buffer formulas retain Qualcomm's
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
loads the experimental module. It verifies AV01 appears, selects AV1 on a
temporary device descriptor and checks that linear NV12 is advertised, and
verifies the installed module checksum stays unchanged. The password is
entered through sudo; no password is embedded in the scripts.

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
sample mismatches. These direct tests predate the format-mask correction.
10-bit/HDR and film grain remain untested.
Loading the module checks AV1 and NV12 format exposure; it does not run a decode.

CHROMIUM INTEGRATION CORRECTIONS, OCTOBER 30-31, 2026

The original AV1 PIX_FMTS initializer supplied FMT_NV12C as the format mask
and omitted the default value. After selecting AV1, enumeration therefore
exposed only Qualcomm compressed Q08C. Chromium stalled during output setup.
The corrected mask includes FMT_NV12, FMT_NV12C and FMT_TP10C, with FMT_NV12C
as the default, following the existing driver's capability-table layout.
The previous direct probes explicitly selected NV12 and missed this issue.

Chromium also needs to skip empty CAPTURE buffers returned between AV1
display frames. Presenting those buffers reused old pixels and caused
blinking, with inflated decoded/dropped-frame counters. The browser fix is
patch 0004 in:
  https://github.com/mmis1000/chromium-webxr-steam-frame
The driver format correction and browser empty-buffer correction address
separate parts of playback and should be used together.

On-device Chromium 156.0.8071.0 results with both corrections:
  YouTube 4K60: 60.39 seconds, 8/3625 dropped frames (0.22%), 0.98 CPU cores.
  Synthetic 8K30: 121.04 seconds, 0/3632 dropped frames, 1.23 CPU cores.
  YouTube 8K60: 120.72 seconds elapsed, only 59.54 seconds of video advanced;
    29.61 presented frames/s and repeated waiting events. Below real time.
All used V4L2VideoDecoder with platform decoding enabled and local files.
CPU cores are summed Chromium process CPU time divided by elapsed time.
The 8K60 browser throughput limit remains unresolved. The user confirmed
blinking was gone and stereo and head tracking looked correct. During that
manual VR check, a stable 14.10-second interval ran at 72 Hz with zero extra
drops across 845 video frames. Automated XR attempts timed out or stopped
advancing after one frame; repeated session entry remains unvalidated.
A WebGL texture-import failure cleared after restarting Chromium; its
trigger remains unresolved. Detailed results and the software baseline are
in the browser repository's docs/video-decoding.md.

The corrected module was built from scratch with the package's pinned
source, headers and compiler. Build, ShellCheck, temporary loading and
codec-specific NV12 enumeration checks passed. Tested module SHA-256:
  0edd298e68b9544952d294151b3b639a838dd9d7f5df9f2b1a35de1bded76b8b

Upstream reference: Qualcomm Iris AV1 v9, December 9, 2025, especially
patch 4/5 (capabilities/properties) and patch 5/5 (buffer calculations).
Message IDs:
  20251209-av1d_stateful_v3-v9-4-718e3b3934b1@oss.qualcomm.com
  20251209-av1d_stateful_v3-v9-5-718e3b3934b1@oss.qualcomm.com
