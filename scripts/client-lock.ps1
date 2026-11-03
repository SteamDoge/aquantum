# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 AQuantum Reader contributors.
function Enter-ReaderClientLock {
    param([string]$Root)
    $lockFolder = Join-Path $Root '.tools'
    New-Item -ItemType Directory -Path $lockFolder -Force | Out-Null
    try {
        # File sharing enforces one owner even through Windows short-path aliases.
        return [System.IO.File]::Open((Join-Path $lockFolder 'flutter-build.lock'), [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    } catch [System.IO.IOException] {
        throw 'Another Flutter build or check owns this generated project. Wait for that operation to finish; do not run platform builds in parallel.'
    }
}

function Remove-ReaderCompletedTemp {
    param([string]$Root, [string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $expectedParent = [System.IO.Path]::GetFullPath((Join-Path $Root 'target/check-tmp')).TrimEnd('\')
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Parent.FullName.TrimEnd('\') -ine $expectedParent -or
        $item.Name -notmatch '^[a-f0-9]{32}$' -or
        ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        throw "Refusing scratch cleanup outside the expected run directory: $Path"
    }
    if (Get-ChildItem -LiteralPath $item.FullName -Force -Recurse -Attributes ReparsePoint -ErrorAction Stop) {
        Write-Warning "Scratch contains reparse points; retained: $Path"
        return
    }
    Remove-Item -LiteralPath $item.FullName -Recurse -Force
}

# Same rule as check.ps1 (ADR-020): each run gets its own TEMP/TMP so tools such as
# NuGet never depend on lock files another user or sandbox left in the shared temp
# folder. Returns a script block that restores the previous values; the run
# directory is retained on failure or when the caller does not mark success.
function Enter-ReaderIsolatedTemp {
    param([string]$Root)
    $previousTemp = [Environment]::GetEnvironmentVariable('TEMP', 'Process')
    $previousTmp = [Environment]::GetEnvironmentVariable('TMP', 'Process')
    $previousNugetHttp = [Environment]::GetEnvironmentVariable('NUGET_HTTP_CACHE_PATH', 'Process')
    $previousNugetPackages = [Environment]::GetEnvironmentVariable('NUGET_PACKAGES', 'Process')
    $runTemp = Join-Path $Root ('target/check-tmp/' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $runTemp -Force | Out-Null
    $env:TEMP = $runTemp
    $env:TMP = $runTemp
    $env:NUGET_HTTP_CACHE_PATH = Join-Path $runTemp 'nuget-http'
    # NuGet supports concurrent consumers of its global package cache. Keep the
    # HTTP scratch isolated, but do not duplicate packages in each worktree.
    $configFile = Join-Path $Root '.tools/toolchains.json'
    $config = if (Test-Path -LiteralPath $configFile) { Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json } else { $null }
    $env:NUGET_PACKAGES = if ($previousNugetPackages) { $previousNugetPackages } elseif ($config -and $config.nugetPackages) { $config.nugetPackages } else { Join-Path $env:USERPROFILE '.nuget/packages' }
    # GetNewClosure creates a dynamic module. Capture the cleanup implementation
    # as a value; resolving its parent-scope function name later can fail when
    # build-client.ps1 returns through its finally block.
    $cleanupCompletedTemp = ${function:Remove-ReaderCompletedTemp}
    return {
        param([switch]$Succeeded)
        foreach ($setting in @(
            @{ name='TEMP'; value=$previousTemp }, @{ name='TMP'; value=$previousTmp },
            @{ name='NUGET_HTTP_CACHE_PATH'; value=$previousNugetHttp },
            @{ name='NUGET_PACKAGES'; value=$previousNugetPackages }
        )) {
            if ($null -eq $setting.value) { Remove-Item -LiteralPath "Env:$($setting.name)" -ErrorAction SilentlyContinue }
            else { [Environment]::SetEnvironmentVariable($setting.name, $setting.value, 'Process') }
        }
        # Only this successful invocation's scratch is disposable. Failed runs
        # and directories containing reparse points remain for manual review.
        if ($Succeeded) { & $cleanupCompletedTemp -Root $Root -Path $runTemp }
    }.GetNewClosure()
}
