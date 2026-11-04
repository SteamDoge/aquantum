# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 AQuantum Reader contributors.
param(
    [string]$Avd = 'AQuantumReaderRC3',
    [ValidateRange(5554,5682)][int]$Port = 5580,
    [string]$AvdHome = '',
    [switch]$ShowWindow,
    [switch]$Background,
    [ValidateSet('swangle','swiftshader','software','host')][string]$Gpu = 'host',
    [switch]$EnableVulkan,
    [ValidateRange(15,600)][int]$BootTimeoutSeconds = 180
)
$ErrorActionPreference = 'Stop'
$rc005Root = Split-Path -Parent $PSScriptRoot
$config = Get-Content -LiteralPath (Join-Path $rc005Root '.tools/toolchains.json') -Raw | ConvertFrom-Json
if (-not $config.androidSdk) { throw 'Configure androidSdk in .tools/toolchains.json first' }
if ($Port % 2) { throw 'Emulator console port must be even' }
if (-not $AvdHome) { $AvdHome = Join-Path (Split-Path -Parent $config.androidSdk) 'avd' }
$AvdHome = (Resolve-Path -LiteralPath $AvdHome).Path
if (-not (Test-Path -LiteralPath (Join-Path $AvdHome "$Avd.ini"))) { throw 'Requested AVD is missing; no AVD will be created or reset' }
$runtime = Join-Path $rc005Root ('.tools/emulator-runs/' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $runtime | Out-Null
$names = @('TEMP','TMP','TMPDIR','ANDROID_TMP','NETSIM_ARTIFACTS_DIR','LOCALAPPDATA','ANDROID_HOME','ANDROID_AVD_HOME','ANDROID_USER_HOME','ANDROID_EMULATOR_HOME','NO_PROXY')
$previous = @{}
foreach ($name in $names) { $previous[$name] = [Environment]::GetEnvironmentVariable($name,'Process') }
try {
    $env:TEMP=$runtime; $env:TMP=$runtime; $env:TMPDIR=$runtime; $env:ANDROID_TMP=$runtime
    # netsim uses TMPDIR for discovery/locks, independently of TEMP and TMP.
    $env:NETSIM_ARTIFACTS_DIR=Join-Path $runtime 'netsim-artifacts'
    $env:LOCALAPPDATA=Join-Path $runtime 'local'
    $env:ANDROID_HOME=$config.androidSdk
    $env:ANDROID_AVD_HOME=$AvdHome
    $env:ANDROID_USER_HOME=Join-Path $runtime 'user'
    $env:ANDROID_EMULATOR_HOME=$env:ANDROID_USER_HOME
    $env:NO_PROXY='localhost,127.0.0.1,::1' + $(if($previous['NO_PROXY']) { ',' + $previous['NO_PROXY'] } else { '' })
    New-Item -ItemType Directory -Path $env:LOCALAPPDATA,$env:ANDROID_USER_HOME,$env:NETSIM_ARTIFACTS_DIR | Out-Null
    $adb=Join-Path $config.androidSdk 'platform-tools/adb.exe'
    $devices = (& $adb devices) -join "`n"
    if ($devices -match "(?m)^emulator-$Port\s+device\s*$") {
        $onlineAvd = (& $adb -s "emulator-$Port" emu avd name | Select-Object -First 1).Trim()
        if ($onlineAvd -ne $Avd) { throw "Port $Port belongs to AVD '$onlineAvd', not '$Avd'; choose another port" }
        $onlineBoot = ((& $adb -s "emulator-$Port" shell getprop sys.boot_completed) | Out-String).Trim()
        if ($onlineBoot -ne '1') { throw "Existing AVD '$Avd' is online but has not finished booting; wait before retrying" }
        Write-Output "emulator-$Port ($Avd) is already ready (sys.boot_completed=1)"
        return
    }
    if ($devices -match "(?m)^emulator-$Port\s+") { throw 'An existing emulator uses this port; close that instance explicitly or choose a different port' }
    # SwiftShader and swangle crashed QEMU during repeated Android shader tests
    # on this Windows host. Use the verified host GLES path by default.
    $arguments=@('-avd',$Avd,'-port',"$Port",'-no-snapshot-load','-no-snapshot-save','-no-audio','-gpu',$Gpu,'-no-metrics','-crash-report-mode','disabled')
    if (-not $EnableVulkan) { $arguments += @('-feature','-Vulkan') }
    if (-not $ShowWindow) { $arguments += '-no-window' }
    Write-Output "Preserving AVD data. Runtime log: $runtime/emulator.log"
    $style = if ($ShowWindow) { 'Normal' } else { 'Hidden' }
    $process = Start-Process -FilePath (Join-Path $config.androidSdk 'emulator/emulator.exe') -ArgumentList $arguments -WindowStyle $style -PassThru -RedirectStandardOutput (Join-Path $runtime 'emulator.log') -RedirectStandardError (Join-Path $runtime 'emulator-error.log')
    $receipt = Join-Path $runtime 'runtime.json'
    $state = [ordered]@{ avd=$Avd; avdHome=$AvdHome; serial="emulator-$Port"; processId=$process.Id; gpu=$Gpu; vulkan=[bool]$EnableVulkan; runtime=$runtime; status='starting' }
    $state | ConvertTo-Json | Set-Content -LiteralPath $receipt -Encoding UTF8
    $deadline = [DateTime]::UtcNow.AddSeconds($BootTimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $process.Refresh()
        if ($process.HasExited) {
            $state['status']='exited-before-boot'
            $state['exitCode']=$process.ExitCode
            $state | ConvertTo-Json | Set-Content -LiteralPath $receipt -Encoding UTF8
            throw "Emulator exited with code $($process.ExitCode); logs preserved in $runtime"
        }
        # An offline transport is expected during cold boot; keep its stderr in
        # the probe, not as a terminating PowerShell NativeCommandError.
        $probePreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $ready = ((& $adb -s "emulator-$Port" shell getprop sys.boot_completed 2>&1) | Out-String).Trim()
        } finally { $ErrorActionPreference = $probePreference }
        if ($ready -eq '1') {
            $state['status']='ready'
            $state['sysBootCompleted']='1'
            $state['readyAt']=[DateTime]::UtcNow.ToString('o')
            $state | ConvertTo-Json | Set-Content -LiteralPath $receipt -Encoding UTF8
            Write-Output "emulator-$Port ready (sys.boot_completed=1). Receipt: $receipt"
            if ($Background) { return }
            $process.WaitForExit()
            $state['status']='exited'
            $state['exitCode']=$process.ExitCode
            $state | ConvertTo-Json | Set-Content -LiteralPath $receipt -Encoding UTF8
            if ($process.ExitCode -ne 0) { throw "Emulator exited with code $($process.ExitCode); logs preserved in $runtime" }
            return
        }
        Start-Sleep -Seconds 1
    }
    $state['status']='boot-timeout'
    $state | ConvertTo-Json | Set-Content -LiteralPath $receipt -Encoding UTF8
    throw "Android did not finish booting in $BootTimeoutSeconds seconds. Process $($process.Id) and logs are retained: $runtime"
} finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name,$previous[$name],'Process') }
}
