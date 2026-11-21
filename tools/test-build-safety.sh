#!/usr/bin/env bash
# tools/test-build-safety.sh — 构建器的安全回归测试（不访问网络，不触碰真实仓库）
#
# 覆盖：
#   * 正常构建、重复构建（无 --force 必须拒绝且不破坏旧产物）
#   * --force 重建（提交/标签数量不变、只有一个根提交、保留 .git/config）
#   * 非空目录（无 --force 拒绝；--force 替换）
#   * 不带目标参数（必须报错，且不删除当前目录）
#   * 目标位于元仓库内部（必须拒绝）
#   * 产物 fsck 干净、工作区干净

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d /tmp/legalize-safety.XXXXXX)"
trap 'rm -rf "$T"' EXIT

failures=0
pass() { printf '  OK   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; failures=$((failures + 1)); }

run_ok() {  # $1=描述，其余=命令
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}
run_fail() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "$desc（本应失败）"; else pass "$desc"; fi
}

tags_of() { git -C "$1" tag -l | sort; }
commits_of() { git -C "$1" rev-list --count --all; }
roots_of() { git -C "$1" rev-list --max-parents=0 --all | wc -l | tr -d ' '; }

echo "== 构建器安全回归 =="

# 1. 正常构建
BUILD="$T/repo"
run_ok "jp 构建成功" bash "$ROOT/jp/build.sh" "$BUILD"
[ -d "$BUILD/.git" ] && pass "目标是一个 Git 仓库" || fail "目标不是 Git 仓库"
[ "$(roots_of "$BUILD")" = "1" ] && pass "只有一个根提交" || fail "根提交数量不是 1"
[ -z "$(git -C "$BUILD" status --porcelain)" ] && pass "工作区干净" || fail "工作区不干净"
git -C "$BUILD" fsck --strict >/dev/null 2>&1 && pass "fsck --strict 干净" || fail "fsck 报错"

tags_before="$(tags_of "$BUILD")"
commits_before="$(commits_of "$BUILD")"
git -C "$BUILD" remote add origin https://example.invalid/legalize-test.git

# 2. 重复构建：无 --force 必须拒绝，且旧产物原样保留
run_fail "非空目标无 --force 被拒绝" bash "$ROOT/jp/build.sh" "$BUILD"
[ "$(tags_of "$BUILD")" = "$tags_before" ] && pass "拒绝后标签未变" || fail "拒绝后标签被改动"
[ "$(commits_of "$BUILD")" = "$commits_before" ] && pass "拒绝后提交数未变" || fail "拒绝后提交数被改动"

# 3. --force 重建：结果应与首次一致，且保留 remote
run_ok "--force 重建成功" bash "$ROOT/jp/build.sh" "$BUILD" --force
[ "$(tags_of "$BUILD")" = "$tags_before" ] && pass "重建后标签一致" || fail "重建后标签不一致"
[ "$(commits_of "$BUILD")" = "$commits_before" ] && pass "重建后提交数一致" || fail "重建后提交数不一致"
[ "$(roots_of "$BUILD")" = "1" ] && pass "重建后仍只有一个根提交" || fail "重建后根提交数量不对"
git -C "$BUILD" remote -v | grep -q 'example.invalid' && pass "重建保留 .git/config（remote）" || fail "重建丢失 remote"

# 3b. 当前工作目录位于目标内：必须拒绝
( cd "$BUILD" && bash "$ROOT/jp/build.sh" "$BUILD" --force >/dev/null 2>&1 )
rc=$?
[ "$rc" -ne 0 ] && pass "从目标内部运行被拒绝" || fail "从目标内部运行未被拒绝"
[ "$(tags_of "$BUILD")" = "$tags_before" ] && pass "拒绝后目标未变" || fail "拒绝后目标被改动"

# 4. 非空普通目录
DIRTY="$T/dirty"
mkdir -p "$DIRTY"
echo keep > "$DIRTY/notes.txt"
run_fail "非空非 Git 目录无 --force 被拒绝" bash "$ROOT/cn/build.sh" "$DIRTY"
[ -f "$DIRTY/notes.txt" ] && pass "拒绝后用户文件仍在" || fail "拒绝后用户文件被删"
run_ok "非空非 Git 目录 --force 构建成功" bash "$ROOT/cn/build.sh" "$DIRTY" --force
[ ! -e "$DIRTY/notes.txt" ] && pass "--force 后旧文件被替换" || fail "--force 后旧文件仍在"
[ -d "$DIRTY/.git" ] && pass "--force 后生成 Git 仓库" || fail "--force 后没有 .git"

# 5. 不带目标参数：必须报错，且不删除当前目录
CWD="$T/cwd"
mkdir -p "$CWD"
echo keep > "$CWD/marker"
( cd "$CWD" && bash "$ROOT/jp/build.sh" >/dev/null 2>&1 )
rc=$?
[ "$rc" -ne 0 ] && pass "缺少目标参数时报错" || fail "缺少目标参数时没有报错"
[ -f "$CWD/marker" ] && pass "缺少参数时当前目录未被破坏" || fail "缺少参数时当前目录被破坏"

# 6. 文件系统顶层目录：必须拒绝
run_fail "文件系统顶层目录被拒绝" bash "$ROOT/jp/build.sh" /tmp --force

# 7. 目标位于元仓库内部：必须拒绝，且不创建目录
INSIDE="$ROOT/.safety-target-should-not-exist"
rm -rf "$INSIDE"
run_fail "元仓库内部路径被拒绝" bash "$ROOT/jp/build.sh" "$INSIDE"
[ ! -e "$INSIDE" ] && pass "被拒绝时没有创建目录" || fail "被拒绝时仍创建了目录"

echo
if [ "$failures" -eq 0 ]; then
  echo "  安全回归全部通过"
  exit 0
fi
echo "  安全回归失败 $failures 项"
exit 1
