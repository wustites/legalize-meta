"""条文编号完整性审计（不访问网络）。

逐份文本核对条文编号是否从 1 起连续、有无缺号/重号，并检查章号连续性。
各地区的写法差别很大，条首的取法必须逐个适配：

  * 简体中文宪法      `**第一百零一条**　...`   粗体，数字与「条」之间无空格
  * 朝鲜 2012        `**第十九条　**　...`     粗体标记内多含一个全角空格
  * 朝鲜 1998        `#### 第一条`             4 级标题，无粗体
  * 朝鲜 2016 / 日本  `第一条`                 独占一行
  * 训政约法          `第　一　條　...`         每个汉字之间都塞了全角空格
  * 韩国 1988        `第一條 :①...`            行首，后接冒号
  * 越南 2001        `**Article 1**`          英文
  * 澳门组织章程      `**第一條**`             原为 {{center|'''第一條'''}}

几个必须绕开的坑：

  * **只看正文**。目录里每个条号都会出现一次（`- [第一条](#第一条)`），
    不排除的话满屏都是「重号」。
  * **条首锚定在行首**。正文里的交叉引用（「适用宪法第三十九条」）不算条文定义。
  * **附则会从第一条重新编号**（《澳门组织章程》第 40 条之后是附则），
    不切掉就会误判重号。
  * **同一文件可能并列收录多个版本**（明治宪法收了原文/JIS 版/新字体版四份，
    曹锟宪法并列两版），条号会整体重复，须按 `##` 小节分别检查。

退出码非零表示有文本存在编号问题。
"""
import collections
import pathlib
import re
import sys

REGIONS = ['cn', 'hk', 'tw', 'mo', 'jp', 'kr', 'kp', 'vn']
DIGIT = {'零': 0, '〇': 0, '一': 1, '二': 2, '三': 3, '四': 4,
         '五': 5, '六': 6, '七': 7, '八': 8, '九': 9}
# CNCH 里的字符是可能出现在条号里的：含「廿」（=20）与「卅」（=30），
# 韩国 1948 年宪法写的是「第廿一條」，不含这两个字就认不出来。
CNCH = '零〇一二三四五六七八九十百廿卅'
UNIT = {'十': 10, '百': 100, '千': 1000, '廿': 20, '卅': 30}
FW = str.maketrans('０１２３４５６７８９', '0123456789')

TIE = r'[条條]'            # 条 / 條
GAP = r'[　 \t]*'          # 标号内夹的全角空格
ALT = r'(?:Article|Art\.?|ARTICLE|条|條)\s*'
H = r'#{1,6}\s+'            # 标题前缀
HD = r'(?:#{1,6}\s+)?'     # 标题前缀（可选）
NP = r'第' + GAP          # 「第」与数字之间也可能夹全角空格（训政约法「第　三　十　條」）
# 条首后接冒号（韩国 1988「第一條 :①…」）或正文（训政约法「第　一　條　…」）。
# 不能把「、」算进来：曹锟宪法「第四十七條、第四十八條議員之職務…」是行首的交叉引用，
# 不是条文定义。BOL 也不能用 \s —— 它会吃掉换行，把同一条数两遍。
BOL = r'(?=[　 \t]*[:：;；]|[　 \t]+\S)'

HEAD_PATS = [
    r'^\s*\*\*第(\d+)' + GAP + TIE + r'\*\*',
    r'^\s*\*\*第([%s]+)' % CNCH + GAP + TIE + r'\*\*',
    r'^\s*\*\*第([０-９]+)' + GAP + TIE + r'\*\*',
    r'^\s*\*\*第(\d+)' + GAP + TIE + r'[　 \s]+\*\*',
    r'^\s*\*\*第([%s]+)' % CNCH + GAP + TIE + r'[　 \s]+\*\*',
    r'^\s*\*\*' + ALT + r'(\d+)\*\*',
    r'^\s*\*\*' + ALT + r'([０-９]+)\*\*',
    HD + NP + r'(\d+)' + GAP + TIE + r'\s*$',
    HD + NP + r'([%s]+)' % CNCH + GAP + TIE + r'\s*$',
    HD + NP + r'([０-９]+)' + GAP + TIE + r'\s*$',
    r'^\s*' + ALT + r'(\d+)\s*$',
    r'^\s*' + ALT + r'([０-９]+)\s*$',
    NP + r'(\d+)' + GAP + TIE + BOL,
    NP + r'([%s]+)' % CNCH + GAP + TIE + BOL,
    NP + r'([０-９]+)' + GAP + TIE + BOL,
    r'^\s*' + ALT + r'(\d+)' + BOL,
]
APPENDIX = re.compile(r'^##+\s*(?:附則|附錄|附录|补则|補則|Supplement\w*)\s*$', re.M)
CHAPTER = re.compile(r'^#+\s*第([%s]+)章' % CNCH)

# 已知的源站笔误：维基文库原文就是这么标的，我们如实照录，不自行订正法律文本。
# 每条都直接读过源站 wikitext 确认过——不是抓取或转换的问题。正文不缺字，
# 只是条号标错了位置，因此不算缺陷，记在这里以便 check-offline.sh 不被它卡住。
# 详见 cn/todo.md。
KNOWN_SOURCE_TYPOS = {
    'mo/texts/main/01-1996-07-29-澳门组织章程.md':
        '源站把附则第一条标成「第四十條」，故第 40 条重复、第 41 条无标题',
    'kp/texts/1998宪法/01-1998-09-05-1998宪法.md':
        '源站第 103 条标了两次、第 143 条漏标',
}


def cn2int(s):
    """中文数字 -> int。两种写法都要认：

      * 定位式  一〇一 / 二〇一二 / 一〇〇        逐位数码，用〇占零
      * 计数式  十 / 十一 / 二十 / 三十八 / 一百零一 / 一百三十八
    旧实现只按计数式解析，把韩国 1948 年宪法的「第一〇一條」算成了 1，
    凭空多出「1、2、3 重号」和「21—39 缺号」；反过来把「十」判成非法。
    """
    s = s.strip()
    if not s:
        return None
    if s.isdigit():
        return int(s)
    if all(ch in DIGIT for ch in s):                      # 定位式
        return int(''.join(str(DIGIT[ch]) for ch in s))
    total = section = number = 0
    for ch in s:
        if ch in DIGIT:
            number = DIGIT[ch]
        elif ch in UNIT:
            section += (number if number else 1) * UNIT[ch]
            number = 0
        else:
            return None
    return total + section + number


def num(g):
    g = g.replace('　', '').replace(' ', '').replace('\t', '')
    if g.isdigit():
        return int(g)
    if '０' <= g[0] <= '９':
        return int(g.translate(FW))
    return cn2int(g)


def heads_of(text):
    """取条首编号。

    **逐行**匹配，命中即止：同一份文本会混用写法（kp 2012 里既有 `**第十九条**`
    又有 `**第十九条　**`），若把所有写法的结果直接并集，同一行会被数两遍，
    凭空多出 20 个「条号重复」。
    """
    out = []
    for line in text.split('\n'):
        for pat in HEAD_PATS:
            m = re.match(pat, line)
            if m:
                v = num(m.group(1))
                if v:
                    out.append(v)
                break
    return out


def check_range(seq, where):
    """返回 (缺号, 重号) 两个列表。"""
    s = set(seq)
    miss = [n for n in range(min(s), max(s) + 1) if n not in s]
    dup = sorted(n for n, k in collections.Counter(seq).items() if k > 1)
    if miss:
        where.append('缺 %d 条：%s' % (len(miss),
                    '、'.join(map(str, miss[:12])) + ('…' if len(miss) > 12 else '')))
    if dup:
        where.append('%d 个条号重复：%s' % (len(dup),
                    '、'.join(map(str, dup[:12])) + ('…' if len(dup) > 12 else '')))
    return miss, dup


def report(path, body):
    issues, notes = [], []
    heads = heads_of(body)
    if not heads:
        # 有些文书本来就没有条文编号：香港《英皇制诰》《皇室训令》是英文敕令，
        # 皇室训令用罗马数字 I./II./III. 编号；这类不算缺陷，但要说明白。
        if re.search(r'^\s*(?:[IVX]+\.|\([ivx]+\))\s', body, re.M):
            notes.append('该文本无「第N条」式编号（英文敕令，用罗马数字分款）')
        else:
            issues.append('未能识别条首写法，且文中也未见任何条文编号——需人工确认')
        return issues, notes

    # 附则从第一条重编，切掉后再判
    main = APPENDIX.split(body, maxsplit=1)[0]
    if len(main) < len(body) * 0.3:
        main = body
    mh = heads_of(main)
    if mh:
        heads = mh

    # 同一文件可能并列收录多个版本（明治宪法收了原文/JIS 版/新字体版/新字新仮名版四份，
    # 曹锟宪法并列两版），此时条号必然整体重复，只能逐版本检查。
    secs = [s for s in re.split(r'^##\s+.+$', body, flags=re.M) if s.strip()]
    with_articles = [s for s in secs if heads_of(s)]

    if len(with_articles) >= 2:
        inner = []
        for sec in with_articles:
            check_range(heads_of(sec), inner)
        if inner:
            issues.extend('某版本：%s' % x for x in inner)
        else:
            notes.append('并列收录 %d 个版本，各版本内部条号连续' % len(with_articles))
    else:
        if min(heads) != 1:
            notes.append('条号从第 %d 条开始（非 1）' % min(heads))
        check_range(heads, issues)

    ch = [cn2int(m.group(1)) for m in CHAPTER.finditer(body)]
    ch = [c for c in ch if c]
    if len(ch) >= 2:
        cm = [n for n in range(1, max(ch) + 1) if n not in set(ch)]
        if cm:
            issues.append('章号缺：%s' % '、'.join(map(str, cm)))
    return issues, notes


def main():
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
    from textframe import split as tf_split   # 取正文，排除框架与目录

    root = pathlib.Path(__file__).resolve().parent.parent
    total = bad = 0
    for reg in REGIONS:
        for path in sorted((root / reg / 'texts').rglob('*.md')):
            total += 1
            body = tf_split(path.read_text(encoding='utf-8'))['body']
            issues, notes = report(path, body)
            rel = str(path.relative_to(root))
            known = KNOWN_SOURCE_TYPOS.get(rel)
            if issues and known:
                # 报出来但不计为失败：源站本身如此，改动法律文本不是本工具该做的事
                print('%s' % rel)
                for i in issues:
                    print('    - %s' % i)
                print('    [已知源站笔误，不计为失败] %s' % known)
            elif issues:
                bad += 1
                print('%s' % rel)
                for i in issues:
                    print('    - %s' % i)
            for n in notes:
                print('    [提示] %s：%s' % (rel, n))
    print()
    print('有编号问题的文本：%d / %d 份'
          '（另有 %d 份为已知源站笔误，见 cn/todo.md）'
          % (bad, total, len(KNOWN_SOURCE_TYPOS)))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
