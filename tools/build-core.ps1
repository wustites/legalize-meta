# tools/build-core.ps1 — 所有法域共用的构建核心（PowerShell 版，离线）
#
# 用法:
#   ./tools/build-core.ps1 -Region cn -RepoPath C:\tmp\legalize-cn [-Force]
#   ./cn/build.ps1 C:\tmp\legalize-cn [-Force]        # 区域 wrapper
#
# 安全约定与 Bash 版一致：
#   * 目标必须显式给出；拒绝当前目录、元仓库本身/上级/内部路径。
#   * 目标非空时必须加 -Force；-Force 会替换目标内容（保留 .git/config）。
#   * 先在与目标同级的临时目录里完整构建，成功后才替换目标。
#   * 生成仓库只有一个根提交；重复构建不会叠加 Initial commit。

param(
    [Parameter(Mandatory=$true)]
    [string]$Region,
    [Parameter(Mandatory=$true)]
    [string]$RepoPath,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$OldOutputEncoding = [Console]::OutputEncoding
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

function Fail([string]$Message) {
    Write-Host "[!] $Message" -ForegroundColor Red
    exit 1
}
function Log([string]$Message) { Write-Host "[*] $Message" -ForegroundColor Cyan }
function Ok([string]$Message)  { Write-Host "  -> $Message" -ForegroundColor Green }
function Warn([string]$Message){ Write-Host "[!] $Message" -ForegroundColor Yellow }

function Invoke-Git {
    param(
        [Parameter(Mandatory=$true)][string]$Repo,
        [Parameter(Mandatory=$true)][string[]]$GitArgs,
        [switch]$AllowFail
    )
    $all = @('-C', $Repo) + $GitArgs
    $out = & git @all 2>&1
    $code = $LASTEXITCODE
    $lines = @($out | ForEach-Object { "$_" })
    if ($code -ne 0 -and -not $AllowFail) {
        throw ("git " + ($GitArgs -join ' ') + " 失败`n" + ($lines -join "`n"))
    }
    return [pscustomobject]@{
        Code  = $code
        Text  = (($lines -join "`n").Trim())
        Lines = $lines
    }
}

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Root = $Root.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$RegionDir = Join-Path $Root $Region
$TextsDir = Join-Path $RegionDir 'texts'
$Manifest = Join-Path $TextsDir 'manifest.tsv'
$RegionsTsv = Join-Path $Root 'tools/regions.tsv'
$ReadmeTpl = Join-Path $Root 'tools/output-README.template.md'
$Notice = Join-Path $Root 'NOTICE.md'

foreach ($p in @($Manifest, (Join-Path $RegionDir '.gitignore'), (Join-Path $RegionDir 'LICENSE'), $RegionsTsv, $ReadmeTpl, $Notice)) {
    if (-not (Test-Path -LiteralPath $p)) { Fail "缺少文件：$p" }
}
# 本脚本用 .NET 计算日期，不依赖 python3；python3 只用于维护者校验工具。

$RegionName = $null
foreach ($line in [IO.File]::ReadAllLines($RegionsTsv, [Text.Encoding]::UTF8)) {
    if (-not $line -or $line.StartsWith('#')) { continue }
    $f = $line -split "`t"
    if ($f.Count -ge 2 -and $f[0] -eq $Region) { $RegionName = $f[1]; break }
}
if (-not $RegionName) { Fail "未知区域：$Region（见 tools/regions.tsv）" }

# ---------------------------------------------------------------- 目标路径与安全检查
try {
    $Target = [IO.Path]::GetFullPath($RepoPath)
} catch {
    Fail "无法解析目标路径：$RepoPath"
}
$Target = $Target.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
if (-not $Target) { Fail "目标路径为空" }

$cmp = [StringComparison]::OrdinalIgnoreCase
$sep = [IO.Path]::DirectorySeparatorChar
if ([string]::Equals($Target, $Root, $cmp)) { Fail "拒绝把元仓库本身作为目标" }
if ($Target -eq ([IO.Path]::GetPathRoot($Target).TrimEnd($sep))) { Fail "拒绝把文件系统根目录作为目标" }
if ($Target.StartsWith($Root + $sep, $cmp)) { Fail "目标不能位于元仓库内部：$Target" }
if ($Root.StartsWith($Target + $sep, $cmp)) { Fail "目标不能是元仓库的上级目录：$Target" }
$cwd = (Get-Location).Path.TrimEnd($sep)
if ([string]::Equals($Target, $cwd, $cmp) -or $cwd.StartsWith($Target + $sep, $cmp)) {
    Fail "当前工作目录位于目标内；请从目标外运行并传入明确路径"
}
$targetParent = [IO.Path]::GetDirectoryName($Target)
if (-not $targetParent) { $targetParent = [IO.Path]::GetPathRoot($Target) }
if ($targetParent) {
    $parentFull = [IO.Path]::GetFullPath($targetParent)
    $rootFull = [IO.Path]::GetFullPath([IO.Path]::GetPathRoot($Target))
    if ([string]::Equals($parentFull, $rootFull, $cmp)) {
        Fail "拒绝把文件系统顶层目录作为目标：$Target"
    }
}
foreach ($protected in @($env:USERPROFILE, $env:TEMP, $env:TMP, $env:WINDIR, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
    if (-not $protected) { continue }
    $pFull = [IO.Path]::GetFullPath($protected).TrimEnd($sep)
    if ([string]::Equals($Target, $pFull, $cmp) -or $pFull.StartsWith($Target + $sep, $cmp)) {
        Fail "目标不能是系统/临时目录或 HOME 的上级：$Target"
    }
}

if (Test-Path -LiteralPath $Target) {
    if (-not (Test-Path -LiteralPath $Target -PathType Container)) { Fail "目标不是目录：$Target" }
    if ((Test-Path -LiteralPath (Join-Path $Target 'HEAD')) -and
        -not (Test-Path -LiteralPath (Join-Path $Target '.git'))) {
        Fail "不支持把裸 Git 仓库作为目标：$Target"
    }
    $entries = @(Get-ChildItem -LiteralPath $Target -Force)
    if ($entries.Count -gt 0 -and -not $Force) {
        Fail "目标非空：$Target`n       确认替换请加 -Force（会替换该目录内容，保留 .git/config）"
    }
}

$Parent = [IO.Path]::GetDirectoryName($Target)
if (-not $Parent) { $Parent = [IO.Path]::GetPathRoot($Target) }
if (-not $Parent) { $Parent = (Get-Location).Path }
if (-not (Test-Path -LiteralPath $Parent)) { New-Item -ItemType Directory -Path $Parent -Force | Out-Null }

$TempRoot = Join-Path $Parent ('.legalize-build.' + [guid]::NewGuid().ToString('N'))
$Build = Join-Path $TempRoot 'repo'
$Backup = Join-Path $Parent ('.legalize-old.' + $PID + '.' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $TempRoot | Out-Null
New-Item -ItemType Directory -Path $Build | Out-Null

$GitName = (git config user.name 2>$null)
$GitEmail = (git config user.email 2>$null)
if (-not $GitName)  { $GitName = 'legalize-meta' }
if (-not $GitEmail) { $GitEmail = 'legalize-meta@example.invalid' }

function Get-TzSeconds([string]$Tz) {
    if ($Tz -notmatch '^([+-])(\d{2})(\d{2})$') { throw "时区格式不对：$Tz" }
    $sign = if ($Matches[1] -eq '-') { -1 } else { 1 }
    return $sign * ([int]$Matches[2] * 3600 + [int]$Matches[3] * 60)
}

function Get-CommitStamp([string]$Date, [string]$Tz) {
    $secs = Get-TzSeconds $Tz
    # ParseExact 返回 Unspecified Kind；DateTimeOffset(dt, offset) 会按「当地 0 点」换算成 UTC。
    # 不能传 Kind=Utc 的 DateTime——.NET 要求 Utc 的 offset 必须为 0。
    $d = [datetime]::ParseExact($Date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    $off = [TimeSpan]::FromSeconds($secs)
    $e = [DateTimeOffset]::new($d, $off).ToUnixTimeSeconds()
    if ($e -lt 0) { return '0 +0000' }
    return "$e $Tz"
}

function Read-Manifest {
    $rows = @()
    foreach ($line in [IO.File]::ReadAllLines($Manifest, [Text.Encoding]::UTF8)) {
        if (-not $line -or $line.StartsWith('#')) { continue }
        $f = $line -split "`t"
        if ($f.Count -lt 7) { throw "清单行字段不足：$line" }
        $rows += [pscustomobject]@{
            Branch  = $f[0]
            Seq     = $f[1]
            File    = $f[2]
            Date    = $f[3]
            Tz      = $f[4]
            OutPath = $f[5]
            Message = $f[6]
        }
    }
    return $rows
}

$Rows = @(Read-Manifest)
if ($Rows.Count -eq 0) { Fail "清单为空：$Manifest" }

function Get-TagName([string]$Branch, [string]$Date) {
    if ($Branch -eq 'main') { return $Date }
    return "$Date-$Branch"
}

function New-CommitByStamp([string]$Stamp, [string]$Msg) {
    $env:GIT_AUTHOR_NAME = $GitName
    $env:GIT_AUTHOR_EMAIL = $GitEmail
    $env:GIT_AUTHOR_DATE = "@$Stamp"
    $env:GIT_COMMITTER_NAME = $GitName
    $env:GIT_COMMITTER_EMAIL = $GitEmail
    $env:GIT_COMMITTER_DATE = "@$Stamp"
    Invoke-Git -Repo $Build -GitArgs @('commit', '--no-verify', '-m', $Msg) | Out-Null
    return (Invoke-Git -Repo $Build -GitArgs @('rev-parse', 'HEAD')).Text
}

function New-Readme {
    $tpl = [IO.File]::ReadAllText($ReadmeTpl, [Text.Encoding]::UTF8)
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($r in $Rows) { [void]$seen.Add("$($r.Branch)`t$($r.Seq)") }
    $tpl = $tpl.Replace('{{REGION}}', $Region)
    $tpl = $tpl.Replace('{{REGION_NAME}}', $RegionName)
    $tpl = $tpl.Replace('{{TEXT_COUNT}}', [string]$Rows.Count)
    $tpl = $tpl.Replace('{{COMMIT_COUNT}}', [string]$seen.Count)
    return $tpl
}

try {
    Log "=== legalize-$Region 宪制历史构建（离线，不访问网络） ==="
    Log "区域: $RegionName"
    Log "目标仓库: $Target"
    Log "文本清单: $Manifest"
    if ($Force) { Log "模式: -Force（完成后替换目标）" }
    Write-Host ''

    Invoke-Git -Repo $Build -GitArgs @('init', '-q') | Out-Null
    Invoke-Git -Repo $Build -GitArgs @('symbolic-ref', 'HEAD', 'refs/heads/main') | Out-Null
    Invoke-Git -Repo $Build -GitArgs @('config', 'core.autocrlf', 'false') | Out-Null
    Invoke-Git -Repo $Build -GitArgs @('config', 'core.quotepath', 'false') | Out-Null

    Copy-Item -LiteralPath (Join-Path $RegionDir '.gitignore') -Destination (Join-Path $Build '.gitignore')
    Copy-Item -LiteralPath (Join-Path $RegionDir 'LICENSE') -Destination (Join-Path $Build 'LICENSE')
    Copy-Item -LiteralPath $Notice -Destination (Join-Path $Build 'NOTICE.md')
    [IO.File]::WriteAllText((Join-Path $Build 'README.md'), (New-Readme), [Text.UTF8Encoding]::new($false))
    Invoke-Git -Repo $Build -GitArgs @('add', '.') | Out-Null

    $First = $Rows[0]
    $FirstStamp = Get-CommitStamp -Date $First.Date -Tz $First.Tz
    $Init = New-CommitByStamp -Stamp $FirstStamp -Msg 'Initial commit'
    Ok "根提交 $Init（$($First.Date) -> 时间戳 $FirstStamp）"

    $prev = $Init
    $prevBranch = ''
    $i = 0
    while ($i -lt $Rows.Count) {
        $g = $Rows[$i]
        $group = @($g)
        $j = $i + 1
        while ($j -lt $Rows.Count -and $Rows[$j].Branch -eq $g.Branch -and $Rows[$j].Seq -eq $g.Seq) {
            $group += $Rows[$j]
            $j++
        }

        $parent = $Init
        if ($g.Branch -eq $prevBranch) { $parent = $prev }
        Invoke-Git -Repo $Build -GitArgs @('checkout', '-q', '-B', $g.Branch, $parent) | Out-Null

        $stamp = Get-CommitStamp -Date $g.Date -Tz $g.Tz
        foreach ($row in $group) {
            $src = Join-Path $TextsDir $row.File
            if (-not (Test-Path -LiteralPath $src)) { throw "缺少文本文件：texts/$($row.File)" }
            if ((Get-Item -LiteralPath $src).Length -eq 0) { throw "文本文件为空：texts/$($row.File)" }
            $dst = [IO.Path]::Combine($Build, ($row.OutPath -replace '/', [IO.Path]::DirectorySeparatorChar))
            $dir = Split-Path -Parent $dst
            if ($dir) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            Copy-Item -LiteralPath $src -Destination $dst -Force
            Invoke-Git -Repo $Build -GitArgs @('add', $row.OutPath) | Out-Null
        }

        $prev = New-CommitByStamp -Stamp $stamp -Msg $g.Message
        $prevBranch = $g.Branch

        $tag = Get-TagName -Branch $g.Branch -Date $g.Date
        $exists = Invoke-Git -Repo $Build -GitArgs @('show-ref', '--verify', '--quiet', "refs/tags/$tag") -AllowFail
        if ($exists.Code -eq 0) { throw "标签重名：$tag（$($g.Branch) #$($g.Seq) $($g.Date)）" }
        Invoke-Git -Repo $Build -GitArgs @('update-ref', "refs/tags/$tag", $prev) | Out-Null

        $msg = if ($g.Message.Length -gt 32) { $g.Message.Substring(0, 32) } else { $g.Message }
        Ok ("{0,-12} #{1,-2} {2,-26} {3}  {4}" -f $g.Branch, $g.Seq, $tag, $g.Date, $msg)
        $i = $j
    }

    Invoke-Git -Repo $Build -GitArgs @('show-ref', '--verify', '--quiet', 'refs/heads/main') | Out-Null
    Invoke-Git -Repo $Build -GitArgs @('checkout', '-q', 'main') | Out-Null
    Invoke-Git -Repo $Build -GitArgs @('symbolic-ref', 'HEAD', 'refs/heads/main') | Out-Null
    $status = (Invoke-Git -Repo $Build -GitArgs @('status', '--porcelain')).Text
    if ($status) { throw "构建后工作区不干净：`n$status" }

    # 保留目标原有的 .git/config（remote、用户设置等）
    $oldConfig = Join-Path $Target '.git/config'
    if (Test-Path -LiteralPath $oldConfig) {
        Copy-Item -LiteralPath $oldConfig -Destination (Join-Path $Build '.git/config') -Force
    }

    $hadTarget = Test-Path -LiteralPath $Target
    if ($hadTarget) {
        Move-Item -LiteralPath $Target -Destination $Backup
    }
    try {
        Move-Item -LiteralPath $Build -Destination $Target
    } catch {
        if ($hadTarget -and (Test-Path -LiteralPath $Backup)) {
            Move-Item -LiteralPath $Backup -Destination $Target
        }
        throw
    }
    if (Test-Path -LiteralPath $Backup) {
        Remove-Item -LiteralPath $Backup -Recurse -Force
    }

    Write-Host ''
    Log '=== 构建完成 ==='
    Log "目标: $Target"
    Log '分支:'
    & git -C $Target branch -a
    Log '日期标签（git tag 按名字排序即时间顺序）:'
    & git -C $Target tag -l | Sort-Object | ForEach-Object { Write-Host "  $_" }

    exit 0
} catch {
    Fail $_.Exception.Message
} finally {
    [Console]::OutputEncoding = $OldOutputEncoding
    # 如果替换过程中被打断，尽量把旧目标放回去。
    if ($Backup -and (Test-Path -LiteralPath $Backup) -and -not (Test-Path -LiteralPath $Target)) {
        Move-Item -LiteralPath $Backup -Destination $Target -ErrorAction SilentlyContinue
    }
    if ($TempRoot -and (Test-Path -LiteralPath $TempRoot)) {
        Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
