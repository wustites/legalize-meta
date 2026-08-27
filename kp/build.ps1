# kp/build.ps1 — 朝鲜宪制历史构建脚本
# 用法: .\kp\build.ps1 <目标Git仓库路径>
# 在指定 git 仓库中构建朝鲜宪制文件历史（主分支 = 现行《社会主义宪法》2023；1972 宪法历史分支）

param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$RepoPath
)

$ErrorActionPreference = "Stop"

$OLD_OUTPUT_ENCODING = [Console]::OutputEncoding
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$GIT_NAME = (git config user.name).Trim()
$GIT_EMAIL = (git config user.email).Trim()
if (-not $GIT_NAME) { $GIT_NAME = "legalize-meta" }
if (-not $GIT_EMAIL) { $GIT_EMAIL = "legalize-meta@example.invalid" }
$env:GIT_AUTHOR_NAME = $GIT_NAME
$env:GIT_AUTHOR_EMAIL = $GIT_EMAIL
$env:GIT_COMMITTER_NAME = $GIT_NAME
$env:GIT_COMMITTER_EMAIL = $GIT_EMAIL

$TMPDIR = Join-Path $env:TMP "legalize-kp-build-$([System.IO.Path]::GetRandomFileName())"
New-Item -ItemType Directory -Path $TMPDIR -Force | Out-Null

$SCRIPT_DIR = $PSScriptRoot

# 维基文库抓取缓存（持久化，避免 429 限流）
if ($env:LEGALIZE_WIKICACHE) { $WIKICACHE = $env:LEGALIZE_WIKICACHE }
else { $WIKICACHE = Join-Path ((@($env:HOME, $env:USERPROFILE) | Where-Object { $_ }) | Select-Object -First 1) ".cache/legalize-meta/wikisource" }
New-Item -ItemType Directory -Path $WIKICACHE -Force | Out-Null

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

function Get-WikisourceRaw {
    param([string]$Lang, [string]$Title)
    $keyBytes = [System.Text.Encoding]::UTF8.GetBytes("${Lang}|$Title")
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $key = ([System.BitConverter]::ToString($md5.ComputeHash($keyBytes))).Replace('-','').ToLower()
    $cache = Join-Path $WIKICACHE $key
    if (Test-Path $cache) { return [System.IO.File]::ReadAllText($cache, [System.Text.Encoding]::UTF8) }

    $encoded = [System.Uri]::EscapeDataString($Title)
    $url = if ($Lang -eq 'en') { "https://en.wikisource.org/w/index.php?action=raw" } else { "https://zh.wikisource.org/w/index.php?action=raw" }
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        try {
            $resp = Invoke-WebRequest -Uri "$url`&title=$encoded" -TimeoutSec 30 -UseBasicParsing
            if ($resp.StatusCode -eq 200) {
                [System.IO.File]::WriteAllText($cache, $resp.Content, [System.Text.Encoding]::UTF8)
                return $resp.Content
            }
        } catch {
        }
        $wait = $attempt * $attempt * 3; if ($wait -gt 60) { $wait = 60 }
        warn "  [fetch] $Lang:$Title 重试($attempt/6) ${wait}s"
        Start-Sleep -Seconds $wait
    }
    warn "  [fetch] 失败: $Lang:$Title"
    return $null
}

function Convert-WikiToMarkdown {
    param([string]$Text)
    $out = $Text
    while ($out.Contains('{{')) {
        $new = [regex]::Replace($out, '\{\{([^{}]*)\}\}', '', 'Singleline')
        if ($new -eq $out) { break }
        $out = $new
    }
    $out = [regex]::Replace($out, '(?is)<noinclude>.*?</noinclude>', '')
    $out = [regex]::Replace($out, '(?is)</?onlyinclude>', '')
    $out = [regex]::Replace($out, '<[^>]+>', '')
    $out = [regex]::Replace($out, "(?s)'''(.*?)'''", '**$1**')
    $out = [regex]::Replace($out, "(?s)''(.*?)''", '*$1*')
    $out = [regex]::Replace($out, '(?m)^====\s*(.*?)\s*====$', '#### $1')
    $out = [regex]::Replace($out, '(?m)^===\s*(.*?)\s*===$', '### $1')
    $out = [regex]::Replace($out, '(?m)^==\s*(.*?)\s*==$', '## $1')
    $out = [regex]::Replace($out, '\[\[[^\]|]+\|([^\]]+)\]\]', '$1')
    $out = [regex]::Replace($out, '\[\[([^\]]+)\]\]', '$1')
    $out = $out.Replace('&nbsp;', ' ')
    $out = $out.Replace("`r`n", "`n")
    $out = [regex]::Replace($out, '(?m)^[ \t\u3000:;]+', '')
    $keep = New-Object System.Collections.Generic.List[string]
    foreach ($ln in $out -split "`n") {
        $s = $ln.Trim()
        if ($s -match '^\[\[(Category|category|分類|分[類类])') { continue }
        if ($s.StartsWith('|') -and $s.Contains('=')) { continue }
        $keep.Add($ln)
    }
    $out = [string]::Join("`n", $keep)
    $out = [regex]::Replace($out, "`n{3,}", "`n`n")
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

function New-CommitObject {
    param([string]$Ref, [string]$DateTs, [string]$Tz, [string]$Msg, [string]$Parent)
    $parent = $null
    if ($Parent -eq "-") { $parent = "" }
    elseif ($Parent) { $parent = $Parent }
    else { $parent = (git rev-parse --verify HEAD 2>$null) }
    $tree = git write-tree
    $content = "tree $tree`n"
    if ($parent) { $content += "parent $parent`n" }
    $content += "author $GIT_NAME <$GIT_EMAIL> $DateTs $Tz`n"
    $content += "committer $GIT_NAME <$GIT_EMAIL> $DateTs $Tz`n"
    $content += "`n$Msg`n"
    $objFile = Join-Path $TMPDIR ("commit-" + [System.IO.Path]::GetRandomFileName())
    [System.IO.File]::WriteAllBytes($objFile, [System.Text.Encoding]::UTF8.GetBytes($content))
    $ch = git hash-object -t commit -w $objFile --literally
    Remove-Item $objFile -Force
    git update-ref "refs/heads/$Ref" $ch
}

function Clean-Repo {
    log "清理目标仓库..."
    $root = git rev-list --max-parents=0 HEAD 2>$null
    if ($root) {
        git checkout main 2>$null
        git reset --hard $root 2>$null
        git rm -r . --quiet 2>$null
    }
    foreach ($f in @(".gitignore", "LICENSE", "README.md")) {
        $src = Join-Path $SCRIPT_DIR $f
        if (Test-Path $src) { Copy-Item $src . -Force }
    }
    git add .
    git branch | ForEach-Object {
        $b = $_.Trim().Replace('* ', '')
        if ($b -ne 'main') { git branch -D $b 2>$null; ok "已删除分支: $b" }
    }
    New-CommitObject -Ref "main" -DateTs "1694134800" -Tz "+0800" -Msg "Initial commit" -Parent "-"
    git branch -M main
    log "根提交: $(git rev-parse HEAD)"
}

function New-HistoricalCommit {
    param($Branch, $DateTs, $Tz, $Msg, $FilePath, $Content, $Parent)
    if (-not $Parent) { $Parent = git rev-list --max-parents=0 HEAD | Select-Object -First 1 }
    $tmpWt = Join-Path $TMPDIR "wt-$([System.IO.Path]::GetRandomFileName())"
    Remove-Item -Recurse -Force $tmpWt -ErrorAction SilentlyContinue
    $wtResult = git worktree add --detach $tmpWt $Parent 2>&1
    if ($LASTEXITCODE -ne 0) { warn "无法创建 worktree: $wtResult"; return }
    Push-Location $tmpWt
    try {
        $dir = Split-Path $FilePath -Parent
        if ($dir) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Set-Content -Path $FilePath -Value $Content -Encoding UTF8
        git add $FilePath
        $tree = git write-tree
        $commitContent = "tree $tree`nparent $Parent`nauthor $GIT_NAME <$GIT_EMAIL> $DateTs $Tz`ncommitter $GIT_NAME <$GIT_EMAIL> $DateTs $Tz`n`n$Msg`n"
        $objFile = Join-Path $TMPDIR "commit-$([System.IO.Path]::GetRandomFileName())"
        [System.IO.File]::WriteAllBytes($objFile, [System.Text.Encoding]::UTF8.GetBytes($commitContent))
        $ch = git hash-object -t commit -w $objFile --literally
        Remove-Item $objFile -Force
        git update-ref "refs/heads/$Branch" $ch
        ok "提交 ${Branch}: $ch"
    } catch {
        warn "提交 $Branch 失败: $_"
    } finally {
        Pop-Location
        git worktree remove $tmpWt -Force 2>$null
    }
}

function Build-MainBranch {
    log "构建主分支: 朝鲜民主主义人民共和国社会主义宪法..."
    New-Item -ItemType Directory -Path "宪法" -Force | Out-Null
    $body = Convert-WikiToMarkdown (Get-WikisourceRaw -Lang "zh" -Title "朝鲜民主主义人民共和国社会主义宪法 (2023年)")
    $text = "# 朝鲜民主主义人民共和国社会主义宪法`n`n> 1972年12月27日通过《朝鲜民主主义人民共和国社会主义宪法》`n> 经1992、1998、2009、2010、2012、2013、2016、2019、2023年历次修订`n`n$(Build-TOC $body)`n`n$body`n`n---`n`n资料来源：https://zh.wikisource.org/wiki/朝鲜民主主义人民共和国社会主义宪法_(2023年)"
    Set-Content -Path "宪法/朝鲜民主主义人民共和国社会主义宪法.md" -Value $text -Encoding UTF8
    git add "宪法/朝鲜民主主义人民共和国社会主义宪法.md"
    New-CommitObject -Ref "main" -DateTs "1694134800" -Tz "+0800" -Msg "现行《朝鲜民主主义人民共和国社会主义宪法》（2023年修订文本）"
    ok "主分支完成: $(git rev-parse HEAD)"
}

function Build-HistoricalBranches {
    log "构建历史宪法分支..."
    $hist = @(
        @{Branch="1972宪法"; Ts="94266000"; Title="朝鲜民主主义人民共和国社会主义宪法 (1972年)"; Display="1972年宪法"; Note="1972年12月27日通过（《朝鲜民主主义人民共和国社会主义宪法》）"}
        @{Branch="1992宪法"; Ts="702781200"; Title="朝鲜民主主义人民共和国社会主义宪法 (1992年)"; Display="1992年修订"; Note="1992年4月9日修订"}
        @{Branch="1998宪法"; Ts="904957200"; Title="朝鲜民主主义人民共和国社会主义宪法 (1998年)"; Display="1998年修订"; Note="1998年9月5日修订"}
        @{Branch="2009宪法"; Ts="1239238800"; Title="朝鲜民主主义人民共和国社会主义宪法 (2009年)"; Display="2009年修订"; Note="2009年4月9日修订"}
        @{Branch="2010宪法"; Ts="1270774800"; Title="朝鲜民主主义人民共和国社会主义宪法 (2010年)"; Display="2010年修订"; Note="2010年4月9日修订"}
        @{Branch="2012宪法"; Ts="1334278800"; Title="朝鲜民主主义人民共和国社会主义宪法 (2012年)"; Display="2012年修订"; Note="2012年4月13日修订"}
        @{Branch="2013宪法"; Ts="1364778000"; Title="朝鲜民主主义人民共和国社会主义宪法 (2013年)"; Display="2013年修订"; Note="2013年4月1日修订"}
        @{Branch="2016宪法"; Ts="1467162000"; Title="朝鲜民主主义人民共和国社会主义宪法 (2016年)"; Display="2016年修订"; Note="2016年6月29日修订"}
        @{Branch="2019宪法"; Ts="1554944400"; Title="朝鲜民主主义人民共和国社会主义宪法 (2019年)"; Display="2019年修订"; Note="2019年4月11日修订"}
    )
    foreach ($h in $hist) {
        $body = Convert-WikiToMarkdown (Get-WikisourceRaw -Lang "zh" -Title $h.Title)
        $text = "# $($h.Display)`n`n> $($h.Note)`n`n$(Build-TOC $body)`n`n$body`n`n---`n`n资料来源：https://zh.wikisource.org/wiki/$($h.Title)"
        New-HistoricalCommit -Branch $h.Branch -DateTs $h.Ts -Tz "+0800" -Msg $h.Note `
            -FilePath "宪法/$($h.Branch).md" -Content $text
    }
    ok "历史分支创建完成"
}

function Main {
    log "=== legalize-kp 宪制历史构建 ==="
    log "目标仓库: $TARGET_REPO"
    ""
    Clean-Repo; ""; Build-MainBranch; ""; Build-HistoricalBranches; ""
    git checkout main 2>$null
    log "=== 构建完成 ==="
    ""; log "分支一览:"; git branch -a | Out-Host; ""; log "主分支历史:"; git log --format="%ai %s" --reverse main | Out-Host
}

Main
