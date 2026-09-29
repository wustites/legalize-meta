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

> 构建只读本目录的 `texts/`（法律文本已入库），**不访问网络**。

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
> 其后果是：`git log` / `git show` 的日期一律显示 `1970-01-01`；`--format=%ai`（或 `%ad`、`%at`）为空；
> `--since` / `--before` 不能按真实日期筛选（结果的方向甚至可能是反的）；`git fsck --strict` 报
> `badDate`（无法规避）。**按年代筛选请用日期标签。**
>
> **为此，每次提交都带一个以真实日期命名的轻量标签**：`git log --decorate` 会直接在提交旁
> 显示日期，`git tag` 排序后即是一份编年表：
>
> ```bash
> git log --oneline --decorate            # 例：0b0db07 (tag: 1947-05-03) 1947年5月3日施行…
> git tag -l | sort                      # 例：1889-02-11-明治宪法 / 1947-05-03
> ```
>
> 标签命名：主分支用裸日期（`1947-12-25`），历史分支加分支名后缀（`1917-02-14-英皇制诰`）。
> 按年代筛选也用标签：`git log --oneline --no-walk $(git tag -l '19[0-4]*' | sed 's|^|refs/tags/|')`。
> 需要精确到秒的原始时间戳与时区时，再从对象读取：`git cat-file -p <commit-sha>`。
>
> 法律文本已随本仓库保存在 `texts/` 下，构建脚本只读本地文本、不联网；重新抓取是维护者操作，见 [`tools/update-sources.sh`](../tools/update-sources.sh)。

## 数据来源

> 以下来源的文本已固化入库于 `texts/`，构建时不再联网抓取；来源登记见 [`tools/sources.tsv`](../tools/sources.tsv)。

- [维基文库（英）：Constitution of Vietnam](https://en.wikisource.org/wiki/Constitution_of_Vietnam) — 越南历部宪法及版本索引。
- [维基文库（英）：Constitution of Vietnam (2001)](https://en.wikisource.org/wiki/Constitution_of_Vietnam_(2001)) — 主分支正文（2001 年整合文本，完整）。
- [维基文库（英）：Constitution of Vietnam (1992)](https://en.wikisource.org/wiki/Constitution_of_Vietnam_(1992)) — `1992宪法` 分支正文。

## 许可

法律文本属于公有领域，不适用著作权法保护；本仓库结构与构建脚本按 MIT License 使用。
