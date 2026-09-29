# legalize-meta

将各法域的宪制性法律文件作为 Git 仓库管理的元项目。每个法域一个子项目目录，各自包含构建脚本（Bash + PowerShell），可在指定目标 Git 仓库中按文件的制定、公布或修订日期生成 commit 历史。

覆盖范围：两岸四地（中国大陆、台湾地区、香港特别行政区、澳门特别行政区）以及日本、韩国、朝鲜、越南。

## 子项目

| 目录 | 范围 | 现行宪制基础 | 构建 |
|---|---|---|---|
| [`cn/`](cn/README.md) | 中华人民共和国（大陆）宪法及宪法相关法 | 1982 年宪法（含五次修正案） | `bash cn/build.sh <目标仓库>` |
| [`hk/`](hk/README.md) | 香港特别行政区宪制性文件 | 《中华人民共和国香港特别行政区基本法》 | `bash hk/build.sh <目标仓库>` |
| [`tw/`](tw/README.md) | 台湾地区宪制性文件 | 1947 年《中华民国宪法》本文 + 七次增修条文 | `bash tw/build.sh <目标仓库>` |
| [`mo/`](mo/README.md) | 澳门特别行政区（回归前）宪制性文件 | 《澳门组织章程》 | `bash mo/build.sh <目标仓库>` |
| [`jp/`](jp/README.md) | 日本宪制性文件 | 1946 年《日本国宪法》（1947 施行） | `bash jp/build.sh <目标仓库>` |
| [`kr/`](kr/README.md) | 韩国宪制性文件 | 1987 年《大韩民国宪法》（第六共和国） | `bash kr/build.sh <目标仓库>` |
| [`kp/`](kp/README.md) | 朝鲜宪制性文件 | 1972 年《社会主义宪法》（含 1948 年宪法分支） | `bash kp/build.sh <目标仓库>` |
| [`vn/`](vn/README.md) | 越南宪制性文件 | 《越南社会主义共和国宪法》（2001 修订；2013 现行全文暂缺） | `bash vn/build.sh <目标仓库>` |

## 通用构建用法

```bash
# Bash（需 curl、python3、git）
bash <region>/build.sh <目标Git仓库路径>     # 例如 bash tw/build.sh /tmp/legalize-tw

# PowerShell（需 PowerShell 7+，不保证兼容 Windows PowerShell 5.1）
.\<region>\build.ps1 <目标Git仓库路径>
```

构建脚本会：
- 清空目标仓库并建立单一根提交；
- 在主分支按真实制定/修订日期建立现行宪制基础及其沿革；
- 为重大历史时期建立独立分支（如 `1947宪法`、`共同纲领`、`英皇制诰`）。

> **文本抓取**：构建时从各来源抓取文本——维基文库（zh / en / ja / ko）、香港基本法官方网站
> （[basiclaw.gov.hk](https://www.basiclaw.gov.hk/)，`hk` 的基本法正文取自此处）、以及
> `cn` 用的两个 GitHub 文本仓库。抓取结果按页面持久缓存在 `~/.cache/legalize-meta/wikisource/`，
> 重复构建直接复用，且对 `429`（限流）自动指数退避重试（最多 6 次）。
> 可用环境变量 `LEGALIZE_WIKICACHE` 改缓存目录（Bash 与 PowerShell 通用；Bash 另兼容旧名 `WIKICACHE_DIR`）；
> 如需强制刷新，删除缓存即可。
>
> 抓不到正文时脚本会**跳过该次提交并告警**，不会写出空壳文件。

## 关于日期显示

早于 1970-01-01 的文件（1912、1917、1947、1949、1954 年的宪法等）其提交日期以**负 Unix 时间戳**写入 Git 对象。
Git 无法渲染 1970 年之前的日期，这是 Git 自身的限制而非本项目的缺陷：Git 的日期解析只接受非负 epoch，
而 1970 年前的时间戳在对象里只能写成负数。其后果：

- `git log` / `git show` 的日期一律显示 `1970-01-01`；`git log --format=%ai`（或 `%ad`、`%at`）输出为空；
- `--since` / `--before` 日期过滤对这些提交无效；
- `git fsck --strict` 会报 `badDate`（无法规避：任何能写出 1970 年前日期的格式都会被判为非法日期）。

**读取真实日期**只能从 commit 对象直接取出 epoch：

```bash
git cat-file -p <commit-sha>    # committer 行末为 "<epoch> +0800"
```

一次性列出各分支的真实日期：

```bash
for b in $(git branch --format='%(refname:short)'); do
  ts=$(git cat-file -p "$b" | sed -n 's/^committer .*<[^>]*> \(-\{0,1\}[0-9]*\) [-+][0-9]*$/\1/p')
  printf '%-14s %s\n' "$b" "$(TZ=Asia/Shanghai date -d "@$ts" '+%Y-%m-%d %H:%M')"
done
```

所有子项目的提交时间均按其声明的时区落在当日 `00:00`。

## 许可

法律、法规等文本属于公有领域，不适用著作权法保护；各子项目仓库结构与构建脚本按 MIT License 使用。
