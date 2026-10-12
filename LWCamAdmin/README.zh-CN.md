# LWCam Admin（管理端）

[English](README.md) | 简体中文

LWCam Admin 是一个面向 Windows 的 Flutter 桌面应用，承担 LWCam 套件中 SuperAdmin 的全部工作：用户账号（角色、Device ID、密码重置）、项目（创建、编辑、元数据模板）、设备重新分配、共享的应用设置，以及每台 PC 的工位设置。

在共享的 PostgreSQL 数据库中，`users`、`projects` 和 `app_settings` 只由它写入。LWCAM 读取的工位配置 `lwcam_node_config.json` 也只由它编辑。它没有采集工作流，没有 ADB，也没有本地采集数据库。

Dart 包名为 `lwcam_admin`，仅支持 Windows。

## 在流水线中的位置

```
LWCAM (capture)  ->  LWIP  ->  QC Platform  ->  Upload
      ^                 各组件都从同一个 PostgreSQL 数据库读取用户和项目
      +-- 由 LWCam Admin 写入（以及采集 PC 的工位配置）
```

- 在这里创建的账号用于登录 LWCAM、QC 控制台，以及 LWIP 和 Upload 的控制台，但不能登录 LWCam Admin。
- 数据库由 `LWCamDatabaseSetup.exe` 创建和升级，本应用只负责连接。Station Setup（工位设置）里有一个 Test connection 按钮。
- 每台新的采集 PC 上都要先运行本应用。

## 界面

| 界面 | 用途 |
| --- | --- |
| Login | 仅限 SuperAdmin（见下文"登录"） |
| User Management | 账号、角色、项目权限、把密码重置为默认值。临时密码字段只能设置，不能读取。 |
| Projects | 创建和编辑项目、地点代码、元数据模板编辑器 |
| Devices | 重新分配 Device ID |
| App Settings | 元数据录入开关、远程快门设置、默认临时密码 |
| Station Setup | 本 PC 的 PostgreSQL 连接和登录、采集站的同步开关、图像目标文件夹、文件夹访问测试 |

主界面上的状态栏会显示数据库是否可达，以及是否有改动在等待推送。

## 目录结构

| 路径 | 内容 |
| --- | --- |
| `lib/main.dart` | 启动。在 `runApp` 之前注册 store 服务，因此没有数据库时也能登录和使用 Station Setup。 |
| `lib/auth/` | SuperAdmin 登录、编译进程序的出厂哈希、密码错误锁定 |
| `lib/services/` | `admin_store_service.dart`（所有读写）、`admin_pg_gateway.dart`、`admin_pg_statements.dart`（纯 SQL 构造器）、节点配置、DPAPI |
| `lib/controllers/` | 各界面的 GetX 控制器和同步状态 |
| `lib/pages/` | 上面列出的各界面 |
| `lib/theme/` | 品牌主题，是 LWCAM 主题的副本，两者要保持一致。 |
| `windows/runner/resources/LWCamAdmin.iss` | Inno Setup 脚本（有自己的 AppId） |
| `test/` | 单元测试。`test/services/fake_admin_gateway.dart` 用来替代数据库。 |

## 运行、构建、测试

需要 Flutter（stable 通道）；构建还需要安装了 "Desktop development with C++" 工作负载的 Visual Studio 2022。详情见 [docs/DEV-SETUP.md](../docs/DEV-SETUP.zh-CN.md)，基线见 [docs/TESTING.md](../docs/TESTING.zh-CN.md)。

```bash
flutter pub get
flutter run -d windows
flutter build windows --release
flutter analyze
flutter test
```

`flutter analyze` 没有任何提示。

## 登录

只有 `SuperAdmin` 账号可以登录。应用依次用下面几项校验密码：

1. PostgreSQL 中的 `app_settings.superadmin_password_hash`（覆盖值）
2. 本地快照中保存的该覆盖值的副本
3. 编译进 `lib/auth/super_admin.dart` 的 bcrypt 哈希（出厂哈希）

因此离线、在新 PC 上、没有数据库时都能登录。出厂密码不在代码仓库里，请向项目负责人索取。

连续输错 5 次密码，登录会锁定 1 分钟。之后每多输错一次，锁定时间翻倍，最长 15 分钟。这只是减速带，不是安全边界（`lib/auth/login_lock.dart`）。

## 配置

Station Setup 编辑 `%USERPROFILE%\LWCAM_DBs\lwcam_node_config.json`，其中包含：

- 本应用的 PostgreSQL 连接（主机、端口、数据库、用户、SSL）；
- LWCAM 和 LWCam Admin 使用的数据库登录。密码以当前 Windows 用户的 Windows DPAPI 加密保存（`pgPasswordProtected`），换一个账号或换一台 PC 就无法读取，需要在那里重新输入。
- LWCAM 的采集同步开关和图像目标文件夹；
- `usersStorePath`，即离线快照 `lwcam_users.json` 所在的文件夹。

`LWCAM/lwcam_node_config.example.json` 列出了各个键。配置文件是整体读取、整体保存的，所以本应用不认识的键会被保留。

## 设计规则

- 所有修改都要经过 `lib/services/admin_store_service.dart` 中的 `_mutate`。它先拉取，再应用并校验，然后在线推送，或带着墓碑标记（tombstone）排入离线队列。推送失败会回退到离线队列，不会丢失任何数据。修改这个文件之前请先读懂这个方法。
- 所有 SQL 都在 `lib/services/admin_pg_statements.dart` 里，是纯 Dart 构造器，不引用 `postgres`，所以测试不需要数据库连接。
- Upsert 的冲突键是 `projects(project_key)`，绝不是 `project_id`。`project_id` 是可编辑的标签，若以它作冲突键，每次重命名都会产生一条重复行。
- 用户 upsert 绝不覆盖 `last_login_at`、`password` 和 `must_change_password`，它们归 LWCAM 所有。过期的快照不能撤销采集用户刚改过的密码。管理员重置密码使用 `userPasswordResetSql`。
- `projectSoftDeleteSql` 会把 `country_location_code` 改写为 `~deleted~<id>`。该列是唯一列，且被 `devices` 表引用。改写后原来的代码就被释放出来，新项目可以重新使用它。
- `buildUsersStoreFromPgRows` 从 `users.roles` 而不是 `user_projects` 读取全局角色。否则没有任何项目的管理员在下一次拉取时会丢失角色。

## 看起来像错误、其实不是的约定

- `lib/theme/` 是 LWCAM 主题的逐字节副本。这三个 Flutter 应用有意做成各自独立的副本，而不是共享库，因为它们各自发布、各自版本化。
- `windows/runner/resources/LWCamAdmin.iss` 有自己的 AppId，因此本应用可以与 LWCAM 并排安装。它手工列出了插件 DLL，新增插件却不更新它，发布版构建在干净的 PC 上会失败。
- 带 emoji 前缀的 `print()` 日志是本项目的风格。`analysis_options.yaml` 中关闭了三条 lint（见 LWCAM 的 README）。

## 接下来读什么

- [AGENTS.md](AGENTS.md)：架构、PostgreSQL 网关和离线队列模型。
- [CHANGELOG.txt](CHANGELOG.txt)：按日期记录的变更历史。
- [../LWCAM/README.md](../LWCAM/README.zh-CN.md)：读取本应用所写内容的采集应用。
