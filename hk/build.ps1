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

function Get-EpochAt {
    # "YYYY-MM-DD" -> 当日 00:00 +0800 的 epoch
    # 必须显式给出 epoch：GIT_AUTHOR_DATE="YYYY-MM-DD 00:00:00" 会按构建机本地时区解析；
    # 而 "@<epoch> +0800" 则是确定性的。
    param([string]$Date, [int]$OffsetHours = 8)
    $d = [datetime]::ParseExact($Date, "yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture)
    $off = [System.TimeSpan]::FromHours($OffsetHours)
    return [DateTimeOffset]::new([DateTime]::SpecifyKind($d, [DateTimeKind]::Utc), $off).ToUnixTimeSeconds()
}

function log   { Write-Host "[*] $args" -ForegroundColor Cyan }
function ok    { Write-Host "  -> $args" -ForegroundColor Green }
function warn  { Write-Host "[!] $args" -ForegroundColor Yellow }

function Get-Cached {
    param([string]$Key, [string]$Url, [string]$UserAgent)
    $keyBytes = [System.Text.Encoding]::UTF8.GetBytes($Key)
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $name = ([System.BitConverter]::ToString($md5.ComputeHash($keyBytes))).Replace('-','').ToLower()
    $cache = Join-Path $WIKICACHE $name
    if (Test-Path $cache) { return [System.IO.File]::ReadAllText($cache, [System.Text.Encoding]::UTF8) }

    for ($attempt = 1; $attempt -le 6; $attempt++) {
        try {
            $resp = Invoke-WebRequest -Uri $Url -TimeoutSec 45 -UseBasicParsing -Headers @{ "User-Agent" = $UserAgent }
            if ($resp.StatusCode -eq 200 -and $resp.Content) {
                [System.IO.File]::WriteAllText($cache, $resp.Content, [System.Text.Encoding]::UTF8)
                return $resp.Content
            }
        } catch {
            # 429/网络错误：退避重试
        }
        $wait = $attempt * $attempt * 3; if ($wait -gt 60) { $wait = 60 }
        warn "  [fetch] $Url 重试($attempt/6) ${wait}s"
        Start-Sleep -Seconds $wait
    }
    warn "  [fetch] 失败: $Url"
    return $null
}

$UA = "legalize-meta/1.0 (constitutional text build script)"

function Get-WikisourceRaw {
    param([string]$Title)
    $encoded = [System.Uri]::EscapeDataString($Title).Replace("%2F", "/")
    return Get-Cached -Key "en|$Title" -Url "https://en.wikisource.org/w/index.php?title=$encoded&action=raw" -UserAgent $UA
}

function Get-WikisourcePage {
    # 校订文本位于 Page: 命名空间
    param([string]$Base, [int]$Number)
    return Get-WikisourceRaw "Page:$Base/$Number"
}

function Get-BasicLawPage {
    # 香港基本法官方网站（官方繁体中文全文）
    param([string]$Page)
    return Get-Cached -Key "basiclaw|$Page" -Url "https://www.basiclaw.gov.hk/tc/basiclaw/$Page.html" -UserAgent $UA
}

function Assert-Body {
    param([string]$Title, [string]$Text, [int]$MinBytes)
    if (-not $Text -or $Text.Length -lt $MinBytes) {
        warn "  正文过短（$($Text.Length) 字符 < $MinBytes），跳过：$Title"
        return $false
    }
    return $true
}

function Convert-WikiToMarkdown {
    param([string]$Text)
    if (-not $Text) { return "" }
    $out = $Text

    # 1) 先展开"带正文"的排版模板，否则内容（如人名）会随模板一起被丢弃
    $unwrap = @('Sc','sc','SmallCaps','Big','big','Center','centre','Right','right block','larger','x-larger','hdr')
    foreach ($n in $unwrap) {
        $pat = "\{\{\s*$([regex]::Escape($n))\s*\|((?:[^{}]|\{\{)*?)\}\}"
        $prev = $null
        while ($prev -ne $out) {
            $prev = $out
            $out = [regex]::Replace($out, $pat, {
                param($m) ([regex]::Replace($m.Groups[1].Value, '\|\s*\d+\s*=', '|'))
            })
        }
    }
    # 2) 丢弃纯装饰 / 元数据模板
    $out = [regex]::Replace($out, '(?is)\{\{\s*(?:rule|sidenotes\s+(?:begin|end)|gap|nbsp|pagequality|rh|running\s?head|header|footer|PPB|br|center|centre|right|sc|Sc|ts|vtt|right\s+block|Big|big)\s*(?:\|[^{}]*)?\}\}', '')
    $out = [regex]::Replace($out, '(?is)<noinclude>.*?</noinclude>', '')
    # 3) 反复剥掉最内层的 {{...}}
    $prev = $null
    while ($prev -ne $out) {
        $prev = $out
        $out = [regex]::Replace($out, '(?s)\{\{([^{}]*)\}\}', '')
    }
    # 4) 维基表格转纯文本
    $out = [regex]::Replace($out, '(?s)\{\|(.*?)\|\}', {
        param($m)
        $rows = @()
        foreach ($ln in ($m.Groups[1].Value -split "`n")) {
            $s = $ln.Trim()
            if (-not $s -or $s.StartsWith('{|')) { continue }
            if ($s -match '^[-+!| ]*[-+!]([-+!| ])*$') { continue }
            $s = [regex]::Replace($s, '^\|[-+!]?\s*', '')
            $s = [regex]::Replace($s, '\s*\|\s*$', '')
            $s = $s.Trim('|').Trim()
            foreach ($cell in ([regex]::Split($s, '\s*\|\|\s*'))) {
                $c = $cell.Trim()
                if ($c) { $rows += $c }
            }
        }
        "`n" + ($rows -join "`n") + "`n"
    })
    $out = [regex]::Replace($out, '(?s)\{\|.*?\}\}', '')
    $out = [regex]::Replace($out, '(?is)</?onlyinclude>', '')
    $out = [regex]::Replace($out, '(?is)<section\b[^>]*/?>', '')
    $out = [regex]::Replace($out, '(?is)<pages\b[^>]*/?>', '')
    $out = [regex]::Replace($out, '(?i)<br\s*/?>', "`n")
    $out = [regex]::Replace($out, '<[^>]+>', '')
    $out = [regex]::Replace($out, "(?s)BOLD_I($1)BOLD_I", '**$1**')
    $out = [regex]::Replace($out, "(?s)ITAL($1)ITAL", '*$1*')
    $out = [regex]::Replace($out, '(?m)^====\s*(.*?)\s*====$', '#### $1')
    $out = [regex]::Replace($out, '(?m)^===\s*(.*?)\s*===$', '### $1')
    $out = [regex]::Replace($out, '(?m)^==\s*(.*?)\s*==$', '## $1')
    $out = [regex]::Replace($out, '(?i)\[\[(?:Category|分類|分类)[:：][^\]]*\]\]', '')
    $out = [regex]::Replace($out, '\[\[[^|\]]+\|([^\]]+)\]\]', '$1')
    $out = [regex]::Replace($out, '\[\[([^\]]+)\]\]', '$1')
    $out = [regex]::Replace($out, '\[(?:https?|ftp)://\S+\s+([^\]]+)\]', '$1')
    $out = $out -replace '&nbsp;', ' '
    $out = $out -replace "`r`n", "`n"
    $out = [regex]::Replace($out, '(?m)[ \t]+$', '')
    $out = [regex]::Replace($out, "`n{3,}", "`n`n")
    return $out.Trim()
}

function Convert-HtmlToMarkdown {
    # basiclaw.gov.hk HTML -> Markdown
    param([string]$Html)
    if (-not $Html) { return "" }
    $body = $Html
    $m = [regex]::Match($body, '(?s)<!--\s*Content Begin\s*-->(.*?)<!--\s*Content End\s*-->')
    if ($m.Success) { $body = $m.Groups[1].Value }
    $body = [regex]::Replace($body, '(?is)<script\b.*?</script>', '')
    $body = [regex]::Replace($body, '(?is)<style\b.*?</style>', '')
    $body = [regex]::Replace($body, '(?s)<!--.*?-->', '')
    $body = [regex]::Replace($body, '(?is)<div class="nav-btn-wrap.*?</div>', '')
    # 标题整体下沉两级（本脚本另行输出 "## 章节名"）
    $body = [regex]::Replace($body, '(?is)<h([1-6])[^>]*>(.*?)</h\1>', {
        param($mm)
        $lvl = [Math]::Min(6, [int]$mm.Groups[1].Value + 2)
        "`n`n" + ('#' * $lvl) + ' ' + $mm.Groups[2].Value + "`n`n"
    })
    $body = [regex]::Replace($body, '(?i)<hr\s*/?>', "`n`n")
    foreach ($tag in @('p','div','tr','dd')) {
        $body = [regex]::Replace($body, "(?i)<$tag\b[^>]*>", "`n`n")
        $body = [regex]::Replace($body, "(?i)</$tag>", "`n`n")
    }
    $body = [regex]::Replace($body, '(?i)<li\b[^>]*>', "`n- ")
    $body = [regex]::Replace($body, '(?i)</li>', '')
    $body = [regex]::Replace($body, '(?i)<dt\b[^>]*>', "`n- ")
    $body = [regex]::Replace($body, '(?i)<br\s*/?>', "`n")
    $body = [regex]::Replace($body, '<[^>]+>', '')
    $body = [System.Net.WebUtility]::HtmlDecode($body)
    $body = $body -replace ([char]0x00A0), ' '
    $body = [regex]::Replace($body, '[ \t]+', ' ')
    $body = [regex]::Replace($body, ' *\n *', "`n")
    $body = [regex]::Replace($body, "`n{3,}", "`n`n")
    return $body.Trim()
}

function Get-MdAnchor {
    # GitHub 锚点（slug）规则：转小写 -> 去掉标点 -> 空白（含全角空格）转连字符。
    # 原实现用 -replace 直接删掉空白，得到 `第一章总纲`，与 GitHub 的 `第一章-总则` 不符，链接失效。
    param([string]$Heading)
    $a = $Heading.Trim().ToLowerInvariant()
    $a = [regex]::Replace($a, '[^\w\s-]', '')
    $a = [regex]::Replace($a, '\s', '-')
    return $a
}

function Build-TOC {
    param([string]$Text)
    $lines = @()
    foreach ($ln in ($Text -split "`n")) {
        if ($ln -match '^##\s+(.+)') {
            $s = $matches[1].Trim()
            $lines += "- [$s](#$(Get-MdAnchor $s))"
        }
    }
    return ($lines -join "`n")
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

    $env:GIT_AUTHOR_DATE = "@$(Get-EpochAt '1990-04-04') +0800"
    $env:GIT_COMMITTER_DATE = "@$(Get-EpochAt '1990-04-04') +0800"
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

# 官方站点分节：主席令 / 序言 / 九章 / 三个附件
$BASICLAW_SECTIONS = @(
    @{Page="decree";   Title="中华人民共和国主席令（第二十六号）"},
    @{Page="preamble"; Title="序言"},
    @{Page="chapter1"; Title="第一章　总则"},
    @{Page="chapter2"; Title="第二章　中央和香港特别行政区的关系"},
    @{Page="chapter3"; Title="第三章　居民的基本权利和义务"},
    @{Page="chapter4"; Title="第四章　政治体制"},
    @{Page="chapter5"; Title="第五章　经济"},
    @{Page="chapter6"; Title="第六章　教育、科学、文化、体育、宗教、劳工和社会服务"},
    @{Page="chapter7"; Title="第七章　对外事务"},
    @{Page="chapter8"; Title="第八章　本法的解释和修改"},
    @{Page="chapter9"; Title="第九章　附则"},
    @{Page="annex1";   Title="附件一　香港特别行政区行政长官的产生办法"},
    @{Page="annex2";   Title="附件二　香港特别行政区立法会的产生办法和表决程序"},
    @{Page="annex3";   Title="附件三　在香港特别行政区实施的全国性法律"}
)

function Write-BasicLaw {
    param([string[]]$RevisionNotes)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("")

    foreach ($sec in $BASICLAW_SECTIONS) {
        $html = Get-BasicLawPage $sec.Page
        if (-not $html) { warn "  抓取失败，跳过：$($sec.Page)"; continue }
        $conv = Convert-HtmlToMarkdown $html
        # 附件页自带标题，与本节标题重复，丢弃其首个标题行
        if ($sec.Page -like "annex*") {
            $lines = @($conv -split "`n")
            if ($lines.Count -gt 1 -and $lines[0] -match '^#+\s*附件') {
                $conv = ($lines[1..($lines.Count - 1)]) -join "`n"
            }
        }
        [void]$sb.Append("## $($sec.Title)`n`n")
        [void]$sb.Append($conv)
        [void]$sb.Append("`n`n")
    }

    $body = $sb.ToString().Trim()
    if (-not (Assert-Body -Title "基本法正文" -Text $body -MinBytes 20000)) { return $null }

    $notes = ($RevisionNotes | ForEach-Object { "> $_" }) -join "`n"
    return @"
# 中华人民共和国香港特别行政区基本法

$notes
> 正文据香港基本法官方网站（basiclaw.gov.hk）官方繁体中文版，章节标题为简体

$(Build-TOC $body)

$body

---

资料来源：

- 香港基本法官方网站（繁体中文）：https://www.basiclaw.gov.hk/tc/basiclaw/index.html
- 香港基本法官方网站（English）：https://www.basiclaw.gov.hk/en/basiclaw/index.html
"@
}

function Build-MainBranch {
    log "构建主分支: 香港基本法..."

    New-Item -ItemType Directory -Path "宪制" -Force | Out-Null
    $file = "宪制/中华人民共和国香港特别行政区基本法.md"

    $stages = @(
        @{Date="1990-04-04"; Notes=@("1990年4月4日第七届全国人民代表大会第三次会议通过","1997年7月1日起施行");
         Msg="1990年4月4日第七届全国人民代表大会第三次会议通过《中华人民共和国香港特别行政区基本法》"},
        @{Date="2010-08-28"; Notes=@("1990年4月4日第七届全国人民代表大会第三次会议通过","1997年7月1日起施行","2010年8月28日第十一届全国人大常委会第十六次会议批准或备案附件一、附件二修正");
         Msg="2010年8月28日全国人大常委会批准或备案香港基本法附件一、附件二修正"},
        @{Date="2021-03-30"; Notes=@("1990年4月4日第七届全国人民代表大会第三次会议通过","1997年7月1日起施行","2010年8月28日第十一届全国人大常委会第十六次会议批准或备案附件一、附件二修正","2021年3月30日第十三届全国人大常委会第二十七次会议修订附件一、附件二");
         Msg="2021年3月30日全国人大常委会修订香港基本法附件一、附件二"}
    )

    foreach ($st in $stages) {
        $text = Write-BasicLaw $st.Notes
        if (-not $text) { warn "  主分支跳过 $($st.Date)"; break }
        Set-Content -Path $file -Value $text -Encoding UTF8
        git add $file
        $env:GIT_AUTHOR_DATE = "@$(Get-EpochAt $st.Date) +0800"
        $env:GIT_COMMITTER_DATE = "@$(Get-EpochAt $st.Date) +0800"
        git commit -q -m $st.Msg
    }

    ok "主分支完成: $(git rev-parse HEAD)"
}

# 校订文本位于 Page: 命名空间；第 5 页是两份文件的交界页，需按分节标记裁切
$COLONIAL_PDF = "Hong Kong Letters Patent and Royal Instructions 1917.pdf"

function Get-ColonialText {
    param([ValidateSet("end","begin")][string]$Mode, [string]$Section, [int]$FromPage, [int]$ToPage)
    $sb = New-Object System.Text.StringBuilder
    for ($i = $FromPage; $i -le $ToPage; $i++) {
        $raw = Get-WikisourcePage $COLONIAL_PDF $i
        if (-not $raw) { return $null }
        if ($i -eq 5) {
            if ($Mode -eq "end") {
                $m = [regex]::Match($raw, '(?s)^(.*?)<section end="' + [regex]::Escape($Section) + '" />')
                if ($m.Success) { $raw = $m.Groups[1].Value }
            } else {
                $m = [regex]::Match($raw, '(?s)<section begin="' + [regex]::Escape($Section) + '" />(.*)$')
                if ($m.Success) { $raw = $m.Groups[1].Value }
            }
        }
        [void]$sb.Append($raw)
        [void]$sb.Append("`n`n")
    }
    return (Convert-WikiToMarkdown $sb.ToString())
}

function Build-HistoricalBranches {
    log "构建殖民地时期宪制分支..."

    $letters = Get-ColonialText -Mode "end" -Section "HKLP1917" -FromPage 1 -ToPage 5
    if (Assert-Body -Title "英皇制诰" -Text $letters -MinBytes 10000) {
        $lettersText = @"
# Hong Kong Letters Patent 1917

> 1917年2月14日乔治五世颁布（1917年4月20日生效）；1997年7月1日香港回归后失效。
> 文本据 en.wikisource 的 Page: 校订文本（《Hong Kong Letters Patent and Royal Instructions 1917.pdf》第 1—5 页，止于 HKLP1917 分节）。

$(Build-TOC $letters)

$letters

---

资料来源：https://en.wikisource.org/wiki/Hong_Kong_Letters_Patent_1917
"@
        New-HistoricalCommit -Branch "英皇制诰" -DateTs "-1668729600" -Tz "+0000" `
            -Msg "1917年2月14日颁布《Hong Kong Letters Patent》" `
            -FilePath "宪制/Hong Kong Letters Patent 1917.md" -Text $lettersText
    }

    $instructions = Get-ColonialText -Mode "begin" -Section "HKRI1917" -FromPage 5 -ToPage 12
    if (Assert-Body -Title "皇室训令" -Text $instructions -MinBytes 10000) {
        $instructionsText = @"
# Hong Kong Royal Instructions 1917

> 1917年2月14日与《英皇制诰》同期颁布（1917年4月20日生效）；1997年7月1日香港回归后失效。
> 文本据 en.wikisource 的 Page: 校订文本（《Hong Kong Letters Patent and Royal Instructions 1917.pdf》第 5—12 页，起于 HKRI1917 分节）。

$(Build-TOC $instructions)

$instructions

---

资料来源：https://en.wikisource.org/wiki/Hong_Kong_Royal_Instructions_1917
"@
        New-HistoricalCommit -Branch "皇室训令" -DateTs "-1668729600" -Tz "+0000" `
            -Msg "1917年2月14日颁布《Hong Kong Royal Instructions》" `
            -FilePath "宪制/Hong Kong Royal Instructions 1917.md" -Text $instructionsText
    }

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
    log "主分支历史（早于 1970 的提交 git log 无法显示日期，请用 git cat-file -p 查看）:"
    git log --format="%ad %s" --reverse main
}

try {
    Main
} finally {
    [Console]::OutputEncoding = $OLD_OUTPUT_ENCODING
    Remove-Item -Recurse -Force $TMPDIR -ErrorAction SilentlyContinue
}
