# LWCAM（Lifewood Capture，采集端）

[English](README.md) | 简体中文

LWCAM 是一个面向 Windows 的 Flutter 桌面应用。它通过 ADB 从 Android 手机拉取照片，先暂存在 PC 上，再复制到本地或网络文件夹。每次采集都会记录到本地 SQLite 数据库，并同步到共享的 PostgreSQL 数据库。

Dart 包名为 `lwcam`，仅支持 Windows。

## 在流水线中的位置

```
LWCAM (capture)  ->  LWIP (deskew/crop)  ->  QC Platform (review, export)  ->  Upload (S3)
   ^ 本应用              用户、项目和工位由 LWCam Admin 管理
```

- LWCAM 把每个完成的文件夹复制到 LWIP 的输入文件夹。
- 随后 LWCAM 在该文件夹中写入一个标记文件（`lwcam_capture_marker.json`）。LWIP 会等到这个标记出现后才处理该文件夹。
- QC Platform 把被退回的页面以 `rework_logs` 行的形式送回。LWCAM 在箱列表上显示为 "Needs Rework" 标记。
- 术语见 [docs/GLOSSARY.md](../docs/GLOSSARY.md)，整体设计见 [docs/ARCHITECTURE.md](../docs/ARCHITECTURE.zh-CN.md)。

## 两种采集工作流

由每个账号各自的元数据录入开关（在 LWCam Admin 中设置）决定使用哪种工作流。

| 模式 | 路由 | 行为 |
| --- | --- | --- |
| Normal Mode（普通模式，录入关闭） | `/gallery` | 从手机拉取照片，传输到按日期命名的目标文件夹。 |
| Box Mode（箱模式，录入开启） | `/boxes` | 一个采集箱包含若干已录入元数据的文件夹（标签、标题、卷号、日期、参考编号、记录类型）。每个文件夹有自己的目标子文件夹。传输在每个箱各自的后台队列中运行。每个箱的卡片实时显示进度，并保留重启后仍在的结果，同时提供 Retry 按钮。 |

一次传输会写出如下目录结构：

```
<destination root>\<work week, e.g. "June 15-19">\<YYYYMMDD>\<folder>\
```

工作周为周一到周五。周末的日期归入它之前的那个工作周。

## 目录结构

| 路径 | 内容 |
| --- | --- |
| `lib/main.dart` | 启动、错误处理、路由（`/`、`/home`、`/boxes`、`/gallery`） |
| `lib/pages/` | 各界面。`gallery_page.dart`（约 6300 行）包含 ADB 代码和返工循环。 |
| `lib/controllers/` | GetX 控制器。`transfer_controller.dart` 负责把文件复制到目标位置。 |
| `lib/services/` | ADB、传输队列、同步到 PostgreSQL、文件锁、节点配置、scrcpy、返工 |
| `lib/db/` | 采集与传输的本地 SQLite 数据库（`upload_stats_db.dart`） |
| `lib/auth/`、`lib/models/` | 登录与数据类 |
| `lwcam_node_config.example.json` | 工位配置示例 |
| `windows/runner/resources/LWCAM.iss` | 本应用的 Inno Setup 脚本 |
| `test/` | 单元测试 |

## 运行、构建、测试

需要 Flutter（stable 通道）。构建还需要安装了 "Desktop development with C++" 工作负载的 Visual Studio 2022。完整的环境搭建见 [docs/DEV-SETUP.md](../docs/DEV-SETUP.zh-CN.md)，测试基线见 [docs/TESTING.md](../docs/TESTING.zh-CN.md)。

```bash
flutter pub get
flutter run -d windows
flutter build windows --release
flutter analyze
flutter test
flutter test test/services/transfer_destination_service_test.dart   # one file
```

`flutter analyze` 会报告少量 info 级别的 lint，没有错误。

运行时应用需要：

- `adb.exe`。应用先在自己的 `.exe` 旁边查找，再查找 `%ProgramFiles%\LWCam\LWCAM\adb.exe`；不会搜索 `PATH` 或工作目录（`AdbDeviceService.resolveAdbPath`）。安装程序会附带 `adb.exe`。从源码运行时，需要把 `adb.exe` 复制到构建出的 `.exe` 旁边。
- `.exe` 旁边 `scrcpy\` 文件夹中的 `scrcpy`。只有 Box Mode 的手机实时镜像需要它。

## 配置

LWCAM 没有 Settings 页面，所有设置都放在一个工位配置文件中：

```
%USERPROFILE%\LWCAM_DBs\lwcam_node_config.json
```

这个文件由 LWCam Admin 写入（Station Setup（工位设置）界面），LWCAM 只读取。`lwcam_node_config.example.json` 列出了各个键：

| 键 | 含义 |
| --- | --- |
| `pgConnectionEnabled`、`pgHost`、`pgPort`、`pgDatabase`、`pgUser`、`pgPassword`、`pgUseSsl` | PostgreSQL 连接。Station Setup 会加密保存密码（`pgPasswordProtected`，Windows DPAPI）。 |
| `syncEnabled`、`syncIntervalSeconds` | 是否把采集记录发送到 PostgreSQL。LWCAM 始终会在本地记录采集，这个开关只控制是否发送。 |
| `destinationPath` | 图像目标根目录（通常是 LWIP 的输入文件夹）。 |

新的采集 PC 上请先运行 LWCam Admin。如果 LWCAM 提示目标路径为空，请到 Station Setup 中修正，这不是 LWCAM 的 bug。

LWCAM 只会向共享数据库写入少量内容：采集记录、用户自己的密码修改、登录时间，以及项目的 `has_data` 标志。用户、项目和应用设置只由 LWCam Admin 写入。

## 可靠性规则

修改传输路径之前请先读这一节。

- **超时。** 单个文件的复制上限为 10 分钟。复制超过 30 秒没有进展即视为停滞。相关常量在 `lib/controllers/transfer_controller.dart` 的开头。
- **崩溃恢复依赖数据库，而不是检查点。** 只有在复制校验通过之后才会写入 `upload_records` 行。重启后的批次会跳过已有记录的文件名。按索引续传的检查点是有意删除的，因为文件名每次运行都从磁盘重新分配。不要再加回来。
- **采集完整性。** 每张图像的 `capture_images` 行是"图像属于哪个箱"的唯一记录。如果这次写入失败，应用会把已拉取的字节存入基于文件的"孤儿台账"（orphan ledger；不用数据库表，因为失败的正是数据库）。箱被标记为已传输之前，必须通过 `verifyBoxComplete`。不一致时，该箱保持 `partial` 状态。
- **加锁。** 批次运行期间，由操作系统文件锁和 SQLite WAL 检查点保护本地数据库（`lib/services/file_lock_service.dart`）。

## 看起来像错误、其实不是的约定

- `lib/pages/settings_page.dart` 里只有 `SettingsController`，并没有设置页面。文件名保留是因为有 import 在引用它。
- 带 emoji 前缀的 `print()` 日志是本项目的风格。`analysis_options.yaml` 中关闭了 `avoid_print`、`deprecated_member_use` 和 `no_leading_underscores_for_local_identifiers` 这几条 lint。
- `lib/pages/gallery_page.dart` 非常庞大。不需要它的功能开发不要去改它。ADB 和传输那一半视为不可触碰。
- `windows/runner/resources/LWCAM.iss` 手工列出了插件 DLL 和 `scrcpy` 文件夹。新增插件却不更新 `.iss`，发布版构建在干净的 PC 上会失败。
- `win32`、`ffi` 和 `hotkey_manager` 要继续留在 `pubspec.yaml` 中，手机镜像和远程快门要用到它们。

## 相关模块

| 模块 | 链接 |
| --- | --- |
| LWCam Admin：用户、项目、应用设置和工位配置的唯一编辑者 | [../LWCamAdmin/README.md](../LWCamAdmin/README.zh-CN.md) |
| LWIP：处理 LWCAM 复制过来的文件夹 | [../LWIP/README.md](../LWIP/README.zh-CN.md) |
| QC Platform：审核页面并把返工送回 | [../LWCam_QC_Platform/README.md](../LWCam_QC_Platform/README.zh-CN.md) |
| 安装程序（`LWCamSetup.exe` 安装 LWCAM 和 LWCam Admin） | [../installer/README.md](../installer/README.zh-CN.md) |

## 接下来读什么

- [AGENTS.md](AGENTS.md)：逐个服务讲解的架构，以及每个不显而易见的选择背后的原因。
- [CHANGELOG.txt](CHANGELOG.txt)：带原因的变更历史。每一项用户可见或行为上的改动都要加一条记录。
