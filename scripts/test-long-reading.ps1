# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 AQuantum Reader contributors.
param(
    [Parameter(Mandatory=$true)][string]$Fixtures,
    [Parameter(Mandatory=$true)][string]$Mobi,
    [string]$Formats = 'Txt,Markdown,Comic,Pdf,Epub,Fb2,Mobi',
    [switch]$DebugRun
)
$ErrorActionPreference = 'Stop'
$longRoot = Split-Path -Parent $PSScriptRoot
Set-Location $longRoot
. (Join-Path $PSScriptRoot 'client-lock.ps1')
$longLock = Enter-ReaderClientLock -Root $longRoot
$restoreTemp = Enter-ReaderIsolatedTemp -Root $longRoot
$names = @('AQ_LONG_FIXTURES','AQ_LONG_MOBI','AQ_LONG_FORMATS','AQ_LONG_RESULTS','AQ_TEST_SUPPORT','AQ_RUST_LIB','NO_PROXY','NUGET_SCRATCH','NUGET_PACKAGES','NUGET_HTTP_CACHE_PATH')
$previous = @{}
foreach ($name in $names) { $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
try {
    $config = Get-Content -Raw .tools/toolchains.json | ConvertFrom-Json
    $run = Join-Path $longRoot ('output/long-reading-run-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $run | Out-Null
    $env:AQ_LONG_FIXTURES = (Resolve-Path -LiteralPath $Fixtures).Path
    $env:AQ_LONG_MOBI = (Resolve-Path -LiteralPath $Mobi).Path
    $env:AQ_LONG_FORMATS = $Formats
    $env:AQ_LONG_RESULTS = Join-Path $run 'driver-results.json'
    $env:AQ_TEST_SUPPORT = Join-Path $run 'support'
    $env:AQ_RUST_LIB = Join-Path $longRoot 'target/release/aq_bridge.dll'
    if (-not (Test-Path -LiteralPath $env:AQ_RUST_LIB)) { throw 'Build aq-bridge --release first' }
    $env:NO_PROXY = '127.0.0.1,localhost,::1'
    $env:NUGET_SCRATCH = Join-Path $run 'nuget-scratch'
    # Enter-ReaderIsolatedTemp already selects the configured shared packages.
    # Keep only request scratch specific to this validation run.
    $env:NUGET_HTTP_CACHE_PATH = Join-Path $run 'nuget-http'
    Write-Output "LONG_RUN: $run"
    # Same workspace-only junction strategy as build-client.ps1 after cleanup.
    $project = Join-Path $longRoot 'apps/flutter_reader'
    $plugins = Get-Content -Raw (Join-Path $project '.flutter-plugins-dependencies') | ConvertFrom-Json
    $linkRoot = Join-Path $project 'windows/flutter/ephemeral/.plugin_symlinks'
    New-Item -ItemType Directory -Path $linkRoot -Force | Out-Null
    foreach ($plugin in $plugins.plugins.windows) {
        $link = Join-Path $linkRoot $plugin.name
        if (-not (Test-Path -LiteralPath $link)) { New-Item -ItemType Junction -Path $link -Target $plugin.path | Out-Null }
    }
    Push-Location apps/flutter_reader
    try {
        if ($DebugRun) {
            & $config.flutter test integration_test/long_reading_flow_test.dart -d windows
        } else {
            & $config.flutter drive --profile -d windows --no-dds --driver=test_driver/long_reading_driver.dart --target=integration_test/long_reading_flow_test.dart
        }
        if ($LASTEXITCODE -ne 0) { throw 'Long reading flow failed; inspect per-format results and retained QA files' }
    } finally { Pop-Location }
} finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process') }
    & $restoreTemp
    $longLock.Dispose()
}
