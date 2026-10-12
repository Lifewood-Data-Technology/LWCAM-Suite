# 交接说明

[English](HANDOVER.md) | 简体中文

写给接手 LWCam 的团队负责人。它说明你拿到了什么、哪些已经验证过、哪些还没有，以及第一周该做什么。术语见 `GLOSSARY.md`。

## 交接内容

| 项目 | 位置 |
| --- | --- |
| 两个版本的源代码 | 私有 GitHub 仓库 `djchoy-LW/LWCAM-Suite` |
| 模块版（新工作都在这里） | 分支 `lwcam-module`（默认） |
| 一体版（较早的版本，供现有站点使用） | 分支 `lwcam-all-in-one` |
| 只读历史 | 分支 `archive/github-main`、`archive/fsi-demo` |
| 安装程序 | GitHub Releases：标签 `v1.1.0`（五个模块版安装程序）和 `v1.1.0-all-in-one`，附 SHA256 校验和。安装程序不在 git 中。 |
| 太大而无法放入 git 的构建输入（Python 嵌入式 zip、VC 运行库、adb、PostgreSQL 安装包、wheel、scrcpy、LWIP 工具） | 私有 GitHub Release，名为 `build-inputs`，附解包脚本。见 `RELEASING.md`。 |
| 示例测试图像 | 不在仓库中。请向项目负责人索取。 |
| 文档 | `README.md`、`docs/`、每个模块一份 `AGENTS.md`、`docs/decisions/` |

## 各模块的状态

“已测试”指自动化测试套件（`TESTING.md`）。在 PC 上安装后的检查，是原开发者在一个小型测试环境里完成的。这里只列出仓库文档中有记载的结论。

| 模块 | 可用功能 | 测试方式 | 尚未验证 |
| --- | --- | --- | --- |
| LWCAM（采集） | 通过 adb 采集、箱模式和普通模式、带重试的传输、带同步的离线队列、返工重拍列表 | 单元测试；在一台 PC 上与其他组件端到端使用过 | 真实站点上的多台采集 PC；不稳定的长距离链路 |
| LWCam Admin | 用户、项目、设备、设置、Station Setup | 单元测试；端到端使用过 | 真实的多站点环境 |
| LWIP | 纠偏、无损裁切、缩略图、清单文件、向数据库上报、https 控制台 | 单元测试；在一台测试 PC 上用真实照片运行过 | 真实站点中位于另一台 PC 的数据库或共享文件夹（SMB 机器账户和登录、延迟、时钟差异） |
| QC Platform | 审核、通过、退回、分卷、客户返工、导出、状态页 | 单元测试；通过控制台端到端使用过 | 客户返工的 Revert 和 Approve 按钮只通过 API 测试过 |
| Upload | 带台账的校验上传、重试、退避、回写结果 | 单元测试；对着一个假的 S3 存储桶运行过 | **真实的 S3 存储桶**，包括客户返工重新发布后的上传 |
| 数据库安装 | PostgreSQL 的安装或复用、数据库结构、共用账号、局域网访问、TLS、每晚备份、恢复脚本 | 在一台 PC 上做过安装测试 | **数据库 PC 的重启**；在站点的新硬件上做恢复 |
| 安装程序 | 五个都能构建；在一台 PC 上测试过安装和卸载 | 带校验和检查的构建脚本 | **从一体版站点升级**；Python 3.14 版本能否在真实 PC 上升级覆盖旧的 Python 3.13 运行时（目前只在一份 3.13 运行时的副本上运行构建脚本证明过） |

整条流水线的规则（核心目标）：采集、LWIP、QC、导出和上传（包括返工）必须能在每个组件各占一台 PC 的情况下工作。设计遵循了这一点（一切都排队并重试，没有环节无超时地等待远程主机，QC 状态页会显示每一处停滞）。目前只在一台 PC 上以角色账号经网络访问的方式证明过，并没有在独立的机器上验证过。在真实的独立 PC 上验证站点的检查清单见 [INSTALL.zh-CN.md](INSTALL.zh-CN.md#14-在多台独立-pc-上验证站点)。

## 已知问题与待办工作

请把这些创建为 GitHub Issue（标签见 `CONTRIBUTING.md`）。

### 功能

- **把 Color Calibration（色彩校准）整合进模块版**（`enhancement`）。每日色彩校准、AI 审核可靠性改进和卷号延续预填目前只存在于一体版（`lwcam-all-in-one`）。请决定移植哪些内容，以及它们在五模块结构中应放在哪里。

### 重构（`refactor`，每项一个 issue）

下列文件是最大、风险最高的。只有在有测试能证明行为不变时才拆分它们。

| 文件 | 说明 |
| --- | --- |
| `LWCAM/lib/pages/gallery_page.dart`（约 6300 行） | ADB/传输这一半风险最大，没有必要就不要动 |
| `LWCam_QC_Platform/frontend/src/views/qc/QcIndexView.vue` | 审核界面 |
| `LWCam_QC_Platform/backend/app/routers/qc.py`（约 3400 行） | |
| `LWCAM/lib/db/upload_stats_db.dart`（约 3200 行） | |
| `LWCam_QC_Platform/backend/app/services/ai_review.py`（约 2600 行） | |
| `LWCam_QC_Platform/backend/app/services/export.py`（约 2200 行） | |
| `LWIP/backend/deskew_crop_tool/orchestrator.py`（约 1900 行） | |
| `LWCAM/lib/controllers/upload_controller.dart`（约 1900 行） | |
| `LWIP/backend/deskew_crop_tool/service.py` 中的 `build_handler` | 一个超长的函数 |
| `LWCam_Upload/backend/lwcam_upload/console.py` 中的 `build_handler` | 一个超长的函数 |
| `LWIP/backend/deskew_crop_tool/config.py` 中的 `load_config` | |
| `LWCam_Upload/backend/lwcam_upload/engine.py` 中的 `_scan` | |

### 小清理

- `QcIndexView.vue` 中有未使用的 CSS：两块样式（例如 `.qc-workbench`、`.tree-*`）在当前模板中没有任何匹配。
- 已停用的设置 `captureImageLocalRoot` 仍保留在 QC 的 admin 模式定义、路由和运行时设置中（`schemas/admin.py`、`routers/admin.py`、`core/runtime_settings.py`）。先确认旧配置文件是否仍需要它，然后将其移除。
- `UploadController` 复制到本地或 NAS 目标位置，并不上传到 S3，名称有误导性。请重命名（文件名已经是 `upload_controller.dart`）。

### 已知的测试基线

在启用了 Windows 长路径的 PC 上，有两个 LWIP 测试（`test_long_paths.py`）会失败。它们是反向对照用例。见 `TESTING.md`。

## 建议的第一周安排

1. 先读 `README.md`，再读 `ARCHITECTURE.md`，然后读 `GLOSSARY.md`。
2. 阅读根目录的 `AGENTS.md`：其中有各种陷阱和设计决策。快速浏览 `docs/decisions/`。
3. 搭建开发环境（`DEV-SETUP.md`）：Flutter、Python 3.14、Node。
4. 运行所有测试套件（`TESTING.md`）。记下你的测试数量，它们就是你的基线。
5. 在一台 PC 上安装全部五个组件（`INSTALL.md`），使用构建输入文件。
6. 让一个测试文件夹走完整条流水线：采集（或手工做一个带标记文件的文件夹）、LWIP、QC 审核并通过、导出、上传到测试存储桶。没有相机时，`LWCam_QC_Platform/scripts/reset_test_folder.py` 可以帮上忙。
7. 从上面的清单中挑一个入门 issue（一项小清理），提交你的第一个拉取请求（`CONTRIBUTING.md`）。

## 联系人

项目负责人：Jackson Choy，jackson.choy@lifewood.com。示例图像、`build-inputs` release 的访问权限，以及关于流水线历史的问题，都请向项目负责人询问。安全问题请私下报告（见 `SECURITY.md`）。
