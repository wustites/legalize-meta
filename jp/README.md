# legalize-jp

将日本宪制性法律文件作为 Git 仓库管理。主分支保留现行《日本国宪法》；历史文件（明治宪法）通过文档记录，每一次重要制定或修订对应真实日期的 Git commit。

> 日本现行宪制基础为 1946 年《日本国宪法》（1947 年 5 月 3 日施行）；此前为 1889 年《大日本帝国宪法》（明治宪法）。本仓库从"宪制史"角度整理文献。

## 已完成

### 现行宪制基础

- **主分支**：[日本国宪法](宪法/日本国宪法.md) — 1946 年 11 月 3 日公布、1947 年 5 月 3 日施行；现为日本国最高法。

### 历史分支

- [`明治宪法`](../明治宪法) — 1889 年 2 月 11 日公布、1890 年 11 月 29 日施行，1947 年《日本国宪法》施行后失效。全文取自 ja.wikisource（独立语言版本）。

## 项目结构

```text
宪法/
  日本国宪法.md
```

## 构建

PowerShell（需要 PowerShell 7+，不保证兼容 Windows PowerShell 5.1）:

```powershell
.\jp\build.ps1 <目标Git仓库路径>
```

Bash:

```bash
bash jp/build.sh <目标Git仓库路径>
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

- [维基文库：日本國憲法](https://zh.wikisource.org/wiki/日本國憲法) — 现行《日本国宪法》（主分支）。
- [维基文库：大日本帝國憲法](https://ja.wikisource.org/wiki/大日本帝國憲法) — 明治宪法（`明治宪法` 分支；ja.wikisource 为独立语言版本，含 JIS X 0208 版全文）。

## 许可

法律文本属于公有领域，不适用著作权法保护；本仓库结构与构建脚本按 MIT License 使用。
