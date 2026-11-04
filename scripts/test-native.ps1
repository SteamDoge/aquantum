# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 AQuantum Reader contributors.
param(
    [ValidateSet('windows','android')][string]$Platform = 'windows',
    [string]$Device = '',
    [string]$TestFile = 'integration_test/native_flow_test.dart',
    [string]$DefineFile = '',
    [string[]]$PluginPackages = @(),
    [switch]$FlutterVerbose
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'client-lock.ps1')
$clientLock = Enter-ReaderClientLock -Root $repoRoot
$restoreTemp = Enter-ReaderIsolatedTemp -Root $repoRoot
$fixtureFile = Join-Path $repoRoot 'apps/flutter_reader/integration_test/plugin_runtime_fixtures.dart'
$fixtureOriginal = if (Test-Path -LiteralPath $fixtureFile) { [IO.File]::ReadAllBytes($fixtureFile) } else { $null }
try {
    if ($PluginPackages.Count -gt 0) {
        if ($PluginPackages.Count -ne 2) { throw 'Supply bookstore and JMComic ZIPs in that order' }
        $payloads = @($PluginPackages | ForEach-Object { "'" + [Convert]::ToBase64String([IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $_).Path)) + "'" })
        [IO.File]::WriteAllText($fixtureFile, 'const externalPluginZipBase64 = <String>[' + ($payloads -join ',') + '];', (New-Object Text.UTF8Encoding($false)))
    }
    $toolFile = Join-Path $repoRoot '.tools/toolchains.json'
    $config = if (Test-Path -LiteralPath $toolFile) { Get-Content -Raw -LiteralPath $toolFile | ConvertFrom-Json } else { $null }
    $flutter = if ($config) { $config.flutter } else { (Get-Command flutter -ErrorAction Stop).Source }
    if ($config -and $config.pubCache) { $env:PUB_CACHE = $config.pubCache }
    if ($config) { $env:JAVA_HOME=$config.java; $env:ANDROID_HOME=$config.androidSdk }
    if ($Platform -eq 'windows') {
        $env:AQ_RUST_LIB = Join-Path $repoRoot 'target/release/aq_bridge.dll'
        if (-not (Test-Path -LiteralPath $env:AQ_RUST_LIB)) { throw 'Build the Windows Rust bridge first' }
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $env:AQ_SCREENSHOT_DIR = Join-Path $repoRoot ('output/native/windows/' + $stamp)
        # Real on-disk preferences and app support, isolated from the user's AppData.
        $env:AQ_TEST_SUPPORT = Join-Path $repoRoot ('output/native/windows/' + $stamp + '-support')
        if (-not $Device) { $Device = 'windows' }
    } else {
        if (-not $Device) { throw 'Supply the explicit Android device serial with -Device' }
        # Flutter may consult the release manifest identity before building the
        # suffixed debug APK. A suffix alone does not protect an installed release.
        $adb = if ($config) { Join-Path $config.androidSdk 'platform-tools/adb.exe' } else { (Get-Command adb -ErrorAction Stop).Source }
        $installed = & $adb -s $Device shell pm list packages -u 'cn.aquantum.aquantum_reader.plugins'
        if ($LASTEXITCODE -ne 0) { throw 'Cannot verify Android release isolation; native QA refused' }
        if ($installed -contains 'package:cn.aquantum.aquantum_reader.plugins') {
            throw 'Native QA refused: this device contains the signed release or retained release data. Use a dedicated QA device without the release; never uninstall or clear user data for this test.'
        }
        Remove-Item Env:AQ_RUST_LIB -ErrorAction SilentlyContinue
        Remove-Item Env:AQ_SCREENSHOT_DIR -ErrorAction SilentlyContinue
        Remove-Item Env:AQ_TEST_SUPPORT -ErrorAction SilentlyContinue
    }
    Push-Location (Join-Path $repoRoot 'apps/flutter_reader')
    try {
        $captures = @{}
        $pluginTestArgs = @('test', $TestFile, '-d', $Device)
        if ($FlutterVerbose) { $pluginTestArgs += '--verbose' }
        if ($DefineFile) { $pluginTestArgs += ('--dart-define-from-file=' + (Resolve-Path -LiteralPath $DefineFile).Path) }
        & $flutter @pluginTestArgs | ForEach-Object {
            if ($_ -match 'QA_IMAGE:([a-z-]+):([A-Za-z0-9+/=]+)') {
                $captureName=$Matches[1]
                if (-not $captures.ContainsKey($captureName)) { $captures[$captureName] = New-Object System.Text.StringBuilder }
                [void]$captures[$captureName].Append($Matches[2])
            } else { Write-Output $_ }
        }
        $testResult = $LASTEXITCODE
        if ($captures.Count -gt 0) {
            $captureRoot = Join-Path $repoRoot ('output/native/android/' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
            New-Item -ItemType Directory -Path $captureRoot | Out-Null
            foreach ($captureName in $captures.Keys) {
                [System.IO.File]::WriteAllBytes((Join-Path $captureRoot "$captureName.png"), [Convert]::FromBase64String($captures[$captureName].ToString()))
            }
            Write-Output "Native screenshots: $captureRoot"
        }
        if ($testResult -ne 0) { throw 'Native Flutter and Rust integration test failed' }
    } finally { Pop-Location }
} finally {
    if ($null -ne $fixtureOriginal) { [IO.File]::WriteAllBytes($fixtureFile, $fixtureOriginal) }
    & $restoreTemp; $clientLock.Dispose()
}
