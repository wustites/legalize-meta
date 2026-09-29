# <region>/build.ps1 — 宪制历史构建脚本（PowerShell 版，离线）
# 用法: .\region\build.ps1 <目标Git仓库路径>
#
# 本脚本不访问网络：法律文本全部随本仓库保存在 <region>/texts>/ 下，
# 由 <region>/texts>/manifest.tsv 描述分支、日期、时区与提交信息。
# 文本的更新由 tools/update-sources.ps1 负责（维护者操作，日常构建不涉及）。

param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$RepoPath
)

$ErrorActionPreference = "Stop"

$OLD_OUTPUT_ENCODING = [Console]::OutputEncoding
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$SCRIPT_DIR = $PSScriptRoot
$REGION = Split-Path $SCRIPT_DIR -Leaf
$TEXTS_DIR = Join-Path $SCRIPT_DIR "texts"
$MANIFEST = Join-Path $TEXTS_DIR "manifest.tsv"

if (-not (Test-Path $MANIFEST)) {
    Write-Host "[!] 找不到文本清单：$MANIFEST" -ForegroundColor Red
    exit 1
}

$GIT_NAME = (git config user.name).Trim()
$GIT_EMAIL = (git config user.email).Trim()
if (-not $GIT_NAME) { $GIT_NAME = "legalize-meta" }
if (-not $GIT_EMAIL) { $GIT_EMAIL = "legalize-meta@example.invalid" }

if (-not (Test-Path $RepoPath)) {
    New-Item -ItemType Directory -Path $RepoPath -Force | Out-Null
    git -C $RepoPath init -q
}
$TARGET_REPO = (Resolve-Path $RepoPath).Path
Set-Location $TARGET_REPO

function log   { Write-Host "[*] $args" -ForegroundColor Cyan }
function ok    { Write-Host "  -> $args" -ForegroundColor Green }
function warn  { Write-Host "[!] $args" -ForegroundColor Yellow }

function Get-EpochAt {
    # "YYYY-MM-DD" + 时区偏移小时 -> 该日 00:00 的 epoch。
    # 必须显式算 epoch：写 "YYYY-MM-DD 00:00:00" 会被 git 按本机时区解析（结果随构建机
    # TZ 变化）；而 1970 年前的日期又无法用日期串表达（git 只接受非负 epoch）。
    param([string]$Date, [int]$OffsetHours = 8)
    $d = [datetime]::ParseExact($Date, "yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture)
    $off = [System.TimeSpan]::FromHours($OffsetHours)
    return [DateTimeOffset]::new([DateTime]::SpecifyKind($d, [DateTimeKind]::Utc), $off).ToUnixTimeSeconds()
}

function Get-TzHours {
    param([string]$Tz)
    if ($Tz -eq "+0000") { return 0 }
    return 8
}

function New-RawCommitObject {
    # 1970 年前的提交：git 无法解析负 epoch，只能手工写 commit 对象再更新 ref。
    # 这类提交的对象对 `git fsck` 会报 badDate，属 Git 固有限制。
    param([long]$Epoch, [string]$Tz, [string]$Msg, [string]$Parent)
    $tree = git write-tree
    if ($LASTEXITCODE -ne 0 -or -not $tree) { throw "git write-tree 失败" }
    if ($Parent -eq "-") {
        $content = "tree $tree`nauthor $GIT_NAME <$GIT_EMAIL> $Epoch $Tz`ncommitter $GIT_NAME <$GIT_EMAIL> $Epoch $Tz`n`n$Msg`n"
    } else {
        $content = "tree $tree`nparent $Parent`nauthor $GIT_NAME <$GIT_EMAIL> $Epoch $Tz`ncommitter $GIT_NAME <$GIT_EMAIL> $Epoch $Tz`n`n$Msg`n"
    }
    $objFile = Join-Path ([System.IO.Path]::GetTempPath()) ("commit-" + [System.IO.Path]::GetRandomFileName())
    [System.IO.File]::WriteAllBytes($objFile, [System.Text.Encoding]::UTF8.GetBytes($content))
    $ch = git hash-object -t commit -w $objFile --literally
    Remove-Item $objFile -Force
    if (-not $ch) { throw "git hash-object 返回空" }
    return $ch
}

function New-DatedCommit {
    # 1970 年及以后：直接用 git commit（索引/工作区/HEAD 一致，不污染主分支索引）
    param([long]$Epoch, [string]$Tz, [string]$Msg)
    $env:GIT_AUTHOR_NAME = $GIT_NAME
    $env:GIT_AUTHOR_EMAIL = $GIT_EMAIL
    $env:GIT_AUTHOR_DATE = "@$Epoch $Tz"
    $env:GIT_COMMITTER_NAME = $GIT_NAME
    $env:GIT_COMMITTER_EMAIL = $GIT_EMAIL
    $env:GIT_COMMITTER_DATE = "@$Epoch $Tz"
    git commit -q --no-verify -m $Msg
    return (git rev-parse HEAD)
}

function Read-Manifest {
    # 返回对象数组：Branch / Seq / File / Date / Tz / OutPath / Message
    $rows = @()
    foreach ($line in [System.IO.File]::ReadAllLines($MANIFEST, [System.Text.Encoding]::UTF8)) {
        if (-not $line -or $line.StartsWith('#')) { continue }
        $f = $line -split "`t"
        if ($f.Count -lt 7) { warn "清单行字段不足，已跳过：$line"; continue }
        $rows += [pscustomobject]@{
            Branch = $f[0]; Seq = $f[1]; File = $f[2]; Date = $f[3]
            Tz = $f[4]; OutPath = $f[5]; Message = $f[6]
        }
    }
    return $rows
}

function Clean-Repo {
    log "清理目标仓库..."
    $rootCommit = git rev-list --max-parents=0 HEAD 2>$null
    if ($rootCommit) {
        git checkout main 2>$null
        git reset --hard $rootCommit 2>$null
        git rm -r . --quiet 2>$null
    }
    foreach ($f in @(".gitignore", "LICENSE", "README.md")) {
        $src = Join-Path $SCRIPT_DIR $f
        if (Test-Path $src) { Copy-Item $src . -Force }
    }
    git add .
    git branch | ForEach-Object {
        $b = $_.Trim().Replace('* ', '')
        if ($b -and $b -ne 'main') { git branch -D $b 2>$null; ok "已删除分支: $b" }
    }
    git symbolic-ref HEAD refs/heads/main
}

function Build-FromManifest {
    $rows = @(Read-Manifest)
    if ($rows.Count -eq 0) { warn "清单为空：$MANIFEST"; exit 1 }

    Clean-Repo
    $firstEpoch = Get-EpochAt -Date $rows[0].Date -OffsetHours (Get-TzHours $rows[0].Tz)
    if ($firstEpoch -ge 0) {
        $script:INIT = New-DatedCommit -Epoch $firstEpoch -Tz $rows[0].Tz -Msg "Initial commit"
    } else {
        $sha = New-RawCommitObject -Epoch $firstEpoch -Tz $rows[0].Tz -Msg "Initial commit" -Parent "-"
        git update-ref refs/heads/main $sha
        $script:INIT = $sha
    }
    ok "根提交 $($script:INIT)（$($rows[0].Date) $($rows[0].Tz)）"

    $prev = $script:INIT; $prevBranch = ""; $prevSeq = ""
    $i = 0
    while ($i -lt $rows.Count) {
        $g = $rows[$i]
        $group = @($g)
        $j = $i + 1
        while ($j -lt $rows.Count -and $rows[$j].Branch -eq $g.Branch -and $rows[$j].Seq -eq $g.Seq) {
            $group += $rows[$j]; $j++
        }

        $parent = $script:INIT
        # 与上一个提交同一分支则接续；不同分支则从初始提交重新开枝
        if ($g.Branch -eq $prevBranch) { $parent = $prev }

        # 先把目标分支指向父提交并签出，索引与工作区随之就位
        git checkout -q -B $g.Branch $parent

        $epoch = Get-EpochAt -Date $g.Date -OffsetHours (Get-TzHours $g.Tz)
        foreach ($row in $group) {
            $src = Join-Path $TEXTS_DIR $row.File
            if (-not (Test-Path $src)) { warn "缺少文本文件：texts/$($row.File)"; exit 1 }
            if ((Get-Item $src).Length -eq 0) { warn "文本文件为空：texts/$($row.File)"; exit 1 }
            $dst = $row.OutPath
            $dir = Split-Path $dst -Parent
            if ($dir) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            Copy-Item $src $dst -Force
            git add $dst
        }

        if ($epoch -ge 0) {
            $prev = New-DatedCommit -Epoch $epoch -Tz $g.Tz -Msg $g.Message
        } else {
            $sha = New-RawCommitObject -Epoch $epoch -Tz $g.Tz -Msg $g.Message -Parent $parent
            git update-ref "refs/heads/$($g.Branch)" $sha
            $prev = $sha
        }
        $prevBranch = $g.Branch; $prevSeq = $g.Seq
        $msg = if ($g.Message.Length -gt 40) { $g.Message.Substring(0, 40) } else { $g.Message }
        ok ("{0,-12} #{1,-2} {2}  {3}" -f $g.Branch, $g.Seq, $g.Date, $msg)
        $i = $j
    }
}

function Show-Dates {
    log "各分支真实日期（早于 1970 的提交 git log 只会显示 1970-01-01）:"
    foreach ($b in @(git branch --format='%(refname:short)')) {
        $raw = git cat-file -p $b
        $line = ($raw | Where-Object { $_ -match '^committer .*<[^>]*> (-?\d+) ([-+]\d{4})$' })
        if (-not $line) { continue }
        if ($line -match '^committer .*<[^>]*> (-?\d+) ([-+]\d{4})$') {
            $ts = [long]$Matches[1]; $tz = $Matches[2]
            $off = Get-TzHours $tz
            $when = [DateTimeOffset]::FromUnixTimeSeconds($ts + $off * 3600).UtcDateTime.ToString('yyyy-MM-dd HH:mm')
            Write-Host ("  {0,-16} {1}  {2}" -f $b, $when, $tz)
        }
    }
}

try {
    log "=== legalize-$REGION 宪制历史构建（离线，不访问网络） ==="
    log "目标仓库: $TARGET_REPO"
    log "文本清单: $MANIFEST"
    ""
    Build-FromManifest
    ""
    git checkout -q main 2>$null
    log "=== 构建完成 ==="
    ""
    log "分支一览:"
    git branch -a
    ""
    Show-Dates
} finally {
    [Console]::OutputEncoding = $OLD_OUTPUT_ENCODING
}
