# ohos-node-shared

面向 OpenHarmony 的**预编译共享库 `libnode.so`** —— 可被应用内嵌的 Node.js 运行时，
由 [electerm-harmony](https://github.com/electerm/electerm-harmony) 用来在应用**内部**
运行一个设备端后端。

对于每个 Node.js 版本，我们都会发布一个以 `ohos-node-shared-v<version>` 为标签的
GitHub Release，内含**真正的共享库**（`libnode-arm64.so` 对应 arm64-v8a 真机，
`libnode-x64.so` 对应 x86_64 模拟器）—— 而**不是** PIE 可执行文件。

---

## 为什么有这个项目 / 它的用途

`electerm-harmony`（electerm 终端 / SSH 客户端的 OpenHarmony 移植版）在设备端运行一个
Node.js 后端：ArkWeb 前端与一个绑定在 `127.0.0.1:5577` 的 Node.js 服务通信。为了把
Node.js 随应用一起分发，我们在运行时通过 `dlopen()` 从 HAP 的原生库目录加载
`libnode.so` —— 这要求它是一**真正的共享库**，而不是一个独立的可执行文件。

本仓库提供：

- **预编译产物**（GitHub Release）。
- **完整、可复现的构建脚本**（Docker + OpenHarmony SDK + LLVM-19）。
- 一个 `prepare-node.sh` **消费脚本**，供 CI 或其他构建拉取正确的产物并校验其形态。

---

## 与 `hqzing/ohos-node` 的区别

[`hqzing/ohos-node`](https://github.com/hqzing/ohos-node) 是 OpenHarmony 上知名的第三方
Node.js 构建。两个项目面向**不同的部署形态**：

| | ohos-node-shared（本仓库） | `hqzing/ohos-node` |
|---|---|---|
| 目标 | 把 Node.js **内嵌**进应用（ArkUI / ArkWeb），通过 `dlopen()` 加载 | 在设备上把 `node` 当作**独立进程**运行 |
| 产物 | 真正的共享库 `libnode.so`（`--shared` 构建） | `node` 可执行文件压缩包（`--partly-static`） |
| `libnode.so` 形态 | 真正的 `ET_DYN` 共享对象，**无** `PT_INTERP` | PIE 可执行文件（`ET_DYN` + `PT_INTERP`） |
| 架构 | arm64-v8a（真机）**与** x86_64（模拟器） | 主要是 arm64（现在也提供 xz 压缩包） |
| 适用场景 | 需要在自己进程内托管 Node.js | 想在 OpenHarmony 上跑 `node script.js` |

### 关键的技术差异：PIE 与真正的共享库

`hqzing/ohos-node`（以及朴素的 `--partly-static` 构建）把 `libnode.so` 产成** PIE
可执行文件** —— 一个带 `PT_INTERP` 程序头的 `ET_DYN`。如果你尝试在 HarmonyOS 应用里
`dlopen()` 它，动态加载器会用**与应用宿主相同的 `%fs` 基址**来映射 PIE 的线程局部存储
（TLS），因为链接器写入的是 `local-exec` 模式的 TLS 偏移量。这会把宿主应用的 TLS 块给
「别名化」，于是 V8 里的

```cpp
thread_local current_per_thread_assert_data
```

读到的就是垃圾数据，紧接着 release 断言

```cpp
AllowHeapAllocationInRelease::IsAllowed()
```

会在 `Isolate::Initialize` 的**第一次堆分配**时就触发。应用在任意 JS 执行前就崩了。

本仓库用 **`--shared`** 配置项构建 Node.js，它让 gyp 真正产出一个带 `SONAME`
（`libnode.so.<vernum>`）且使用**动态 TLS**（非 `local-exec`）的 `ET_DYN` 共享对象。
这种形态能干净地 `dlopen()`，V8 才能正常工作。

`prepare-node.sh` 还会在**下载时直接拒绝 PIE 形态的产物**（校验 `e_type == ET_DYN &&
!PT_INTERP`），从而杜绝坏构建进入 HAP。

---

## 构建流程

全部流程都可由 `scripts/` 复现。你需要 Docker —— 交叉编译在一个 Ubuntu 24.04 容器内
完成，首次运行会下载 OpenHarmony SDK + LLVM-19（约 3 GB，之后缓存）。

```bash
# 1. 一次构建一个架构（产物 -> scripts/output/libnode.so）
./scripts/build-node-ohos.sh v24.2.0 2 arm64
./scripts/build-node-ohos.sh v24.2.0 2 x64

# 2.（可选）发布为 GitHub Release —— 每个架构一个产物
RELEASE_REPO=electerm/ohos-node-shared ./scripts/publish-node-release.sh v24.2.0 arm64 x64
```

`build-node-ohos-inner.sh` 在容器内依次做：

1. 安装构建依赖（`build-essential`、`curl`、`git`、`jq`、`unzip`、`python3`、`libxml2`）。
2. 从每日构建 API 下载 OpenHarmony SDK（`ohos-sdk-public`）与 LLVM-19，解压出
   `toolchains` 与 sysroot。
3. 将 OHOS clang 工具链设为 `CC` / `CXX`，并加上 `-fno-emulated-tls`。
4. 下载 Node.js v24.2.0 源码压缩包。
5. 打上 `0001-fix-argument-list-too-long.patch`（v24.2.0 需要）。
6. 修补 V8 的 `maglev-assembler.h`，把 `set_allow_*` 声明移到 `#ifdef DEBUG` 之外
   （release 构建修复）。
7. 以
   `--dest-cpu=<arch> --dest-os=openharmony --cross-compiling --openssl-no-asm --shared`
   配置。
8. `make -j2` 然后 `make install`。
9. 找出真正的 `libnode.so*`，strip，并用 OHOS 的 `binary-sign-tool.jar` 做**自签名**
   （HAP 加载它是必需的）。
10. 把结果拷到 `scripts/output/libnode.so`。

> `--shared` 是整个构建的关键：正是它让 gyp 产出真正的共享库，而非 PIE 可执行文件。

---

## 如何使用预编译产物

在与 `electerm-harmony` 同样的「内嵌 Node.js」方式的项目中：

```bash
# 把 libnode-<arch>.so 下载到 entry/libs/<abi>/libnode.so
RELEASE_REPO=electerm/ohos-node-shared ./scripts/prepare-node.sh arm64
RELEASE_REPO=electerm/ohos-node-shared ./scripts/prepare-node.sh x64
```

也可以直接从
[Releases](https://github.com/electerm/ohos-node-shared/releases) 页面获取二进制。

对 `electerm-harmony` 自身而言，`scripts/prepare-node.sh` 已经默认指向本仓库，
因此直接 `./scripts/prepare-node.sh arm64` 即可。

---

## `ohos-node-shared-v24.2.0` 产物

| 文件 | 架构 | SHA-256 |
|---|---|---|
| `libnode-arm64.so` | arm64-v8a（真机） | `3019bf5f9a279d98a87606fc13c53b0e797b6a50cf174f8a1243d880c71151a1` |
| `libnode-x64.so`     | x86_64（模拟器）  | `d001ec8b34db459d45ce5f1b8952b49fc55ac0b5e0a5d2b77193f6a1a3608990` |

---

## 仓库结构

```
scripts/
  build-node-ohos.sh          # Docker 驱动脚本 —— 构建单个架构的 libnode.so
  build-node-ohos-inner.sh    # 在容器内运行
  publish-node-release.sh     # 发布 GitHub Release（每个架构一个产物）
  prepare-node.sh             # 消费端：下载 + 校验 + 安装
  0001-fix-argument-list-too-long.patch
```

---

## 许可证

产出的 `libnode.so` 遵循 Node.js 许可证（见 <https://github.com/nodejs/node>）。
本仓库中的构建脚本采用 MIT 许可证。
