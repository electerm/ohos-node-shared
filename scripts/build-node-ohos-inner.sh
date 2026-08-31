#!/bin/bash
# build-inner.sh — Runs INSIDE the Docker container.
#
# Downloads the OpenHarmony SDK and LLVM-19 (same as hqzing/ohos-node's
# build.sh), then cross-compiles Node.js for x86_64.
#
# No external mounts required — everything runs self-contained in the
# container.  The only mount is the script dir itself (for output).
set -e

# Whenever build.sh captures us to a log file, stdio block-buffering would hide
# progress until a buffer fills (or we exit). Re-pipe stdout through a
# line-buffered cat so the log updates live.
exec > >(stdbuf -oL cat)
exec 2>&1

# --- Config -----------------------------------------------------------------

VERSION="${NODE_VERSION:-v24.2.0}"
ARCH="${ARCH:-x64}"
WORKDIR="/build/workspace"
OUT_DIR="/build/output"
SCRIPT_DIR="/build"

# Map ARCH -> node's dest-cpu, OHOS clang triple, and naming suffixes.
# The OHOS LLVM toolchain ships both x86_64- and aarch64-unknown-linux-ohos
# wrappers, so building the other arch is purely a parameter change.
case "${ARCH}" in
  x64|x86_64|amd64)    ARCH="x64";    CLANG_TRIPLE="x86_64-unknown-linux-ohos";  PREFIX_SUFFIX="x64" ;;
  arm64|aarch64)       ARCH="arm64";  CLANG_TRIPLE="aarch64-unknown-linux-ohos"; PREFIX_SUFFIX="arm64" ;;
  *) echo "    ✗ Unsupported ARCH: ${ARCH} (use x64 or arm64)"; exit 1 ;;
esac

# x64 keeps the historical node-<ver> dir (no suffix) so existing checkouts
# are reused untouched; any other arch gets its own source dir so the x64
# build's out/ is never clobbered.
NODE_SUFFIX=""
[ "${ARCH}" != "x64" ] && NODE_SUFFIX="-${ARCH}"

mkdir -p "${WORKDIR}" "${OUT_DIR}"
cd "${WORKDIR}"

# --- Install build deps -----------------------------------------------------

echo "==> Installing build dependencies ..."
saved_ok=0
for i in 1 2 3; do
    echo "    apt-get update (attempt ${i}/3, timeout 300s) ..."
    if timeout 300 apt-get update; then
        saved_ok=1
        break
    fi
    echo "    apt-get update attempt ${i} failed or timed out, retrying in 5s ..."
    sleep 5
done
if [ "${saved_ok}" != "1" ]; then
    echo "    ✗ apt-get update failed after 3 attempts"
    exit 1
fi
if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        -o Acquire::Retries=5 \
        -o Acquire::http::Timeout=120 \
        -o Acquire::https::Timeout=120 \
        build-essential \
        ca-certificates \
        curl \
        git \
        jq \
        unzip \
        xz-utils \
        python3 \
        libxml2 \
        > /tmp/apt-install.log 2>&1; then
    echo "    ✗ apt-get install failed; last output:"
    tail -30 /tmp/apt-install.log
    exit 1
fi
echo "    ✓ build deps installed"

# --- Download OHOS SDK ------------------------------------------------------

echo "==> Downloading OpenHarmony SDK ..."

query_component() {
  component=$1
  local url=""
  local max_retries=5
  local retry=0
  while [ $retry -lt $max_retries ]; do
    retry=$((retry + 1))
    echo "    Querying ${component} (attempt ${retry}/${max_retries}) ..." >&2
    url=$(curl -fsSL --connect-timeout 30 --max-time 120 \
      'https://dcp.openharmony.cn/api/daily_build/build/list/component' \
      -H 'Accept: application/json, text/plain, */*' \
      -H 'Content-Type: application/json' \
      --data-raw '{"projectName":"openharmony","branch":"master","pageNum":1,"pageSize":10,"deviceLevel":"","component":"'${component}'","type":1,"startTime":"2025080100000000","endTime":"20990101235959","sortType":"","sortField":"","hardwareBoard":"","buildStatus":"success","buildFailReason":"","withDomain":1}' \
      2>/dev/null | jq -r ".data.list.dataList[0].obsPath" 2>/dev/null)
    if [ -n "$url" ] && [ "$url" != "null" ]; then
      echo "$url"
      return 0
    fi
    echo "    Attempt ${retry} failed, retrying in 15s ..." >&2
    sleep 15
  done
  echo "    ERROR: Failed to query ${component} after ${max_retries} attempts" >&2
  return 1
}

# --- Download OHOS SDK (skip if already extracted) -------------------------

if [ ! -d "${WORKDIR}/ohos-sdk/linux/toolchains" ]; then
    echo "==> Downloading OpenHarmony SDK ..."
    sdk_download_url=$(query_component "ohos-sdk-public")
    if [ -z "$sdk_download_url" ]; then
        echo "    ✗ Failed to get SDK URL"
        exit 1
    fi
    echo "    SDK URL: ${sdk_download_url}"
    curl -fL --retry 10 --retry-delay 10 --connect-timeout 30 --max-time 600 -o ohos-sdk-public.tar.gz "$sdk_download_url"
    tar -zxf ohos-sdk-public.tar.gz
    rm -rf daily_build.log manifest_tag.xml ohos-sdk/windows ohos-sdk/ohos
    cd ohos-sdk/linux
    unzip -q toolchains-*.zip
    rm -rf *.zip
    cd ../..
    rm -f ohos-sdk-public.tar.gz
else
    echo "    ✓ OHOS SDK already extracted, skipping download"
fi

# --- Download LLVM-19 (skip if already extracted) ---------------------------

if [ ! -d "${WORKDIR}/llvm-19/llvm/bin" ]; then
    echo "==> Downloading LLVM-19 ..."
    llvm19_download_url=$(query_component "LLVM-19")
    if [ -z "$llvm19_download_url" ]; then
        echo "    ✗ Failed to get LLVM-19 URL"
        exit 1
    fi
    echo "    LLVM-19 URL: ${llvm19_download_url}"
    curl -fL --retry 10 --retry-delay 10 --connect-timeout 30 --max-time 600 -o LLVM-19.tar.gz "$llvm19_download_url"
    mkdir -p llvm-19
    tar -zxf LLVM-19.tar.gz -C llvm-19
    cd llvm-19
    tar -zxf llvm-linux-x86_64.tar.gz
    tar -zxf ohos-sysroot.tar.gz
    cd ..
    rm -f LLVM-19.tar.gz
else
    echo "    ✓ LLVM-19 already extracted, skipping download"
fi

# --- Set up environment -----------------------------------------------------

export CC="${WORKDIR}/llvm-19/llvm/bin/${CLANG_TRIPLE}-clang -fno-emulated-tls"
export CXX="${WORKDIR}/llvm-19/llvm/bin/${CLANG_TRIPLE}-clang++ -fno-emulated-tls"
export CC_host="gcc"
export CXX_host="g++"

echo "    CC=${CC}"

# --- Download Node.js source (tarball is more reliable than git clone) ------

# Version-specific source dir. The /build/workspace persists across container
# runs (it's the mounted script dir), so a previous run may have left a
# DIFFERENT node version (e.g. v24.19.0) checked out. Keying the dir on the
# version means we never have to DELETE an old checkout — through the Docker
# Desktop mount, directories can carry Windows read-only attributes and
# `rm -rf` fails with Permission denied. A mismatched old checkout is simply
# left in place; only a "rename" is ever needed.
NODE_DIR="${WORKDIR}/node-${VERSION#v}${NODE_SUFFIX}"

NODE_HAVE=""
if [ -f "${NODE_DIR}/configure" ] && [ -f "${NODE_DIR}/src/node_version.h" ]; then
    NODE_HAVE="$(grep -E '^#define NODE_(MAJOR|MINOR|PATCH)_VERSION' \
        "${NODE_DIR}/src/node_version.h" | awk '{print $3}' | paste -sd. )"
fi
if [ "${NODE_HAVE}" != "${VERSION#v}" ]; then
    echo "==> Downloading Node.js ${VERSION} source tarball (have: ${NODE_HAVE:-none}) ..."
    rm -f node-src.tar.gz
    # Try nodejs.org first (faster, more reliable), fallback to GitHub
    if ! curl -fL --retry 10 --retry-delay 10 \
        -o node-src.tar.gz \
        "https://nodejs.org/dist/${VERSION}/node-${VERSION}.tar.gz"; then
        echo "    nodejs.org failed, trying GitHub ..."
        curl -fL --retry 10 --retry-delay 10 \
            -o node-src.tar.gz \
            "https://github.com/nodejs/node/archive/refs/tags/${VERSION}.tar.gz"
    fi
    tar -zxf node-src.tar.gz -C "${WORKDIR}"
    rm -f node-src.tar.gz
    # Both tarballs extract to node-${VERSION}/ (release and GitHub archives
    # use the same top-level name). Rename into the versioned dir; if a stale
    # one exists, shift it aside rather than deleting (read-only attr issue).
    if [ -e "${NODE_DIR}" ]; then
        mv "${NODE_DIR}" "${NODE_DIR}.stale.$$"
    fi
    mv "${WORKDIR}/node-${VERSION}" "${NODE_DIR}"
else
    echo "    ✓ Node.js source v${NODE_HAVE} matches ${VERSION}, reusing"
fi
cd "${NODE_DIR}"

# --- Apply patches ----------------------------------------------------------

need_patch_0001_versions="v24.2.0 v24.3.0 v24.4.0 v24.4.1 v24.5.0 v24.6.0"
if echo " $need_patch_0001_versions " | grep -q " $VERSION "; then
    echo "    Applying 0001 patch ..."
    patch -p1 < "${SCRIPT_DIR}/0001-fix-argument-list-too-long.patch" || true
fi

need_patch_0002_versions="^v22\."
if echo "$VERSION" | grep -q "$need_patch_0002_versions"; then
    echo "    Applying 0002 patch ..."
    patch -p1 < "${SCRIPT_DIR}/0002-use-C++20-for-Node.js-core.patch" || true
fi

need_no_error_versions="v24.2.0 v24.3.0 v24.4.0 v24.4.1 v24.5.0 \
                        v24.6.0 v24.7.0 v24.8.0 v22.17.0 v22.17.1 \
                        v22.18.0 v22.19.0"
if echo " $need_no_error_versions " | grep -q " $VERSION "; then
    export CC="$CC -Wno-error=implicit-function-declaration"
    export CXX="$CXX -Wno-error=implicit-function-declaration"
fi

# --- Configure --------------------------------------------------------------

echo "==> Configuring Node.js for OpenHarmony ${ARCH} ..."

INSTALL_PREFIX="${WORKDIR}/node-${VERSION}-openharmony-${PREFIX_SUFFIX}"

CONFIGURE_ARGS="--dest-cpu=${ARCH} \
  --dest-os=openharmony \
  --cross-compiling \
  --openssl-no-asm \
  --shared \
  --prefix=${INSTALL_PREFIX}"
# --shared makes gyp build node's libnode target as a REAL shared library
# (libnode.so, PIC + dynamic TLS) rather than a PIE executable. dlopen()ing a
# PIE executable into the HarmonyOS app breaks its thread_local storage (the
# linker wrote local-exec %fs offsets that alias the host app's TLS block), so
# V8's `thread_local current_per_thread_assert_data` reads garbage and the
# release CHECK `AllowHeapAllocationInRelease::IsAllowed()` fires on the very
# first heap allocation at Isolate::Initialize.

if ./configure --help 2>&1 | grep -q -- "--v8-disable-temporal-support"; then
    CONFIGURE_ARGS="$CONFIGURE_ARGS --v8-disable-temporal-support"
fi

echo "    Configure args: ${CONFIGURE_ARGS}"

# --- Patch V8 source to fix set_allow_call compile error ------------------
# In maglev-assembler.h, set_allow_call(), set_allow_deferred_call(), and
# set_allow_allocate() are guarded by #ifdef DEBUG. But in maglev-assembler-inl.h,
# the calls to these methods are NOT guarded. In release builds (no DEBUG defined),
# this causes a compile error: "no member named 'set_allow_call'".
# Fix: move the method declarations and member fields OUT of the #ifdef DEBUG
# block in maglev-assembler.h, so they are always available.
# This way, the calls in maglev-assembler-inl.h (which ARE inside #ifdef DEBUG
# blocks) will compile successfully in both debug and release modes.
MAGLEV_H="${NODE_DIR}/deps/v8/src/maglev/maglev-assembler.h"
if [ -f "${MAGLEV_H}" ]; then
    echo "==> Patching maglev-assembler.h: move set_allow_* out of #ifdef DEBUG"
    # Check if already patched (methods exist outside #ifdef DEBUG)
    if grep -q 'set_allow_deferred_call' "${MAGLEV_H}" && \
       ! awk '/^#ifdef DEBUG$/{found=1} found && /set_allow_deferred_call/{print; exit}' "${MAGLEV_H}" | grep -q .; then
        echo "    Already patched, skipping"
    else
        # Use awk to remove #ifdef DEBUG / #endif pairs around methods and fields
        awk '
        /^#ifdef DEBUG$/ {
            save = $0
            getline next_line
            if (next_line ~ /bool allow_allocate/ || next_line ~ /bool allow_call_/) {
                print next_line
                next
            } else {
                print save
                print next_line
                next
            }
        }
        /^#endif  \/\/ DEBUG$/ {
            if (prev ~ /allow_deferred_call/) {
                next
            } else {
                print
                next
            }
        }
        { prev = $0; print }
        ' "${MAGLEV_H}" > "${MAGLEV_H}.tmp" && mv "${MAGLEV_H}.tmp" "${MAGLEV_H}"

        # Ensure allow_allocate_ field exists (may have been removed by awk)
        if ! grep -q 'bool allow_allocate_ = false;' "${MAGLEV_H}"; then
            sed -i 's/  bool allow_call_ = false;/  bool allow_allocate_ = false;\n  bool allow_call_ = false;/' "${MAGLEV_H}"
        fi
        echo "    Patched maglev-assembler.h"
    fi
fi

# Keep release semantics explicit (NDEBUG is the default for Release; these
# ensure it even if the environment set DEBUG elsewhere).
export CFLAGS="${CFLAGS:-} -DNDEBUG"
export CXXFLAGS="${CXXFLAGS:-} -DNDEBUG"

./configure $CONFIGURE_ARGS

# --- Build ------------------------------------------------------------------

echo "==> Building Node.js (this may take 10-30 minutes) ..."
# Limit parallel jobs to avoid OOM kill in Docker
MAKE_JOBS="${MAKE_JOBS:-2}"
echo "    Using ${MAKE_JOBS} parallel jobs"
make -j${MAKE_JOBS}

# --- Install ----------------------------------------------------------------

echo "==> Installing ..."
make install

# --- Locate the real shared libnode.so --------------------------------------

# With --shared, `make install` provides bin/node (thin wrapper) and
# lib/libnode.so (the real shared library). gyp may name the product
# libnode.so directly; install.py may version it as libnode.so.<vernum> with a
# libnode.so symlink. Resolve it (inside the container), falling back to gyp's
# own out/ products if the install step did not place it.
# OHOS's install.py installs ONLY the versioned file libnode.so.<vernum> (it
# does not create the unversioned libnode.so symlink), and out/Release/ likewise
# keeps libnode.so.<vernum>. So resolve by globbing libnode.so* in each
# candidate dir, picking the real file (skip symlinks to the same target).
LIBNODE=""
for d in \
    "${INSTALL_PREFIX}/lib" \
    "${NODE_DIR}/out/Release/lib.target" \
    "${NODE_DIR}/out/Release" \
    "${NODE_DIR}/out/Debug/lib.target" \
    "${NODE_DIR}/out/Debug"; do
    for f in "${d}"/libnode.so*; do
        [ -e "${f}" ] || continue
        LIBNODE="${f}"
        echo "    libnode.so: ${LIBNODE} ($(du -h "${LIBNODE}" | cut -f1))"
        break 2
    done
done
if [ -z "${LIBNODE}" ]; then
    echo "    ✗ libnode.so not found after --shared build."
    echo "      Checked: ${INSTALL_PREFIX}/lib/libnode.so*  and  out/Release/{lib.target,}/libnode.so*"
    exit 1
fi

# --- Strip ------------------------------------------------------------------

echo "==> Stripping libnode.so ..."
STRIP_BIN="${WORKDIR}/llvm-19/llvm/bin/llvm-strip"
if [ -x "${STRIP_BIN}" ]; then
    "${STRIP_BIN}" "${LIBNODE}" || echo "    ⚠ strip failed, keeping unstripped"
fi

# --- Code sign (self-sign) --------------------------------------------------

BINSIGN_JAR="${WORKDIR}/ohos-sdk/linux/toolchains/lib/binary-sign-tool.jar"
if [ -f "${BINSIGN_JAR}" ]; then
    echo "==> Code-signing libnode.so (self-sign) ..."
    SIGNED_TMP="$(mktemp).signed"
    if java -jar "${BINSIGN_JAR}" sign \
        -inFile "${LIBNODE}" \
        -outFile "${SIGNED_TMP}" \
        -selfSign 1 2>/dev/null; then
        mv -f "${SIGNED_TMP}" "${LIBNODE}"
        echo "    ✓ libnode.so self-signed"
    else
        echo "    ⚠ self-sign failed — shipping unsigned"
        rm -f "${SIGNED_TMP}"
    fi
else
    echo "    ⚠ binary-sign-tool.jar not found, skipping code signing"
fi

# --- Copy output ------------------------------------------------------------

echo "==> Copying output to ${OUT_DIR} ..."
cp "${LIBNODE}" "${OUT_DIR}/libnode.so"
cp -r "${INSTALL_PREFIX}" "${OUT_DIR}/" 2>/dev/null || true

# Copy V8 snapshot data files if the build produced any on-disk blobs (the
# snapshot is embedded by default; these files are only needed for embedders
# that load them externally).
for snap in "snapshot_blob.bin" "v8_context_snapshot.bin" "icudtl.dat"; do
    src="${INSTALL_PREFIX}/lib/${snap}"
    [ -f "${src}" ] || src="${INSTALL_PREFIX}/bin/${snap}"
    [ -f "${src}" ] || src="${NODE_DIR}/out/Release/${snap}"
    [ -f "${src}" ] || src="${NODE_DIR}/out/default/${snap}"
    if [ -f "${src}" ]; then
        cp "${src}" "${OUT_DIR}/${snap}"
        echo "    copied snapshot: ${snap}"
    fi
done

echo ""
echo "==> Build complete!"
echo "    Output: ${OUT_DIR}/libnode.so"
echo "    $(du -h "${OUT_DIR}/libnode.so" | cut -f1)  $(file "${OUT_DIR}/libnode.so" | cut -d: -f2)"
