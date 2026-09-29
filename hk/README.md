# legalize-hk

将香港特别行政区宪制性法律文件作为 Git 仓库管理。主分支保留现行宪制基础文件；历史殖民地宪制文件通过独立分支处理，每一次重要制定或修订对应一次 commit（日期见下文「关于早于 1970-01-01 的日期」）。

## 已完成

### 现行宪制基础

- **主分支**：[中华人民共和国香港特别行政区基本法](宪制/中华人民共和国香港特别行政区基本法.md) — 1990 年 4 月 4 日通过、1997 年 7 月 1 日实施；三次提交分别对应 1990 年通过、2010 年附件一/二修正、2021 年附件一/二修订。含序言、九章一百六十条与三个附件的完整正文。

### 历史分支

- [`英皇制诰`](../英皇制诰) — 1917 年《Hong Kong Letters Patent》，殖民地时期核心宪制文件，1917 年 4 月 20 日生效，1997 年 7 月 1 日失效。
- [`皇室训令`](../皇室训令) — 1917 年《Hong Kong Royal Instructions》，规范行政局、立法局等运作，1917 年 4 月 20 日生效，1997 年 7 月 1 日失效。

## 项目结构

```text
宪制/
  中华人民共和国香港特别行政区基本法.md
```

## 构建

> 构建只读本目录的 `texts/`（法律文本已入库），**不访问网络**。

PowerShell（需要 PowerShell 7+，不保证兼容 Windows PowerShell 5.1）:

```powershell
.\hk\build.ps1 <目标Git仓库路径>
```

Bash:

```bash
bash hk/build.sh <目标Git仓库路径>
```

> **关于早于 1970-01-01 的日期**：Git 无法表示 1970 年之前的提交日期——这是 Git 自身的限制，
> 不是本项目的缺陷。这类提交的时间戳**统一写为 `unix 0`**（`1970-01-01 00:00:00 +0000`）：
> 若强行写入负 epoch，`git log` 会一律渲染成 `1970-01-01`，`--format=%ai`（或 `%ad`、`%at`）为空，
> `--since` / `--before` 的结果方向甚至可能是反的，`git fsck --strict` 会报 `badDate`，
> 而 GitHub 与部分客户端会直接显示出错（溢出）的时间。统一为 `unix 0` 后这些现象全部消失，
> 代价只是提交对象里不再保留 1970 年前的真实日期——**真实日期由日期标签承载**。
>
> **因此，每次提交都带一个以真实日期命名的轻量标签**：`git log --decorate` 会在提交旁直接
> 显示日期，`git tag` 排序后即是一份编年表，GitHub 上每个提交旁同样会显示：
>
> ```bash
> git log --oneline --decorate            # 例：af4042f (tag: 1947-05-03) 1947年5月3日施行…
> git tag -l | sort                      # 例：1889-02-11-明治宪法 / 1947-05-03
> ```
>
> 标签命名：主分支用裸日期（`1947-12-25`），历史分支加分支名后缀（`1917-02-14-英皇制诰`）。
> 按年代筛选用标签：`git log --oneline --no-walk $(git tag -l '19[0-4]*' | sed 's|^|refs/tags/|')`。
> 提交对象里的时间戳可另行读取：`git cat-file -p <commit-sha>`，其中 `epoch` 为 `0`
> 即表示该日期早于 1970（1970 年及以后的提交按其声明时区落在当日 `00:00`）。
>
> 法律文本已随本仓库保存在 `texts/` 下，构建脚本只读本地文本、不联网；重新抓取是维护者操作，见 [`tools/update-sources.sh`](../tools/update-sources.sh)。
>
> 香港殖民地的历史文本在 `texts/manifest.tsv` 中声明为 `+0000` 时区（英国文书惯例），
> 与 `+0800` 的法律文件分开计。这两份文件都在 1970 年之前，故提交时间戳同样是 `0`；
> `+0000` 声明仍予保留，作为该批文书时区惯例的记录。

## 数据来源

> 以下来源的文本已固化入库于 `texts/`，构建时不再联网抓取；来源登记见 [`tools/sources.tsv`](../tools/sources.tsv)。

- [香港基本法官方网站（繁体中文全文）](https://www.basiclaw.gov.hk/tc/basiclaw/index.html) — **主分支正文来源**：序言、九章、附件一/二/三的完整官方文本。官方另有 [English 版](https://www.basiclaw.gov.hk/en/basiclaw/index.html) 与 [PDF 全文](https://www.basiclaw.gov.hk/filemanager/content/tc/files/basiclawtext/basiclaw_full_text.pdf)。
- [香港基本法官方网站：历次决定与相关文件](https://www.basiclaw.gov.hk/tc/basiclaw/annex-instrument.html) — 2010、2021 年两次附件修订的全国人大常委会决定原文。
- [维基文库：Hong Kong Letters Patent 1917](https://en.wikisource.org/wiki/Hong_Kong_Letters_Patent_1917) — 1917 年《英皇制诰》。正文取自该页的 `Page:` 校订文本（源文件为 1917 年 4 月 20 日《香港政府宪报》扫描件，校对等级 3 级）。
- [维基文库：Hong Kong Royal Instructions 1917](https://en.wikisource.org/wiki/Hong_Kong_Royal_Instructions_1917) — 1917 年《皇室训令》，同源扫描件。

> 注：en.wikisource 上《香港基本法》与《英皇制诰》《皇室训令》的条目页本身只是 `<pages>` 扫描索引，
> 不含正文；因此本项目的基本法正文改取自官方站点，两份殖民地文件改取 `Page:` 校订文本。
> 香港殖民地的历史文本在 `texts/manifest.tsv` 中声明为 `+0000` 时区（英国文书惯例），
> 与 `+0800` 的法律文件分开计。这两份文件都在 1970 年之前，故提交时间戳同样是 `0`；
> `+0000` 声明仍予保留，作为该批文书时区惯例的记录。

## 许可

法律、法规、国家机关决定等文本属于公有领域；本仓库结构与构建脚本按 MIT License 使用。
