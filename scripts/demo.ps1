# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 AQuantum Reader contributors.
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)

& cargo build -p aq-cli --locked
if ($LASTEXITCODE -ne 0) { throw '构建失败' }
$demoStamp = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,6)
$demoRoot = Join-Path (Get-Location) "artifacts/demo-library/$demoStamp"
$sourceRoot = Join-Path $demoRoot '样例原件'
$libraryRoot = Join-Path $demoRoot '资料库'
$planPath = Join-Path $demoRoot '导入计划.json'
$notesPath = Join-Path $demoRoot '阅读笔记.md'
New-Item -ItemType Directory -Path $sourceRoot | Out-Null
Set-Content -LiteralPath (Join-Path $sourceRoot '阅读示例.txt') -Value "第一段：先导入，再阅读。`n`n第二段：原件保留，阅读使用内部副本。`n`n第三段：核心规则与界面分开。" -Encoding utf8
Set-Content -LiteralPath (Join-Path $sourceRoot '设计说明.md') -Value "# AQuantum Reader`n`n这是 Markdown 源码阅读示例。`n`n完整排版引擎留待后续。" -Encoding utf8
$executable = Join-Path (Get-Location) 'target/debug/aqreader.exe'
if (-not (Test-Path -LiteralPath $executable)) { $executable = Join-Path (Get-Location) 'target/debug/aqreader' }

function Invoke-Reader {
    param([string[]]$ReaderArgs)
    $readerOutput = & $executable --library $libraryRoot @ReaderArgs
    if ($LASTEXITCODE -ne 0) { throw "演示操作失败：$($ReaderArgs -join ' ')" }
    if ($readerOutput) { return ($readerOutput -join "`n" | ConvertFrom-Json) }
}

$identity = Invoke-Reader -ReaderArgs @('init')
$plan = Invoke-Reader -ReaderArgs @('plan',$sourceRoot,'--output',$planPath)
$imported = Invoke-Reader -ReaderArgs @('import',$planPath)
$again = Invoke-Reader -ReaderArgs @('import',$planPath)
if (($imported.books -join ',') -ne ($again.books -join ',')) { throw '相同导入任务产生不同书籍' }
$listing = Invoke-Reader -ReaderArgs @('list')
$book = @($listing.books | Where-Object { $_.format -eq 'Txt' })[0]
$document = Invoke-Reader -ReaderArgs @('read',$book.id)
$null = Invoke-Reader -ReaderArgs @('progress',$book.id,'--paragraph','2')
$null = Invoke-Reader -ReaderArgs @('note',$book.id,'这是第二段的关联笔记。','--paragraph','2')
$null = Invoke-Reader -ReaderArgs @('export-notes',$book.id,'--output',$notesPath)
$storage = Invoke-Reader -ReaderArgs @('storage')
$bookState = Invoke-Reader -ReaderArgs @('show',$book.id)
$history = Invoke-Reader -ReaderArgs @('history')
$receipt = [ordered]@{
    timestamp = (Get-Date).ToString('o')
    library = $libraryRoot
    identity = $identity
    projectCount = @($listing.projects).Count
    bookCount = @($listing.books).Count
    paragraphCount = @($document.paragraphs).Count
    repeatedTaskPreservedIds = $true
    progress = $bookState.progress
    notesFile = $notesPath
    operationCount = @($history).Count
    storage = $storage
}
$receipt | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $demoRoot 'receipt.json') -Encoding utf8
Write-Host "演示完成：$demoRoot"
Write-Host "项目 $($receipt.projectCount) 个，书籍 $($receipt.bookCount) 本；相同任务重试无重复。"
Write-Host "TXT 共 $($receipt.paragraphCount) 段，已保存第 2 段进度及关联笔记。"
Write-Host "查看导出的笔记：$notesPath"

