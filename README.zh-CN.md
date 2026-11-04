<div align="center">

<img src="design-system/app-icon.png" alt="AQuantum Reader" width="96">

# AQuantum Reader

**一本书，一处阅读。**

面向 Android 与 Windows 的本地阅读器 · Flutter 界面 · Rust 核心

[![Release](https://img.shields.io/github/v/release/SteamDoge/aquantum?include_prereleases&style=flat-square&label=release)](https://github.com/SteamDoge/aquantum/releases) [![Downloads](https://img.shields.io/github/downloads/SteamDoge/aquantum/total?style=flat-square&logo=github)](https://github.com/SteamDoge/aquantum/releases) [![License](https://img.shields.io/badge/license-AGPL--3.0--only-00AEEF?style=flat-square)](LICENSE)<br>
![Android](https://img.shields.io/badge/Android-3DDC84?logo=android&logoColor=white) ![Windows](https://img.shields.io/badge/Windows-0078D4?logo=windows&logoColor=white)

**[下载](#下载)** &nbsp;·&nbsp; **[功能](#功能)** &nbsp;·&nbsp; **[使用](#使用)** &nbsp;·&nbsp; **[源码构建](#源码构建)** &nbsp;·&nbsp; **[问题反馈](https://github.com/SteamDoge/aquantum/issues)**

[English](README.md) · **简体中文**

</div>

## 适合你吗

书常常散落在不同的应用里：小说在一个，漫画在另一个，PDF 和 EPUB 又在别处，各自记着进度和设置。AQuantum Reader 把它们放进手机或电脑上的同一个本地资料库：

- **一个应用读多种格式**：文本、Markdown、图片与漫画、PDF、EPUB、MOBI、AZW3、FB2。
- **原文件保持不变**：导入时复制一份进资料库，原件不会被改动。
- **免登录，可离线**：资料库、进度和笔记都留在你的设备上。
- **按需扩展**：安装 JavaScript 插件，增加页面和工具。

如果你读的多是本地文件、格式又多，想集中在一处，它适合你。如果你依赖书城的云端书架，或需要多设备同步，目前还做不到。支持 Android 7.0+ 和 Windows 10／11 x64。

## 功能

- **本地阅读**：免登录，可离线使用；导入时复制文件，保留外部原件。
- **多种内容**：文本、图片／漫画、PDF、Markdown、EPUB、MOBI、AZW3、FB2 等；各格式按自身能力排版。
- **持续阅读**：保存阅读位置、书签与笔记，管理资料库和本地备份。
- **统一体验**：连续滚动与横向分页，四套配色及浅深主题，适配手机和桌面布局。
- **独立扩展**：通过 `javascript-v1` 插件接口安装 JavaScript 模块，可选 HTML 页面；联网能力由模块及其声明的权限决定。
- **开放源码**：原创代码采用 **AGPL-3.0-only**，第三方许可与版权声明完整保留。

有插件接口不代表已经内置 OCR、AI 或云同步，这些都没有实现。书目信息检索和联网插件需要网络。

## 下载

当前版本：[**RC015 · rc.0.0.15**](https://github.com/SteamDoge/aquantum/releases/tag/rc.0.0.15)。在 [所有版本](https://github.com/SteamDoge/aquantum/releases) 查看更新与安装包。

| 平台 | 下载 | 选择说明 |
| --- | --- | --- |
| Android 7.0+（API 24+） | [![APK ARM64](https://img.shields.io/badge/APK-ARM64-3DDC84?logo=android&logoColor=white)](https://github.com/SteamDoge/aquantum/releases/download/rc.0.0.15/AQuantumReader-rc.0.0.15-android-arm64.apk) | 大多数手机选择此版本 |
| Android x86_64 | [![APK x64](https://img.shields.io/badge/APK-x64-168039?logo=android&logoColor=white)](https://github.com/SteamDoge/aquantum/releases/download/rc.0.0.15/AQuantumReader-rc.0.0.15-android-x64.apk) | x86_64 设备／模拟器 |
| Windows 10／11 x64 | [![Portable x64](https://img.shields.io/badge/Portable-x64-00AEEF)](https://github.com/SteamDoge/aquantum/releases/download/rc.0.0.15/AQuantumReader-rc.0.0.15-windows-x64.zip) | 解压完整目录，运行 `AQuantumReader.exe` |
| 插件开发 | [SDK 源码与示例](https://github.com/SteamDoge/aquantum/releases/download/rc.0.0.15/AQuantumReader-rc.0.0.15-plugin-sdk.zip) | 开发工具，不是已安装的功能模块 |

<sub>Windows 阅读 EPUB 等文档需安装 Microsoft Edge WebView2 Runtime。当前没有 Linux、macOS、iOS 或 Windows ARM64 安装包。ARM64 实体机及完整 GUI／设备／格式矩阵仍有验证缺口。</sub>

## 使用

**1 · 安装。** Android 安装对应的 APK；Windows 解压便携包，并保留 EXE 旁边的 DLL、`data` 和插件资源，只复制 EXE 无法运行。

**2 · 导入。** 选择文件、目录或压缩包，预览后导入资料库。

**3 · 阅读。** 打开内容阅读，在设置中调整配色和阅读偏好。

升级或手动操作资料库前先备份。Android 覆盖升级需要兼容签名；自行构建的签名与发布包不同时，先导出备份再处理安装，不要用卸载代替备份。

## 源码构建

<details>
<summary>展开环境要求、构建命令与测试步骤</summary>

### 构建环境

本版本使用 Rust **1.98.1**、Flutter **3.47.7 stable / Dart 3.13.5** 验证。依赖版本分别锁定在 `Cargo.lock` 和 `apps/flutter_reader/pubspec.lock`；请先安装 SDK，再恢复依赖。构建首次需要联网获取依赖及 PDFium 原生资源。

- Windows：Windows 10/11 x64、Visual Studio 的 Desktop development with C++ 工作负载、CMake、NuGet CLI 和 PowerShell。运行 EPUB 等文档需要 Microsoft Edge WebView2 Runtime。
- Android：JDK 21、Android SDK 36、NDK **28.2.13676358**、CMake 3.22.1；工程固定 AGP 9.1.0 / Gradle 9.3.1。安装相应 Android Rust target，并提供可供 bindgen 使用的 `libclang`。
- Flutter/Android SDK 路径避免空格。环境变量 `JAVA_HOME`、`ANDROID_HOME`、`LIBCLANG_PATH` 指向各自安装目录；NuGet CLI 应在 PATH 中。无需本项目开发者的私有工具路径、原签名或 SDK 副本。

### 构建

```powershell
git clone git@github.com:SteamDoge/aquantum.git
cd aquantum
cargo fetch --locked
Push-Location apps/flutter_reader
flutter pub get --enforce-lockfile
Pop-Location

# Windows：先构建 Rust 桥接，再构建 Flutter；脚本负责此顺序
powershell -ExecutionPolicy Bypass -File scripts/build-client.ps1 -Platform windows

# 或仅使用核心命令行（亦可在 Rust 支持的平台构建）
cargo run --locked -p aq-cli -- --help
```

Windows 完整输出位于 `apps/flutter_reader/build/windows/x64/runner/Release/`。运行 `AQuantumReader.exe` 时保留同目录 DLL、`data` 和插件资源；不能只复制 EXE。开发运行也应先 `cargo build --locked -p aq-bridge --release`，再在 Flutter 目录执行 `flutter run -d windows`。

### Android 签名

Android Release 构建前请自行生成并安全保管签名密钥，创建被忽略的 `apps/flutter_reader/android/key.properties`：

```properties
storeFile=C:/private/your-release-key.jks
storePassword=YOUR_LOCAL_STORE_PASSWORD
keyAlias=YOUR_KEY_ALIAS
keyPassword=YOUR_LOCAL_KEY_PASSWORD
```

这些占位符不是可用凭据。不要提交此文件或密钥。自行签名的安装包与其他签名的已安装版本不能直接覆盖升级；需要保留数据时先通过应用备份。

```powershell
rustup target add aarch64-linux-android x86_64-linux-android
powershell -ExecutionPolicy Bypass -File scripts/build-client.ps1 -Platform android -AndroidX64
```

APK 位于 `apps/flutter_reader/build/app/outputs/flutter-apk/`。省略 `-AndroidX64` 时仅构建 ARM64。脚本生成 JNI 库并检查 R8 的 JNI 保留规则；正式包仍需安装验证。所有客户端构建和测试串行执行。Release 不使用 `--no-pub`，以确保正确重生成插件注册文件。Flutter 会补齐被 Git 忽略的 Gradle wrapper 启动文件和本地 SDK 路径文件。

### 测试

首次运行测试前，从示例源码生成测试使用的 SDK 包（已经生成的示例无需重复执行；打包器拒绝覆盖既有 ZIP）。Python 3.11+ 只用于此打包步骤，不是应用运行依赖；生成的 dist/ZIP 被忽略：

```powershell
python plugin-sdk/build.py plugin-sdk/examples/headless
python plugin-sdk/build.py plugin-sdk/examples/native
python plugin-sdk/build.py plugin-sdk/examples/html
```

一键完整检查（版本一致性、Rust 格式/测试/静态检查、Flutter 分析/格式/测试）：

```powershell
powershell -ExecutionPolicy Bypass -File scripts/check.ps1
```

也可以分步执行：

```powershell
node scripts/check-version.mjs
cargo test --workspace --locked
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo build --locked -p aq-bridge --release
$env:AQ_RUST_LIB = (Resolve-Path target/release/aq_bridge.dll).Path
Push-Location apps/flutter_reader
flutter analyze
flutter test
Pop-Location
```

原生集成测试位于 `apps/flutter_reader/integration_test`，可用 `scripts/test-native.ps1` 在 Windows 或指定 Android 设备上运行；它会创建独立的 QA 资料库，不使用个人资料。Windows 可用 `AQ_READER_DATA` 指定独立的绝对数据目录。

第三方插件以独立 `javascript-v1` ZIP 安装，HTML 页面可选；类型接口见 `plugin-sdk/index.d.ts`，打包用 `python plugin-sdk/build.py --help`，源码示例在 `plugin-sdk/examples`。示例源码不代表已安装功能。

</details>

## 工程结构

| 路径 | 职责 |
| --- | --- |
| `apps/flutter_reader` | Flutter UI、平台工程与文档引擎资源 |
| `crates/domain` | 核心规则 |
| `crates/application` | 操作层与存储端口 |
| `crates/local` | SQLite、受管资源及文件系统 |
| `crates/bridge` | JSON C ABI 与 QuickJS 插件运行时 |
| `apps/cli` | 核心命令行入口 |
| `plugin-sdk` | 运行时、类型声明、打包脚本及最小示例 |
| `scripts` | 构建、完整检查、原生测试、测试样本生成与许可清单 |

## 隐私

AQuantum Reader 不需要账号，不收集使用统计或崩溃报告。资料库、阅读进度、笔记和设置都保存在你的设备上。只有使用下面这些功能时才会联网：

| | |
| :-- | :-- |
| **书目信息检索** | 只在书籍信息页主动搜索时发生。发送你输入的书名、作者或 ISBN 到 [Open Library](https://openlibrary.org)；封面图片来自 Open Library 的服务器。 |
| **通过链接安装插件** | 从你输入的 GitHub 仓库、Release 页面或 HTTPS ZIP 下载；GitHub Release 通过 `api.github.com` 查询。如果 DNS 返回 VPN 的虚假 IP，会改用 Google Public DNS（`dns.google`）解析域名。 |
| **插件** | 插件声明了网络权限才能发起 HTTPS 请求。发送什么由插件决定，安装前请查看它的权限和源码。 |

## 反馈与贡献

请通过 [GitHub Issues](https://github.com/SteamDoge/aquantum/issues) 提交问题或建议，注明版本、系统、复现步骤与预期结果；日志及样例请先移除个人资料。欢迎提交聚焦问题的 Pull Request；新增的原创源文件请在开头保留 `SPDX-License-Identifier: AGPL-3.0-only` 与版权注释，提交前运行 `scripts/check.ps1`。

如果 AQuantum Reader 对你有用，点一个 ⭐ 能让更多人找到它。

## 许可证

本项目原创代码采用 **AGPL-3.0-only**，完整 GNU 官方原文见 [LICENSE](LICENSE)。没有额外的非商用或禁止修改限制。分发修改版以及通过网络向用户提供修改版服务时，应遵守许可证适用的源码提供义务。

第三方代码、依赖及 Flutter 工程模板保留各自原有许可和版权声明（见 [第三方声明](THIRD_PARTY_NOTICES.md)），本项目的许可证不改变它们的许可。独立 HTML/JavaScript 插件通过公开的消息接口和权限端口交互；插件作者需为自己的代码、依赖和素材选择适用许可证，不能仅凭使用接口就推定所有第三方插件必须采用 AGPL。实际复制宿主代码或形成衍生作品时，应另行评估相应许可义务。
