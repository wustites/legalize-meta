# legalize-hk

将香港特别行政区宪制性法律文件作为 Git 仓库管理。主分支保留现行宪制基础文件；历史殖民地宪制文件通过独立分支处理，每一次重要制定或修订对应真实日期的 Git commit。

## 已完成

### 现行宪制基础

- **主分支**：[中华人民共和国香港特别行政区基本法](宪制/中华人民共和国香港特别行政区基本法.md) — 1990 年通过、1997 年实施；附件一、附件二记录 2010 与 2021 年调整，附件三记录全国性法律适用清单。

### 历史分支

- [`英皇制诰`](../英皇制诰) — 1917 年《Hong Kong Letters Patent》，殖民地时期核心宪制文件，1997 年 7 月 1 日失效。
- [`皇室训令`](../皇室训令) — 1917 年《Hong Kong Royal Instructions》，规范行政局、立法局等运作，1997 年 7 月 1 日失效。

## 项目结构

```text
宪制/
  中华人民共和国香港特别行政区基本法.md
```

## 构建

PowerShell（需要 PowerShell 7+，不保证兼容 Windows PowerShell 5.1）:

```powershell
.\hk\build.ps1 <目标Git仓库路径>
```

Bash:

```bash
bash hk/build.sh <目标Git仓库路径>
```

## 数据来源

- [香港基本法官方网站](https://www.basiclaw.gov.hk/) — 现行《香港基本法》、附件及相关决定。
- [维基文库：Basic Law of the Hong Kong Special Administrative Region](https://en.wikisource.org/wiki/Basic_Law_of_the_Hong_Kong_Special_Administrative_Region) — 英文公开文本。
- [维基文库：Hong Kong Letters Patent 1917](https://en.wikisource.org/wiki/Hong_Kong_Letters_Patent_1917) — 1917 年《英皇制诰》。
- [维基文库：Hong Kong Royal Instructions 1917](https://en.wikisource.org/wiki/Hong_Kong_Royal_Instructions_1917) — 1917 年《皇室训令》。

## 许可

法律、法规、国家机关决定等文本属于公有领域；本仓库结构与构建脚本按 MIT License 使用。
