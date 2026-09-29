#!/usr/bin/env bash
# meta/build.sh — 宪法历史构建脚本（Bash 版）
# 用法: bash cn/build.sh <目标Git仓库路径>
# 在指定的 git 仓库中构建完整的宪法历史（主分支 + 历史宪法分支）
# todo: git push --force

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

REPO_PATH="${1:-.}"

# 确保目标目录存在且是一个 git 仓库
if [ ! -d "$REPO_PATH" ]; then
  mkdir -p "$REPO_PATH"
  cd "$REPO_PATH"
  git init
elif [ ! -d "$REPO_PATH/.git" ]; then
  cd "$REPO_PATH"
  git init
fi

TARGET_REPO="$(cd "$REPO_PATH" && pwd)"
cd "$TARGET_REPO"

TMPDIR=$(mktemp -d /tmp/legalize-build.XXXXXX)
trap "rm -rf $TMPDIR" EXIT

GIT_NAME="$(git config user.name)"
GIT_EMAIL="$(git config user.email)"

log()  { echo "[*] $*"; }
ok()   { echo "  -> $*"; }
warn() { echo "[!] $*" >&2; }   # 警告输出到 stderr，避免污染抓取内容

# 把 "YYYY-MM-DD" 转成"当日 00:00 +0800"的 epoch。
# 必须显式给出 epoch：GIT_AUTHOR_DATE="YYYY-MM-DD 00:00:00" 会按构建机的本地时区解析，
# 结果随构建机 TZ 变化；"@<epoch> +0800" 则是确定性的。
epoch_at() {
  local d="$1" off="${2:-8}"
  echo $(( $(date -u -d "$d 00:00:00" +%s) - off * 3600 ))
}

# 维基文库抓取：持久缓存 + 限流退避重试（避免 429）
WIKICACHE="${LEGALIZE_WIKICACHE:-${WIKICACHE_DIR:-$HOME/.cache/legalize-meta/wikisource}}"
mkdir -p "$WIKICACHE"

wiki_fetch() {  # $1=host(en|zh) $2=title
  local host="$1" title="$2"
  local key
  key="$(printf '%s|%s' "$host" "$title" | md5sum | cut -d' ' -f1)"
  local cache="$WIKICACHE/$key"
  if [ -s "$cache" ]; then cat "$cache"; return 0; fi

  local url code rc attempt wait
  if [ "$host" = "en" ]; then
    url="https://en.wikisource.org/w/index.php?title=${title}&action=raw"
  else
    url="https://zh.wikisource.org/w/index.php?action=raw"
  fi

  for attempt in 1 2 3 4 5 6; do
    rm -f "$TMPDIR/fetch.$$"
    if [ "$host" = "zh" ]; then
      code="$(curl -sS --max-time 30 -o "$TMPDIR/fetch.$$" -w '%{http_code}' --get --data-urlencode "title=$title" "$url" 2>/dev/null)"
    else
      code="$(curl -sS --max-time 30 -o "$TMPDIR/fetch.$$" -w '%{http_code}' "$url" 2>/dev/null)"
    fi
    rc=$?
    if [ "$rc" -eq 0 ] && [ "$code" = "200" ]; then
      mv "$TMPDIR/fetch.$$" "$cache"
      cat "$cache"
      return 0
    fi
    wait=$(( attempt * attempt * 3 ))
    [ "$wait" -gt 60 ] && wait=60
    rm -f "$TMPDIR/fetch.$$"
    warn "  [fetch] $host:$title http=$code rc=$rc 重试($attempt/6) ${wait}s"
    sleep "$wait"
  done
  warn "  [fetch] 失败: $host:$title"
  return 1
}

# ============================================================
# 0. 克隆数据源
# ============================================================
clone_sources() {
  log "克隆数据源..."

  if [ -d "$TMPDIR/chinese-constitution" ]; then
    log "  chinese-constitution 已存在"
  else
    git clone --depth=10 https://github.com/tianyikillua/chinese-constitution.git "$TMPDIR/chinese-constitution"
  fi

  if [ -d "$TMPDIR/Chinese_Laws" ]; then
    log "  Chinese_Laws 已存在"
  else
    git clone --depth=5 https://github.com/risshun/Chinese_Laws.git "$TMPDIR/Chinese_Laws"
  fi
}

# ============================================================
# 1. 清理目标仓库
# ============================================================
clean_repo() {
  log "清理目标仓库..."

  local root
  root=$(git rev-list --max-parents=0 HEAD 2>/dev/null || echo "")

  if [ -n "$root" ]; then
    git checkout main 2>/dev/null
    git reset --hard "$root" 2>/dev/null
    git rm -r . --quiet 2>/dev/null || true  # 完全清空索引和工作树
  fi

  # 从源仓库覆盖 LICENSE、README.md、.gitignore
  cp "$SCRIPT_DIR/.gitignore" "$SCRIPT_DIR/LICENSE" "$SCRIPT_DIR/README.md" . 2>/dev/null || true
  git add .

  if [ -n "$root" ]; then
    GIT_AUTHOR_DATE="@$(epoch_at 1982-12-04) +0800" GIT_COMMITTER_DATE="@$(epoch_at 1982-12-04) +0800" \
    git commit --amend --no-edit 2>/dev/null || true
  else
    GIT_AUTHOR_DATE="@$(epoch_at 1982-12-04) +0800" GIT_COMMITTER_DATE="@$(epoch_at 1982-12-04) +0800" \
    git commit -m "Initial commit" 2>/dev/null || true
  fi
  log "根提交: $(git rev-parse HEAD)"

  git branch -M main

  for b in $(git branch | sed 's/^\*//' | tr -d ' '); do
    [ "$b" = "main" ] && continue
    git branch -D "$b" 2>/dev/null && ok "已删除分支: $b" || true
  done
}

# ============================================================
# 2. 构建主分支 — 1982 宪法及修正案
# ============================================================
# 维基文库 wikitext -> Markdown（仅 78宪法 的 1979/1980 修正版用到；
# 原先的 sed 链无法剥掉跨行 {{header}} 模板，其导航链接 [[...]] 会整块漏进产物）
cat > "$TMPDIR/wiki_to_md.py" <<'PY'
import sys, re
text = sys.stdin.read()
while '{{' in text:
    new = re.sub(r'\{\{([^{}]*)\}\}', '', text, flags=re.S)
    if new == text: break
    text = new
text = re.sub(r'(?is)<noinclude>.*?</noinclude>', '', text)
text = re.sub(r'(?is)</?onlyinclude>', '', text)
text = re.sub(r'<[^>]+>', '', text)
text = re.sub(r"(?s)'''", r'**\1**', text)
text = re.sub(r"(?s)'''", r'*\1*', text)
text = re.sub(r'(?m)^====\s*(.*?)\s*====$', r'#### \1', text)
text = re.sub(r'(?m)^===\s*(.*?)\s*===$', r'### \1', text)
text = re.sub(r'(?m)^==\s*(.*?)\s*==$', r'## \1', text)
text = re.sub(r'\[\[(?:Category|分類|分类)[:：][^\]]*\]\]', '', text, flags=re.I)  # 分类链接须先删
text = re.sub(r'\[\[[^\]|]+\|([^\]]+)\]\]', r'\1', text)
text = re.sub(r'\[\[([^\]]+)\]\]', r'\1', text)
text = text.replace('&nbsp;', ' ')
text = re.sub(r'\r\n?', '\n', text)
text = re.sub(r'(?m)^[ \t\u3000:;]+', '', text)
text = re.sub(r'\n{3,}', '\n\n', text)
print(text.strip())
PY
wiki_to_markdown(){ python3 "$TMPDIR/wiki_to_md.py"; }

# 目录生成。锚点按 GitHub 的 slug 规则计算：转小写 -> 去掉标点 -> 空白（含全角空格）转连字符。
# （原实现用 sed 直接删掉空白，得到 `第一章总纲`，与 GitHub 的 `第一章-总纲` 不符，链接失效。）
md_toc() {
  python3 -c 'import re, sys
for line in sys.stdin:
    if not line.startswith("## "): continue
    h = line[3:].strip()
    if not h: continue
    a = re.sub(r"\s", "-", re.sub(r"[^\w\s-]", "", h.lower()))
    print("- [%s](#%s)" % (h, a))' || true
}

build_toc() {
  md_toc < "$1"
}

build_main_branch() {
  log "构建主分支: 1982 宪法及修正案..."
  local src="$TMPDIR/chinese-constitution"

  local versions=(
    "1fb3f30:1982-12-04:1982年12月4日第五届全国人民代表大会第五次会议通过《中华人民共和国宪法》"
    "08dcbc4:1988-04-12:1988年4月12日第七届全国人民代表大会第一次会议通过宪法修正案"
    "c53dd9b:1993-03-29:1993年3月29日第八届全国人民代表大会第一次会议通过宪法修正案"
    "e4132c5:1999-03-15:1999年3月15日第九届全国人民代表大会第二次会议通过宪法修正案"
    "b913443:2004-03-14:2004年3月14日第十届全国人民代表大会第二次会议通过宪法修正案"
    "12b6d7b:2018-03-11:2018年3月11日第十三届全国人民代表大会第一次会议通过宪法修正案"
  )

  mkdir -p 宪法
  rm -f 宪法/中华人民共和国宪法.md

  for ver_info in "${versions[@]}"; do
    local hash="${ver_info%%:*}"
    local rest="${ver_info#*:}"
    local date_str="${rest%%:*}"
    local msg="${rest#*:}"

    log "  提交: $date_str — $msg"
    local body
    body=$(git -C "$src" show "$hash:Constitution.md")

    local toc
    toc=$(printf '%s
' "$body" | md_toc)

    local header_lines
    case "$hash" in
      1fb3f30) header_lines="> 1982年12月4日第五届全国人民代表大会第五次会议通过" ;;
      08dcbc4) header_lines=$(printf "> 1982年12月4日第五届全国人民代表大会第五次会议通过\n> 1988年4月12日第七届全国人民代表大会第一次会议修正") ;;
      c53dd9b) header_lines=$(printf "> 1982年12月4日第五届全国人民代表大会第五次会议通过\n> 1988年4月12日第七届全国人民代表大会第一次会议修正\n> 1993年3月29日第八届全国人民代表大会第一次会议修正") ;;
      e4132c5) header_lines=$(printf "> 1982年12月4日第五届全国人民代表大会第五次会议通过\n> 1988年4月12日第七届全国人民代表大会第一次会议修正\n> 1993年3月29日第八届全国人民代表大会第一次会议修正\n> 1999年3月15日第九届全国人民代表大会第二次会议修正") ;;
      b913443) header_lines=$(printf "> 1982年12月4日第五届全国人民代表大会第五次会议通过\n> 1988年4月12日第七届全国人民代表大会第一次会议修正\n> 1993年3月29日第八届全国人民代表大会第一次会议修正\n> 1999年3月15日第九届全国人民代表大会第二次会议修正\n> 2004年3月14日第十届全国人民代表大会第二次会议修正") ;;
      12b6d7b) header_lines=$(printf "> 1982年12月4日第五届全国人民代表大会第五次会议通过\n> 1988年4月12日第七届全国人民代表大会第一次会议修正\n> 1993年3月29日第八届全国人民代表大会第一次会议修正\n> 1999年3月15日第九届全国人民代表大会第二次会议修正\n> 2004年3月14日第十届全国人民代表大会第二次会议修正\n> 2018年3月11日第十三届全国人民代表大会第一次会议修正") ;;
    esac

    {
      echo '# 中华人民共和国宪法'
      echo ''
      echo "$header_lines"
      echo ''
      echo "$toc"
      echo ''
      echo "$body"
    } > "宪法/中华人民共和国宪法.md"

    git add "宪法/中华人民共和国宪法.md"

    GIT_AUTHOR_NAME="$GIT_NAME" GIT_AUTHOR_EMAIL="$GIT_EMAIL" \
    GIT_AUTHOR_DATE="@$(epoch_at "$date_str") +0800" \
    GIT_COMMITTER_NAME="$GIT_NAME" GIT_COMMITTER_EMAIL="$GIT_EMAIL" \
    GIT_COMMITTER_DATE="@$(epoch_at "$date_str") +0800" \
    git commit -m "$msg"
  done
  ok "主分支完成: $(git rev-parse HEAD)"
}

# ============================================================
# 3. 构建历史宪法分支（使用临时 worktree）
# ============================================================
make_historical_commit() {
  local branch="$1" date_ts="$2" tz="${3:-+0800}" msg="$4" file_path="$5" src_file="$6" parent="${7:-}"

  if [ -z "$parent" ]; then
    parent=$(git rev-list --max-parents=0 HEAD | head -1)
  fi

  local wt="$TMPDIR/wt-$branch"
  rm -rf "$wt"
  git worktree prune 2>/dev/null || true
  git worktree add --detach "$wt" "$parent" 2>/dev/null

  cd "$wt"
  mkdir -p "$(dirname "$file_path")"
  cp "$src_file" "$file_path"
  git add "$file_path"

  local tree
  tree=$(git write-tree)

  local commit_content
  commit_content=$(printf "tree %s\nparent %s\nauthor %s <%s> %s %s\ncommitter %s <%s> %s %s\n\n%s\n" \
    "$tree" "$parent" \
    "$GIT_NAME" "$GIT_EMAIL" "$date_ts" "$tz" \
    "$GIT_NAME" "$GIT_EMAIL" "$date_ts" "$tz" \
    "$msg")

  local commit_hash
  commit_hash=$(echo "$commit_content" | git hash-object -t commit -w --stdin --literally)
  git update-ref "refs/heads/$branch" "$commit_hash"

  cd "$TARGET_REPO"
  git worktree remove "$wt" -f 2>/dev/null || true
  ok "分支 $branch 创建完成"
}

build_historical_branches() {
  log "构建历史宪法分支..."
  local src="$TMPDIR/Chinese_Laws/宪法"

  make_historical_commit \
    "共同纲领" "-639302400" "+0800" \
    "1949年9月29日中国人民政治协商会议第一届全体会议通过《中国人民政治协商会议共同纲领》" \
    "宪法/中国人民政治协商会议共同纲领.md" \
    "$src/中国人民政治协商会议共同纲领（已失效）.md"

  make_historical_commit \
    "54宪法" "-482313600" "+0800" \
    "1954年9月20日第一届全国人民代表大会第一次会议通过《中华人民共和国宪法》" \
    "宪法/中华人民共和国宪法.md" \
    "$src/五四宪法（已失效）.md"

  make_historical_commit \
    "75宪法" "159120000" "+0800" \
    "1975年1月17日第四届全国人民代表大会第一次会议通过《中华人民共和国宪法》" \
    "宪法/中华人民共和国宪法.md" \
    "$src/七五宪法（已失效）.md"

  # 78 宪法（含修正案，每个修正案作为独立提交）
  local base78="$src/七八宪法（已失效）.md"
  if [ -f "$base78" ]; then
    local base_text clean78 toc78 tmp78
    base_text=$(cat "$base78")
    # 去掉源文件自带的标题、引言与目录条目（否则会与下面生成的目录重复）
    clean78=$(echo "$base_text" | sed '/^# /d; /^>/d; /^\[.*\](.*)/d; /^[[:space:]]*-[[:space:]]*\[/d' | tr -s '\n')
    toc78=$(printf '%s\n' "$clean78" | md_toc)
    tmp78="$TMPDIR/78宪法-1978.txt"
    { echo '# 中华人民共和国宪法'; echo ''; echo '> 1978年3月5日中华人民共和国第五届全国人民代表大会第一次会议通过'; echo ''; echo "$toc78"; echo ''; echo "$clean78"; } > "$tmp78"
    make_historical_commit "78宪法" "257875200" "+0800" \
      "1978年3月5日第五届全国人民代表大会第一次会议通过《中华人民共和国宪法》" \
      "宪法/中华人民共和国宪法.md" "$tmp78"
    rm -f "$tmp78"

    # 尝试从维基文库获取修正案全文
    local wiki79 wiki80 wiki_ok=true
    wiki79=$(wiki_fetch zh "中华人民共和国宪法_(1979年)" 2>/dev/null || echo "")
    wiki80=$(wiki_fetch zh "中华人民共和国宪法_(1980年)" 2>/dev/null || echo "")
    echo "$wiki79" | grep -q '<html\|<error' && wiki_ok=false
    echo "$wiki80" | grep -q '<html\|<error' && wiki_ok=false
    [ -z "$wiki79" ] && wiki_ok=false
    [ -z "$wiki80" ] && wiki_ok=false

    if [ "$wiki_ok" = true ]; then
      log "从维基文库获取78宪法修正版成功..."
      # 1979 修正案
      local parent79 body79 toc79 tmp79
      parent79=$(git rev-parse 78宪法)
      body79=$(printf '%s\n' "$wiki79" | wiki_to_markdown)
      toc79=$(printf '%s\n' "$body79" | md_toc)
      tmp79="$TMPDIR/78宪法-1979.txt"
      { echo '# 中华人民共和国宪法'; echo ''; printf '> 1978年3月5日中华人民共和国第五届全国人民代表大会第一次会议通过\n> 1979年7月1日第五届全国人民代表大会第二次会议修正'; echo ''; echo ''; echo "$toc79"; echo ''; echo "$body79"; } > "$tmp79"
      make_historical_commit "78宪法" "299606400" "+0800" \
        "1979年7月1日第五届全国人民代表大会第二次会议修正《中华人民共和国宪法》" \
        "宪法/中华人民共和国宪法.md" "$tmp79" "$parent79"
      rm -f "$tmp79"

      # 1980 修正案
      local parent80 body80 toc80 tmp80
      parent80=$(git rev-parse 78宪法)
      body80=$(printf '%s\n' "$wiki80" | wiki_to_markdown)
      toc80=$(printf '%s\n' "$body80" | md_toc)
      tmp80="$TMPDIR/78宪法-1980.txt"
      { echo '# 中华人民共和国宪法'; echo ''; printf '> 1978年3月5日中华人民共和国第五届全国人民代表大会第一次会议通过\n> 1979年7月1日第五届全国人民代表大会第二次会议修正\n> 1980年9月10日第五届全国人民代表大会第三次会议修正'; echo ''; echo ''; echo "$toc80"; echo ''; echo "$body80"; } > "$tmp80"
      make_historical_commit "78宪法" "337363200" "+0800" \
        "1980年9月10日第五届全国人民代表大会第三次会议修正《中华人民共和国宪法》" \
        "宪法/中华人民共和国宪法.md" "$tmp80" "$parent80"
      rm -f "$tmp80"
    else
      warn "维基文库不可用，自生成78宪法修正版..."
      # 1979 修正案（自生成）
      local parent79 text79 clean79 toc79 tmp79
      parent79=$(git rev-parse 78宪法)
      text79=$(echo "$base_text" | sed 's/地方各级革命委员会/地方各级人民政府/g; s/第三节.*/第三节 地方各级人民代表大会和地方各级人民政府/')
      clean79=$(echo "$text79" | sed '/^# /d; /^>/d; /^\[.*\](.*)/d' | tr -s '\n')
      toc79=$(printf '%s\n' "$clean79" | md_toc)
      tmp79="$TMPDIR/78宪法-1979.txt"
      { echo '# 中华人民共和国宪法'; echo ''; printf '> 1978年3月5日中华人民共和国第五届全国人民代表大会第一次会议通过\n> 1979年7月1日第五届全国人民代表大会第二次会议修正'; echo ''; echo ''; echo "$toc79"; echo ''; echo "$clean79"; } > "$tmp79"
      make_historical_commit "78宪法" "299606400" "+0800" \
        "1979年7月1日第五届全国人民代表大会第二次会议修正《中华人民共和国宪法》" \
        "宪法/中华人民共和国宪法.md" "$tmp79" "$parent79"
      rm -f "$tmp79"

      # 1980 修正案（自生成）
      local parent80 text80 clean80 toc80 tmp80
      parent80=$(git rev-parse 78宪法)
      text80=$(echo "$clean79" | sed 's/有运用.*大鸣.*大放.*大辩论.*大字报.*的权利//')
      clean80=$(echo "$text80" | tr -s '\n')
      toc80=$(printf '%s\n' "$clean80" | md_toc)
      tmp80="$TMPDIR/78宪法-1980.txt"
      { echo '# 中华人民共和国宪法'; echo ''; printf '> 1978年3月5日中华人民共和国第五届全国人民代表大会第一次会议通过\n> 1979年7月1日第五届全国人民代表大会第二次会议修正\n> 1980年9月10日第五届全国人民代表大会第三次会议修正'; echo ''; echo ''; echo "$toc80"; echo ''; echo "$clean80"; } > "$tmp80"
      make_historical_commit "78宪法" "337363200" "+0800" \
        "1980年9月10日第五届全国人民代表大会第三次会议修正《中华人民共和国宪法》" \
        "宪法/中华人民共和国宪法.md" "$tmp80" "$parent80"
      rm -f "$tmp80"
    fi
  else
    warn "找不到 78 宪法源文件，跳过"
  fi

  ok "历史分支创建完成"
}

# ============================================================
# 主流程
# ============================================================
main() {
  log "=== legalize-cn 宪法历史构建 ==="
  log "目标仓库: $TARGET_REPO"
  echo ""

  clean_repo
  echo ""

  clone_sources
  echo ""

  build_main_branch
  echo ""

  build_historical_branches
  echo ""

  git checkout main 2>/dev/null || true
  log "=== 构建完成 ==="
  echo ""
  log "分支一览:"
  git branch -a | cat
  echo ""
  log "主分支历史:"
  git log --format="%ai %s" --reverse main | cat
}

cd "$TARGET_REPO"
main "$@"
