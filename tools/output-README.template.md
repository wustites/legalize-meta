# legalize-{{REGION}}

{{REGION_NAME}}宪制性法律文件的历史仓库。本仓库由 **legalize-meta** 元项目生成，包含 {{TEXT_COUNT}} 份文本、{{COMMIT_COUNT}} 次立法事件提交。

> 这是构建产物，请不要直接修改。文本、日期与提交信息都在 `legalize-meta/{{REGION}}/texts/` 中维护。

## 阅读历史

```bash
git log --oneline --decorate --all     # 分支与日期标签一览
git tag -l | sort                      # 按时间排序的日期标签
git branch -a                          # 现行文本与历史分支
git show <日期标签>                    # 查看某一次立法事件
git diff <分支A>..<分支B>              # 比较不同时期
```

- `main` 保存该法域当前的宪制基础；历史文本在独立分支上。
- 每次提交都带一个以真实日期命名的轻量标签：主分支用 `<日期>`，历史分支用 `<日期>-<分支名>`。
- **1970-01-01 之前**的提交在 Git 对象里存为 `unix 0`（`1970-01-01 00:00:00 +0000`），因为 Git 无法表示更早的日期；真实日期请看标签。1970 年及以后的提交时间落在该日当地 0 点，`%ai` 与标签名一致。
- 按年代筛选请用标签，例如：

  ```bash
  git log --oneline --no-walk $(git tag -l '19[0-4]*' | sed 's|^|refs/tags/|')
  ```

## 文件

```bash
git ls-tree -r --name-only main
```

各历史分支的文件布局可在切换分支后用同一条命令查看。文本均为 Markdown，标题、说明、目录与正文结构见各文件头部。

## 来源与许可

- 每份文本末尾的「资料来源」给出抓取来源；完整登记见元项目的 `tools/sources.tsv`。
- 官方法律文本属于公有领域；译本与第三方整理文本按其来源页的许可使用。详见本仓库的 [`NOTICE.md`](NOTICE.md)。
- 本仓库的目录结构与构建脚本按 MIT License 使用，见 [`LICENSE`](LICENSE)。

## 构建

本仓库是生成产物，不包含构建脚本。如需重建，请在 `legalize-meta` 元项目的根目录运行：

```bash
bash {{REGION}}/build.sh <本仓库路径> --force
```

构建只读元项目中已入库的文本，不访问网络；会先在与本仓库同级的临时目录完成，成功后才替换本仓库。
