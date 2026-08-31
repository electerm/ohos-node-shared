#!/bin/bash
# build-node-ohos.sh — Build a REAL shared libnode.so for OpenHarmony (x86_64
# emulator or arm64 device) in Docker, exactly like the scripts under temp/bak
# but committed so CI and other machines can reproduce the build.
#
# Why a real shared library? dlopen()ing a PIE executable (what hqzing/ohos-node
# ships as "libnode.so") breaks thread_local storage inside the HarmonyOS app
# and V8 dies on the very first heap allocation with the release CHECK
# `AllowHeapAllocationInRelease::IsAllowed()`. A --shared build produces a true
# ET_DYN shared library (PIC + dynamic TLS) that dlopen()s cleanly.
#
# The container downloads the OHOS SDK + LLVM-19 (~3 GB, cached in the mounted
# workspace dir after the first run) and cross-compiles Node.js.
#
# Usage:
#   ./scripts/build-node-ohos.sh [version] [jobs] [arch]
#     version  Node.js version, default v24.2.0
#     jobs     make -j, default 2 (keep low; OOM in Docker otherwise)
#     arch     x64 (default) | arm64
#
# Output: scripts/workspace/... node-<ver>-openharmony-<arch>/ (install tree)
#         scripts/output/libnode.so  (stripped, self-signed real shared lib)
#
# To install into the project:
#   cp scripts/output/libnode.so entry/libs/arm64-v8a/libnode.so   # arch=arm64
#   cp scripts/output/libnode.so entry/libs/x86_64/libnode.so      # arch=x64
set -e

VERSION="${1:-v24.2.0}"
MAKE_JOBS="${2:-2}"
ARCH="${3:-${ARCH:-x64}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${ARCH}" in
  x64)      LIBS_DIR="x86_64" ;;
  arm64)    LIBS_DIR="arm64-v8a" ;;
  *) echo "    ✗ Unsupported arch: ${ARCH} (use x64 or arm64)"; exit 1 ;;
esac

echo "==> Checking prerequisites ..."

if ! command -v docker >/dev/null 2>&1; then
    echo "    ✗ Docker not found. Install Docker Desktop or colima."
    exit 1
fi
echo "    ✓ docker: $(docker --version)"

# Git Bash (MSYS) mangles unix-style docker args like `-w /build` into
# Windows paths for native docker.exe. Convert the host mount side here and
# disable per-arg conversion. On Linux this is a harmless no-op.
HOST_MOUNT="$(cygpath -m "${SCRIPT_DIR}" 2>/dev/null || echo "${SCRIPT_DIR}")"

echo "==> Building Node.js ${VERSION} for OpenHarmony ${ARCH} in Docker ..."
echo "    Container will download the OHOS SDK + LLVM-19 on first run, then build."
echo "    This will take 15-30 minutes ..."

MSYS_NO_PATHCONV=1 docker run --rm \
    --memory=12g --memory-swap=16g \
    -v "${HOST_MOUNT}:/build:rw" \
    -e "NODE_VERSION=${VERSION}" \
    -e "MAKE_JOBS=${MAKE_JOBS}" \
    -e "ARCH=${ARCH}" \
    -w /build \
    ubuntu:24.04 \
    bash /build/build-node-ohos-inner.sh

# --- Check output ------------------------------------------------------------

OUT_DIR="${SCRIPT_DIR}/output"
if [ -f "${OUT_DIR}/libnode.so" ]; then
    echo ""
    echo "==> Build complete!"
    echo "    Output: ${OUT_DIR}/libnode.so"
    echo "    $(du -h "${OUT_DIR}/libnode.so" | cut -f1)  $(file "${OUT_DIR}/libnode.so" | cut -d: -f2)"
    echo ""
    echo "To install into the project:"
    echo "  cp ${OUT_DIR}/libnode.so entry/libs/${LIBS_DIR}/libnode.so"
else
    echo ""
    echo "==> ✗ Build FAILED — no libnode.so produced"
    exit 1
fi
