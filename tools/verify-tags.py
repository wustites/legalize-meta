"""校验构建产物的日期标签与提交时间戳（不访问网络）。

每次提交都应有一个以真实日期命名的轻量标签：
  * 主分支      —— 裸日期，如 1947-12-25
  * 历史分支    —— "<日期>-<分支名>"，如 1917-02-14-英皇制诰

关于提交时间戳：1970-01-01 之前的日期 Git 无法表示（负 epoch 会让 GitHub 与部分客户端
显示出错/溢出的时间，git fsck 也会报 badDate），因此统一存为 unix 0；真实日期由标签承载。
所以这里校验的是「manifest 的历史日期」与「Git 里实际存的时间戳」是否符合上述约定，
而不是要求两者相等。

检查六项：标签命名规则与唯一性、标签覆盖 manifest 的每一次提交、标签分支名有效、
`git log --decorate` 能显示出来、1970 前的提交确实存为 unix 0、1970 后的存为该日 00:00。

用法：python3 tools/verify-tags.py <构建产物目录> [区域...]
"""
import subprocess, pathlib, sys, re, datetime

REG = ['cn', 'hk', 'tw', 'mo', 'jp', 'kr', 'kp', 'vn']
MANIFEST_ROOT = pathlib.Path(__file__).resolve().parent.parent
TS_RE = re.compile(r'^committer .*<[^>]*> (-?\d+) ([-+]\d{4})$', re.M)
TAG_RE = re.compile(r'^(\d{4}-\d{2}-\d{2})(?:-(.+))?$')


def sh(cmd, cwd=None):
    return subprocess.run(cmd, cwd=cwd, shell=True, capture_output=True, text=True).stdout


def stamp_of(repo, ref):
    raw = sh("git cat-file -p '%s'" % ref, repo)
    m = TS_RE.search(raw)
    if not m:
        return None
    return int(m.group(1)), m.group(2)


def check(repo, region):
    bad = 0
    manifest = MANIFEST_ROOT / region / 'texts' / 'manifest.tsv'
    expected = {}
    for line in manifest.read_text(encoding='utf-8').split('\n'):
        if not line or line.startswith('#'):
            continue
        f = line.split('\t')
        expected[(f[0], f[1])] = (f[3], f[4])
    branches = {b for b, _ in expected}
    pairs = {(b, d) for (b, _), (d, _) in expected.items()}

    tags = sh('git tag -l', repo).split()
    if len(tags) != len(expected):
        print("   !! 标签数 %d 与清单提交数 %d 不符" % (len(tags), len(expected))); bad += 1

    covered = set()
    for t in tags:
        m = TAG_RE.match(t)
        if not m:
            print("   !! 标签名不符合 <日期>[-<分支>]：%s" % t); bad += 1
            continue
        date, branch = m.group(1), m.group(2) or 'main'
        if branch not in branches:
            print("   !! %s 的分支名 %r 不是该区域的分支" % (t, branch)); bad += 1
        if (branch, date) not in pairs:
            print("   !! %s 的 (分支,日期) 与清单不符" % t); bad += 1
        # 存入的时间戳：1970 前必须是 unix 0，1970 后必须是该日 00:00
        st = stamp_of(repo, 'refs/tags/' + t)
        if st is None:
            print("   !! %s 指向的提交读不到时间戳" % t); bad += 1
            continue
        ts, tz = st
        want = ((datetime.datetime.strptime(date, '%Y-%m-%d') - datetime.datetime(1970, 1, 1))
                .total_seconds())
        want = int(want) - (8 if tz == '+0800' else 0) * 3600
        if date < '1970-01-01':
            if (ts, tz) != (0, '+0000'):
                print("   !! %s 是 1970 年前的提交，时间戳应为 unix 0，实为 %s %s" % (t, ts, tz)); bad += 1
        else:
            if ts != want:
                print("   !! %s 的时间戳应为 %d，实为 %d" % (t, want, ts)); bad += 1
        covered.add((branch, date))

    missing = pairs - covered
    if missing:
        print("   !! 清单中以下提交没有对应标签：%s" % sorted(missing)); bad += 1

    dec = sh('git log --oneline --decorate --all', repo)
    shown = sum(1 for t in tags if ('tag: ' + t) in dec)
    if shown != len(tags):
        print("   !! git log --decorate 只显示了 %d / %d 个标签" % (shown, len(tags))); bad += 1

    # 仓库里不应再有负时间戳，也不应再有 fsck 错误
    for br in sh("git branch --format='%(refname:short)'", repo).split():
        st = stamp_of(repo, br)
        if st and st[0] < 0:
            print("   !! 分支 %s 仍有负时间戳 %d" % (br, st[0])); bad += 1
    fsck = sh('git fsck --strict 2>&1', repo)
    if 'badDate' in fsck or 'error' in fsck:
        print("   !! git fsck --strict 有问题：%s" % fsck.strip().split(chr(10))[0]); bad += 1
    return bad, len(tags), next((l for l in dec.split('\n') if 'tag:' in l), '')


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    base = pathlib.Path(sys.argv[1])
    regions = sys.argv[2:] or REG
    bad = total = 0
    for r in regions:
        repo = base / r
        if not (repo / '.git').exists():
            print("### %s  跳过（%s 不是 git 仓库）" % (r, repo)); bad += 1; continue
        b, n, sample = check(repo, r)
        bad += b; total += n
        print("### %-3s %2d 个标签，log --decorate 全部可见%s"
              % (r, n, '' if not b else '，%d 处问题' % b))
        print("   %s" % sample)
    print()
    if bad:
        print("发现 %d 处问题" % bad)
        return 1
    print("全部通过：%d 个日期标签；命名唯一、覆盖全部提交、log --decorate 可见；时间戳为 unix 0（1970 前）或该日 00:00（1970 后），无负时间戳、fsck 干净" % total)
    return 0


if __name__ == '__main__':
    sys.exit(main())
