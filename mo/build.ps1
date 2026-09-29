# <region>/build.ps1 — 宪制历史构建脚本（PowerShell 版，离线）
# 用法: .\region\build.ps1 <目标Git仓库路径>
#
# 本脚本不访问网络：法律文本全部随本仓库保存在 <region>/texts/ 下，
# 由 <region>/texts/manifest.tsv 描述分支、日期、时区与提交信息。
# 文本的更新由 tools/update-sources.sh 负责（维护者操作，日常构建不涉及）。
#
# 提交时间戳的处理：
#   1970-01-01 及以后 —— 写入该日「当地 0 点」这一瞬间，即对象里的偏移取 manifest 声明的
#                        偏移，`git log` 的 %ai 恰好是 <日期> 00:00:00 <偏移>。
#   1970-01-01 之前   —— 统一写入 unix 0（1970-01-01 00:00:00 +0000）。
#     原因是 Git 无法表示更早的日期：负 epoch 写进对象后，git log 渲染为 1970-01-01、
#     %ai/%ad/%at 为空、--since/--before 结果不可靠、git fsck 报 badDate，
#     而 GitHub 与部分客户端会直接显示出错（溢出）的时间。
#     统一为 unix 0 后，Git 与 GitHub 都能正常显示，仓库也不再带 fsck 错误。
#     **真实日期改由日期标签承载**：主分支为裸日期，历史分支为 "<日期>-<分支名>"，
#     例如 `git log --decorate` 显示 (tag: 1947-12-25)、`git tag` 排序即编年表。

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

function Get-CommitStamp {
    # "<日期> <声明时区>" -> "<存入的 epoch> <存入的时区>"
    # 存入的值是该日「当地 0 点」这一瞬间，即提交对象的 %ai 恰好是 <日期> 00:00:00 <时区>。
    # 1970 年前的日期统一收敛到 unix 0（见文件头说明）。之所以显式算 epoch 而不写
    # "YYYY-MM-DD 00:00:00"，是因为后者会被 git 按本机时区解析，结果随构建机 TZ 变化。
    param([string]$Date, [string]$Tz)
    $secs = Get-TzSeconds $Tz
    $d = [datetime]::ParseExact($Date, "yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture)
    $off = [System.TimeSpan]::FromSeconds($secs)
    $e = [DateTimeOffset]::new([DateTime]::SpecifyKind($d, [DateTimeKind]::Utc), $off).ToUnixTimeSeconds()
    if ($e -lt 0) { return "0 +0000" }
    return "$e $Tz"
}

function Get-TzSeconds {
    # "+0800" / "+0830" / "-0330" -> 相对 UTC 的秒数（东正西负）。
    # 必须支持任意 ±HHMM：各地区不止 +0800（日本/韩国/朝鲜 +0900，越南 +0700，
    # 朝鲜 2015-2018 年间的"平壤时间" +0830），写死 +8 会让这些地区的时间戳整体偏掉。
    param([string]$Tz)
    if ($Tz -notmatch '^([+-])(\d{2})(\d{2})$') { throw "时区格式不对：$Tz" }
    $sign = if ($Matches[1] -eq '-') { -1 } else { 1 }
    return $sign * ([int]$Matches[2] * 3600 + [int]$Matches[3] * 60)
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

function New-CommitByStamp {
    param([string]$Stamp, [string]$Msg)
    $env:GIT_AUTHOR_NAME = $GIT_NAME
    $env:GIT_AUTHOR_EMAIL = $GIT_EMAIL
    $env:GIT_AUTHOR_DATE = "@$Stamp"
    $env:GIT_COMMITTER_NAME = $GIT_NAME
    $env:GIT_COMMITTER_EMAIL = $GIT_EMAIL
    $env:GIT_COMMITTER_DATE = "@$Stamp"
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
    $firstStamp = Get-CommitStamp -Date $rows[0].Date -Tz $rows[0].Tz
    $script:INIT = New-CommitByStamp -Stamp $firstStamp -Msg "Initial commit"
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

        $stamp = Get-CommitStamp -Date $g.Date -Tz $g.Tz
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

        $prev = New-CommitByStamp -Stamp $stamp -Msg $g.Message
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
    # 真实日期以日期标签为准；1970 前的提交在 Git 里存为 unix 0
    log "各提交的真实日期（以日期标签为准）："
    foreach ($tag in (@(git tag -l) | Sort-Object)) {
        $raw = git cat-file -p "refs/tags/$tag"
        $line = ($raw | Where-Object { $_ -match '^committer .*<[^>]*> (\d+) ([-+]\d{4})$' })
        if (-not $line) { continue }
        $null = $line -match '^committer .*<[^>]*> (\d+) ([-+]\d{4})$'
        $ts = [long]$Matches[1]; $tz = $Matches[2]
        $subj = [string](git log -1 --format=%s "refs/tags/$tag")
        if ($subj.Length -gt 44) { $subj = $subj.Substring(0, 44) }
        if ($ts -eq 0) {
            Write-Host ("  {0,-28} {1,-16}  {2}" -f $tag, "unix 0", $subj)
        } else {
            # 直接用 git 自己的渲染（%ad 即按对象里存的时区显示），与 Bash 版完全一致
            $when = (git log -1 --format='%ad' --date='format:%Y-%m-%d %H:%M' "refs/tags/$tag")
            Write-Host ("  {0,-28} {1,-16}  {2}" -f $tag, $when, $subj)
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
        Write-Host ("  {0,-30} {1}" -f $tag, (git log -1 --format=%s "refs/tags/$tag"))
    }
    ""
    Show-Dates
} finally {
    [Console]::OutputEncoding = $OLD_OUTPUT_ENCODING
}
