#!/usr/bin/env bash
# mo/build.sh — 澳门宪制历史构建脚本（Bash 版）
# 用法: bash mo/build.sh <目标Git仓库路径>
# 在指定 git 仓库中构建澳门宪制文件（主分支 = 《澳门组织章程》1996 年整合文本）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

REPO_PATH="${1:-.}"

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

TMPDIR="$(mktemp -d /tmp/legalize-mo-build.XXXXXX)"
trap "rm -rf '$TMPDIR'" EXIT

GIT_NAME="$(git config user.name || true)"
GIT_EMAIL="$(git config user.email || true)"
[ -n "$GIT_NAME" ] || GIT_NAME="legalize-meta"
[ -n "$GIT_EMAIL" ] || GIT_EMAIL="legalize-meta@example.invalid"

log()  { echo "[*] $*"; }
ok()   { echo "  -> $*"; }
warn() { echo "[!] $*" >&2; }

# 维基文库抓取：持久缓存 + 限流退避重试（避免 429）
WIKICACHE="${WIKICACHE_DIR:-$HOME/.cache/legalize-meta/wikisource}"
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

zh_wiki_raw() { wiki_fetch zh "$1"; }

cat > "$TMPDIR/wiki_to_md.py" <<'PY'
import sys, re
text = sys.stdin.read()
while '{{' in text:
    new = re.sub(r'\{\{([^{}]*)\}\}', '', text, flags=re.S)
    if new == text:
        break
    text = new
text = re.sub(r'(?is)<noinclude>.*?</noinclude>', '', text)
text = re.sub(r'(?is)</?onlyinclude>', '', text)
text = re.sub(r'<[^>]+>', '', text)
text = re.sub(r"(?s)'''(.*?)'''", r'**\1**', text)
text = re.sub(r"(?s)''(.*?)''", r'*\1*', text)
text = re.sub(r'(?m)^====\s*(.*?)\s*====$', r'#### \1', text)
text = re.sub(r'(?m)^===\s*(.*?)\s*===$', r'### \1', text)
text = re.sub(r'(?m)^==\s*(.*?)\s*==$', r'## \1', text)
text = re.sub(r'\[\[[^\]|]+\|([^\]]+)\]\]', r'\1', text)
text = re.sub(r'\[\[([^\]]+)\]\]', r'\1', text)
text = text.replace('&nbsp;', ' ')
text = re.sub(r'\r\n', '\n', text)
text = re.sub(r'(?m)^[ \t\u3000:;]+', '', text)
keep = []
for ln in text.split('\n'):
    s = ln.strip()
    if re.match(r'^\[\[(Category|category|分類|分[類类])', s, re.I):
        continue
    if s.startswith('|') and '=' in s:
        continue
    keep.append(ln)
text = '\n'.join(keep)
text = re.sub(r'\n{3,}', '\n\n', text)
print(text.strip())
PY

wiki_to_markdown() {
  python3 "$TMPDIR/wiki_to_md.py"
}

build_toc() {
  grep '^## ' "$1" | sed 's/^## //' | while IFS= read -r line; do
    anchor="$(printf '%s' "$line" | sed 's/　//g; s/ //g')"
    printf -- '- [%s](#%s)\n' "$line" "$anchor"
  done || true
}

# 手动构造 commit 对象：GIT 的 GIT_AUTHOR_DATE 无法解析早于 1970 的日期。
mk_commit() {  # $1=ref, $2=epoch, $3=tz, $4=msg, $5=parent(可选; "-" 表示无父)
  local ref="$1" ts="$2" z="$3" msg="$4"
  local parent="${5:-__auto__}"
  local tree content hash
  tree="$(git write-tree)"
  if [ "$parent" = "__auto__" ]; then
    parent="$(git rev-parse --verify HEAD 2>/dev/null || true)"
  fi
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

  local root
  root="$(git rev-list --max-parents=0 HEAD 2>/dev/null || true)"

  if [ -n "$root" ]; then
    git checkout main 2>/dev/null || true
    git reset --hard "$root" 2>/dev/null || true
    git rm -r . --quiet 2>/dev/null || true
  fi

  cp "$SCRIPT_DIR/.gitignore" "$SCRIPT_DIR/LICENSE" "$SCRIPT_DIR/README.md" . 2>/dev/null || true
  git add .

  git branch | sed 's/^\*//' | tr -d ' ' | while IFS= read -r b; do
    [ "$b" = "main" ] && continue
    [ -z "$b" ] && continue
    git branch -D "$b" 2>/dev/null || true
  done

  mk_commit "main" "838602000" "+0800" "Initial commit" "-"
  git branch -M main
  log "根提交: $(git rev-parse HEAD)"
}

build_main_branch() {
  log "构建主分支: 澳门组织章程..."

  mkdir -p 宪制
  local body="$TMPDIR/组织章程.md"
  local file="宪制/澳门组织章程.md"

  zh_wiki_raw "澳門組織章程" | wiki_to_markdown > "$body"
  {
    echo '# 澳门组织章程'
    echo
    echo '> 第1/76号法律（1976年2月17日通过；政府公报第9期副刊，1976年3月1日）'
    echo '> 经第53/79号法律（1979年9月14日）、第13/90号法律（1990年5月10日）、第23-A/96号法律（1996年7月29日）修改'
    echo '> 1999年12月20日澳门回归后由《中华人民共和国澳门特别行政区基本法》取代'
    echo
    build_toc "$body"
    echo
    cat "$body"
  } > "$file"
  git add "$file"
  mk_commit "main" "838602000" "+0800" "1996年7月29日第23-A/96号法律修改《澳门组织章程》"
  ok "主分支完成: $(git rev-parse HEAD)"
}

main() {
  log "=== legalize-mo 宪制历史构建 ==="
  log "目标仓库: $TARGET_REPO"
  echo

  clean_repo
  echo

  build_main_branch
  echo

  git checkout main 2>/dev/null || true
  log "=== 构建完成 ==="
  echo
  log "分支一览:"
  git branch -a | cat
  echo
  log "主分支历史:"
  git log --format="%ai %s" --reverse main | cat
}

cd "$TARGET_REPO"
main "$@"
