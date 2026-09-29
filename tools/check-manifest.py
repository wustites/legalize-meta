import sys, pathlib, re

TZ_RE = re.compile(r'^[+-]\d{4}$')

def tz_minutes(tz):
    """'+0800' -> 480；'-0330' -> -210"""
    sign = -1 if tz[0] == '-' else 1
    return sign * (int(tz[1:3]) * 60 + int(tz[3:5]))

bad = 0
for d in ('cn', 'hk', 'tw', 'mo', 'jp', 'kr', 'kp', 'vn'):
    m = pathlib.Path(d) / 'texts' / 'manifest.tsv'
    prev_branch, prev_seq = None, 0
    order = []                       # 分支出现顺序，用于检查是否连续
    for n, line in enumerate(m.read_text(encoding='utf-8').split('\n'), 1):
        if not line or line.startswith('#'):
            continue
        f = line.split('\t')
        if len(f) != 7:
            print("   !! %s:%d 字段数 %d（应为 7）" % (m, n, len(f))); bad += 1; continue
        branch, seq, file, date, tz, out, msg = f
        if not seq.isdigit() or int(seq) < 1:
            print("   !! %s:%d seq %r" % (m, n, seq)); bad += 1; continue
        if len(date) != 10 or date[4] != '-' or date[7] != '-':
            print("   !! %s:%d 日期格式 %r" % (m, n, date)); bad += 1
        # 时区：任意 ±HHMM（各地区不止 +0800：日/韩/朝 +0900、越南 +0700、
        # 朝鲜 2015-2018 年间的"平壤时间" +0830）；范围限 UTC±14:00
        if not TZ_RE.match(tz) or abs(tz_minutes(tz)) > 14 * 60:
            print("   !! %s:%d 时区 %r" % (m, n, tz)); bad += 1
        if not out or out.startswith('/'):
            print("   !! %s:%d outpath %r" % (m, n, out)); bad += 1
        if not msg or msg != msg.strip():
            print("   !! %s:%d 提交信息异常 %r" % (m, n, msg)); bad += 1
        if not (m.parent / file).is_file():
            print("   !! %s:%d 文本不存在 %r" % (m, n, file)); bad += 1
        # seq：同一分支内不重复、不跳跃（同一提交的多文件可重复同一 seq）
        if branch == prev_branch and int(seq) not in (prev_seq, prev_seq + 1):
            print("   !! %s:%d 分支 %s 的 seq 跳跃（%s -> %s）" % (m, n, branch, prev_seq, seq))
            bad += 1
        if branch != prev_branch:
            if branch in order:
                print("   !! %s:%d 分支 %s 不连续（同一分支须集中出现）" % (m, n, branch))
                bad += 1
            order.append(branch)
            prev_seq = 0
        prev_branch, prev_seq = branch, int(seq)

if bad == 0:
    print("  OK：8 份清单格式正确（字段数、日期、时区、seq 连续性、分支连续性、文本存在性）")
else:
    print("  清单校验未通过，共 %d 处问题" % bad)
sys.exit(1 if bad else 0)
