# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 AQuantum Reader contributors.
param([string]$Fixtures = 'output/rc005-pdf-fixtures')
$ErrorActionPreference = 'Stop'
$rc005Root = Split-Path -Parent $PSScriptRoot
Set-Location $rc005Root
. (Join-Path $PSScriptRoot 'client-lock.ps1')
$rc005Lock = Enter-ReaderClientLock -Root $rc005Root
$rc005Names = @('TEMP','TMP','NO_PROXY','PUB_CACHE','AQ_RUST_LIB','AQ_PDF_FIXTURES','AQ_PDF_RESULTS','AQ_TEST_SUPPORT')
$rc005Previous = @{}
foreach ($name in $rc005Names) { $rc005Previous[$name] = [Environment]::GetEnvironmentVariable($name,'Process') }
try {
    $config = Get-Content -Raw .tools/toolchains.json | ConvertFrom-Json
    $env:TEMP = Join-Path $rc005Root ('target/perf-tmp/' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $env:TEMP | Out-Null
    $env:TMP = $env:TEMP
    $env:NO_PROXY = 'localhost,127.0.0.1,::1' + $(if($rc005Previous['NO_PROXY']) { ',' + $rc005Previous['NO_PROXY'] } else { '' })
    if ($config.pubCache) { $env:PUB_CACHE = $config.pubCache }
    $env:AQ_RUST_LIB = Join-Path $rc005Root 'target/release/aq_bridge.dll'
    $env:AQ_TEST_SUPPORT = Join-Path $env:TEMP 'support'
    $env:AQ_PDF_FIXTURES = (Resolve-Path -LiteralPath $Fixtures).Path
    $env:AQ_PDF_RESULTS = Join-Path $rc005Root ('output/rc005-pdf-profile-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
    if(Test-Path -LiteralPath $env:AQ_PDF_RESULTS) {throw 'Result already exists'}
    Push-Location apps/flutter_reader
    try {
        & $config.flutter drive --profile -d windows --host-vmservice-port=59765 --no-dds --driver=test_driver/rc005_perf_driver.dart --target=integration_test/rc005_pdf_perf_test.dart
        if($LASTEXITCODE -ne 0) {throw 'PDF profile run failed'}
    } finally {Pop-Location}
    Write-Output "PDF measurements: $env:AQ_PDF_RESULTS"
} finally {
    foreach ($name in $rc005Names) { [Environment]::SetEnvironmentVariable($name,$rc005Previous[$name],'Process') }
    $rc005Lock.Dispose()
}
