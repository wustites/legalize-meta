# legalize-vn

将越南宪制性法律文件作为 Git 仓库管理。主分支保留现行《越南社会主义共和国宪法》（1992；2013 年现行宪法全文在维基文库暂缺）；重要历史宪法作为独立分支，每一次重要制定或修订对应真实日期的 Git commit。

> 越南 1976 年统一前分为北部（越南民主共和国）与南部（越南共和国）。现行宪制基础为 2013 年宪法。本仓库采用维基文库英文版文本（zh.wikisource 无越南宪法全文）。

## 已完成

### 现行宪制基础

- **主分支**：[越南社会主义共和国宪法](宪法/越南社会主义共和国宪法.md) — 1992 年 4 月 15 日第八届国会第十一次会议通过，2001 年 12 月 25 日第 51/2001/QH10 号决议修订（主分支即 2001 年整合文本）。2013 年现行宪法全文在维基文库缺页，见 [`law.md`](law.md)。

### 历史分支

- [`1946宪法`](../1946宪法) — 1946 年 11 月 9 日通过（越南民主共和国首部宪法）。
- [`1959宪法`](../1959宪法) — 1959 年 12 月 31 日通过（越南民主共和国宪法）。
- [`1980宪法`](../1980宪法) — 1980 年 12 月 18 日通过（统一后首部宪法）。
- [`1992宪法`](../1992宪法) — 1992 年 4 月 15 日通过（越南社会主义共和国宪法）。

## 项目结构

```text
宪法/
  越南社会主义共和国宪法.md
```

## 构建

PowerShell（需要 PowerShell 7+，不保证兼容 Windows PowerShell 5.1）:

```powershell
.\vn\build.ps1 <目标Git仓库路径>
```

Bash:

```bash
bash vn/build.sh <目标Git仓库路径>
```

> **关于早于 1970-01-01 的日期**：Git 无法渲染 1970 年之前的提交日期——这是 Git 自身的限制，
> 不是本项目的缺陷。1970 年前的时间戳在 commit 对象里只能写成负 epoch，而 Git 的日期解析只接受非负值。
> 其后果是：
>
> - `git log` / `git show` 的日期一律显示 `1970-01-01`；`git log --format=%ai`（或 `%ad`、`%at`）输出为空；
> - `--since` / `--before` 日期过滤对这些提交无效；
> - `git fsck --strict` 会报 `badDate`（无法规避：任何能写出 1970 年前日期的格式都会被判为非法日期）。
>
> 真实日期需从 commit 对象直接读取：
>
> ```bash
> git cat-file -p <commit-sha>   # committer 行末为 "<epoch> +0800"，epoch 为负数即 1970 年前
> ```
>
> 维基文库抓取结果持久缓存在 `~/.cache/legalize-meta/wikisource/`。

## 数据来源

- [维基文库（英）：Constitution of Vietnam](https://en.wikisource.org/wiki/Constitution_of_Vietnam) — 越南历部宪法及版本索引。
- [维基文库（英）：Constitution of Vietnam (2001)](https://en.wikisource.org/wiki/Constitution_of_Vietnam_(2001)) — 主分支正文（2001 年整合文本，完整）。
- [维基文库（英）：Constitution of Vietnam (1992)](https://en.wikisource.org/wiki/Constitution_of_Vietnam_(1992)) — `1992宪法` 分支正文。

## 许可

法律文本属于公有领域，不适用著作权法保护；本仓库结构与构建脚本按 MIT License 使用。
