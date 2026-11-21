"""条文审计工具的自测（不访问网络）。

重点回归一个曾经的盲区：`report()` 曾把所有 `##` 小节都当“并列版本”，
导致章与章之间的条号断档（如 kp 2013/2016 缺第 86 条）被漏掉。
"""
import importlib.util
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('audit_articles', HERE / 'audit-articles.py')
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)

failures = 0


def check(desc, cond):
    global failures
    if cond:
        print('  OK   ' + desc)
    else:
        failures += 1
        print('  FAIL ' + desc)


# 1. 章与章之间的断档必须被发现
chaptered = """## 第一章　總則
**第一條**　甲。
**第二條**　乙。
## 第二章　其他
**第四條**　丁。
**第五條**　戊。
"""
issues, notes = audit.report(pathlib.Path('synthetic.md'), chaptered)
check('跨章缺条被报告', any('缺 1 条：3' in x for x in issues))

# 2. 真正的多版本文本仍按版本检查，不应误报
versions = """## 原文
第一條　甲。
第二條　乙。
## 新字体版
第一條　甲。
第二條　乙。
"""
issues, notes = audit.report(pathlib.Path('synthetic.md'), versions)
check('多版本不误报', not issues)
check('多版本提示存在', any('并列收录' in x for x in notes))

# 3. 真实语料中的已知源站笔误必须进入审计视野
for rel in ('kp/texts/2013宪法/01-2013-04-01-2013宪法.md',
            'kp/texts/2016宪法/01-2016-06-29-2016宪法.md'):
    p = HERE.parent / rel
    check('文件存在：' + rel, p.is_file())
    text = p.read_text(encoding='utf-8')
    # report() 需要正文；这里直接复用 textframe 拆出正文
    sys.path.insert(0, str(HERE))
    import textframe
    issues, _ = audit.report(p, textframe.split(text)['body'])
    check('缺第 86 条被报告：' + rel, any('86' in x for x in issues))
    check('已登记为已知笔误：' + rel, rel in audit.KNOWN_SOURCE_TYPOS)

if failures:
    print('  审计自测失败 %d 项' % failures)
    sys.exit(1)
print('  审计自测全部通过')
