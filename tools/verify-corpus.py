"""校验已入库的宪制文本（不访问网络）。

1. 拆分后用原正文重组，应与原文件逐字节一致（证明 textframe 的拆分/重组是幂等的）；
2. 文件里的目录条目应与正文 '## ' 标题按 GitHub slug 规则算出的目录一致；
3. 正文不得为空；
4. 不得出现空标题（`####` 之类，转换器漏掉标题内容时会留下）；
5. `##` 小节不得为空（只剩标题、没有正文）。
"""
import re, sys, pathlib
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
        body = parts['body']
        if not body.strip():
            bad += 1
            print("   !! %s：正文为空" % p)

        empty_heads = [i + 1 for i, line in enumerate(body.split('\n'))
                       if re.match(r'^#{1,6}\s*$', line)]
        if empty_heads:
            bad += 1
            print("   !! %s：出现 %d 个空标题（行 %s）"
                  % (p, len(empty_heads), '、'.join(map(str, empty_heads[:8]))))

        marks = list(re.finditer(r'^##\s+(.+?)\s*$', body, re.M))
        empty_sections = []
        for i, m in enumerate(marks):
            start = m.end()
            end = marks[i + 1].start() if i + 1 < len(marks) else len(body)
            if not body[start:end].strip():
                empty_sections.append(m.group(1).strip())
        if empty_sections:
            bad += 1
            print("   !! %s：%d 个空小节（%s）"
                  % (p, len(empty_sections), ' / '.join(empty_sections[:5])))

print("  校验 %d 个文本文件：%s" % (n, "全部通过（拆分/重组幂等、目录与正文一致、正文非空、无空标题/空小节）"
                                if bad == 0 else "%d 个有问题" % bad))
sys.exit(1 if bad else 0)
