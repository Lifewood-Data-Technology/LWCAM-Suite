# 贡献指南

[English](CONTRIBUTING.md) | 简体中文

本指南说明如何修改 LWCam 并让改动被合并。环境搭建请读 `docs/DEV-SETUP.md`，测试请读 `docs/TESTING.md`，设计规则和陷阱请读 `AGENTS.md`。

## 分支

| 分支 | 用途 |
| --- | --- |
| `lwcam-module`（默认） | 模块版：五个安装程序。新工作都放在这里。 |
| `lwcam-all-in-one` | 一体版：一个较早的安装程序。为现有站点保留。 |
| `feat/<short-name>` | 新功能，从 `lwcam-module` 切出。 |
| `fix/<short-name>` | 缺陷修复，从 `lwcam-module` 切出。 |

`archive/*` 分支是只读的历史记录，不要向它们推送。

按常规方式克隆仓库即可，不需要使用 git worktree。

```bash
git clone https://github.com/djchoy-LW/LWCAM-Suite.git
cd LWCAM-Suite
git switch -c fix/short-name
```

## 拉取请求流程

GitHub 套餐是 Free，所以 GitHub 不会强制代码评审，也不会运行 CI。团队靠人工遵守这些规则：

1. 凡是比小修小补更大的改动，先开一个 issue。使用对应模块的标签（见“Issues 与标签”）。
2. 从 `lwcam-module` 切出分支。保持分支小而专注。
3. 对你改动过的模块运行测试套件。命令和预期的数量见 `docs/TESTING.md`。
4. 向 `lwcam-module` 提交拉取请求。把测试结果（命令和通过/失败数量）贴到描述中。
5. 请一位队友评审。即使 GitHub 允许，也不要在未经评审的情况下合并自己的拉取请求。
6. 处理完评审意见后再合并，然后删除分支。

## 提交信息

使用约定式提交（conventional commits），与 `git log` 中的风格一致：

```
type(scope): short summary in the imperative
```

| 类型 | 用途 |
| --- | --- |
| `feat` | 用户可见的新能力 |
| `fix` | 缺陷修复 |
| `docs` | 仅限文档或注释 |
| `chore` | 重命名、清理、工具 |
| `build` | 构建或打包方面的改动 |
| `perf` | 性能改进 |
| `refactor` | 不改变行为的改动 |

scope 可取：`lwcam`、`lwcam-admin`、`lwip`、`qc-platform`（或 `qc`）、`upload`、`installer`、`db`。可以用逗号组合多个 scope（`feat(lwip,qc): ...`）。历史记录中的例子：`fix(upload): retry a failed package at once when it
changes`、`feat(db): one shared LWCam login chosen at install`。

正文要写给一年后的读者：不仅说明改了什么，还要说明为什么。

## 换行符

`.gitattributes` 设置了 `* -text`。Git 不做任何转换，而换行符是**按文件混用的**：有些文件是 CRLF，有些是 LF。请保持文件原有的风格。

- 重写文件前先检查：`file <path>`。
- 不要用另一种风格重新保存整个文件，否则提交中每一行都会显示为已改动。
- Git Bash 的 `sed -i` 会把 CRLF 变成 LF。请使用能保持原风格的编辑器。
- 提交前运行 `git diff --stat`。小改动应只显示少量行数。如果显示整个文件都变了，说明你改动了换行符。

## 代码风格

- **注释和标识符使用英文。**
- **Dart（LWCAM、LWCam Admin）：** `flutter analyze` 的结果不得变差。lint 规则来自 `flutter_lints`；每个应用中的 `analysis_options.yaml` 有意关闭了 `avoid_print`、`deprecated_member_use` 和 `no_leading_underscores_for_local_identifiers`。使用 `print` 输出日志是既定风格。`dart format` 只应用在你改动的那几行上，不要重新格式化整个文件。
- **Python（LWIP、QC 后端、Upload）：** Python 3.14。使用类型注解和 `from __future__ import annotations`，与现有文件一致。每个模块顶部写一段简短的 docstring。测试是 `unittest.TestCase` 类，必须能在没有 pytest 的情况下运行：不要 `conftest.py`，不要 fixture。
- **Vue/TypeScript（QC 控制台）：** `npm run build` 会运行 `vue-tsc --noEmit`，必须通过。
- **逐字节一致的文件。** `lwcam_secrets.py`、`tls.py`、`netlogin.py` 和 `geometry_replay.py` 存在于多个模块中。每个测试套件里都有一个测试，会在副本不一致时失败。请修改其中一份，复制到其他位置，再运行各测试套件。
- 缺陷修复需要一个没有该修复就会失败的测试。请确认它确实会失败。

## CHANGELOG

每一项用户可见的改动（新功能、行为变化、用户能察觉到的缺陷修复）都要在 `CHANGELOG.md` 中写一条记录。重构或文档改动不要添加记录。按版本分组，最新的在最前。

## 数据库结构变更

1. 在 `LWCam_QC_Platform/database/migrations/` 中新增一个带编号的文件，例如 `009_short_name.sql`。绝不要修改旧的迁移脚本。
2. 让它可以安全地重复运行（`IF NOT EXISTS` 等）。`setup_qc_db.py` 按名称顺序应用所有迁移脚本，并在 `schema_migrations` 中记录每一个。
3. 按需把新对象授权给组角色 `lwcam_app`。对一个测试数据库运行 `scripts/check_role_grants.py`。
4. 在需要新结构的代码中提高要求的级别。该级别就是最大的迁移编号。目前 QC 要求 8（`LWCam_QC_Platform/backend/app/services/schema_check.py` 中的 `REQUIRED_SCHEMA`），LWCAM（`LWCAM/lib/services/sync_sink.dart` 中的 `kRequiredSchema`）、LWIP（`cloud_report.py`）和 Upload（`health.py`）要求 7。只提高那些确实需要新对象的组件。
5. 注意发布顺序：在需要新级别的组件启动之前，必须先在数据库 PC 上运行 `LWCamDatabaseSetup`。请在 changelog 中写明这一点。
6. 对本地 PostgreSQL 运行数据库测试（`tests/test_setup_qc_db.py`）。

## 密钥

绝不要提交真实的配置或密钥：密码、密钥、`config.txt`、`upload_config.json`、含真实登录信息的 `deskew_crop_config.json`、证书、PostgreSQL 转储文件、客户图像。只提交 `*.example` 文件（`config.example.txt`、`upload_config.example.json`、`deskew_crop_config.example.json`）。如果你误提交了密钥，请立即告知项目负责人：该密钥必须轮换，仅仅在下一次提交中把它删掉是不够的。见 `SECURITY.md`。

## Issues 与标签

工作在 GitHub Issues 中跟踪。每个 issue 要有：

- 一个**模块**标签：`lwcam`、`lwcam-admin`、`lwip`、`qc-platform`、`upload`、`installer`、`database`、`docs`；
- 一个**类型**标签：`bug`、`enhancement`、`refactor`。

## 把修复带到另一个版本

一个修复可能同时属于两个版本。先在 `lwcam-module` 上完成，再用 `git cherry-pick` 带到 `lwcam-all-in-one`：

```bash
git switch lwcam-all-in-one
git switch -c fix/short-name-aio
git cherry-pick <commit>
```

两个版本都把各应用放在仓库根目录。唯一的路径差异是 LWIP：一体版在 `LWCAM/LWIP/`，模块版在 `LWIP/`。Git 的重命名检测通常能处理这种情况。如果 cherry-pick 发生冲突，请到新路径下的文件里手动应用改动。两份 `AGENTS.md` 一定会冲突。一体版还有模块版没有的功能（每日色彩校准、AI 审核可靠性改进、卷号延续预填），不要不小心把它们复制回去。两个版本都要测试：一体版的测试套件数量不同。
