# meta/build.ps1 — 香港宪制历史构建脚本
# 用法: .\hk\build.ps1 <目标Git仓库路径>
# 在指定 git 仓库中构建香港宪制文件历史（主分支 + 历史宪制分支）

param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$RepoPath
)

$ErrorActionPreference = "Stop"

$OLD_OUTPUT_ENCODING = [Console]::OutputEncoding
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$GIT_NAME = (git config user.name).Trim()
$GIT_EMAIL = (git config user.email).Trim()
if (-not $GIT_NAME) { $GIT_NAME = "legalize-meta" }
if (-not $GIT_EMAIL) { $GIT_EMAIL = "legalize-meta@example.invalid" }
$env:GIT_AUTHOR_NAME = $GIT_NAME
$env:GIT_AUTHOR_EMAIL = $GIT_EMAIL
$env:GIT_COMMITTER_NAME = $GIT_NAME
$env:GIT_COMMITTER_EMAIL = $GIT_EMAIL

$TMPDIR = Join-Path $env:TMP "legalize-hk-build-$([System.IO.Path]::GetRandomFileName())"
New-Item -ItemType Directory -Path $TMPDIR -Force | Out-Null

$SCRIPT_DIR = $PSScriptRoot

$TARGET_REPO = Resolve-Path -Path $RepoPath -ErrorAction SilentlyContinue
if (-not $TARGET_REPO) {
    New-Item -ItemType Directory -Path $RepoPath -Force | Out-Null
    $TARGET_REPO = Resolve-Path $RepoPath
    Set-Location $RepoPath
    git init
} elseif (-not (Test-Path (Join-Path $TARGET_REPO ".git"))) {
    Set-Location $TARGET_REPO
    git init
} else {
    Set-Location $TARGET_REPO
}
Set-Location $TARGET_REPO

function log   { Write-Host "[*] $args" -ForegroundColor Cyan }
function ok    { Write-Host "  -> $args" -ForegroundColor Green }
function warn  { Write-Host "[!] $args" -ForegroundColor Yellow }

function Get-UrlText {
    param([string]$Url)
    $resp = Invoke-WebRequest -Uri $Url -TimeoutSec 30 -UseBasicParsing
    return $resp.Content
}

function Get-WikisourceRaw {
    param([string]$Title)
    $encoded = [System.Uri]::EscapeDataString($Title).Replace("%2F", "/")
    return Get-UrlText "https://en.wikisource.org/w/index.php?title=$encoded&action=raw"
}

function Convert-WikiToMarkdown {
    param([string]$Text)
    $out = $Text
    $out = $out -replace "(?s)<noinclude>.*?</noinclude>", ""
    $out = $out -replace "\{\{[^{}]*\}\}", ""
    $out = $out -replace "'''(.*?)'''", '**$1**'
    $out = $out -replace "''(.*?)''", '*$1*'
    $out = $out -replace "====\s*(.*?)\s*====", '#### $1'
    $out = $out -replace "===\s*(.*?)\s*===", '### $1'
    $out = $out -replace "==\s*(.*?)\s*==", '## $1'
    $out = $out -replace "\[\[([^|\]]+)\|([^\]]+)\]\]", '$2'
    $out = $out -replace "\[\[([^\]]+)\]\]", '$1'
    $out = $out -replace "\[https?://[^\s\]]+\s+([^\]]+)\]", '$1'
    $out = $out -replace "&nbsp;", " "
    $out = $out -replace "`r`n", "`n"
    $out = $out -replace "`n{3,}", "`n`n"
    return $out.Trim()
}

function Build-TOC {
    param([string]$Text)
    $lines = @()
    $Text -split "`n" | ForEach-Object {
        if ($_ -match '^##\s+(.+)') {
            $s = $matches[1].Trim()
            $a = ($s -replace '　','') -replace ' ',''
            $lines += "- [$s](#$a)"
        }
    }
    return $lines -join "`n"
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

    $env:GIT_AUTHOR_DATE = "1990-04-04 08:00:00"
    $env:GIT_COMMITTER_DATE = "1990-04-04 08:00:00"
    if ($rootCommit) {
        git commit --amend --no-edit 2>$null
    } else {
        git commit -m "Initial commit" 2>$null
    }
    git branch -M main
    log "根提交: $(git rev-parse HEAD)"

    git branch | ForEach-Object {
        $b = $_.Trim().Replace('* ', '')
        if ($b -ne 'main') { git branch -D $b 2>$null; ok "已删除分支: $b" }
    }
}

function New-HistoricalCommit {
    param($Branch, $DateTs, $Tz, $Msg, $FilePath, $Text, $Parent)

    if (-not $Parent) {
        $Parent = git rev-list --max-parents=0 HEAD | Select-Object -First 1
    }

    $tmpWt = Join-Path $TMPDIR "wt-$([System.IO.Path]::GetRandomFileName())"
    Remove-Item -Recurse -Force $tmpWt -ErrorAction SilentlyContinue
    $wtResult = git worktree add --detach $tmpWt $Parent 2>&1
    if ($LASTEXITCODE -ne 0) {
        warn "无法创建 worktree: $wtResult"
        return
    }

    Push-Location $tmpWt
    try {
        $dir = Split-Path $FilePath -Parent
        if ($dir) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Set-Content -Path $FilePath -Value $Text -Encoding UTF8
        git add $FilePath

        $tree = git write-tree
        if ($LASTEXITCODE -ne 0 -or -not $tree) { throw "git write-tree 失败" }

        $commitContent = "tree $tree`nparent $Parent`nauthor $GIT_NAME <$GIT_EMAIL> $DateTs $Tz`ncommitter $GIT_NAME <$GIT_EMAIL> $DateTs $Tz`n`n$Msg`n"
        $objFile = Join-Path $TMPDIR "commit-$([System.IO.Path]::GetRandomFileName())"
        [System.IO.File]::WriteAllBytes($objFile, [System.Text.Encoding]::UTF8.GetBytes($commitContent))
        $ch = git hash-object -t commit -w $objFile --literally
        Remove-Item $objFile -Force
        if (-not $ch) { throw "git hash-object 返回空" }

        git update-ref "refs/heads/$Branch" $ch 2>$null
        if ($LASTEXITCODE -ne 0) { throw "git update-ref 失败" }
        ok "提交 ${Branch}: $ch"
    } catch {
        warn "提交 $Branch 失败: $_"
    } finally {
        Pop-Location
        git worktree remove $tmpWt -Force 2>$null
    }
}

function Get-BasicLawText {
    param([string[]]$RevisionNotes)

    $body = Convert-WikiToMarkdown (Get-WikisourceRaw "Basic_Law_of_the_Hong_Kong_Special_Administrative_Region")
    $annex1 = Convert-WikiToMarkdown (Get-WikisourceRaw "Basic_Law_of_the_Hong_Kong_Special_Administrative_Region/Annex_I_(2021)")
    $annex2 = Convert-WikiToMarkdown (Get-WikisourceRaw "Basic_Law_of_the_Hong_Kong_Special_Administrative_Region/Annex_II_(2021)")
    $annex3 = Convert-WikiToMarkdown (Get-WikisourceRaw "Basic_Law_of_the_Hong_Kong_Special_Administrative_Region/Annex_III")

    $notes = ($RevisionNotes | ForEach-Object { "> $_" }) -join "`n"
    $toc = Build-TOC $body

    return @"
# 中华人民共和国香港特别行政区基本法

$notes

$toc

$body

---

$annex1

---

$annex2

---

$annex3

---

资料来源：

- 香港基本法官方网站：https://www.basiclaw.gov.hk/
- 维基文库：https://en.wikisource.org/wiki/Basic_Law_of_the_Hong_Kong_Special_Administrative_Region
"@
}

function Build-MainBranch {
    log "构建主分支: 香港基本法..."

    New-Item -ItemType Directory -Path "宪制" -Force | Out-Null
    $file = "宪制/中华人民共和国香港特别行政区基本法.md"

    $text1990 = Get-BasicLawText @(
        "1990年4月4日第七届全国人民代表大会第三次会议通过",
        "1997年7月1日起施行"
    )
    Set-Content -Path $file -Value $text1990 -Encoding UTF8
    git add $file
    $env:GIT_AUTHOR_DATE = "1990-04-04 09:00:00"
    $env:GIT_COMMITTER_DATE = "1990-04-04 09:00:00"
    git commit -m "1990年4月4日第七届全国人民代表大会第三次会议通过《中华人民共和国香港特别行政区基本法》"

    $text2010 = Get-BasicLawText @(
        "1990年4月4日第七届全国人民代表大会第三次会议通过",
        "1997年7月1日起施行",
        "2010年8月28日第十一届全国人大常委会第十六次会议批准或备案附件一、附件二修正"
    )
    Set-Content -Path $file -Value $text2010 -Encoding UTF8
    git add $file
    $env:GIT_AUTHOR_DATE = "2010-08-28 09:00:00"
    $env:GIT_COMMITTER_DATE = "2010-08-28 09:00:00"
    git commit -m "2010年8月28日全国人大常委会批准或备案香港基本法附件一、附件二修正"

    $text2021 = Get-BasicLawText @(
        "1990年4月4日第七届全国人民代表大会第三次会议通过",
        "1997年7月1日起施行",
        "2010年8月28日第十一届全国人大常委会第十六次会议批准或备案附件一、附件二修正",
        "2021年3月30日第十三届全国人大常委会第二十七次会议修订附件一、附件二"
    )
    Set-Content -Path $file -Value $text2021 -Encoding UTF8
    git add $file
    $env:GIT_AUTHOR_DATE = "2021-03-30 09:00:00"
    $env:GIT_COMMITTER_DATE = "2021-03-30 09:00:00"
    git commit -m "2021年3月30日全国人大常委会修订香港基本法附件一、附件二"

    ok "主分支完成: $(git rev-parse HEAD)"
}

function Build-HistoricalBranches {
    log "构建殖民地时期宪制分支..."

    $letters = Convert-WikiToMarkdown (Get-WikisourceRaw "Hong_Kong_Letters_Patent_1917")
    $lettersText = @"
# Hong Kong Letters Patent 1917

> 1917年2月14日乔治五世颁布；1997年7月1日香港回归后失效。

$letters

资料来源：https://en.wikisource.org/wiki/Hong_Kong_Letters_Patent_1917
"@
    New-HistoricalCommit -Branch "英皇制诰" -DateTs "-1668729600" -Tz "+0000" `
        -Msg "1917年2月14日颁布《Hong Kong Letters Patent》" `
        -FilePath "宪制/Hong Kong Letters Patent 1917.md" -Text $lettersText

    $instructions = Convert-WikiToMarkdown (Get-WikisourceRaw "Hong_Kong_Royal_Instructions_1917")
    $instructionsText = @"
# Hong Kong Royal Instructions 1917

> 1917年2月14日乔治五世颁布；1997年7月1日香港回归后失效。

$instructions

资料来源：https://en.wikisource.org/wiki/Hong_Kong_Royal_Instructions_1917
"@
    New-HistoricalCommit -Branch "皇室训令" -DateTs "-1668729600" -Tz "+0000" `
        -Msg "1917年2月14日颁布《Hong Kong Royal Instructions》" `
        -FilePath "宪制/Hong Kong Royal Instructions 1917.md" -Text $instructionsText

    ok "历史分支创建完成"
}

function Main {
    log "=== legalize-hk 宪制历史构建 ==="
    log "目标仓库: $TARGET_REPO"
    ""

    Clean-Repo
    ""

    Build-MainBranch
    ""

    Build-HistoricalBranches
    ""

    git checkout main 2>$null
    log "=== 构建完成 ==="
    ""
    log "分支一览:"
    git branch -a
    ""
    log "主分支历史:"
    git log --format="%ai %s" --reverse main
}

try {
    Main
} finally {
    [Console]::OutputEncoding = $OLD_OUTPUT_ENCODING
    Remove-Item -Recurse -Force $TMPDIR -ErrorAction SilentlyContinue
}
