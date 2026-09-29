"""宪制文本的"框架 / 正文"拆分与重组。

入库文本的结构：

    # <标题>                <- 可有多行（一部分源文件自带副标题）
    <空行>
    > <说明行>*            <- 可为空；'>' 后可无空格
    <空行>
    - [目录项](#锚点)*      <- 可为空（正文无 '## ' 标题时就没有）
    <空行>
    <正文>
    <空行>
    ---                    <- 可无（无出处脚注时）
    <空行>
    <出处脚注>*

正文由 tools/update-sources.sh 从外部来源重新抓取转换；标题、说明行、目录、脚注属于
编辑内容，随文件保存。本模块提供拆分与重组，供更新工具与校验脚本共用。

框架的识别按内容而非固定行号：开头连续的 空行 / '#' 开头行 / '>' 开头行 属于框架，
其后（跳过空行）若紧跟连续的 '- [..](#..)' 行则 those 是目录，再往后才是正文。
这样即使空行数量、标题行数与常规不同也能正确拆分，且重组是逐字节幂等的。
"""

import re

TOC_RE = re.compile(r'^- \[.*\]\(#.*\)$')


def split(text):
    """返回 dict：head / toc / gap / body / suffix（head/gap/suffix 为行列表，body 为字符串）。"""
    lines = text.split('\n')

    # 1) 框架：开头连续的 空行 / '#' 行 / '>' 行
    i = 0
    while i < len(lines) and (lines[i] == '' or lines[i].startswith('#') or lines[i].startswith('>')):
        i += 1
    j = i
    while j < len(lines) and lines[j] == '':
        j += 1

    # 2) 目录：框架之后紧接的 '- [..](#..)' 连续行
    k = j
    while k < len(lines) and TOC_RE.match(lines[k]):
        k += 1

    if k > j:                                   # 有目录
        head = lines[:j]
        toc = lines[j:k]
        p = k
        while p < len(lines) and lines[p] == '':
            p += 1
        gap = lines[k:p]
        body_from = p
    else:                                       # 无目录
        head = lines[:j]
        toc = []
        gap = []
        body_from = j

    # 3) 脚注：正文之后第一条独立的 '---' 行（连同其前的空行一并归入 suffix）
    foot = None
    m = body_from
    while m < len(lines):
        if lines[m] == '---' and (m == 0 or lines[m - 1] == ''):
            foot = m
            break
        m += 1

    if foot is None:
        body = '\n'.join(lines[body_from:]).strip('\n')
        suffix = []
    else:
        s = foot
        while s > body_from and lines[s - 1] == '':
            s -= 1
        body = '\n'.join(lines[body_from:s]).strip('\n')
        suffix = lines[s:]

    return {'head': head, 'toc': toc, 'gap': gap, 'body': body, 'suffix': suffix}


def toc_of(body):
    """按 GitHub slug 规则由正文生成目录行。"""
    out = []
    for line in body.split('\n'):
        if not line.startswith('## '):
            continue
        h = line[3:].strip()
        if not h:
            continue
        slug = re.sub(r'\s', '-', re.sub(r'[^\w\s-]', '', h.lower()))
        out.append('- [%s](#%s)' % (h, slug))
    return out


def rebuild(parts, body):
    """用（新的）正文重组；目录按新正文重新生成，其余原样保留。"""
    out = list(parts['head'])
    out.extend(toc_of(body))
    out.extend(parts['gap'])
    if out and out[-1] != '':
        out.append('')
    out.append(body)
    out.extend(parts['suffix'])
    return '\n'.join(out).rstrip('\n') + '\n'
