#!/usr/bin/env bash
# tools/update-sources.sh — 重新抓取宪制文本（维护者操作，会访问网络）
#
#   bash tools/update-sources.sh [区域...]      # 不带参数则更新全部区域
#   bash tools/update-sources.sh --check jp tw  # 只抓取并与库内文本比对，不写回
#
# build.sh / build.ps1 完全离线，只读 <region>/texts/；本脚本是唯一会联网的地方，
# 用于在外部来源更新后刷新库内文本。文本的"框架"（标题、说明行、出处脚注）不在本
# 脚本维护范围，只重抓"正文"，目录按新正文自动重算。
#
# 依赖：bash、curl、python3、git（cn 区域还需要 git 访问 GitHub）
# 抓取结果缓存在 $LEGALIZE_WIKICACHE（或 WIKICACHE_DIR，或
# ~/.cache/legalize-meta/wikisource），并对 429 做指数退避重试。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CHECK_ONLY=0
REGIONS=()
for a in "$@"; do
  case "$a" in
    --check) CHECK_ONLY=1 ;;
    *) REGIONS+=("$a") ;;
  esac
done
[ ${#REGIONS[@]} -gt 0 ] || REGIONS=(cn hk tw mo jp kr kp vn)

SOURCES="$ROOT/tools/sources.tsv"
[ -f "$SOURCES" ] || { echo "[!] 找不到 $SOURCES" >&2; exit 1; }

WIKICACHE="${LEGALIZE_WIKICACHE:-${WIKICACHE_DIR:-$HOME/.cache/legalize-meta/wikisource}}"
mkdir -p "$WIKICACHE"
WORK="$(mktemp -d /tmp/legalize-sources.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
UA="legalize-meta/1.0 (constitutional text maintainer tool)"

log(){ echo "[*] $*"; }; ok(){ echo "  -> $*"; }; warn(){ echo "[!] $*" >&2; }

# ---------------------------------------------------------------- 抓取
fetch() {  # $1=缓存键 $2=URL $3...=额外 curl 参数
  local key="$1" url="$2"; shift 2
  local cache; cache="$WIKICACHE/$(printf '%s' "$key" | md5sum | cut -d' ' -f1)"
  if [ -s "$cache" ]; then cat "$cache"; return 0; fi
  local code rc attempt wait
  for attempt in 1 2 3 4 5 6; do
    code="$(curl -sS -L --max-time 45 -A "$UA" -o "$WORK/f" -w '%{http_code}' "$@" "$url" 2>/dev/null)" || rc=$?
    if [ "${rc:-0}" -eq 0 ] && [ "$code" = "200" ] && [ -s "$WORK/f" ]; then
      mv "$WORK/f" "$cache"; cat "$cache"; return 0
    fi
    wait=$(( attempt * attempt * 3 )); [ "$wait" -gt 60 ] && wait=60
    warn "  [fetch] $url http=$code 重试($attempt/6) ${wait}s"; sleep "$wait"
  done
  warn "  [fetch] 失败：$url"; return 1
}

# ---------------------------------------------------------------- 转换器
cat > "$WORK/wiki_to_md.py" <<'PY'
import sys, re

# 用法： wiki_to_md.py [raw]
#   默认      —— 用于维基文库 wikitext：按维基习惯清理行首缩进与定义列表标记 ':'
#   raw      —— 用于本来就是 Markdown 的源（如 cn 的两个 GitHub 仓库）：
#               只做实体解码等无损处理，不动行首缩进
MODE = sys.argv[1] if len(sys.argv) > 1 else 'wiki'
# 排版模板：剥掉模板壳、保留内容。center/right 必须在这里剥而不能删——
# 澳门组织章程的条文编号写作 {{center|'''第一條'''}}，删掉会连条号一起吞，
# 全文 145 条编号全部消失（库里那份 mo 章程正是这样缺了编号的）。
UNWRAP = ['Sc', 'sc', 'SmallCaps', 'Big', 'big', 'Center', 'center', 'centre',
          'Right', 'right', 'right block', 'larger', 'x-larger', 'hdr']
text = sys.stdin.read()
for name in UNWRAP:
    pat = r'\{\{\s*' + re.escape(name) + r'\s*\|((?:[^{}]|\{\{)*?)\}\}'
    prev = None
    while prev != text:
        prev = text
        text = re.sub(pat, lambda m: re.sub(r'\|\s*\d+\s*=', '|', m.group(1)), text, flags=re.S)
# 纯排版模板：连内容一起删。注意 center/right 只能删「无参数」形式——
# 澳门组织章程的条文编号写作 {{center|'''第一條'''}}，若把带参数的一并删掉，
# 会连「第一條」这个条号一起吞掉，全文 145 条编号全部消失。
text = re.sub(r'(?is)\{\{\s*(?:rule|Rule|sidenotes\s+(?:begin|end)|gap|nbsp|pagequality|rh|'
              r'running\s?head|header|footer|PPB|br|sc|Sc|ts|vtt|'
              r'right\s+block|Big|big)\s*(?:\|[^{}]*)?\}\}', '', text)
text = re.sub(r'(?is)\{\{\s*(?:center|centre|right)\s*\}\}', '', text)
text = re.sub(r'(?is)<noinclude>.*?</noinclude>', '', text)
prev = None
while prev != text:
    prev = text
    text = re.sub(r'(?s)\{\{([^{}]*)\}\}', '', text)


def _table(m):
    rows = []
    for ln in m.group(1).split('\n'):
        s = ln.strip()
        if not s or s.startswith('{|'):
            continue
        if re.fullmatch(r'[-+!| ]*[-+!]([-+!| ]*)', s):
            continue
        s = re.sub(r'^\|[-+!]?\s*', '', s)
        s = re.sub(r'\s*\|\s*$', '', s)
        s = s.strip('|').strip()
        if not s:
            continue
        cells = [c.strip() for c in re.split(r'\s*\|\|\s*', s) if c.strip()]
        if cells:
            rows.append(cells)
    if not rows:
        return '\n'
    width = max(len(r) for r in rows)
    if width == 1:                                   # 单列：逐行输出
        return '\n' + '\n'.join(r[0] for r in rows) + '\n'
    # 多列：取第一个满宽度的行做表头，输出 Markdown 表格（否则单元格首尾相连不可读）
    head = next(r for r in rows if len(r) == width)
    out = ['| ' + ' | '.join(head) + ' |', '|' + '---|' * width]
    for r in rows:
        if r is head:
            continue
        cells = (r + [''] * width)[:width]
        out.append('| ' + ' | '.join(cells) + ' |')
    return '\n' + '\n'.join(out) + '\n'


text = re.sub(r'(?s)\{\|(.*?)\|\}', _table, text, flags=re.S)
text = re.sub(r'(?s)\{\|.*?\}\}', '', text)
text = re.sub(r'(?is)</?onlyinclude>', '', text)
text = re.sub(r'(?is)<section\b[^>]*/?>', '', text)
text = re.sub(r'(?is)<pages\b[^>]*/?>', '', text)
text = re.sub(r'(?i)<br\s*/?>', '\n', text)
text = re.sub(r'<[^>]+>', '', text)
Q3 = chr(39) * 3
Q2 = chr(39) * 2
text = re.sub(r'(?s)' + Q3 + r'(.*?)' + Q3, r'**\1**', text)
text = re.sub(r'(?s)' + Q2 + r'(.*?)' + Q2, r'*\1*', text)
text = re.sub(r'(?m)^====\s*(.*?)\s*====$', r'#### \1', text)
text = re.sub(r'(?m)^===\s*(.*?)\s*===$', r'### \1', text)
text = re.sub(r'(?m)^==\s*(.*?)\s*==$', r'## \1', text)
text = re.sub(r'\[\[(?:Category|分類|分类)[:：][^\]]*\]\]', '', text, flags=re.I)
# 文件/图片链接：目标在 Markdown 文本里无法呈现，整条删除
# （否则 [[File:xxx.svg|170px]] 会被下面的通用规则还原成 "170px" 尺寸数字）
text = re.sub(r'\[\[:?(?:File|Image|文件|檔案|圖像|图像)[:：][^\]]*\]\]', '', text, flags=re.I)
text = re.sub(r'\[\[(?:File|Image|文件|檔案|圖像|图像)[:：][^\]]*\]\]', '', text, flags=re.I)
# 跨语言链接（interwiki）：[[en:Additional Articles...]] / [[vi:Hiến pháp...]]。
# 这些链接指向同一份文书的别语版本，链接目标即标题，去掉语言前缀即可；
# 不处理的话会留下 "en:Additional Articles…" 这种半截标记。
text = re.sub(r'\[\[(?:[a-z]{2,12}|[一-鿿]{2,3}):([^\]|]+)\]\]', r'\1', text)
text = re.sub(r'\[\[[^\]|]+\|([^\]]+)\]\]', r'\1', text)
text = re.sub(r'\[\[([^\]]+)\]\]', r'\1', text)
text = re.sub(r'\[(?:https?|ftp)://\S+\s+([^\]]+)\]', r'\1', text)
for a, b in (('&nbsp;', ' '), ('&amp;', '&'), ('&lt;', '<'), ('&gt;', '>'), ('&quot;', '"')):
    text = text.replace(a, b)
text = re.sub(r'\r\n?', '\n', text)
# 行尾空白必须在标题转换之前清掉：维基标题常写成 "== 标题 == "（结尾多一个空格），
# 不先清掉的话 ^==\s*(.*?)\s*==$ 匹配不上，整章标题会以原文形态漏进正文。
text = re.sub(r'[ \t\u3000]+$', '', text, flags=re.M)
if MODE != 'raw':
    text = re.sub(r'(?m)^[ \t\u3000:;]+', '', text)      # 维基习惯：去行首缩进与 ':' 定义列表标记
keep = []
for ln in text.split('\n'):
    s = ln.strip()
    if re.match(r'^\[\[(Category|分類|分类)', s, re.I):
        continue
    if s in ('__NOTOC__', '__TOC__', '__NEWSECTION__', '__FORCETOC__'):
        continue                      # 维基的目录开关行为标记，Markdown 里无意义
    if MODE != 'raw' and s.startswith('|') and '=' in s:   # 残留的表格参数行
        continue
    keep.append(ln)
text = '\n'.join(keep)
text = re.sub(r'\n{3,}', '\n\n', text)
print(text.strip())
PY

cat > "$WORK/html_to_md.py" <<'PY'
import sys, re, html
text = sys.stdin.read()
m = re.search(r'<!--\s*Content Begin\s*-->(.*?)<!--\s*Content End\s*-->', text, re.S | re.I)
body = m.group(1) if m else text
body = re.sub(r'(?is)<script\b.*?</script>', '', body)
body = re.sub(r'(?is)<style\b.*?</style>', '', body)
body = re.sub(r'(?s)<!--.*?-->', '', body)
body = re.sub(r'(?is)<div class="nav-btn-wrap.*?</div>', '', body)
body = re.sub(r'(?is)<h([1-6])[^>]*>(.*?)</h\1>',
              lambda m: '\n\n' + '#' * min(6, int(m.group(1)) + 2) + ' ' + m.group(2) + '\n\n', body, flags=re.S)
body = re.sub(r'(?i)<hr\s*/?>', '\n\n', body)
for tag in ('p', 'div', 'tr', 'dd'):
    body = re.sub(r'(?i)<%s\b[^>]*>' % tag, '\n\n', body)
    body = re.sub(r'(?i)</%s>' % tag, '\n\n', body)
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

# 香港基本法官方站点的分节（简体章节名 + 官方繁体站点）
BASICLAW_SECTIONS=(
  "decree|中华人民共和国主席令（第二十六号）" "preamble|序言"
  "chapter1|第一章　总则" "chapter2|第二章　中央和香港特别行政区的关系"
  "chapter3|第三章　居民的基本权利和义务" "chapter4|第四章　政治体制"
  "chapter5|第五章　经济"
  "chapter6|第六章　教育、科学、文化、体育、宗教、劳工和社会服务"
  "chapter7|第七章　对外事务" "chapter8|第八章　本法的解释和修改"
  "chapter9|第九章　附则" "annex1|附件一　香港特别行政区行政长官的产生办法"
  "annex2|附件二　香港特别行政区立法会的产生办法和表决程序"
  "annex3|附件三　在香港特别行政区实施的全国性法律"
)

# ---------------------------------------------------------------- 各类来源 -> 正文
body_wikisource() {  # $1=语言 $2=标题
  local lang="$1" title="$2"
  fetch "ws|$lang|$title" "https://$lang.wikisource.org/w/index.php?action=raw" \
        --get --data-urlencode "title=$title" | python3 "$WORK/wiki_to_md.py"
}

body_wikisource_pages() {  # $1=语言 $2=基名 $3=起 $4=止 [$5=分节] [$6=begin|end]
  local lang="$1" base="$2" from="$3" to="$4" sec="${5:-}" mode="${6:-}" i
  {
    for i in $(seq "$from" "$to"); do
      printf '\n\n'
      fetch "ws|$lang|Page:$base/$i" "https://$lang.wikisource.org/w/index.php?action=raw" \
            --get --data-urlencode "title=Page:$base/$i" || return 1
    done
  } > "$WORK/pages.raw"
  if [ -n "$sec" ]; then
    if [ "$mode" = "end" ]; then
      awk -v m="<section end=\"$sec\" />" 'index($0,m){exit} {print}' "$WORK/pages.raw" > "$WORK/pages.cut"
    else
      awk -v m="<section begin=\"$sec\" />" 'f{print} index($0,m){f=1}' "$WORK/pages.raw" > "$WORK/pages.cut"
    fi
    mv "$WORK/pages.cut" "$WORK/pages.raw"
  fi
  python3 "$WORK/wiki_to_md.py" < "$WORK/pages.raw"
}

body_basiclaw() {  # 官方站点全部章节
  local item page title
  : > "$WORK/bl.md"
  for item in "${BASICLAW_SECTIONS[@]}"; do
    page="${item%%|*}"; title="${item#*|}"
    fetch "basiclaw|$page" "https://www.basiclaw.gov.hk/tc/basiclaw/$page.html" \
      | python3 "$WORK/html_to_md.py" > "$WORK/bl-$page.md" || return 1
    if [ "$page" != "${page#annex}" ]; then
      sed -i '1{/^#\{1,6\} *附件/d}' "$WORK/bl-$page.md"   # 附件页自带标题，与本节重复
    fi
    { echo "## $title"; echo; cat "$WORK/bl-$page.md"; echo; } >> "$WORK/bl.md"
  done
  cat "$WORK/bl.md"
}

CN_LAWS_REPO="https://github.com/risshun/Chinese_Laws.git"
CN_CONST_REPO="https://github.com/tianyikillua/chinese-constitution.git"

body_github() {  # $1=仓库URL $2=ref(可空) $3=路径
  local url="$1" ref="$2" path="$3" dir
  dir="$WORK/gh"
  # 同一仓库只克隆一次：cn 的 10 个文本来自 2 个仓库，逐个克隆既慢又容易被限流
  local key="$WORK/.gh-$(printf '%s' "$url" | md5sum | cut -d' ' -f1)"
  if [ ! -d "$key" ]; then
    rm -rf "$key"
    if ! git clone -q --filter=blob:none --no-checkout "$url" "$key"; then
      warn "  克隆失败：$url"; return 1
    fi
  fi
  if [ -n "$ref" ]; then
    # 短 hash 不一定在浅克隆里可达，取不到就补一次 fetch
    git -C "$key" cat-file -e "$ref^{commit}" 2>/dev/null \
      || git -C "$key" fetch -q --depth=1 origin "$ref" 2>/dev/null \
      || git -C "$key" fetch -q origin 2>/dev/null \
      || { warn "  取 ref $ref 失败：$url"; return 1; }
    git -C "$key" show "$ref:$path" 2>/dev/null
  else
    git -C "$key" show "HEAD:$path" 2>/dev/null
  fi
}

# cn 的源文件自带标题、说明与目录，正文入库时要去掉（框架由已入库的文件保留）。
# 注意不能用 `tr -s '\n'`：那会把段落之间的空行也压掉。
cn_clean() {
  sed -e '/^# /d' -e '/^>/d' -e '/^\[.*\](.*)/d' -e '/^[[:space:]]*-[[:space:]]*\[/d' -e 's/<br>//g'
}

# ---------------------------------------------------------------- 主流程
changed=0; failed=0
for region in "${REGIONS[@]}"; do
  manifest="$ROOT/$region/texts/manifest.tsv"
  [ -f "$manifest" ] || { warn "跳过 $region（无 texts/manifest.tsv）"; continue; }
  log "=== $region ==="
  while IFS=$'\t' read -r reg file kind spec; do
    [ -n "${reg:-}" ] || continue
    case "$reg" in '#') continue ;; esac
    target="$ROOT/$reg/texts/$file"
    [ -f "$target" ] || { warn "  库内缺少 $reg/texts/$file"; failed=$((failed+1)); continue; }

    newbody="$WORK/body.md"
    case "$kind" in
      wikisource)
        lang="${spec#wikisource:}"; lang="${lang%%:*}"; title="${spec#*:}"
        body_wikisource "$lang" "$title" > "$newbody" || { warn "  抓取失败：$spec"; failed=$((failed+1)); continue; }
        ;;
      wikisource-pages)
        rest="${spec#wikisource-pages:}"
        lang="${rest%%:*}"; rest="${rest#*:}"
        base="${rest%%|*}"; rest="${rest#*|}"
        rng="${rest%%|*}"; from="${rng%%-*}"; to="${rng##*-}"; rest="${rest#*|}"
        sec=""; mode=""
        [ -n "$rest" ] && sec="${rest#cut:}"; sec="${sec%%:*}"; mode="${rest##*:}"
        body_wikisource_pages "$lang" "$base" "$from" "$to" "$sec" "$mode" > "$newbody" \
          || { warn "  抓取失败：$spec"; failed=$((failed+1)); continue; }
        ;;
      basiclaw)
        body_basiclaw > "$newbody" || { warn "  抓取失败：$spec"; failed=$((failed+1)); continue; }
        ;;
      github)
        # 形如 github:<仓库>[@<ref>]:<路径>
        rest="${spec#github:}"
        repo="${rest%%:*}"; rest="${rest#*:}"
        ref=""
        case "$repo" in
          *@*) ref="${repo##*@}"; repo="${repo%@*}" ;;
        esac
        path="$rest"
        case "$repo" in
          tianyikillua/chinese-constitution) url="$CN_CONST_REPO" ;;
          risshun/Chinese_Laws)              url="$CN_LAWS_REPO" ;;
          *) url="https://github.com/$repo.git" ;;
        esac
        body_github "$url" "$ref" "$path" > "$WORK/raw.md" || { warn "  取源失败：$spec"; failed=$((failed+1)); continue; }
        python3 "$WORK/wiki_to_md.py" raw < "$WORK/raw.md" | cn_clean > "$newbody"
        ;;
      *)
        warn "  未知 kind：$kind"; failed=$((failed+1)); continue ;;
    esac

    if [ ! -s "$newbody" ]; then warn "  正文为空：$spec"; failed=$((failed+1)); continue; fi

    # 用新正文重组（保留标题/说明/脚注，目录按新正文重算）
    NEWBODY="$newbody" TARGET="$target" TOOLS="$ROOT/tools" python3 - <<'PY' > "$WORK/rebuilt.md"
import os, sys, pathlib
sys.path.insert(0, os.environ["TOOLS"])
import textframe
t = pathlib.Path(os.environ['TARGET'])
raw = t.read_text(encoding='utf-8')
parts = textframe.split(raw)
body = pathlib.Path(os.environ['NEWBODY']).read_text(encoding='utf-8').strip('\n')
sys.stdout.write(textframe.rebuild(parts, body))
PY
    if diff -q "$WORK/rebuilt.md" "$target" >/dev/null 2>&1; then
      ok "无变化  $file"
    elif [ "$CHECK_ONLY" = 1 ]; then
      warn "有差异  $file（--check 未写回）"
      diff -u "$target" "$WORK/rebuilt.md" | head -25 | sed 's/^/        /'
      changed=$((changed+1))
    else
      cp "$WORK/rebuilt.md" "$target"
      ok "已更新  $file"
      changed=$((changed+1))
    fi
  done < <(awk -F'\t' -v r="$region" 'NF==4 && $1==r' "$SOURCES")
done

echo
if [ "$CHECK_ONLY" = 1 ]; then
  log "--check：$changed 个文本与库内不同（未写回），失败 $failed 个"
else
  log "完成：$changed 个文本已更新，失败 $failed 个"
fi
[ "$failed" -eq 0 ] || exit 1
