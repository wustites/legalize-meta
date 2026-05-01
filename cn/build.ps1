# meta/build.ps1 — 宪法历史构建脚本
# 用法: .\cn\build.ps1 <目标Git仓库路径>
# 在指定的 git 仓库中构建完整的宪法历史（主分支 + 历史宪法分支）
# todo: git push --force

param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$RepoPath
)

$ErrorActionPreference = "Stop"

# git show 输出 UTF-8，确保 PowerShell 正确解码中文
$OLD_OUTPUT_ENCODING = [Console]::OutputEncoding
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$GIT_NAME = (git config user.name).Trim()
$GIT_EMAIL = (git config user.email).Trim()
$env:GIT_AUTHOR_NAME = $GIT_NAME
$env:GIT_AUTHOR_EMAIL = $GIT_EMAIL
$env:GIT_COMMITTER_NAME = $GIT_NAME
$env:GIT_COMMITTER_EMAIL = $GIT_EMAIL

$TMPDIR = Join-Path $env:TMP "legalize-build-$([System.IO.Path]::GetRandomFileName())"
New-Item -ItemType Directory -Path $TMPDIR -Force | Out-Null

$SCRIPT_DIR = $PSScriptRoot  # 脚本所在目录（含 LICENSE/README.md）

$TARGET_REPO = Resolve-Path -Path $RepoPath -ErrorAction SilentlyContinue
if (-not $TARGET_REPO) {
    New-Item -ItemType Directory -Path $RepoPath -Force | Out-Null
    Set-Location $RepoPath
    git init
    $TARGET_REPO = Resolve-Path $RepoPath
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

# ============================================================
# 0. 克隆数据源
# ============================================================
function Clone-Sources {
    log "克隆数据源..."

    $constitutionDir = Join-Path $TMPDIR "chinese-constitution"
    if (-not (Test-Path $constitutionDir)) {
        git clone --depth=10 "https://github.com/tianyikillua/chinese-constitution.git" $constitutionDir
    } else { log "  chinese-constitution 已存在" }

    $lawsDir = Join-Path $TMPDIR "Chinese_Laws"
    if (-not (Test-Path $lawsDir)) {
        git clone --depth=5 "https://github.com/risshun/Chinese_Laws.git" $lawsDir
    } else { log "  Chinese_Laws 已存在" }

    return @{constitution=$constitutionDir; laws=$lawsDir}
}

# ============================================================
# 1. 清理目标仓库
# ============================================================
function Clean-Repo {
    log "清理目标仓库..."

    $rootCommit = git rev-list --max-parents=0 HEAD 2>$null
    if ($rootCommit) {
        git checkout main 2>$null
        git reset --hard $rootCommit 2>$null
        # 完全清空索引和工作树
        git rm -r . --quiet 2>$null
    }

    # 从源仓库覆盖 LICENSE、README.md、.gitignore
    foreach ($f in @(".gitignore", "LICENSE", "README.md")) {
        $src = Join-Path $SCRIPT_DIR $f
        if (Test-Path $src) { Copy-Item $src . -Force }
    }
    git add .

    $env:GIT_AUTHOR_DATE = "1982-12-04 08:00:00"
    $env:GIT_COMMITTER_DATE = "1982-12-04 08:00:00"
    if ($rootCommit) {
        git commit --amend --no-edit 2>$null
    } else {
        git commit -m "Initial commit" 2>$null
    }
    log "根提交: $(git rev-parse HEAD)"

    # 删除所有非 main 的分支
    git branch | ForEach-Object {
        $b = $_.Trim().Replace('* ', '')
        if ($b -ne 'main') { git branch -D $b 2>$null; ok "已删除分支: $b" }
    }
}

# ============================================================
# 2. 构建主分支 — 1982 宪法及修正案
# ============================================================
function Build-MainBranch {
    param($Sources)

    log "构建主分支: 1982 宪法及修正案..."
    $src = $Sources.constitution

    $versions = @(
        @{Hash="1fb3f30"; Date="1982-12-04"; Msg="1982年12月4日第五届全国人民代表大会第五次会议通过《中华人民共和国宪法》"}
        @{Hash="08dcbc4"; Date="1988-04-12"; Msg="1988年4月12日第七届全国人民代表大会第一次会议通过宪法修正案"}
        @{Hash="c53dd9b"; Date="1993-03-29"; Msg="1993年3月29日第八届全国人民代表大会第一次会议通过宪法修正案"}
        @{Hash="e4132c5"; Date="1999-03-15"; Msg="1999年3月15日第九届全国人民代表大会第二次会议通过宪法修正案"}
        @{Hash="b913443"; Date="2004-03-14"; Msg="2004年3月14日第十届全国人民代表大会第二次会议通过宪法修正案"}
        @{Hash="12b6d7b"; Date="2018-03-11"; Msg="2018年3月11日第十三届全国人民代表大会第一次会议通过宪法修正案"}
    )

    $headers = @{
        "1fb3f30" = @("> 1982年12月4日第五届全国人民代表大会第五次会议通过")
        "08dcbc4" = @("> 1982年12月4日第五届全国人民代表大会第五次会议通过", "> 1988年4月12日第七届全国人民代表大会第一次会议修正")
        "c53dd9b" = @("> 1982年12月4日第五届全国人民代表大会第五次会议通过", "> 1988年4月12日第七届全国人民代表大会第一次会议修正", "> 1993年3月29日第八届全国人民代表大会第一次会议修正")
        "e4132c5" = @("> 1982年12月4日第五届全国人民代表大会第五次会议通过", "> 1988年4月12日第七届全国人民代表大会第一次会议修正", "> 1993年3月29日第八届全国人民代表大会第一次会议修正", "> 1999年3月15日第九届全国人民代表大会第二次会议修正")
        "b913443" = @("> 1982年12月4日第五届全国人民代表大会第五次会议通过", "> 1988年4月12日第七届全国人民代表大会第一次会议修正", "> 1993年3月29日第八届全国人民代表大会第一次会议修正", "> 1999年3月15日第九届全国人民代表大会第二次会议修正", "> 2004年3月14日第十届全国人民代表大会第二次会议修正")
        "12b6d7b" = @("> 1982年12月4日第五届全国人民代表大会第五次会议通过", "> 1988年4月12日第七届全国人民代表大会第一次会议修正", "> 1993年3月29日第八届全国人民代表大会第一次会议修正", "> 1999年3月15日第九届全国人民代表大会第二次会议修正", "> 2004年3月14日第十届全国人民代表大会第二次会议修正", "> 2018年3月11日第十三届全国人民代表大会第一次会议修正")
    }

    if (Test-Path "宪法") { Remove-Item -Recurse -Force "宪法" -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path "宪法" -Force | Out-Null

    foreach ($ver in $versions) {
        $hash = $ver.Hash; $dateStr = $ver.Date; $msg = $ver.Msg
        log "  $dateStr — $msg"

        $body = git -C "$src" show "${hash}:Constitution.md"
        if ($body -is [array]) { $body = $body -join "`n" }
        $tocLines = @()
        $body -split "`n" | ForEach-Object {
            if ($_ -match '^##\s+(.+)') {
                $s = $matches[1]; $a = ($s -replace '　','') -replace ' ',''
                $tocLines += "- [$s](#$a)"
            }
        }
        $toc = $tocLines -join "`n"
        $headerLines = $headers[$hash] -join "`n"

@"
# 中华人民共和国宪法

$headerLines

$toc

$body
"@ | Set-Content -Path "宪法/中华人民共和国宪法.md" -Encoding UTF8

        git add "宪法/中华人民共和国宪法.md"
        $env:GIT_AUTHOR_DATE = "$dateStr 09:00:00"
        $env:GIT_COMMITTER_DATE = "$dateStr 09:00:00"
        git commit -m "$msg"
        ok "提交 $hash"
    }
    ok "主分支完成: $(git rev-parse HEAD)"
}

# ============================================================
# 3. 构建历史宪法分支（使用临时 worktree）
# ============================================================
function New-HistoricalCommit {
    param($Branch, $DateTs, $Tz, $Msg, $FilePath, $SrcFile, $Parent)

    if (-not (Test-Path $SrcFile)) {
        warn "源文件不存在: $SrcFile"
        return
    }

    # 未指定父提交时，以根提交为父（每个分支都包含主分支的初始提交）
    if (-not $Parent) {
        $Parent = git rev-list --max-parents=0 HEAD | Select-Object -First 1
    }

    # 创建 detached worktree
    $tmpWt = Join-Path $TMPDIR "wt-$([System.IO.Path]::GetRandomFileName())"
    Remove-Item -Recurse -Force $tmpWt -ErrorAction SilentlyContinue
    $wtResult = git worktree add --detach $tmpWt $Parent 2>&1
    if ($LASTEXITCODE -ne 0) {
        warn "无法创建 worktree: $wtResult"
        return
    }

    $ok = $false
    Push-Location $tmpWt
    try {
        $dir = Split-Path $FilePath -Parent
        if ($dir) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Copy-Item $SrcFile $FilePath -Force
        git add $FilePath

        $tree = git write-tree
        if ($LASTEXITCODE -ne 0 -or -not $tree) { throw "git write-tree 失败" }

        $commitContent = "tree $tree`nparent $Parent`nauthor $GIT_NAME <$GIT_EMAIL> $DateTs $Tz`ncommitter $GIT_NAME <$GIT_EMAIL> $DateTs $Tz`n`n$Msg`n"
        $objFile = Join-Path $TMPDIR "commit-$([System.IO.Path]::GetRandomFileName())"
        $commitBytes = [System.Text.Encoding]::UTF8.GetBytes($commitContent)
        [System.IO.File]::WriteAllBytes($objFile, $commitBytes)
        $ch = git hash-object -t commit -w $objFile --literally
        Remove-Item $objFile -Force
        if (-not $ch) { throw "git hash-object 返回空" }

        git update-ref "refs/heads/$Branch" $ch 2>$null
        if ($LASTEXITCODE -ne 0) { throw "git update-ref 失败" }

        $ok = $true
        ok "提交 ${Branch}: $ch"
    } catch {
        warn "提交 $Branch 失败: $_"
    } finally {
        Pop-Location
        git worktree remove $tmpWt -Force 2>$null
    }
}

function Build-HistoricalBranches {
    param($Sources)
    log "构建历史宪法分支..."

    $src = Join-Path $Sources.laws "宪法"

    New-HistoricalCommit -Branch "共同纲领" -DateTs "0" -Tz "+0800" `
        -Msg "1949年9月29日中国人民政治协商会议第一届全体会议通过《中国人民政治协商会议共同纲领》" `
        -FilePath "宪法/中国人民政治协商会议共同纲领.md" `
        -SrcFile (Join-Path $src "中国人民政治协商会议共同纲领（已失效）.md")

    New-HistoricalCommit -Branch "54宪法" -DateTs "0" -Tz "+0800" `
        -Msg "1954年9月20日第一届全国人民代表大会第一次会议通过《中华人民共和国宪法》" `
        -FilePath "宪法/中华人民共和国宪法.md" `
        -SrcFile (Join-Path $src "五四宪法（已失效）.md")

    New-HistoricalCommit -Branch "75宪法" -DateTs "159152400" -Tz "+0800" `
        -Msg "1975年1月17日第四届全国人民代表大会第一次会议通过《中华人民共和国宪法》" `
        -FilePath "宪法/中华人民共和国宪法.md" `
        -SrcFile (Join-Path $src "七五宪法（已失效）.md")

    # 78 宪法（含修正案，每个修正案作为独立提交）
    $base78 = Join-Path $src "七八宪法（已失效）.md"
    if (Test-Path $base78) {
        $baseText = Get-Content $base78 -Raw -Encoding UTF8

        # 1978 版（基版本）
        $clean78 = $baseText -replace "^# .*`n", "" -replace "^>.*`n", "" -replace "^\[.*\]\(.*\)`n", "" -replace "`n{3,}", "`n`n"
        $toc78 = Build-TOC $clean78
        $full78 = "# 中华人民共和国宪法`n`n> 1978年3月5日中华人民共和国第五届全国人民代表大会第一次会议通过`n`n$toc78`n`n$clean78"
        $tmp78 = Join-Path $TMPDIR "78宪法-1978.txt"
        $full78 | Set-Content -Path $tmp78 -Encoding UTF8
        New-HistoricalCommit -Branch "78宪法" -DateTs "257907600" -Tz "+0800" `
            -Msg "1978年3月5日第五届全国人民代表大会第一次会议通过《中华人民共和国宪法》" `
            -FilePath "宪法/中华人民共和国宪法.md" -SrcFile $tmp78
        Remove-Item $tmp78 -Force

        # 尝试从维基文库获取修正案全文
        $wikiTexts = @{}
        $wikiOk = $true
        foreach ($year in @("1979", "1980")) {
            $url = "https://zh.wikisource.org/w/index.php?title=中华人民共和国宪法_(${year}年)&action=raw"
            try {
                $resp = Invoke-WebRequest -Uri $url -TimeoutSec 10 -UseBasicParsing
                if ($resp.Content -match '<html') { $wikiOk = $false; break }
                $wikiTexts[$year] = $resp.Content
            } catch {
                $wikiOk = $false
                break
            }
        }

        if ($wikiOk) {
            log "从维基文库获取78宪法修正版成功..."
            # 1979 修正案
            $parent79 = git rev-parse 78宪法
            $raw79 = $wikiTexts["1979"]
            $body79 = $raw79 -replace "^# .*`n", "" -replace "'''(.*?)'''", '**$1' -replace "^==", "##" -replace "==$", ""
            $toc79 = @()
            $body79 -split "`n" | ForEach-Object {
                if ($_ -match '^##\s+(.+)') { $s = $matches[1]; $a = ($s -replace '　','') -replace ' ',''; $toc79 += "- [$s](#$a)" }
            }
            $full79 = "# 中华人民共和国宪法`n`n> 1978年3月5日中华人民共和国第五届全国人民代表大会第一次会议通过`n> 1979年7月1日第五届全国人民代表大会第二次会议修正`n`n$($toc79 -join "`n")`n`n$body79"
            $tmp79 = Join-Path $TMPDIR "78宪法-1979.txt"
            $full79 | Set-Content -Path $tmp79 -Encoding UTF8
            New-HistoricalCommit -Branch "78宪法" -DateTs "300175200" -Tz "+0800" `
                -Msg "1979年7月1日第五届全国人民代表大会第二次会议修正《中华人民共和国宪法》" `
                -FilePath "宪法/中华人民共和国宪法.md" -SrcFile $tmp79 -Parent $parent79
            Remove-Item $tmp79 -Force

            # 1980 修正案
            $parent80 = git rev-parse 78宪法
            $raw80 = $wikiTexts["1980"]
            $body80 = $raw80 -replace "^# .*`n", "" -replace "'''(.*?)'''", '**$1' -replace "^==", "##" -replace "==$", ""
            $toc80 = @()
            $body80 -split "`n" | ForEach-Object {
                if ($_ -match '^##\s+(.+)') { $s = $matches[1]; $a = ($s -replace '　','') -replace ' ',''; $toc80 += "- [$s](#$a)" }
            }
            $full80 = "# 中华人民共和国宪法`n`n> 1978年3月5日中华人民共和国第五届全国人民代表大会第一次会议通过`n> 1979年7月1日第五届全国人民代表大会第二次会议修正`n> 1980年9月10日第五届全国人民代表大会第三次会议修正`n`n$($toc80 -join "`n")`n`n$body80"
            $tmp80 = Join-Path $TMPDIR "78宪法-1980.txt"
            $full80 | Set-Content -Path $tmp80 -Encoding UTF8
            New-HistoricalCommit -Branch "78宪法" -DateTs "337384800" -Tz "+0800" `
                -Msg "1980年9月10日第五届全国人民代表大会第三次会议修正《中华人民共和国宪法》" `
                -FilePath "宪法/中华人民共和国宪法.md" -SrcFile $tmp80 -Parent $parent80
            Remove-Item $tmp80 -Force
        } else {
            warn "维基文库不可用，自生成78宪法修正版..."
            # 1979 修正案（自生成）
            $parent79 = git rev-parse 78宪法
            $text79 = $baseText -replace "地方各级革命委员会", "地方各级人民政府"
            $text79 = $text79 -replace "第三节 地方各级人民代表大会和地方各级革命委员会", "第三节 地方各级人民代表大会和地方各级人民政府"
            $clean79 = $text79 -replace "^# .*`n", "" -replace "^>.*`n", "" -replace "^\[.*\]\(.*\)`n", "" -replace "`n{3,}", "`n`n"
            $toc79 = Build-TOC $clean79
            $full79 = "# 中华人民共和国宪法`n`n> 1978年3月5日中华人民共和国第五届全国人民代表大会第一次会议通过`n> 1979年7月1日第五届全国人民代表大会第二次会议修正`n`n$toc79`n`n$clean79"
            $tmp79 = Join-Path $TMPDIR "78宪法-1979.txt"
            $full79 | Set-Content -Path $tmp79 -Encoding UTF8
            New-HistoricalCommit -Branch "78宪法" -DateTs "300175200" -Tz "+0800" `
                -Msg "1979年7月1日第五届全国人民代表大会第二次会议修正《中华人民共和国宪法》" `
                -FilePath "宪法/中华人民共和国宪法.md" -SrcFile $tmp79 -Parent $parent79
            Remove-Item $tmp79 -Force

            # 1980 修正案（自生成）
            $parent80 = git rev-parse 78宪法
            $text80 = $clean79 -replace '有运用.*?大鸣.*?大放.*?大辩论.*?大字报.*?的权利', ''
            $clean80 = $text80 -replace "`n{3,}", "`n`n"
            $toc80 = Build-TOC $clean80
            $full80 = "# 中华人民共和国宪法`n`n> 1978年3月5日中华人民共和国第五届全国人民代表大会第一次会议通过`n> 1979年7月1日第五届全国人民代表大会第二次会议修正`n> 1980年9月10日第五届全国人民代表大会第三次会议修正`n`n$toc80`n`n$clean80"
            $tmp80 = Join-Path $TMPDIR "78宪法-1980.txt"
            $full80 | Set-Content -Path $tmp80 -Encoding UTF8
            New-HistoricalCommit -Branch "78宪法" -DateTs "337384800" -Tz "+0800" `
                -Msg "1980年9月10日第五届全国人民代表大会第三次会议修正《中华人民共和国宪法》" `
                -FilePath "宪法/中华人民共和国宪法.md" -SrcFile $tmp80 -Parent $parent80
            Remove-Item $tmp80 -Force
        }
    } else {
        warn "找不到 78 宪法源文件，跳过"
    }

    ok "历史分支创建完成"
}

function Build-TOC {
    param($Text)
    $lines = @()
    $Text -split "`n" | ForEach-Object {
        if ($_ -match '^##\s+(.+)') {
            $s = $matches[1]; $a = ($s -replace '　','') -replace ' ',''
            $lines += "- [$s](#$a)"
        }
    }
    return $lines -join "`n"
}

# ============================================================
# 主流程
# ============================================================
function Main {
    log "=== legalize-cn 宪法历史构建 ==="
    log "目标仓库: $TARGET_REPO"
    ""

    Clean-Repo
    ""

    $sources = Clone-Sources
    ""

    Build-MainBranch $sources
    ""

    Build-HistoricalBranches $sources
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
