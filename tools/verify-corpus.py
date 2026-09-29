"""校验已入库的宪制文本（不访问网络）。

1. 拆分后用原正文重组，应与原文件逐字节一致（证明 textsframe 的拆分/重组是幂等的）；
2. 文件里的目录条目应与正文 '## ' 标题按 GitHub slug 规则算出的目录一致；
3. 正文不得为空。
"""
import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import textframe

REG = ['cn', 'hk', 'tw', 'mo', 'jp', 'kr', 'kp', 'vn']
bad = 0
n = 0
for d in REG:
    man = pathlib.Path(d) / 'texts' / 'manifest.tsv'
    for line in man.read_text(encoding='utf-8').split('\n'):
        if not line or line.startswith('#'):
            continue
        f = line.split('\t')
        p = pathlib.Path(d) / 'texts' / f[2]
        raw = p.read_text(encoding='utf-8')
        parts = textframe.split(raw)
        again = textframe.rebuild(parts, parts['body'])
        n += 1
        if again != raw:
            bad += 1
            a, b = raw.split('\n'), again.split('\n')
            print("   !! %s：重组后与原文不一致" % p)
            for i in range(max(len(a), len(b))):
                x = a[i] if i < len(a) else '<EOF>'
                y = b[i] if i < len(b) else '<EOF>'
                if x != y:
                    print("        行 %d\n          原: %r\n          新: %r" % (i + 1, x[:80], y[:80]))
                    break
            continue
        if parts['toc'] != textframe.toc_of(parts['body']):
            bad += 1
            print("   !! %s：目录与正文标题不一致（文件 %d 条 / 应为 %d 条）"
                  % (p, len(parts['toc']), len(textframe.toc_of(parts['body']))))
        if not parts['body'].strip():
            bad += 1
            print("   !! %s：正文为空" % p)

print("  校验 %d 个文本文件：%s" % (n, "全部通过（拆分/重组幂等、目录与正文一致、正文非空）"
                                if bad == 0 else "%d 个有问题" % bad))
sys.exit(1 if bad else 0)
