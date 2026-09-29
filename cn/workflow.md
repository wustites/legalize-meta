# cn 扩展规划（路线图，非当前实现）

> 本文件记录**计划**，不是现状。当前实现只覆盖 `宪法/`：主分支为 1982 年宪法及五次修正案，
> 历史分支为 `共同纲领`（1949）、`54宪法`、`75宪法`、`78宪法`。已实现部分见 [`README.md`](README.md) 与 [`law.md`](law.md)。

## 1. 目标结构

```
宪法/                       — 宪法及宪法相关法
constitution-related/        — 宪法相关法（选举法、全国人大组织法等）
civil-commercial/            — 民法商法
criminal/                    — 刑法
administrative/              — 行政法
economic/                    — 经济法
social/                      — 社会法
procedural/                  — 诉讼与非诉讼程序法
scripts/                     — 校验、索引、统计
docs/                        — 贡献指南、数据来源
```

每部法律一个 Markdown 文件，文件头统一 YAML 元数据（`title`、`enacted`、`last_amended`、
`repealed`、`status`、`department`、`source`）。已废止或被取代的版本放各部门的 `historical/`，
或在需要突出历史时期时另开分支。

## 2. 分支策略

现行文本放主分支；制宪／修宪等重大节点另开分支：

- `共同纲领`（1949）— 已实现
- `54宪法`（1954）— 已实现
- `75宪法`（1975）— 已实现
- `78宪法`（1978，含 1979/1980 修正）— 已实现
- `1982宪法`（1982 年原始通过文本，与主分支的整合文本相对）— 待实现
- `civil-reform-2020`（民法典施行、旧民事单行法废止）— 待实现

```bash
git checkout 78宪法          # 切到 1978 年视角
git diff 78宪法..main        # 对比不同宪法版本
```

## 3. 里程碑标签

建议用语义化 tag 标记重大节点，便于检出特定时期快照：

```
v1949-common-program   v1954-constitution   v1975-constitution
v1978-constitution     v1982-constitution   v2020-civil-code
```

```bash
git tag -a v1954-constitution -m "中华人民共和国1954年宪法通过"
```

## 4. 提交信息

沿用 Conventional Commits，并体现法律语义：

- `feat(civil-commercial): 新增民法典`
- `amend(constitution): 2018 年宪法修正案 — 国家监察委员会`
- `repeal(civil-commercial): 婚姻法已被民法典（2021-01-01 施行）取代`
- `docs: 更新法律数量与来源说明`

法律修订建议用 `amend`（而非通用 `fix`），废止用 `repeal`，以便生成"法律演变 Changelog"。

## 5. 数据来源优先级

1. 国家法律法规数据库 <https://flk.npc.gov.cn>
2. 全国人大官网 <https://www.npc.gov.cn>
3. 香港／澳门基本法官方网站（<https://www.basiclaw.gov.hk>、<https://bo.dsaj.gov.mo>）
4. 维基文库（历史文本与官方未上网者）
5. 学术机构整理本（仅作校勘参考，需注明版本）

## 6. 已知待办

- [ ] 1954 年宪法改用维基文库全文（`中華人民共和國憲法 (1954年)`），摆脱对 `risshun/Chinese_Laws` 的依赖
- [x] 78宪法 分支的目录重复与节级死链已清理
