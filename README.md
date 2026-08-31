# ohos-node-shared

Prebuilt **shared `libnode.so`** for OpenHarmony — the embeddable Node.js runtime
used by [electerm-harmony](https://github.com/electerm/electerm-harmony) to run an
on-device backend **inside** the app.

For each Node.js version we publish a GitHub release tagged
`ohos-node-shared-v<version>` containing a **real shared library**
(`libnode-arm64.so` for arm64-v8a devices, `libnode-x64.so` for the x86_64
emulator) — **not** a PIE executable.

---

## Why this exists / What it is for

`electerm-harmony` (the OpenHarmony port of the electerm terminal / SSH client)
runs an on-device Node.js backend. The ArkWeb front-end talks to a Node.js server
bound to `127.0.0.1:5577`. To ship Node.js inside the app we `dlopen()` a
`libnode.so` from the HAP's native libs directory at runtime — which requires a
**true shared library**, not a standalone executable.

This repository provides:

- The **prebuilt artifacts** (GitHub releases).
- The **exact, reproducible build scripts** (Docker + OpenHarmony SDK + LLVM-19).
- A `prepare-node.sh` **consumer** script that CI / other builds use to pull the
  right artifact and verify its shape.

---

## How it differs from `hqzing/ohos-node`

[`hqzing/ohos-node`](https://github.com/hqzing/ohos-node) is the well-known
third-party Node.js build for OpenHarmony. The two projects target **different
deployment models**:

| | ohos-node-shared (this repo) | `hqzing/ohos-node` |
|---|---|---|
| Goal | Embed Node.js **inside** an app (ArkUI / ArkWeb) via `dlopen()` | Run the `node` CLI as a **standalone** process on a device |
| Output | A real shared library `libnode.so` (`--shared` build) | A `node` executable tarball (`--partly-static`) |
| `libnode.so` form | True `ET_DYN` shared object, **no** `PT_INTERP` | PIE executable (`ET_DYN` + `PT_INTERP`) |
| Architectures | arm64-v8a (device) **and** x86_64 (emulator) | primarily arm64 (now also xz artifacts) |
| Use when | You need to host Node.js inside your own process | You want to run `node script.js` on OpenHarmony |

### The critical technical difference: PIE vs. real shared library

`hqzing/ohos-node` (and a naive `--partly-static` build) produce `libnode.so`
as a **PIE executable** — an `ET_DYN` with a `PT_INTERP` program header. If you
try to `dlopen()` that inside a HarmonyOS app, the dynamic loader maps the PIE's
thread-local storage using the **same `%fs` base as the host app**, because the
linker wrote `local-exec` TLS offsets. That aliases the host app's TLS block, so
V8's

```cpp
thread_local current_per_thread_assert_data
```

reads garbage, and the release assertion

```cpp
AllowHeapAllocationInRelease::IsAllowed()
```

fires on the very first heap allocation at `Isolate::Initialize`. The app crashes
before any JS runs.

This repo builds Node.js with the **`--shared`** configure flag, which makes gyp
emit a genuine `ET_DYN` shared object with a `SONAME` (`libnode.so.<vernum>`)
and **dynamic TLS** (not `local-exec`). That form `dlopen()`s cleanly and V8
works.

`prepare-node.sh` even **rejects a PIE artifact at download time** (it checks
`e_type == ET_DYN && !PT_INTERP`) so a bad build can never reach the HAP.

---

## Build process

Everything is reproducible from `scripts/`. You need Docker — the cross-compile
runs in an Ubuntu 24.04 container that downloads the OpenHarmony SDK + LLVM-19 on
first run (~3 GB, then cached).

```bash
# 1. Build one ABI at a time (output -> scripts/output/libnode.so)
./scripts/build-node-ohos.sh v24.2.0 2 arm64
./scripts/build-node-ohos.sh v24.2.0 2 x64

# 2. (Optional) Publish as a GitHub release — one asset per ABI
RELEASE_REPO=electerm/ohos-node-shared ./scripts/publish-node-release.sh v24.2.0 arm64 x64
```

What `build-node-ohos-inner.sh` does inside the container:

1. Installs build deps (`build-essential`, `curl`, `git`, `jq`, `unzip`,
   `python3`, `libxml2`).
2. Downloads the OpenHarmony SDK (`ohos-sdk-public`) and LLVM-19 from the daily
   build API; extracts `toolchains` and the sysroot.
3. Sets the OHOS clang toolchain as `CC` / `CXX` with `-fno-emulated-tls`.
4. Downloads the Node.js v24.2.0 source tarball.
5. Applies `0001-fix-argument-list-too-long.patch` (needed for v24.2.0).
6. Patches V8's `maglev-assembler.h` so `set_allow_*` is declared outside
   `#ifdef DEBUG` (release-build fix).
7. Configures with
   `--dest-cpu=<arch> --dest-os=openharmony --cross-compiling --openssl-no-asm --shared`.
8. `make -j2` then `make install`.
9. Locates the real `libnode.so*`, strips it, and **self-signs** it with the OHOS
   `binary-sign-tool.jar` (required for the HAP to load it).
10. Copies the result to `scripts/output/libnode.so`.

> The `--shared` flag is the whole point: it is what makes gyp produce a real
> shared library instead of a PIE executable.

---

## Consuming the prebuilt artifact

In a project that embeds Node.js the same way `electerm-harmony` does:

```bash
# downloads libnode-<arch>.so into entry/libs/<abi>/libnode.so
RELEASE_REPO=electerm/ohos-node-shared ./scripts/prepare-node.sh arm64
RELEASE_REPO=electerm/ohos-node-shared ./scripts/prepare-node.sh x64
```

Or grab the binaries directly from the
[releases](https://github.com/electerm/ohos-node-shared/releases) page.

For `electerm-harmony` itself, `scripts/prepare-node.sh` already defaults to this
repo, so a plain `./scripts/prepare-node.sh arm64` is enough.

---

## Assets for `ohos-node-shared-v24.2.0`

| File | Arch | SHA-256 |
|---|---|---|
| `libnode-arm64.so` | arm64-v8a (device) | `3019bf5f9a279d98a87606fc13c53b0e797b6a50cf174f8a1243d880c71151a1` |
| `libnode-x64.so`     | x86_64 (emulator)  | `d001ec8b34db459d45ce5f1b8952b49fc55ac0b5e0a5d2b77193f6a1a3608990` |

---

## Repository layout

```
scripts/
  build-node-ohos.sh          # Docker driver — builds one ABI's libnode.so
  build-node-ohos-inner.sh    # runs inside the container
  publish-node-release.sh     # publishes the GitHub release (one asset per ABI)
  prepare-node.sh             # consumer: download + verify + install
  0001-fix-argument-list-too-long.patch
```

---

## Author

Maintained by **赵旭东 (ZHAO Xudong)** — GitHub [@zxdong262](https://github.com/zxdong262), <zxdong@gmail.com>.

---

## License

The produced `libnode.so` is covered by the Node.js license (see
<https://github.com/nodejs/node>). The build scripts in this repo are MIT.
