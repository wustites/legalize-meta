# <region>/build.ps1 — 宪制历史构建脚本（PowerShell 版，离线）
# 用法: .\region\build.ps1 <目标Git仓库路径>
#
# 本脚本不访问网络：法律文本全部随本仓库保存在 <region>/texts>/ 下，
# 由 <region>/texts>/manifest.tsv 描述分支、日期、时区与提交信息。
# 文本的更新由 tools/update-sources.sh 负责（维护者操作，日常构建不涉及）。
#
# 每次提交会打一个以真实日期命名的轻量标签（主分支为裸日期，历史分支为
# "<日期>-<分支名>"），以便在 git log --decorate 与 GitHub 上直接看出日期——
# Git 本身无法渲染 1970-01-01 之前的提交日期。

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

function Get-TagName {
    # 标签名：让 1970 年前后的提交在 git log / GitHub 上都能看出真实日期。
    # Git 无法渲染 1970-01-01 之前的提交日期（见根 README「关于日期显示」），因此给
    # 每次提交打一个以日期命名的轻量标签，`git log --decorate` 会在提交旁显示
    #   abc1234 (tag: 1947-12-25) 1947年12月25日施行《中华民国宪法》
    # `git tag` 按名字排序即时间顺序；主分支用裸日期，历史分支加分支名后缀以免重名。
    param([string]$Branch, [string]$Date)
    if ($Branch -eq "main") { return $Date }
    return "$Date-$Branch"
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
    # 标签是独立于分支的 ref，重建前要一并清掉，否则日期标签会重名
    foreach ($tag in @(git tag -l)) { git update-ref -d "refs/tags/$tag" }
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
        # 打日期标签，使真实日期在 git log --decorate / GitHub 上可见。
        # 用 git update-ref 而非 git tag：后者会解析目标提交的日期来写 reflog，
        # 遇到 1970 年前的负时间戳会报 "Timestamp too large for this system" 而失败。
        $tag = Get-TagName -Branch $g.Branch -Date $g.Date
        git show-ref --verify --quiet "refs/tags/$tag"
        if ($LASTEXITCODE -eq 0) { warn "标签重名：$tag"; exit 1 }
        git update-ref "refs/tags/$tag" $prev
        $msg = if ($g.Message.Length -gt 36) { $g.Message.Substring(0, 36) } else { $g.Message }
        ok ("{0,-12} #{1,-2} {2,-26} {3}  {4}" -f $g.Branch, $g.Seq, $tag, $g.Date, $msg)
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
    log "日期标签（git tag 按名字排序即时间顺序）:"
    foreach ($tag in (@(git tag -l) | Sort-Object)) {
        $subj = (git log -1 --format=%s "refs/tags/$tag")
        Write-Host ("  {0,-30} {1}" -f $tag, $subj)
    }
    ""
    Show-Dates
} finally {
    [Console]::OutputEncoding = $OLD_OUTPUT_ENCODING
}
