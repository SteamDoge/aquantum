# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 AQuantum Reader contributors.
param([switch]$CoreOnly)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'client-lock.ps1')
$rc005PreviousTemp = [Environment]::GetEnvironmentVariable('TEMP', 'Process')
$rc005PreviousTmp = [Environment]::GetEnvironmentVariable('TMP', 'Process')
$rc005CheckRoot = Split-Path -Parent $PSScriptRoot
$rc005CheckTemp = Join-Path $rc005CheckRoot ('target/check-tmp/' + [Guid]::NewGuid().ToString('N'))
$checkCompleted = $false
$checkPreviousLocation = Get-Location
$checkPreviousRustLib = [Environment]::GetEnvironmentVariable('AQ_RUST_LIB', 'Process')
try {
    New-Item -ItemType Directory -Path $rc005CheckTemp -Force | Out-Null
    $env:TEMP = $rc005CheckTemp
    $env:TMP = $rc005CheckTemp
    Set-Location (Split-Path -Parent $PSScriptRoot)

    & node scripts/check-version.mjs
    if ($LASTEXITCODE -ne 0) { throw '版本一致性检查失败' }

    & cargo fmt --all -- --check
    if ($LASTEXITCODE -ne 0) { throw 'Rust 格式检查失败' }
    & cargo test --workspace --locked
    if ($LASTEXITCODE -ne 0) { throw '业务回归失败' }
    & cargo clippy --workspace --all-targets --locked -- -D warnings
    if ($LASTEXITCODE -ne 0) { throw 'Rust 静态检查失败' }

    if (-not $CoreOnly) {
        $repoPath = (Get-Location).Path
        $clientLock = Enter-ReaderClientLock -Root $repoPath
        try {
        $toolFile = Join-Path $repoPath '.tools/toolchains.json'
        $flutterExe = if (Test-Path -LiteralPath $toolFile) { (Get-Content -Raw -LiteralPath $toolFile | ConvertFrom-Json).flutter } else { (Get-Command flutter -ErrorAction Stop).Source }
        & cargo build -p aq-bridge --release --locked
        if ($LASTEXITCODE -ne 0) { throw 'Flutter 原生桥接构建失败' }
        $env:AQ_RUST_LIB = Join-Path $repoPath 'target/release/aq_bridge.dll'
        Push-Location (Join-Path $repoPath 'apps/flutter_reader')
        try {
            & $flutterExe analyze --no-pub
            if ($LASTEXITCODE -ne 0) { throw 'Flutter 静态分析失败' }
            & (Join-Path (Split-Path -Parent $flutterExe) 'dart.bat') format --output=none --set-exit-if-changed lib test integration_test test_driver
            if ($LASTEXITCODE -ne 0) { throw 'Dart 格式检查失败' }
            & $flutterExe test --no-pub
            if ($LASTEXITCODE -ne 0) { throw 'Flutter 界面/真实 FFI 回归失败' }
        } finally { Pop-Location }
        } finally { $clientLock.Dispose() }
    }
    $checkCompleted = $true
} finally {
    Set-Location $checkPreviousLocation
    [Environment]::SetEnvironmentVariable('AQ_RUST_LIB', $checkPreviousRustLib, 'Process')
    [Environment]::SetEnvironmentVariable('TEMP', $rc005PreviousTemp, 'Process')
    [Environment]::SetEnvironmentVariable('TMP', $rc005PreviousTmp, 'Process')
    # Successful scratch can be regenerated; failures stay available to inspect.
    if ($checkCompleted) { Remove-ReaderCompletedTemp -Root $rc005CheckRoot -Path $rc005CheckTemp }
}
