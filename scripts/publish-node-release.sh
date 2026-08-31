#!/usr/bin/env bash
# publish-node-release.sh — Build the real shared libnode.so for OpenHarmony
# and publish it as a GitHub release so CI (and any other build) can consume
# it via scripts/prepare-node.sh instead of building Node.js themselves.
#
# Usage:
#   ./scripts/publish-node-release.sh [version] [arch ...]
#     version  Node.js version the release is built from, default v24.2.0
#     arch     one or more of: arm64 x64 (default: arm64 x64)
#
# Examples:
#   ./scripts/publish-node-release.sh v24.2.0 arm64          # just arm64
#   ./scripts/publish-node-release.sh v24.2.0 arm64 x64      # both ABIs
#
# Prerequisites:
#   - Docker (build-node-ohos.sh)
#   - `gh` authenticated with write access to ${RELEASE_REPO}
#
# The release is tagged ohos-node-shared-v<version> and carries one asset per
# arch: libnode-arm64.so, libnode-x86_64.so (named to match prepare-node.sh's
# libnode-${ARCH}.so lookup).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

NODE_VERSION="${1:-v24.2.0}"
RELEASE_REPO="${RELEASE_REPO:-electerm/electerm-harmony}"
# Strip a leading "v" so "v24.2.0" and "24.2.0" both map to the same tag
# ohos-node-shared-v24.2.0 (matches scripts/prepare-node.sh's default tag).
RELEASE_TAG="${RELEASE_TAG:-ohos-node-shared-v${NODE_VERSION#v}}"

# archs to build/publish (default: both)
if [ $# -gt 1 ]; then
  shift
  ARCHS=("$@")
else
  ARCHS=(arm64 x64)
fi

echo "==> Publishing libnode release ${RELEASE_TAG}"
echo "    Repo: ${RELEASE_REPO}"
echo "    Archs: ${ARCHS[*]}"

# --- Preflight --------------------------------------------------------------

if ! command -v gh >/dev/null 2>&1; then
  echo "    ✗ gh not found. Install GitHub CLI: https://cli.github.com/"
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "    ✗ gh not authenticated. Run: gh auth login"
  exit 1
fi

if gh release view "${RELEASE_TAG}" --repo "${RELEASE_REPO}" >/dev/null 2>&1; then
  echo "    Release ${RELEASE_TAG} already exists — adding/updating assets only."
  CREATE_RELEASE="no"
else
  CREATE_RELEASE="yes"
fi

# --- Build each arch (skip if scripts/build-node-ohos.sh already produced it) -
STAGING="$(mktemp -d)"
trap 'rm -rf "${STAGING}"' EXIT

# Describe an ELF: prints "<machine>:<pie>" e.g. "183:no" (arm64 real shared
# lib), "183:yes" (arm64 PIE — the broken hqzing form), "62:no" (x64 real).
elf_desc() {
  python3 - "$1" <<'PYEOF'
import struct, sys
p = sys.argv[1]
d = open(p, 'rb').read(64)
if d[:4] != b'\x7fELF':
    print('?:?'); sys.exit()
le = d[5] == 1
fmt = '<' if le else '>'
machine = struct.unpack(fmt + 'H', d[18:20])[0]
etype   = struct.unpack(fmt + 'H', d[16:18])[0]
e_phoff = struct.unpack(fmt + 'Q', d[32:40])[0]
phentsize = struct.unpack(fmt + 'H', d[54:56])[0]
phnum   = struct.unpack(fmt + 'H', d[56:58])[0]
interp = False
with open(p, 'rb') as f:
    for i in range(phnum):
        f.seek(e_phoff + i * phentsize)
        ph = f.read(phentsize)
        if struct.unpack(fmt + 'I', ph[0:4])[0] == 3:
            interp = True
            break
pie = 'yes' if interp else 'no'
print(f'{machine}:{pie}')
PYEOF
}

for arch in "${ARCHS[@]}"; do
  case "${arch}" in
    arm64) ABI="arm64-v8a"; WANT_MACHINE="183" ;;
    x64)   ABI="x86_64";   WANT_MACHINE="62" ;;
    *) echo "    ✗ Unknown arch: ${arch} (use arm64 or x64)"; exit 1 ;;
  esac

  echo ""
  echo "==> [${arch}] Building/collecting libnode.so ..."
  OUT_DIR="${SCRIPT_DIR}/output"
  BUILT=""

  # Prefer the version already installed in the project (entry/libs/<abi>) —
  # both ABIs are kept there locally, so publishing packages what we built
  # without rebuilding anything. Accept only REAL shared libs (no PT_INTERP):
  # a stale PIE in entry/libs/ is exactly what we must NOT ship.
  INSTALLED="${PROJECT_ROOT}/entry/libs/${ABI}/libnode.so"
  if [ -f "${INSTALLED}" ]; then
    DESC=$(elf_desc "${INSTALLED}")
    if [ "${DESC}" = "${WANT_MACHINE}:no" ]; then
      BUILT="${INSTALLED}"
      echo "    Reusing installed lib: ${INSTALLED} (${DESC})"
    else
      echo "    Installed lib rejected (${DESC}, want ${WANT_MACHINE}:no) — ignoring"
    fi
  fi

  # Fall back to scripts/output/libnode.so (the last build-node-ohos.sh run)
  if [ -z "${BUILT}" ] && [ -f "${OUT_DIR}/libnode.so" ]; then
    DESC=$(elf_desc "${OUT_DIR}/libnode.so")
    if [ "${DESC}" = "${WANT_MACHINE}:no" ]; then
      BUILT="${OUT_DIR}/libnode.so"
      echo "    Reusing build output: ${BUILT} (${DESC})"
    fi
  fi

  # Otherwise build from scratch
  if [ -z "${BUILT}" ]; then
    echo "    No matching real shared lib found — building ..."
    "${SCRIPT_DIR}/build-node-ohos.sh" "${NODE_VERSION}" 2 "${arch}"
    BUILT="${OUT_DIR}/libnode.so"
  fi

  echo "    Verifying ELF is a shared library (not a PIE) ..."
  DESC=$(elf_desc "${BUILT}")
  if [ "${DESC}" != "${WANT_MACHINE}:no" ]; then
    echo "    ✗ Expected ${WANT_MACHINE}:no got ${DESC}"
    exit 1
  fi

  ASSET="${STAGING}/libnode-${arch}.so"
  cp "${BUILT}" "${ASSET}"
  echo "    Staged: ${ASSET} ($(du -h "${ASSET}" | cut -f1))"
done

# --- Publish ----------------------------------------------------------------

echo ""
echo "==> Publishing release ${RELEASE_TAG} to ${RELEASE_REPO} ..."

if [ "${CREATE_RELEASE}" = "yes" ]; then
  gh release create "${RELEASE_TAG}" \
    "${STAGING}"/libnode-*.so \
    --repo "${RELEASE_REPO}" \
    --title "OpenHarmony Node.js shared libnode ${NODE_VERSION}" \
    --notes "Real shared libnode.so for OpenHarmony (built with \`--shared\`, not a PIE). Built from Node.js ${NODE_VERSION} using the OHOS SDK + LLVM-19 (scripts/build-node-ohos.sh). Consumed by scripts/prepare-node.sh."
else
  # assets are immutable once uploaded — for an existing release, replace the
  # files via release upload of the same names fails, so delete-then-upload.
  gh release upload "${RELEASE_TAG}" \
    "${STAGING}"/libnode-*.so \
    --repo "${RELEASE_REPO}" --clobber
fi

echo ""
echo "==> Done!"
echo "    Release: https://github.com/${RELEASE_REPO}/releases/tag/${RELEASE_TAG}"
echo "    consume via: ./scripts/prepare-node.sh <arch>"
