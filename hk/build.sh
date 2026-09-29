#!/usr/bin/env bash
# hk/build.sh — 香港宪制历史构建脚本（Bash 版）
# 用法: bash hk/build.sh <目标Git仓库路径>
# 主分支：现行《中华人民共和国香港特别行政区基本法》
#         正文取自香港基本法官方网站 basiclaw.gov.hk（官方全文，含附件一、二、三）
# 历史分支：1917 年《英皇制诰》(Letters Patent) 与《皇室训令》(Royal Instructions)
#         取自 en.wikisource 的 Page: 校订文本（校对等级 3 级）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_PATH="${1:-.}"

if [ ! -d "$REPO_PATH" ]; then
  mkdir -p "$REPO_PATH"; cd "$REPO_PATH"; git init
elif [ ! -d "$REPO_PATH/.git" ]; then
  cd "$REPO_PATH"; git init
fi

TARGET_REPO="$(cd "$REPO_PATH" && pwd)"; cd "$TARGET_REPO"
TMPDIR="$(mktemp -d /tmp/legalize-hk-build.XXXXXX)"; trap "rm -rf '$TMPDIR'" EXIT

GIT_NAME="$(git config user.name || true)"; GIT_EMAIL="$(git config user.email || true)"
[ -n "$GIT_NAME" ] || GIT_NAME="legalize-meta"
[ -n "$GIT_EMAIL" ] || GIT_EMAIL="legalize-meta@example.invalid"

log(){ echo "[*] $*"; }; ok(){ echo "  -> $*"; }; warn(){ echo "[!] $*" >&2; }

# 把 "YYYY-MM-DD" 转成"当日 00:00 +0800"的 epoch。
# 必须显式给出 epoch：GIT_AUTHOR_DATE="YYYY-MM-DD 00:00:00" 会按构建机的本地时区解析，
# 结果随构建机 TZ 变化；"@<epoch> +0800" 则是确定性的。
epoch_at() {
  local d="$1" off="${2:-8}"
  echo $(( $(date -u -d "$d 00:00:00" +%s) - off * 3600 ))
}

# ---------------------------------------------------------------- 抓取
# 统一缓存（按 cache key 的 md5 命名）+ 429 指数退避重试。
# 缓存目录：LEGALIZE_WIKICACHE > WIKICACHE_DIR > ~/.cache/legalize-meta/wikisource
WIKICACHE="${LEGALIZE_WIKICACHE:-${WIKICACHE_DIR:-$HOME/.cache/legalize-meta/wikisource}}"
mkdir -p "$WIKICACHE"
UA="legalize-meta/1.0 (constitutional text build script)"

fetch_cached() {  # $1=cache key  $2=url  $3...=extra curl args
  local key="$1" url="$2"; shift 2
  local cache; cache="$WIKICACHE/$(printf '%s' "$key" | md5sum | cut -d' ' -f1)"
  if [ -s "$cache" ]; then cat "$cache"; return 0; fi
  local code rc attempt wait
  for attempt in 1 2 3 4 5 6; do
    rm -f "$TMPDIR/fetch.$$"
    code="$(curl -sS -L --max-time 45 -A "$UA" -o "$TMPDIR/fetch.$$" -w '%{http_code}' "$@" "$url" 2>/dev/null)"
    rc=$?
    if [ "$rc" -eq 0 ] && [ "$code" = "200" ] && [ -s "$TMPDIR/fetch.$$" ]; then
      mv "$TMPDIR/fetch.$$" "$cache"; cat "$cache"; return 0
    fi
    wait=$(( attempt * attempt * 3 )); [ "$wait" -gt 60 ] && wait=60
    rm -f "$TMPDIR/fetch.$$"
    warn "  [fetch] $url http=$code rc=$rc 重试($attempt/6) ${wait}s"; sleep "$wait"
  done
  warn "  [fetch] 失败: $url"; return 1
}

wiki_raw() {  # $1=title（en.wikisource）
  fetch_cached "en|$1" "https://en.wikisource.org/w/index.php?action=raw" \
    --get --data-urlencode "title=$1"
}

wiki_page() {  # $1=文件基名  $2=页码（en.wikisource Page: 命名空间）
  wiki_raw "Page:$1/$2"
}

basiclaw_page() {  # $1=页面名（basiclaw.gov.hk 繁体中文官方版）
  fetch_cached "basiclaw|$1" "https://www.basiclaw.gov.hk/tc/basiclaw/$1.html"
}

# ---------------------------------------------------------------- 转换器
# 维基文库 wikitext -> Markdown
cat > "$TMPDIR/wiki_to_md.py" <<'PY'
import sys, re

# 1) 先展开"带正文"的排版模板，否则内容（如人名）会随模板一起被丢弃
UNWRAP = ['Sc', 'sc', 'SmallCaps', 'Big', 'big', 'Center', 'centre', 'Right',
          'right block', 'larger', 'x-larger', 'hdr']
text = sys.stdin.read()
for name in UNWRAP:
    pat = r'\{\{\s*' + re.escape(name) + r'\s*\|((?:[^{}]|\{\{)*?)\}\}'
    prev = None
    while prev != text:
        prev = text
        text = re.sub(pat, lambda m: re.sub(r'\|\s*\d+\s*=', '|', m.group(1)), text, flags=re.S)

# 2) 丢弃纯装饰 / 元数据模板（ts/vtt 是表格样式标记，不是正文）
DROP = (r'(?is)\{\{\s*(?:rule|Rule|sidenotes\s+(?:begin|end)|gap|nbsp|'
        r'pagequality|rh|running\s?head|header|footer|PPB|br|'
        r'center|centre|right|sc|Sc|ts|vtt|right\s+block|Big|big)\s*(?:\|[^{}]*)?\}\}')
text = re.sub(DROP, '', text)
text = re.sub(r'(?is)<noinclude>.*?</noinclude>', '', text)

# 3) 模板：反复剥掉最内层的 {{...}}
while '{{' in text:
    new = re.sub(r'\{\{([^{}]*)\}\}', '', text, flags=re.S)
    if new == text: break
    text = new

# 4) 维基表格转纯文本
def _table(m):
    rows = []
    for ln in m.group(1).split('\n'):
        s = ln.strip()
        if not s or s.startswith('{|'): continue
        if re.fullmatch(r'[-+!| ]*[-+!]([-+!| ]*)', s): continue
        s = re.sub(r'^\|[-+!]?\s*', '', s)
        s = re.sub(r'\s*\|\s*$', '', s)
        s = s.strip('|').strip()
        # 合并单元格分隔符 || 视为换行
        for cell in re.split(r'\s*\|\|\s*', s):
            cell = cell.strip()
            if cell: rows.append(cell)
    return '\n' + '\n'.join(rows) + '\n'
text = re.sub(r'\{\|(.*?)\|\}', _table, text, flags=re.S)
text = re.sub(r'\{\|.*?\}\}', '', text, flags=re.S)   # 未闭合的残余

text = re.sub(r'(?is)</?onlyinclude>', '', text)
text = re.sub(r'(?is)<section\b[^>]*/?>', '', text)   # 校订页分节标记
text = re.sub(r'(?is)<pages\b[^>]*/?>', '', text)      # DjVu/PDF 索引标记
text = re.sub(r'(?i)<br\s*/?>', '\n', text)
text = re.sub(r'<[^>]+>', '', text)
text = re.sub(r"(?s)'''(.*?)'''", r'**\1**', text)
text = re.sub(r"(?s)''(.*?)''", r'*\1*', text)
text = re.sub(r'(?m)^====\s*(.*?)\s*====$', r'#### \1', text)
text = re.sub(r'(?m)^===\s*(.*?)\s*===$', r'### \1', text)
text = re.sub(r'(?m)^==\s*(.*?)\s*==$', r'## \1', text)
text = re.sub(r'\[\[(?:Category|分類|分类)[:：][^\]]*\]\]', '', text, flags=re.I)  # 分类链接先删
text = re.sub(r'\[\[(?:Category|分類|分类)[:：][^\]]*\]\]', '', text, flags=re.I)  # 分类链接须先于普通链接删除
text = re.sub(r'\[\[[^\]|]+\|([^\]]+)\]\]', r'\1', text)
text = re.sub(r'\[\[([^\]]+)\]\]', r'\1', text)
text = re.sub(r'\[(?:https?|ftp)://\S+\s+([^\]]+)\]', r'\1', text)
for a, b in (('&nbsp;', ' '), ('&amp;', '&'), ('&lt;', '<'), ('&gt;', '>'), ('&quot;', '"')):
    text = text.replace(a, b)
text = re.sub(r'\r\n?', '\n', text)
keep = []
for ln in text.split('\n'):
    s = ln.strip()
    if re.match(r'^\[\[(Category|分類|分类)', s, re.I): continue
    keep.append(ln)
text = '\n'.join(keep)
text = re.sub(r'[ \t\u3000]+$', '', text, flags=re.M)
text = re.sub(r'\n{3,}', '\n\n', text)
print(text.strip())
PY
wiki_to_markdown(){ python3 "$TMPDIR/wiki_to_md.py"; }

# basiclaw.gov.hk HTML -> Markdown
cat > "$TMPDIR/html_to_md.py" <<'PY'
import sys, re, html
text = sys.stdin.read()
# 只取正文区块
m = re.search(r'<!--\s*Content Begin\s*-->(.*?)<!--\s*Content End\s*-->', text, re.S | re.I)
body = m.group(1) if m else text
body = re.sub(r'(?is)<script\b.*?</script>', '', body)
body = re.sub(r'(?is)<style\b.*?</style>', '', body)
body = re.sub(r'(?is)<!--.*?-->', '', body)          # 残留注释（含模板泄漏的 <!-- <sup>...</sup> -->）
body = re.sub(r'(?is)<div class="nav-btn-wrap.*?</div>', '', body)
# 块级元素转 Markdown（标题整体下沉两级：本脚本另行输出 "## 章节名"）
body = re.sub(r'(?i)<h([1-6])[^>]*>(.*?)</h\1>',
              lambda m: '\n\n' + '#' * min(6, int(m.group(1)) + 2) + ' ' + m.group(2) + '\n\n',
              body, flags=re.S)
body = re.sub(r'(?i)<hr\s*/?>', '\n\n', body)
body = re.sub(r'(?i)<(p|div|tr|dd)\b[^>]*>', '\n\n', body)
body = re.sub(r'(?i)</(p|div|tr|dd)>', '\n\n', body)
body = re.sub(r'(?i)<li\b[^>]*>', '\n- ', body)
body = re.sub(r'(?i)</li>', '', body)
body = re.sub(r'(?i)<dt\b[^>]*>', '\n- ', body)
body = re.sub(r'(?i)<br\s*/?>', '\n', body)
body = re.sub(r'<[^>]+>', '', body)
body = html.unescape(body)
body = body.replace('\u00a0', ' ')
body = re.sub(r'[ \t]+', ' ', body)
body = re.sub(r' *\n *', '\n', body)
body = re.sub(r'\n{3,}', '\n\n', body)
print(body.strip())
PY
html_to_markdown(){ python3 "$TMPDIR/html_to_md.py"; }

# 保护：抓回来的正文若几乎为空，绝不写进仓库（避免产出空壳文件）
assert_body() {  # $1=标题  $2=文件  $3=最小字节数
  local size; size=$(wc -c < "$2" | tr -d ' ')
  if [ "$size" -lt "${3:-500}" ]; then
    warn "  正文过短（${size}B < ${3:-500}B），跳过：$1"; return 1
  fi
  return 0
}

# GitHub 锚点（slug）规则：转小写 -> 去掉标点 -> 空白转连字符（与 github-slugger 一致）。
build_toc() {
  python3 -c 'import re, sys
for line in sys.stdin:
    if not line.startswith("## "): continue
    h = line[3:].strip()
    if not h: continue
    a = re.sub(r"\s", "-", re.sub(r"[^\w\s-]", "", h.lower()))
    print("- [%s](#%s)" % (h, a))' < "$1" || true
}

# ---------------------------------------------------------------- commit
# 手动构造 commit 对象：早于 1970-01-01 的日期无法用 GIT_AUTHOR_DATE 表达，
# 直接写入树/父/作者/提交者（支持负 epoch）并更新 ref。
mk_commit() {  # $1=ref $2=epoch $3=tz $4=msg $5=parent(可选; "-"=无父)
  local ref="$1" ts="$2" z="$3" msg="$4"; local parent="${5:-__auto__}"
  local tree content hash
  tree="$(git write-tree)"
  if [ "$parent" = "__auto__" ]; then parent="$(git rev-parse --verify HEAD 2>/dev/null || true)"; fi
  if [ -n "$parent" ] && [ "$parent" != "-" ]; then
    content="tree $tree\nparent $parent\nauthor $GIT_NAME <$GIT_EMAIL> $ts $z\ncommitter $GIT_NAME <$GIT_EMAIL> $ts $z\n\n$msg\n"
  else
    content="tree $tree\nauthor $GIT_NAME <$GIT_EMAIL> $ts $z\ncommitter $GIT_NAME <$GIT_EMAIL> $ts $z\n\n$msg\n"
  fi
  hash="$(printf '%b' "$content" | git hash-object -t commit -w --stdin --literally)"
  git update-ref "refs/heads/$ref" "$hash"
}

clean_repo() {
  log "清理目标仓库..."
  local root; root="$(git rev-list --max-parents=0 HEAD 2>/dev/null || true)"
  if [ -n "$root" ]; then
    git checkout main 2>/dev/null || true
    git reset --hard "$root" 2>/dev/null || true
    git rm -r . --quiet 2>/dev/null || true
  fi
  cp "$SCRIPT_DIR/.gitignore" "$SCRIPT_DIR/LICENSE" "$SCRIPT_DIR/README.md" . 2>/dev/null || true
  git add .
  git branch | sed 's/^\*//' | tr -d ' ' | while IFS= read -r b; do
    [ "$b" = "main" ] && continue; [ -z "$b" ] && continue
    git branch -D "$b" 2>/dev/null && ok "已删除分支: $b" || true
  done
  mk_commit "main" "639158400" "+0800" "Initial commit" "-"
  git branch -M main
  log "根提交: $(git rev-parse HEAD)"
}

make_historical_commit() {  # $1=branch $2=epoch $3=tz $4=msg $5=file_path $6=src_file $7=parent
  local branch="$1" date_ts="$2" tz="$3" msg="$4" file_path="$5" src_file="$6" parent="${7:-}"
  if [ -z "$parent" ]; then parent="$(git rev-list --max-parents=0 HEAD | head -1)"; fi
  local wt="$TMPDIR/wt-$branch"; rm -rf "$wt"
  git worktree prune 2>/dev/null || true
  git worktree add --detach "$wt" "$parent" 2>/dev/null
  (
    cd "$wt"; mkdir -p "$(dirname "$file_path")"; cp "$src_file" "$file_path"
    git add "$file_path"
    local tree; tree="$(git write-tree)"
    local cc; cc="$(printf "tree %s\nparent %s\nauthor %s <%s> %s %s\ncommitter %s <%s> %s %s\n\n%s\n" \
      "$tree" "$parent" "$GIT_NAME" "$GIT_EMAIL" "$date_ts" "$tz" "$GIT_NAME" "$GIT_EMAIL" "$date_ts" "$tz" "$msg")"
    git update-ref "refs/heads/$branch" "$(printf '%s' "$cc" | git hash-object -t commit -w --stdin --literally)"
  )
  git worktree remove "$wt" -f 2>/dev/null || true
  ok "分支 $branch 创建完成"
}

# ---------------------------------------------------------------- 基本法正文
# 官方站点分节：主席令 / 序言 / 九章 / 三个附件
BASICLAW_SECTIONS=(
  "decree|中华人民共和国主席令（第二十六号）"
  "preamble|序言"
  "chapter1|第一章　总则"
  "chapter2|第二章　中央和香港特别行政区的关系"
  "chapter3|第三章　居民的基本权利和义务"
  "chapter4|第四章　政治体制"
  "chapter5|第五章　经济"
  "chapter6|第六章　教育、科学、文化、体育、宗教、劳工和社会服务"
  "chapter7|第七章　对外事务"
  "chapter8|第八章　本法的解释和修改"
  "chapter9|第九章　附则"
  "annex1|附件一　香港特别行政区行政长官的产生办法"
  "annex2|附件二　香港特别行政区立法会的产生办法和表决程序"
  "annex3|附件三　在香港特别行政区实施的全国性法律"
)

write_basic_law() {  # $1=输出文件  $2...=版本说明行
  local target="$1"; shift
  local notes=("$@")
  local body="$TMPDIR/basiclaw-body.md"
  : > "$body"

  local item page title rawf conv
  for item in "${BASICLAW_SECTIONS[@]}"; do
    page="${item%%|*}"; title="${item#*|}"
    rawf="$TMPDIR/bl-$page.raw"; conv="$TMPDIR/bl-$page.md"
    if ! basiclaw_page "$page" > "$rawf" 2>/dev/null; then
      warn "  抓取失败，跳过：$page"; continue
    fi
    html_to_markdown < "$rawf" > "$conv"
    # 附件页自带标题，与本节标题重复，丢弃其首个标题行
    case "$page" in annex*) sed -i '1{/^#\{1,6\} *附件/d}' "$conv" ;; esac
    {
      echo "## $title"
      echo
      cat "$conv"
      echo
    } >> "$body"
  done

  if ! assert_body "基本法正文" "$body" 20000; then
    warn "  基本法正文不完整（可能是官方站点结构变动），主分支跳过"; return 1
  fi

  {
    echo "# 中华人民共和国香港特别行政区基本法"
    echo
    for n in "${notes[@]}"; do echo "> $n"; done
    echo "> 正文据香港基本法官方网站（basiclaw.gov.hk）官方繁体中文版，章节标题为简体"
    echo
    build_toc "$body"
    echo
    cat "$body"
    echo
    echo "---"
    echo
    echo "资料来源："
    echo
    echo "- 香港基本法官方网站（繁体中文）：https://www.basiclaw.gov.hk/tc/basiclaw/index.html"
    echo "- 香港基本法官方网站（English）：https://www.basiclaw.gov.hk/en/basiclaw/index.html"
    echo "- 香港基本法官方网站（PDF 全文）：https://www.basiclaw.gov.hk/filemanager/content/tc/files/basiclawtext/basiclaw_full_text.pdf"
  } > "$target"
}

build_main_branch() {
  log "构建主分支: 香港基本法..."
  mkdir -p "宪制"
  local file="宪制/中华人民共和国香港特别行政区基本法.md"

  write_basic_law "$file" \
    "1990年4月4日第七届全国人民代表大会第三次会议通过" \
    "1997年7月1日起施行" || return 1
  git add "$file"
  GIT_AUTHOR_NAME="$GIT_NAME" GIT_AUTHOR_EMAIL="$GIT_EMAIL" GIT_AUTHOR_DATE="@$(epoch_at 1990-04-04) +0800" \
  GIT_COMMITTER_NAME="$GIT_NAME" GIT_COMMITTER_EMAIL="$GIT_EMAIL" GIT_COMMITTER_DATE="@$(epoch_at 1990-04-04) +0800" \
    git commit -q -m "1990年4月4日第七届全国人民代表大会第三次会议通过《中华人民共和国香港特别行政区基本法》"

  write_basic_law "$file" \
    "1990年4月4日第七届全国人民代表大会第三次会议通过" \
    "1997年7月1日起施行" \
    "2010年8月28日第十一届全国人大常委会第十六次会议批准或备案附件一、附件二修正" || return 1
  git add "$file"
  GIT_AUTHOR_NAME="$GIT_NAME" GIT_AUTHOR_EMAIL="$GIT_EMAIL" GIT_AUTHOR_DATE="@$(epoch_at 2010-08-28) +0800" \
  GIT_COMMITTER_NAME="$GIT_NAME" GIT_COMMITTER_EMAIL="$GIT_EMAIL" GIT_COMMITTER_DATE="@$(epoch_at 2010-08-28) +0800" \
    git commit -q -m "2010年8月28日全国人大常委会批准或备案香港基本法附件一、附件二修正"

  write_basic_law "$file" \
    "1990年4月4日第七届全国人民代表大会第三次会议通过" \
    "1997年7月1日起施行" \
    "2010年8月28日第十一届全国人大常委会第十六次会议批准或备案附件一、附件二修正" \
    "2021年3月30日第十三届全国人大常委会第二十七次会议修订附件一、附件二" || return 1
  git add "$file"
  GIT_AUTHOR_NAME="$GIT_NAME" GIT_AUTHOR_EMAIL="$GIT_EMAIL" GIT_AUTHOR_DATE="@$(epoch_at 2021-03-30) +0800" \
  GIT_COMMITTER_NAME="$GIT_NAME" GIT_COMMITTER_EMAIL="$GIT_EMAIL" GIT_COMMITTER_DATE="@$(epoch_at 2021-03-30) +0800" \
    git commit -q -m "2021年3月30日全国人大常委会修订香港基本法附件一、附件二"

  ok "主分支完成: $(git rev-parse HEAD)"
}

# ---------------------------------------------------------------- 殖民地时期
# en.wikisource 的《英皇制诰》《皇室训令》正文在 12 页扫描件里，
# 校订文本位于 Page: 命名空间。第 5 页是两份文件的交界页
# （<section end="HKLP1917" /> 之后转入训令），需按分节标记裁切。
COLONIAL_PDF="Hong Kong Letters Patent and Royal Instructions 1917.pdf"

wiki_page_range() {  # $1=基名 $2=起页 $3=止页  -> 拼接后的 wikitext
  local base="$1" from="$2" to="$3" i
  for i in $(seq "$from" "$to"); do
    printf '\n\n'
    wiki_page "$base" "$i" || return 1
  done
}

# 裁掉校订页中某个分节之前/之后的内容
cut_section() {  # $1=文件 $2=begin|end $3=分节名  -> 裁切后的文件
  local f="$1" mode="$2" sec="$3"
  if [ "$mode" = "end" ]; then
    # 保留 <section end="SEC" /> 之前的内容
    awk -v m="<section end=\"$sec\" />" 'index($0,m){exit} {print}' "$f" > "$f.cut" && mv "$f.cut" "$f"
  else
    # 保留 <section begin="SEC" /> 之后的内容
    awk -v m="<section begin=\"$sec\" />" 'f{print} index($0,m){f=1}' "$f" > "$f.cut" && mv "$f.cut" "$f"
  fi
}

build_historical_branches() {
  log "构建殖民地时期宪制分支..."
  local lp="$TMPDIR/letters.md" ri="$TMPDIR/instructions.md"
  local p5="$TMPDIR/p5.txt"

  # 英皇制诰：第 1—4 页全文 + 第 5 页在 HKLP1917 分节结束前的部分
  {
    wiki_page_range "$COLONIAL_PDF" 1 4
    wiki_page "$COLONIAL_PDF" 5 > "$p5"
    cut_section "$p5" end HKLP1917
    cat "$p5"
  } 2>/dev/null | wiki_to_markdown > "$lp.raw"
  assert_body "英皇制诰" "$lp.raw" 10000 || { warn "  英皇制诰正文抓取失败，跳过该分支"; return 1; }
  {
    echo "# Hong Kong Letters Patent 1917"
    echo
    echo "> 1917年2月14日乔治五世颁布（1917年4月20日生效）；1997年7月1日香港回归后失效。"
    echo "> 文本据 en.wikisource 的 Page: 校订文本（《Hong Kong Letters Patent and Royal Instructions 1917.pdf》第 1—5 页，止于 HKLP1917 分节）。"
    echo
    build_toc "$lp.raw"
    echo
    cat "$lp.raw"
    echo
    echo "---"
    echo
    echo "资料来源：https://en.wikisource.org/wiki/Hong_Kong_Letters_Patent_1917"
  } > "$lp"
  make_historical_commit "英皇制诰" "-1668729600" "+0000" \
    "1917年2月14日颁布《Hong Kong Letters Patent》" \
    "宪制/Hong Kong Letters Patent 1917.md" "$lp"

  # 皇室训令：第 5 页 HKRI1917 分节之后的部分 + 第 6—12 页
  {
    wiki_page "$COLONIAL_PDF" 5 > "$p5"
    cut_section "$p5" begin HKRI1917
    cat "$p5"
    wiki_page_range "$COLONIAL_PDF" 6 12
  } 2>/dev/null | wiki_to_markdown > "$ri.raw"
  assert_body "皇室训令" "$ri.raw" 10000 || { warn "  皇室训令正文抓取失败，跳过该分支"; return 1; }
  {
    echo "# Hong Kong Royal Instructions 1917"
    echo
    echo "> 1917年2月14日与《英皇制诰》同期颁布（1917年4月20日生效）；1997年7月1日香港回归后失效。"
    echo "> 文本据 en.wikisource 的 Page: 校订文本（《Hong Kong Letters Patent and Royal Instructions 1917.pdf》第 5—12 页，起于 HKRI1917 分节）。"
    echo
    build_toc "$ri.raw"
    echo
    cat "$ri.raw"
    echo
    echo "---"
    echo
    echo "资料来源：https://en.wikisource.org/wiki/Hong_Kong_Royal_Instructions_1917"
  } > "$ri"
  make_historical_commit "皇室训令" "-1668729600" "+0000" \
    "1917年2月14日颁布《Hong Kong Royal Instructions》" \
    "宪制/Hong Kong Royal Instructions 1917.md" "$ri"

  ok "历史分支创建完成"
}

main() {
  log "=== legalize-hk 宪制历史构建 ==="; log "目标仓库: $TARGET_REPO"; echo
  clean_repo; echo
  build_main_branch; echo
  build_historical_branches; echo
  git checkout main 2>/dev/null || true
  log "=== 构建完成 ==="; echo; log "分支一览:"; git branch -a | cat; echo
  log "主分支历史（早于 1970 的提交 git log 无法显示日期，请用 git cat-file -p 查看）:"
  git log --format="%ad %s" --reverse main | cat
}

cd "$TARGET_REPO"; main "$@"
