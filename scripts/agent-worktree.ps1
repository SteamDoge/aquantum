# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 AQuantum Reader contributors.
param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Branch,
    [string]$Base = 'HEAD',
    [string]$Repo = ''
)
# Creates an isolated worktree for one agent (GPT/Codex or Claude) next to the
# existing ones in ..\worktrees, sharing the same toolchain configuration.
# It never touches the main workspace's uncommitted files and never overwrites
# an existing worktree or branch.
$ErrorActionPreference = 'Stop'
$repoRoot = if ($Repo) { (Resolve-Path -LiteralPath $Repo).Path } else { Split-Path -Parent $PSScriptRoot }
if ($Name -notmatch '^[A-Za-z0-9._-]+$') { throw "Invalid worktree name: $Name" }
if ($Branch -notmatch '^(codex|claude)/[A-Za-z0-9._/-]+$') {
    throw 'Branch must be codex/<topic> or claude/<topic>'
}
$target = Join-Path (Split-Path -Parent $repoRoot) (Join-Path 'worktrees' $Name)
if (Test-Path -LiteralPath $target) { throw "Worktree folder already exists: $target" }
& git -C $repoRoot rev-parse --verify --quiet "refs/heads/$Branch" | Out-Null
if ($LASTEXITCODE -eq 0) { throw "Branch already exists: $Branch" }
$baseCommit = (& git -C $repoRoot rev-parse --verify "$Base^{commit}").Trim()
if ($LASTEXITCODE -ne 0) { throw "Unknown base: $Base" }

& git -C $repoRoot worktree add -b $Branch $target $baseCommit
if ($LASTEXITCODE -ne 0) { throw 'git worktree add failed' }

# Share the toolchain paths (Flutter, Android SDK, JDK). Signing material and
# emulator state stay in the main workspace only.
$tools = Join-Path $repoRoot '.tools/toolchains.json'
if (Test-Path -LiteralPath $tools) {
    New-Item -ItemType Directory -Path (Join-Path $target '.tools') -Force | Out-Null
    Copy-Item -LiteralPath $tools -Destination (Join-Path $target '.tools/toolchains.json')
}
New-Item -ItemType Directory -Path (Join-Path $target '.tools') -Force | Out-Null
@{ base = $baseCommit; branch = $Branch; createdAt = (Get-Date -Format o); integrationRoot = $repoRoot } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $target '.tools/worktree.json') -Encoding UTF8
Write-Output "worktree=$target"
Write-Output "branch=$Branch"
Write-Output "base=$baseCommit"
