<div align="center">

<img src="design-system/app-icon.png" alt="AQuantum Reader" width="96">

# AQuantum Reader

**Every book, one place to read.**

A local reader for Android and Windows · Flutter UI · Rust core

[![Release](https://img.shields.io/github/v/release/SteamDoge/aquantum?include_prereleases&style=flat-square&label=release)](https://github.com/SteamDoge/aquantum/releases) [![Downloads](https://img.shields.io/github/downloads/SteamDoge/aquantum/total?style=flat-square&logo=github)](https://github.com/SteamDoge/aquantum/releases) [![License](https://img.shields.io/badge/license-AGPL--3.0--only-00AEEF?style=flat-square)](LICENSE)<br>
![Android](https://img.shields.io/badge/Android-3DDC84?logo=android&logoColor=white) ![Windows](https://img.shields.io/badge/Windows-0078D4?logo=windows&logoColor=white)

**[Download](#download)** &nbsp;·&nbsp; **[Features](#features)** &nbsp;·&nbsp; **[Getting started](#getting-started)** &nbsp;·&nbsp; **[Build from source](#build-from-source)** &nbsp;·&nbsp; **[Issues](https://github.com/SteamDoge/aquantum/issues)**

**English** · [简体中文](README.zh-CN.md)

</div>

## Is AQuantum Reader for you?

Books tend to end up in different apps: novels in one, comics in another, PDFs and EPUBs somewhere else, each with its own progress and settings. AQuantum Reader keeps them in one local library on your phone or PC:

- **Read many formats in one app**: text, Markdown, images and comics, PDF, EPUB, MOBI, AZW3 and FB2.
- **Keep your files as they are**: importing copies a file into the library; the original is never changed.
- **No account, works offline**: your library, progress and notes stay on your device.
- **Add what you need**: install JavaScript plugins for extra pages and tools.

It's for you if you read local files in several formats and want them in one place. If you depend on a store's cloud library or need sync between devices, it doesn't do that yet. Runs on Android 7.0+ and Windows 10/11 x64.

## Features

- **Local reading**: no sign-in, works offline; importing copies the file and leaves the original untouched.
- **Many formats**: text, images/comics, PDF, Markdown, EPUB, MOBI, AZW3, FB2 and more, each laid out according to what the format supports.
- **Pick up where you left off**: reading position, bookmarks and notes are saved; manage the library and local backups.
- **One reading experience**: continuous scrolling or page-by-page, four color schemes with light and dark themes, layouts for phones and desktops.
- **Plugins**: install JavaScript modules through the `javascript-v1` plugin interface, with optional HTML pages; network access depends on the plugin and the permissions it declares.
- **Open source**: original code under **AGPL-3.0-only**; third-party licenses and notices are kept intact.

Having a plugin interface does not mean OCR, AI or cloud sync are built in; they are not. Book metadata search and networked plugins need an internet connection.

## Download

Current version: [**RC015 · rc.0.0.15**](https://github.com/SteamDoge/aquantum/releases/tag/rc.0.0.15). See [all releases](https://github.com/SteamDoge/aquantum/releases) for changes and packages.

| Platform | Download | Which one |
| --- | --- | --- |
| Android 7.0+ (API 24+) | [![APK ARM64](https://img.shields.io/badge/APK-ARM64-3DDC84?logo=android&logoColor=white)](https://github.com/SteamDoge/aquantum/releases/download/rc.0.0.15/AQuantumReader-rc.0.0.15-android-arm64.apk) | Most phones |
| Android x86_64 | [![APK x64](https://img.shields.io/badge/APK-x64-168039?logo=android&logoColor=white)](https://github.com/SteamDoge/aquantum/releases/download/rc.0.0.15/AQuantumReader-rc.0.0.15-android-x64.apk) | x86_64 devices and emulators |
| Windows 10/11 x64 | [![Portable x64](https://img.shields.io/badge/Portable-x64-00AEEF)](https://github.com/SteamDoge/aquantum/releases/download/rc.0.0.15/AQuantumReader-rc.0.0.15-windows-x64.zip) | Extract the whole folder and run `AQuantumReader.exe` |
| Plugin development | [SDK source and examples](https://github.com/SteamDoge/aquantum/releases/download/rc.0.0.15/AQuantumReader-rc.0.0.15-plugin-sdk.zip) | A developer tool, not an installed feature module |

<sub>Reading EPUB and similar documents on Windows requires the Microsoft Edge WebView2 Runtime. There are no Linux, macOS, iOS or Windows ARM64 packages yet. ARM64 physical devices and the full GUI, device and format matrix have not been fully verified.</sub>

## Getting started

**1 · Install.** On Android, install the APK for your device. On Windows, extract the portable ZIP and keep the DLLs, `data` and plugin resources next to the EXE; copying only the EXE won't work.

**2 · Import.** Choose files, a folder or an archive, preview them, then import them into the library.

**3 · Read.** Open a book, then adjust the color scheme and reading preferences in settings.

Back up the library before upgrading or changing it by hand. Upgrading an existing Android install needs a matching signature; if your own build is signed differently, export a backup first. Don't uninstall in place of making a backup.

## Build from source

<details>
<summary>Show requirements, build commands and tests</summary>

### Requirements

This version was verified with Rust **1.98.1** and Flutter **3.47.7 stable / Dart 3.13.5**. Dependency versions are locked in `Cargo.lock` and `apps/flutter_reader/pubspec.lock`; install the SDKs first, then restore dependencies. The first build needs network access to fetch dependencies and the PDFium native library.

- Windows: Windows 10/11 x64, Visual Studio with the Desktop development with C++ workload, CMake, NuGet CLI and PowerShell. Reading EPUB and similar documents needs the Microsoft Edge WebView2 Runtime.
- Android: JDK 21, Android SDK 36, NDK **28.2.13676358**, CMake 3.22.1; the project pins AGP 9.1.0 / Gradle 9.3.1. Install the Android Rust targets and provide a `libclang` that bindgen can use.
- Avoid spaces in the Flutter and Android SDK paths. Point `JAVA_HOME`, `ANDROID_HOME` and `LIBCLANG_PATH` at their install directories and put the NuGet CLI on `PATH`. No private tool paths, original signing keys or SDK copies from the maintainers are needed.

### Build

```powershell
git clone git@github.com:SteamDoge/aquantum.git
cd aquantum
cargo fetch --locked
Push-Location apps/flutter_reader
flutter pub get --enforce-lockfile
Pop-Location

# Windows: the script builds the Rust bridge first, then Flutter
powershell -ExecutionPolicy Bypass -File scripts/build-client.ps1 -Platform windows

# Or only the core command line (builds on any platform Rust supports)
cargo run --locked -p aq-cli -- --help
```

The complete Windows output is in `apps/flutter_reader/build/windows/x64/runner/Release/`. Keep the DLLs, `data` and plugin resources next to `AQuantumReader.exe`; copying only the EXE won't work. For development runs, also build `cargo build --locked -p aq-bridge --release` first, then run `flutter run -d windows` in the Flutter directory.

### Android signing

Before an Android release build, create and safely store your own signing key, then add the git-ignored `apps/flutter_reader/android/key.properties`:

```properties
storeFile=C:/private/your-release-key.jks
storePassword=YOUR_LOCAL_STORE_PASSWORD
keyAlias=YOUR_KEY_ALIAS
keyPassword=YOUR_LOCAL_KEY_PASSWORD
```

These placeholders are not real credentials. Never commit this file or the key. A package signed with your key can't be installed over a version signed with a different key; back up through the app first if you want to keep your data.

```powershell
rustup target add aarch64-linux-android x86_64-linux-android
powershell -ExecutionPolicy Bypass -File scripts/build-client.ps1 -Platform android -AndroidX64
```

APKs are written to `apps/flutter_reader/build/app/outputs/flutter-apk/`. Without `-AndroidX64` only ARM64 is built. The script builds the JNI libraries and checks the R8 keep rules for JNI; a release package still needs an install test. Run all client builds and tests one at a time. Release builds don't use `--no-pub`, so the plugin registrant is regenerated correctly. Flutter recreates the git-ignored Gradle wrapper scripts and local SDK path file.

### Tests

Before the first test run, build the SDK example packages the tests use (skip examples that are already built; the packager refuses to overwrite an existing ZIP). Python 3.11+ is only needed for this packaging step, not to run the app; the generated `dist/` ZIPs are git-ignored:

```powershell
python plugin-sdk/build.py plugin-sdk/examples/headless
python plugin-sdk/build.py plugin-sdk/examples/native
python plugin-sdk/build.py plugin-sdk/examples/html
```

Full check (version consistency, Rust format/tests/lints, Flutter analysis/format/tests):

```powershell
powershell -ExecutionPolicy Bypass -File scripts/check.ps1
```

Or step by step:

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

Native integration tests live in `apps/flutter_reader/integration_test`. Run them with `scripts/test-native.ps1` on Windows or a chosen Android device; they create a separate QA library and never touch personal data. On Windows, `AQ_READER_DATA` can point the app at a separate absolute data directory.

Third-party plugins are installed as standalone `javascript-v1` ZIPs, with optional HTML pages. The type definitions are in `plugin-sdk/index.d.ts`, packaging help is at `python plugin-sdk/build.py --help`, and source examples are in `plugin-sdk/examples`. The examples are not installed features.

</details>

## Project structure

| Path | Responsibility |
| --- | --- |
| `apps/flutter_reader` | Flutter UI, platform projects and document engine resources |
| `crates/domain` | Core rules |
| `crates/application` | Operations layer and storage ports |
| `crates/local` | SQLite, managed resources and the file system |
| `crates/bridge` | JSON C ABI and the QuickJS plugin runtime |
| `apps/cli` | Core command-line entry point |
| `plugin-sdk` | Runtime, type definitions, packaging script and minimal examples |
| `scripts` | Build, full check, native tests, test fixture generation and license inventory |

## Privacy

AQuantum Reader needs no account and collects no usage statistics or crash reports. Your library, reading progress, notes and settings stay on your device. The app only goes online when you use one of these features:

| | |
| :-- | :-- |
| **Book metadata search** | Only when you search on a book's info page. The title, author or ISBN you typed is sent to [Open Library](https://openlibrary.org); cover images come from Open Library's servers. |
| **Installing a plugin from a link** | Downloads from the GitHub repository, release page or HTTPS ZIP you entered; GitHub releases are looked up through `api.github.com`. If your DNS returns VPN fake-IP addresses, the host name is resolved through Google Public DNS (`dns.google`). |
| **Plugins** | A plugin can make HTTPS requests only if it declares the network permission. What it sends is up to the plugin, so check its permissions and source before installing it. |

## Feedback and contributing

Report problems or ideas in [GitHub Issues](https://github.com/SteamDoge/aquantum/issues). Include the version, system, steps to reproduce and what you expected; remove personal data from logs and samples first. Focused pull requests are welcome: start new original source files with `SPDX-License-Identifier: AGPL-3.0-only` and the copyright line, and run `scripts/check.ps1` before submitting.

If AQuantum Reader is useful to you, a ⭐ helps others find it.

## License

The original code of this project is licensed under **AGPL-3.0-only**; the full official GNU text is in [LICENSE](LICENSE). There are no extra non-commercial or no-modification restrictions. If you distribute a modified version, or offer one to users over a network, follow the license's source-code obligations.

Third-party code, dependencies and Flutter project templates keep their own licenses and copyright notices (see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)); this project's license does not change them. Standalone HTML/JavaScript plugins interact through the public message interface and permission ports. Plugin authors choose the licenses for their own code, dependencies and assets; using the interface alone does not mean every third-party plugin must use the AGPL. Copying host code or creating a derivative work needs its own license assessment.
