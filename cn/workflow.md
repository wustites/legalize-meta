**legalize-cn 项目总结**（仿照 legalize-es 风格，2026年最新版）

项目目标：将**中华人民共和国法律法规**作为 Git 仓库管理。每部法律一个 Markdown 文件，每一次修订/废止/取代对应一个真实的 Git commit。主分支只保留**现行有效法律**（截至2026年3月共 **310 件**），历史文件通过分支或 historical 目录处理，不按地域划分，严格按**七大法律部门**组织。

### 1. 项目整体结构（推荐最终版）

```
legalize-cn/
├── README.md                          # 项目介绍、使用方法、法律数量说明、分支指南
├── LICENSE                            # MIT（结构与工具）；法律文本为公有领域
├── constitution.md                    # 现行1982年宪法（含五次修正案的整合 consolidated 文本）
├── constitution-related/              # 宪法相关法（约56件）
│   ├── historical/                    # 已废止或历史版本（如早期组织法等）
│   └── *.md                           # 现行文件（如选举法、全国人大组织法等）
├── civil-commercial/                  # 民法商法（民法典为核心 + 商事法律）
│   ├── historical/                    # 旧单行法（如婚姻法-1950、合同法等，已被民法典取代）
│   └── *.md
├── criminal/                          # 刑法（刑法.md + 修正案历史通过 commit 记录）
│   ├── historical/                    # 1979年刑法等
│   └── *.md
├── administrative/                    # 行政法
├── economic/                          # 经济法
├── social/                            # 社会法
├── procedural/                        # 诉讼与非诉讼程序法
├── scripts/                           # 辅助工具（可选）：校验 YAML、生成索引、统计法律数量、转换工具
├── docs/                              # 贡献指南、数据来源、法律清理记录
├── .github/                           # workflows（可选：CI 检查 Markdown 格式、链接有效性）
├── .gitignore
└── historical-branches/               # 可选：说明文档，实际历史用分支实现
```

**关键原则**：
- **不按地域划分**：所有文件均为全国人大及其常委会制定的全国性法律。
- **每个法律 = 一个 Markdown 文件**：文件名推荐使用中文（如 `民法典.md`、`行政处罚法.md`、`宪法-1954.md`）。
- **YAML Frontmatter**：每个文件开头统一元数据（title、enacted、last_amended、repealed、status、department、source 等）。
- **现行法律数量**：主分支 ≈ 310 个 Markdown 文件（宪法1件 + 其余309件左右）。
- **历史文件**：置于各部门 `historical/` 子目录，或通过专用 Git 分支隔离。

### 2. Git 分支策略（处理历史，尤其是共同纲领与四部宪法）

- **main**（默认分支）：仅现行有效法律（1982年宪法整合版 + 310件现行法律）。
- **历史专用分支**（每个重大宪法/法律时期一个分支，体现“每一次变革一个分支”）：
  - `common-program-1949` → 共同纲领 + 前三十年重要法令
  - `constitution-1954` → 1954年宪法 + 当时配套单行法律
  - `constitution-1975` → 1975年宪法
  - `constitution-1978` → 1978年宪法（含1979/1980修改）
  - `constitution-1982-original` → 1982年宪法原始通过文本
  - 其他可选：`civil-reform-2020`（民法典编纂后废止旧民事法律的分支）

**使用方法**（写入 README）：
```bash
git checkout constitution-1954   # 切换到1954年宪法视角
git diff constitution-1978..main # 对比不同宪法版本
```

**结合方式**：历史分支中可包含当时完整的部门结构；主分支保留 `historical/` 作为只读归档。

### 3. Commit Message 规范（推荐 Conventional Commits + 法律语义）

采用 **Conventional Commits** 规范，便于自动化生成 Changelog、版本管理，并体现法律特性：

**格式**：
```
<type>(<scope>): <description>

[optional body]

[optional footer]
```

**常用类型（法律项目适配）**：
- `feat`：新增一部法律或重大新增内容（如 `feat(civil-commercial): 添加民法典`）
- `fix`：修正法律文本中的错误、格式问题
- `docs`：更新注释、YAML 元数据、README（如 `docs(historical): 更新1954年宪法背景说明`）
- `reform` / `amend`：法律修订（推荐自定义，体现法律特色）→ `reform(constitution): 2018年宪法修正案 - 增加监察委员会`
- `archive` / `repeal`：归档或废止法律 → `archive(civil-commercial): 婚姻法已于2020年被民法典取代`
- `chore`：维护性工作（脚本更新、.gitignore 等）
- `historical`：添加前三十年或历史文件

**Scope**（可选）：使用部门缩写，如 `(constitution)`、`(civil)`、`(criminal)`、`(admin)` 等。

**示例**：
- `reform(constitution): 2018年宪法修正案 - 国家监察委员会相关内容`
- `feat(procedural): 新增民事诉讼法最新修正`
- `archive(historical): 移动1979年刑法至 criminal/historical/`
- `docs: 更新 README 中的现行法律数量至310件（2026年3月）`

**好处**：`git log --oneline` 一目了然；便于生成法律演变 Changelog；与 legalize-es “every reform a commit” 理念高度一致。

### 4. Git Tag 里程碑（推荐）

使用 **语义化 Tag** 标记重要历史节点，便于用户快速检出特定时期快照：

- `v1949-common-program` → 共同纲领时期
- `v1954-constitution` → 1954年宪法通过
- `v1975-constitution`
- `v1978-constitution`
- `v1982-constitution` → 1982年宪法原始版
- `v2020-civil-code` → 民法典施行（旧民事法律大规模废止里程碑）
- `v2026-03-310-laws` → 现行310件法律快照（2026年3月更新）

**创建示例**：
```bash
git tag -a v1954-constitution -m "中华人民共和国1954年宪法通过"
git push origin v1954-constitution
```

**README 中说明**：
> 使用 `git tag` 查看里程碑：
> `git tag -l "v19*"` 查看前三十年相关标签。

### 5. 其他实用建议
- **数据来源**：优先全国人大官网（npc.gov.cn）、国家法律法规数据库；历史文本参考可靠档案或维基文库。
- **README 核心章节**：项目理念、法律数量（现行310件）、分支与历史处理、Commit 规范、贡献指南。
- **扩展方向**：未来可增加行政法规、司法解释（仍按部门归类），或开发脚本自动统计 Markdown 文件数量与官方目录对比。

这个结构干净、专业、研究友好，完全忠实于中国特色社会主义法律体系（以宪法为统帅、七大部门），同时完美继承 legalize-es 的 Git 哲学。

如果你需要：
- 完整的 README.md 模板（中英双语）
- 某个具体文件的 Markdown + YAML 示例
- Git 初始化命令序列
- 或进一步调整（如增加更多自定义 commit 类型）

随时告诉我，我可以立即生成！🚀  
现在 legalize-cn 项目已经具备清晰、可维护、可扩展的完整框架了。