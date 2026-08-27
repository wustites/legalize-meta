# tw/build.ps1 — 台湾宪制历史构建脚本
# 用法: .\tw\build.ps1 <目标Git仓库路径>
# 在指定 git 仓库中构建台湾宪制文件历史（主分支 + 历史宪法分支）

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

$TMPDIR = Join-Path $env:TMP "legalize-tw-build-$([System.IO.Path]::GetRandomFileName())"
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

function Get-ZhWikisourceRaw {
    param([string]$Title)
    $keyBytes = [System.Text.Encoding]::UTF8.GetBytes("zh|$Title")
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $key = ([System.BitConverter]::ToString($md5.ComputeHash($keyBytes))).Replace('-','').ToLower()
    $cache = Join-Path $WIKICACHE $key
    if (Test-Path $cache) { return [System.IO.File]::ReadAllText($cache, [System.Text.Encoding]::UTF8) }

    $encoded = [System.Uri]::EscapeDataString($Title)
    $url = "https://zh.wikisource.org/w/index.php?action=raw&title=$encoded"
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        try {
            $resp = Invoke-WebRequest -Uri $url -TimeoutSec 30 -UseBasicParsing
            if ($resp.StatusCode -eq 200) {
                [System.IO.File]::WriteAllText($cache, $resp.Content, [System.Text.Encoding]::UTF8)
                return $resp.Content
            }
        } catch {
            # 429/网络错误：退避重试
        }
        $wait = $attempt * $attempt * 3; if ($wait -gt 60) { $wait = 60 }
        warn "  [fetch] zh:$Title 重试($attempt/6) ${wait}s"
        Start-Sleep -Seconds $wait
    }
    warn "  [fetch] 失败: zh:$Title"
    return $null
}

function Convert-WikiToMarkdown {
    param([string]$Text)
    $out = $Text
    # 去除 {{...}} 模板（含多行/嵌套）
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

# 手动构造 commit 对象：GIT 的 GIT_AUTHOR_DATE 无法解析早于 1970 的日期。
# $Parent: 省略=自动取当前 HEAD；"-"=无父；否则用指定父提交。
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

    New-CommitObject -Ref "main" -DateTs "-694911600" -Tz "+0800" -Msg "Initial commit" -Parent "-"
    git branch -M main
    log "根提交: $(git rev-parse HEAD)"
}

function New-HistoricalCommit {
    param($Branch, $DateTs, $Tz, $Msg, $FilePath, $Content, $Parent)

    if (-not $Parent) {
        $Parent = git rev-list --max-parents=0 HEAD | Select-Object -First 1
    }

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
    log "构建主分支: 宪法本文 + 增修条文..."

    New-Item -ItemType Directory -Path "宪法" -Force | Out-Null
    $constitutionFile = "宪法/中华民国宪法.md"
    $amendmentFile = "宪法/中华民国宪法增修条文.md"

    $body = Convert-WikiToMarkdown (Get-ZhWikisourceRaw "中華民國憲法")
    $textConstitution = "# 中华民国宪法`n`n> 1946年12月25日制宪国民大会通过`n> 1947年1月1日国民政府公布`n> 1947年12月25日施行`n`n$(Build-TOC $body)`n`n$body"
    Set-Content -Path $constitutionFile -Value $textConstitution -Encoding UTF8
    git add $constitutionFile
    New-CommitObject -Ref "main" -DateTs "-694911600" -Tz "+0800" -Msg "1947年12月25日施行《中华民国宪法》"
    ok "本文提交: $(git rev-parse HEAD)"

    $amendList = @(
        @{Title="中華民國憲法增修條文 (民國80年)"; Date="1991-05-01"; Ts="673059600"; Msg="1991年5月1日制定公布（第1次增修）"}
        @{Title="中華民國憲法增修條文 (民國81年)"; Date="1992-05-28"; Ts="707014800"; Msg="1992年5月28日增订公布第11至18条（第2次增修）"}
        @{Title="中華民國憲法增修條文 (民國83年)"; Date="1994-08-01"; Ts="775702800"; Msg="1994年8月1日修正公布全文（第3次增修）"}
        @{Title="中華民國憲法增修條文 (民國86年)"; Date="1997-07-21"; Ts="869446800"; Msg="1997年7月21日修正公布全文（第4次增修）"}
        @{Title="中華民國憲法增修條文 (民國88年)"; Date="1999-09-15"; Ts="937357200"; Msg="1999年9月15日修正公布（第5次增修，后经大法官释字第499号失效）"}
        @{Title="中華民國憲法增修條文 (民國89年)"; Date="2000-04-25"; Ts="956624400"; Msg="2000年4月25日修正公布全文（第6次增修）"}
        @{Title="中華民國憲法增修條文 (民國93年立法94年公布)"; Date="2005-06-10"; Ts="1118365200"; Msg="2005年6月10日修正公布（第7次增修，现行）"}
    )

    $notes = "> 1947年12月25日施行《中华民国宪法》本文"
    foreach ($a in $amendList) {
        log "  提交: $($a.Date) — $($a.Msg)"
        $amendBody = Convert-WikiToMarkdown (Get-ZhWikisourceRaw $a.Title)
        $notes = "$notes`n> $($a.Msg)"
        $textAmend = "# 中华民国宪法增修条文`n`n$notes`n`n$(Build-TOC $amendBody)`n`n$amendBody"
        Set-Content -Path $amendmentFile -Value $textAmend -Encoding UTF8
        git add $amendmentFile
        New-CommitObject -Ref "main" -DateTs $a.Ts -Tz "+0800" -Msg $a.Msg
        ok "  提交完成: $(git rev-parse HEAD)"
    }

    ok "主分支完成: $(git rev-parse HEAD)"
}

function Add-Pre1947 {
    param($Branch, $Title, $DateTs, $Display, $Note)
    $body = Convert-WikiToMarkdown (Get-ZhWikisourceRaw $Title)
    $toc = Build-TOC $body
    $text = "# $Display`n`n> $Note`n`n$toc`n`n$body`n`n---`n`n资料来源：https://zh.wikisource.org/wiki/$Title"
    New-HistoricalCommit -Branch $Branch -DateTs $DateTs -Tz "+0800" -Msg $Note `
        -FilePath "宪法/$Branch.md" -Content $text
}

function Build-HistoricalBranches {
    log "构建历史宪法分支..."

    $body = Convert-WikiToMarkdown (Get-ZhWikisourceRaw "中華民國憲法")
    $toc = Build-TOC $body
    $text = "# 中华民国宪法`n`n> 1946年12月25日制宪国民大会通过`n> 1947年1月1日国民政府公布`n> 1947年12月25日施行`n`n$toc`n`n$body"

    New-HistoricalCommit -Branch "1947宪法" -DateTs "-726447600" -Tz "+0800" `
        -Msg "1946年12月25日制宪国民大会通过《中华民国宪法》" `
        -FilePath "宪法/中华民国宪法.md" -Content $text

    # 1947 年之前的中华民国制宪沿革（历史分支）
    Add-Pre1947 -Branch "临时约法" -Title "中華民國臨時約法" -DateTs "-1824332400" -Display "中华民国临时约法" -Note "1912年3月11日南京临时政府公布（《中华民国临时约法》）"
    Add-Pre1947 -Branch "袁记约法" -Title "中華民國約法" -DateTs "-1756854000" -Display "中华民国约法" -Note "1914年5月1日公布（《中华民国约法》，世称袁记约法）"
    Add-Pre1947 -Branch "曹锟宪法" -Title "曹錕憲法" -DateTs "-1458860400" -Display "曹锟宪法" -Note "1923年10月10日公布（《中华民国宪法》，世称曹锟宪法）"
    Add-Pre1947 -Branch "训政约法" -Title "中華民國訓政時期約法" -DateTs "-1219446000" -Display "中华民国训政时期约法" -Note "1931年5月12日国民会议制定（《中华民国训政时期约法》）"
    Add-Pre1947 -Branch "五五宪草" -Title "五五憲草" -DateTs "-1062198000" -Display "中华民国宪法草案" -Note "1936年5月5日国民政府公布（《中华民国宪法草案》，世称五五宪草，未施行）"

    ok "历史分支创建完成"
}

function Main {
    log "=== legalize-tw 宪制历史构建 ==="
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
    git branch -a | Out-Host
    ""
    log "主分支历史:"
    git log --format="%ai %s" --reverse main | Out-Host
}

Main
