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
# Bash（需 git、date、python3；不联网）
bash <region>/build.sh <目标Git仓库路径>     # 例如 bash tw/build.sh /tmp/legalize-tw

# PowerShell（需 PowerShell 7+，不保证兼容 Windows PowerShell 5.1；不联网）
.\<region>\build.ps1 <目标Git仓库路径>
```

构建脚本会：
- 清空目标仓库并建立单一根提交；
- 读 `<region>/texts/manifest.tsv`，把法律文本写入目标仓库；
- 在主分支按真实制定/修订日期建立现行宪制基础及其沿革；
- 为重大历史时期建立独立分支（如 `1947宪法`、`共同纲领`、`英皇制诰`）。

文本缺失或为空时脚本**立即报错退出**，不会产出残缺仓库。

## 文本入库，构建离线

**法律文本全部随本仓库保存在 `<region>/texts/` 下**（59 个文件，约 2.3 MB），
构建脚本只读本地文本，**不访问网络**。构建结果因此不再受外部站点改版、限流或下架影响，
每份文本的来源也可逐条审计。

`texts/` 下每个文件是一份法律文本的最终形态：

```
# 标题
（空行）
> 说明行（版本、通过/修正日期等）
（空行）
- [目录](#锚点)          由正文的 '## ' 标题自动生成
（空行）
正文
（空行）
---                     有出处脚注时才有
资料来源：……
```

`texts/manifest.tsv` 逐行描述一次提交：

| 列 | 含义 |
|---|---|
| `branch` | 目标分支名 |
| `seq` | 该分支内第几次提交；相同 `(branch, seq)` 的多行属于同一次提交的不同文件 |
| `file` | `texts/` 下的相对路径 |
| `date` | 提交日期，按 `tz` 落在当日 `00:00` |
| `tz` | 提交声明的时区 |
| `outpath` | 写入目标仓库的相对路径 |
| `message` | 提交信息 |

初始提交的日期取第一行的 `date`。同一分支的连续行依次接续；分支名改变则从初始提交重新开枝
（所以同一分支的各行须集中出现）。

### 维护者工具

| 脚本 | 用途 | 联网 |
|---|---|---|
| `tools/check-offline.sh` | 断言构建脚本无任何取网络命令/URL，清单格式正确，文本齐备 | 否 |
| `tools/verify-corpus.py` | 校验 59 份文本可无损拆分重组、目录与正文一致、正文非空 | 否 |
| `tools/update-sources.sh` | 从外部来源重新抓取正文并写回 `texts/`；`--check` 只比对不写回 | **是** |

`tools/sources.tsv` 登记每份文本的来源（维基文库 zh/en/ja、香港基本法官方网站、两个
GitHub 文本仓库）。`update-sources.sh` 只重抓**正文**；标题、说明、出处属于编辑内容不动，
目录按新正文重算。抓取结果缓存在 `~/.cache/legalize-meta/wikisource/`，
可用 `LEGALIZE_WIKICACHE` 改目录，对 `429` 做指数退避重试。

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
