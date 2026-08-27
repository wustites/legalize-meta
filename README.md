# legalize-meta

将两岸四地（中国大陆、台湾地区、香港特别行政区、澳门特别行政区）的宪制性法律文件作为 Git 仓库管理的元项目。每个地区一个子项目目录，各自包含构建脚本（Bash + PowerShell），可在指定目标 Git 仓库中按文件的制定、公布或修订日期生成真实日期的 commit 历史。

## 子项目

| 目录 | 范围 | 现行宪制基础 | 构建 |
|---|---|---|---|
| [`cn/`](cn/README.md) | 中华人民共和国（大陆）宪法及宪法相关法 | 1982 年宪法（含五次修正案） | `bash cn/build.sh <目标仓库>` |
| [`hk/`](hk/README.md) | 香港特别行政区宪制性文件 | 《中华人民共和国香港特别行政区基本法》 | `bash hk/build.sh <目标仓库>` |
| [`tw/`](tw/README.md) | 台湾地区宪制性文件 | 1947 年《中华民国宪法》本文 + 七次增修条文 | `bash tw/build.sh <目标仓库>` |
| [`mo/`](mo/README.md) | 澳门特别行政区（回归前）宪制性文件 | 《澳门组织章程》 | `bash mo/build.sh <目标仓库>` |
| [`jp/`](jp/README.md) | 日本宪制性文件 | 1946 年《日本国宪法》（1947 施行） | `bash jp/build.sh <目标仓库>` |
| [`kr/`](kr/README.md) | 韩国宪制性文件 | 1987 年《大韩民国宪法》（第六共和国） | `bash kr/build.sh <目标仓库>` |
| [`kp/`](kp/README.md) | 朝鲜宪制性文件 | 1972 年《社会主义宪法》（1992—2023 修订） | `bash kp/build.sh <目标仓库>` |
| [`vn/`](vn/README.md) | 越南宪制性文件 | 《越南社会主义共和国宪法》（1992；2013 现行全文暂缺） | `bash vn/build.sh <目标仓库>` |

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

> **维基文库抓取**：构建时从维基文库抓取文本。抓取结果按页面持久缓存在 `~/.cache/legalize-meta/wikisource/`，重复构建直接复用，且对 `429`（限流）自动指数退避重试（最多 6 次）。可用环境变量 `LEGALIZE_WIKICACHE` 改缓存目录；如需强制刷新，删除缓存即可。

## 关于日期显示

早于 1970-01-01 的提交日期（如 1917、1949、1954 年的文件）以负 Unix 时间戳写入 Git 对象，本地 `git log` / `git show` / `git cat-file -p` 可正确显示；GitHub 网页端无法渲染负时间戳的提交日期，会显示异常或回落到 1970。查看真实提交日期请用 `git log` 或 `git show`。

## 许可

法律、法规等文本属于公有领域，不适用著作权法保护；各子项目仓库结构与构建脚本按 MIT License 使用。
