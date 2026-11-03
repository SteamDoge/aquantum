# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 AQuantum Reader contributors.
param(
    [ValidateSet('windows','android','all')][string]$Platform = 'all',
    [string]$Flutter = '',
    [switch]$AndroidX64
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot
. (Join-Path $PSScriptRoot 'client-lock.ps1')
$clientLock = Enter-ReaderClientLock -Root $repoRoot
$restoreTemp = Enter-ReaderIsolatedTemp -Root $repoRoot
$buildCompleted = $false
$previousBuildPath = $env:PATH
try {
$toolchainFile = Join-Path $repoRoot '.tools/toolchains.json'
$toolchains = if (Test-Path -LiteralPath $toolchainFile) { Get-Content -Raw -LiteralPath $toolchainFile | ConvertFrom-Json } else { $null }
if (-not $Flutter) {
    $Flutter = if ($toolchains) { $toolchains.flutter } else { (Get-Command flutter -ErrorAction Stop).Source }
}
if (-not (Test-Path -LiteralPath $Flutter)) { throw 'Flutter SDK not found; supply -Flutter <flutter.bat>' }
if ($toolchains -and $toolchains.pubCache) { $env:PUB_CACHE = $toolchains.pubCache }
if ($toolchains -and $toolchains.java) { $env:JAVA_HOME = $toolchains.java }
if ($toolchains -and $toolchains.nuget -and (Test-Path -LiteralPath $toolchains.nuget)) {
    $env:PATH = (Split-Path -Parent $toolchains.nuget) + ';' + $env:PATH
}
$flutterProject = Join-Path $repoRoot 'apps/flutter_reader'

# Flutter needs links to plugin sources. Junctions keep this workspace buildable
# without changing the machine's Developer Mode or requesting administrator rights.
Push-Location $flutterProject
try {
    & $Flutter pub get
    $pubResult = $LASTEXITCODE
    $pluginsFile = Join-Path $flutterProject '.flutter-plugins-dependencies'
    if (Test-Path -LiteralPath $pluginsFile) {
        $plugins = Get-Content -Raw -LiteralPath $pluginsFile | ConvertFrom-Json
        $linkRoot = Join-Path $flutterProject 'windows/flutter/ephemeral/.plugin_symlinks'
        New-Item -ItemType Directory -Path $linkRoot -Force | Out-Null
        foreach ($plugin in $plugins.plugins.windows) {
            $link = Join-Path $linkRoot $plugin.name
            if (-not (Test-Path -LiteralPath $link)) { New-Item -ItemType Junction -Path $link -Target $plugin.path | Out-Null }
        }
        if ($pubResult -ne 0) {
            & $Flutter pub get
            if ($LASTEXITCODE -ne 0) { throw 'Flutter dependency preparation failed' }
        }
    } elseif ($pubResult -ne 0) { throw 'Flutter dependency resolution failed' }
} finally { Pop-Location }

if ($Platform -in @('windows','all')) {
    & cargo build -p aq-bridge --release --locked
    if ($LASTEXITCODE -ne 0) { throw 'Windows Rust bridge build failed' }
    Push-Location $flutterProject
    try {
        # Do not use --no-pub here: Flutter 3.47 also skips release plugin
        # regeneration with that flag, leaving dev-only native test plugins.
        & $Flutter build windows --release
        if ($LASTEXITCODE -ne 0) { throw 'Windows Flutter build failed' }
    } finally { Pop-Location }
}
if ($Platform -in @('android','all')) {
    if ($toolchains -and $toolchains.androidSdk) { $env:ANDROID_HOME = $toolchains.androidSdk }
    if (-not $env:ANDROID_HOME) { throw 'Set ANDROID_HOME to an installed SDK path without spaces' }
    $env:NDK_HOME = Join-Path $env:ANDROID_HOME 'ndk/28.2.13676358'
    if (-not (Test-Path -LiteralPath $env:NDK_HOME)) { throw 'Android NDK 28.2.13676358 is required (matches Flutter native plugins)' }
    if (-not (Test-Path -LiteralPath (Join-Path $flutterProject 'android/key.properties'))) {
        throw 'RC signing configuration is missing; preserve/restore the local signing key before building releases'
    }
    $abis = @(@{ rust='aarch64-linux-android'; clang='aarch64-linux-android24-clang.cmd'; folder='arm64-v8a'; flutter='android-arm64' })
    if ($AndroidX64) { $abis += @{ rust='x86_64-linux-android'; clang='x86_64-linux-android24-clang.cmd'; folder='x86_64'; flutter='android-x64' } }
    $ndkBin = Join-Path $env:NDK_HOME 'toolchains/llvm/prebuilt/windows-x86_64/bin'
    # QuickJS Android bindings are generated with libclang. Keep this optional
    # tool local to the workspace; never modify the system compiler setup.
    $localClang = Join-Path $repoRoot '.tools/plugin-libclang/clang/native'
    if (-not $env:LIBCLANG_PATH -and (Test-Path -LiteralPath (Join-Path $localClang 'libclang.dll'))) { $env:LIBCLANG_PATH = $localClang }
    if (-not $env:LIBCLANG_PATH) { throw 'Set LIBCLANG_PATH to a libclang directory for QuickJS Android bindgen' }
    $ndkClangRoot = (Split-Path -Parent $ndkBin).Replace('\','/')
    $clangResource = Get-ChildItem -LiteralPath "$ndkClangRoot/lib/clang" -Directory | Select-Object -First 1
    foreach ($abi in $abis) {
        $targetKey = $abi.rust.ToUpper().Replace('-','_')
        Set-Item -Path "Env:CARGO_TARGET_${targetKey}_LINKER" -Value (Join-Path $ndkBin $abi.clang)
        $ccKey = $abi.rust.Replace('-','_')
        Set-Item -Path "Env:CC_$ccKey" -Value (Join-Path $ndkBin $abi.clang)
        Set-Item -Path "Env:AR_$ccKey" -Value (Join-Path $ndkBin 'llvm-ar.exe')
        Set-Item -Path "Env:BINDGEN_EXTRA_CLANG_ARGS_$ccKey" -Value "--target=$($abi.rust)24 --sysroot=$ndkClangRoot/sysroot -resource-dir=$ndkClangRoot/lib/clang/$($clangResource.Name)"
        & cargo build -p aq-bridge --target $abi.rust --release --locked
        if ($LASTEXITCODE -ne 0) { throw "Rust Android build failed: $($abi.rust)" }
        $jni = Join-Path $flutterProject "android/app/src/main/jniLibs/$($abi.folder)"
        New-Item -ItemType Directory -Path $jni -Force | Out-Null
        Copy-Item -LiteralPath "target/$($abi.rust)/release/libaq_bridge.so" -Destination (Join-Path $jni 'libaq_bridge.so')
    }
    Push-Location $flutterProject
    try {
        $platforms = ($abis | ForEach-Object { $_.flutter }) -join ','
        & $Flutter build apk --release "--target-platform=$platforms" --split-per-abi
        if ($LASTEXITCODE -ne 0) { throw 'Android Flutter APK build failed' }
        # JNI reflection is invisible to R8. Verify the actual minified output,
        # not only source annotations; device Release smoke testing is still required.
        $mapping = Get-Content -Raw -LiteralPath 'build/app/outputs/mapping/release/mapping.txt'
        foreach ($runtimeType in @('io.flutter.plugins.sharedpreferences.SharedPreferencesApiRegistrar','kotlin.coroutines.Continuation','kotlin.coroutines.intrinsics.CoroutineSingletons','kotlin.coroutines.intrinsics.IntrinsicsKt','kotlin.Result','kotlin.Result$Failure','kotlin.Unit')) {
            $escaped = [regex]::Escape($runtimeType)
            if ($mapping -notmatch "(?m)^$escaped -> ${escaped}:\r?$") {
                throw "Release JNI runtime contract was removed or renamed: $runtimeType"
            }
        }
    } finally { Pop-Location }
}
$buildCompleted = $true
} finally { $env:PATH = $previousBuildPath; & $restoreTemp -Succeeded:$buildCompleted; $clientLock.Dispose() }
