<div align="center">

<img src="design-system/app-icon.png" alt="AQuantum Reader" width="96">

# AQuantum Reader

**一本书，一处阅读。**

面向 Android 与 Windows 的本地阅读器 · Flutter 界面 · Rust 核心

[![Release](https://img.shields.io/github/v/release/SteamDoge/aquantum?include_prereleases&style=flat-square&label=release)](https://github.com/SteamDoge/aquantum/releases)
[![Downloads](https://img.shields.io/github/downloads/SteamDoge/aquantum/total?style=flat-square&logo=github)](https://github.com/SteamDoge/aquantum/releases)
[![License](https://img.shields.io/badge/license-AGPL--3.0--only-00AEEF?style=flat-square)](LICENSE)

[下载](#下载) · [功能](#功能) · [使用](#使用) · [源码构建](#源码构建) · [问题反馈](https://github.com/SteamDoge/aquantum/issues)

</div>

## 功能

- **本地阅读**：免登录，可离线使用；导入时复制文件，保留外部原件。
- **多种内容**：文本、图片／漫画、PDF、Markdown、EPUB、MOBI、AZW3、FB2 等；各格式按自身能力排版。
- **持续阅读**：保存阅读位置、书签与笔记，管理资料库和本地备份。
- **统一体验**：连续滚动与横向分页，四套配色及浅深主题，适配手机和桌面布局。
- **独立扩展**：通过 `javascript-v1` 插件接口安装 JavaScript 模块，可选 HTML 页面；联网能力由模块及用户授权决定。
- **开放源码**：原创代码采用 AGPL-3.0-only，第三方许可与版权声明完整保留。

OCR、AI、云同步等扩展方向不代表主程序已经实现的功能。可选书目信息检索及联网插件需要网络。

## 下载

当前预发布：[**RC015 · rc.0.0.15**](https://github.com/SteamDoge/aquantum/releases/tag/rc.0.0.15)。在 [所有版本](https://github.com/SteamDoge/aquantum/releases) 查看更新与安装包。

| 平台 | 下载 | 选择说明 |
| --- | --- | --- |
| Android 7.0+（API 24+） | [![APK ARM64](https://img.shields.io/badge/APK-ARM64-3DDC84?logo=android&logoColor=white)](https://github.com/SteamDoge/aquantum/releases/download/rc.0.0.15/AQuantumReader-rc.0.0.15-android-arm64.apk) | 大多数手机选择此版本 |
| Android x86_64 | [![APK x64](https://img.shields.io/badge/APK-x64-168039?logo=android&logoColor=white)](https://github.com/SteamDoge/aquantum/releases/download/rc.0.0.15/AQuantumReader-rc.0.0.15-android-x64.apk) | x86_64 设备／模拟器 |
| Windows 10／11 x64 | [![Portable x64](https://img.shields.io/badge/Portable-x64-00AEEF)](https://github.com/SteamDoge/aquantum/releases/download/rc.0.0.15/AQuantumReader-rc.0.0.15-windows-x64.zip) | 解压完整目录，运行 `AQuantumReader.exe` |
| 插件开发 | [SDK 源码与示例](https://github.com/SteamDoge/aquantum/releases/download/rc.0.0.15/AQuantumReader-rc.0.0.15-plugin-sdk.zip) | 开发工具，不是已安装的功能模块 |

Windows 阅读 EPUB 等文档需安装 Microsoft Edge WebView2 Runtime。当前没有 Linux、macOS、iOS 或 Windows ARM64 安装包。RC 为预发布版本；ARM64 实体机及完整 GUI／设备／格式矩阵仍有验证缺口。

## 使用

1. Android 安装对应 APK；Windows 解压便携包并保留 DLL、`data` 和插件资源，不能只复制 EXE。
2. 在应用中选择文件、目录或压缩包，预览后导入资料库。
3. 打开内容阅读，在设置中调整配色和阅读偏好；升级或手动操作资料库前先备份。

Android 覆盖升级需要兼容签名。自行构建的签名与发布包不同时，先导出备份，再处理安装；不要通过卸载来代替备份。

## 源码构建

<details>
<summary>展开环境要求、构建命令与测试步骤</summary>

## 构建环境

本版本使用 Rust **1.98.1**、Flutter **3.47.7 stable / Dart 3.13.5** 验证。依赖版本分别锁定在 `Cargo.lock` 和 `apps/flutter_reader/pubspec.lock`；请先安装 SDK，再恢复依赖。构建首次需要联网获取依赖及 PDFium 原生资源。

- Windows：Windows 10/11 x64、Visual Studio 的 Desktop development with C++ 工作负载、CMake、NuGet CLI 和 PowerShell。运行 EPUB 等文档需要 Microsoft Edge WebView2 Runtime。
- Android：JDK 21、Android SDK 36、NDK **28.2.13676358**、CMake 3.22.1；工程固定 AGP 9.1.0 / Gradle 9.3.1。安装相应 Android Rust target，并提供可供 bindgen 使用的 `libclang`。
- Flutter/Android SDK 路径避免空格。环境变量 `JAVA_HOME`、`ANDROID_HOME`、`LIBCLANG_PATH` 指向各自安装目录；NuGet CLI 应在 PATH 中。无需本项目开发者的私有工具路径、原签名或 SDK 副本。

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

Windows 完整输出位于 `apps/flutter_reader/build/windows/x64/runner/Release/`。运行 `AQuantumReader.exe` 时保留同目录 DLL、data 和插件资源；不能只复制 EXE。开发运行也应先 `cargo build --locked -p aq-bridge --release`，再在 Flutter 目录执行 `flutter run -d windows`。

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

## 验证与使用

首次运行测试前，从示例源码生成测试使用的 SDK 包（已经生成的示例无需重复执行；打包器拒绝覆盖既有 ZIP）。Python 3.11+ 只用于此打包步骤，不是应用运行依赖；生成的 dist/ZIP 被忽略：

```powershell
python plugin-sdk/build.py plugin-sdk/examples/headless
python plugin-sdk/build.py plugin-sdk/examples/native
python plugin-sdk/build.py plugin-sdk/examples/html
```

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

应用内选择文件、目录或压缩包，预览后导入，在资料库打开阅读；设置、阅读记录与插件权限在客户端管理。Windows 可用 `AQ_READER_DATA` 指定独立绝对数据目录。卸载或手动操作资料库前先备份。第三方模块以独立 `javascript-v1` ZIP 安装，HTML 页面可选；类型接口见 `plugin-sdk/index.d.ts`，打包用 `python plugin-sdk/build.py --help`，源码示例在 `plugin-sdk/examples`。示例源码不代表已安装功能；OCR、AI、同步等能力不因存在扩展接口而宣称实现。

当前源码来源与第三方声明见 [第三方声明](THIRD_PARTY_NOTICES.md) 和 [PUBLIC_SOURCE.json](PUBLIC_SOURCE.json)。ARM64 实体机和完整设备/格式矩阵仍有验证缺口。

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
| `scripts` | 手动构建、工程锁与版本检查 |

## 反馈与贡献

请通过 [GitHub Issues](https://github.com/SteamDoge/aquantum/issues) 提交问题或建议，注明版本、系统、复现步骤与预期结果；日志及样例请先移除个人资料。欢迎提交聚焦问题的 Pull Request。

## 许可证

本项目原创代码采用 **AGPL-3.0-only**，完整 GNU 官方原文见 [LICENSE](LICENSE)。没有额外的非商用或禁止修改限制。分发修改版以及通过网络向用户提供修改版服务时，应遵守许可证适用的源码提供义务。

第三方代码、依赖及 Flutter 工程模板保留各自原有许可和版权声明。本项目的许可证不改变它们的许可。独立 HTML/JavaScript 插件通过公开的消息接口和权限端口交互；插件作者需为自己的代码、依赖和素材选择适用许可证，不能仅凭使用接口就推定所有第三方插件必须采用 AGPL。实际复制宿主代码或形成衍生作品时，应另行评估相应许可义务。
