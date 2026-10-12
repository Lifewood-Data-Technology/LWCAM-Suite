# LWCam QC Platform（质检平台）

[English](README.md) | 简体中文

QC Platform 是 LWCam 套件中负责审核和导出的部分。它是一个 FastAPI 服务器，配有 Vue 3 的 Web 控制台。多位审核员通过网络在浏览器中打开控制台，检查每个处理过的页面文件夹，通过它或把页面退回，服务器再把通过的文件夹导出为交付包。

它与采集 PC 没有直接联系，只通过共享的 PostgreSQL 数据库和磁盘上的文件夹与其他部分交互。

## 它做什么

- 审核：显示文件夹的页面，修改页面几何，替换或插入页面，用分卷标记拆分文件夹，通过，或退回重拍。
- 客户返工：重新打开已交付的文件夹，修改后以相同的 Group ID 重新发布。
- 导出：在工作目录中构建 TIFF 或 JPEG 交付包（可选 ZIP），并发布到输出文件夹。
- 管理：统计、QC 任务管理、导出管理、设置，以及显示整个站点各部分状态的 System status 页面。
- 可选的、通过 OpenRouter 进行的 AI 元数据审核（默认关闭）。

它不负责采集，不处理图像（由 LWIP 负责），不上传到 S3（由 LWCam Upload 负责），也不管理用户和项目（由 LWCam Admin 负责）。

## 在流水线中的位置

```
LWCAM -> LWIP -> output folder (qcInputRoot) -> QC Platform -> export folder (qcOutputRoot) -> Upload
                                                     ^
                                   PostgreSQL: folders, pages, QC state, users
```

LWIP 把页面几何作为数据（`qc_ops`）记录下来，QC 服务器在导出之前一直把它当作数据保存。导出时，它在原始像素上一次性重放整条操作链。原因见 [../docs/FAMILYSEARCH-FIX.md](../docs/FAMILYSEARCH-FIX.md) 和 [../docs/ARCHITECTURE.md](../docs/ARCHITECTURE.zh-CN.md)。

## 目录结构

| 路径 | 内容 |
| --- | --- |
| `backend/` | FastAPI 服务器 |
| `backend/run_server.py` | 启动脚本（请用它，见"从源码运行"） |
| `backend/app/main.py` | 应用启动，同时提供构建好的控制台。 |
| `backend/app/routers/` | HTTP 路由：`auth`、`qc`、`export`、`admin` |
| `backend/app/services/` | 预览、几何重放、分卷、草稿、导出、AI 审核、自动扫描、状态心跳、数据库结构检查 |
| `backend/app/core/` | 设置（`server_settings.py`）、安全、TLS、机密 |
| `backend/app/models/`、`schemas/`、`db/` | 数据库模型、API schema、会话 |
| `backend/tests/` | 单元测试 |
| `backend/repair_split_manifests.py` | 针对某个修复之前就已拆分的文件夹的一次性修复脚本 |
| `frontend/` | Vue 3 + TypeScript + Vite + Element Plus 控制台 |
| `database/` | 统一的数据库结构转储和 `migrations/`（001 到 008） |
| `scripts/` | `setup_qc_db.py`（创建或升级数据库结构）、`check_role_grants.py`、`reset_test_folder.py` |
| `config.example.txt` | 设置文件示例 |

数据库结构由 `LWCamDatabaseSetup.exe` 应用，它会运行 `scripts/setup_qc_db.py`。如果数据库结构版本级别低于 `backend/app/services/schema_check.py` 中的 `REQUIRED_SCHEMA`，服务器会拒绝工作。

## 从源码运行

这里是简版。完整的环境搭建（Python、PostgreSQL、Node）见 [../docs/DEV-SETUP.md](../docs/DEV-SETUP.zh-CN.md)。

```bash
# 1. 配置：复制示例文件，然后填写数据库登录信息和 jwtSecret
copy config.example.txt config.txt

# 2. 构建控制台（服务端直接提供 frontend/dist）
cd frontend
npm ci
npm run build          # vue-tsc --noEmit && vite build

# 3. 启动服务端
cd ..\backend
python -m pip install -r requirements.txt
python run_server.py   # port from config.txt, default 8080
```

做控制台开发时，在 `frontend/` 中运行 `npm run dev`。Vite 监听 5174 端口，并把 `/api` 代理到 `http://localhost:8080`（用 `VITE_API_TARGET` 修改）。

一定要用 `run_server.py`，不要在 `backend/` 中用 `python -m app.main` 启动服务器。在已安装 QC 服务器的 PC 上，如果运行该命令的是它的嵌入式 Python，该运行环境的 `._pth` 文件会把已安装的 backend 排在路径最前面，于是你启动的是错误的服务器，并且它会不带任何提示地退出。`run_server.py` 会把本文件夹放在最前面，并打印出它所服务的目录树。

测试：[../docs/TESTING.md](../docs/TESTING.zh-CN.md) 里有基线和已知失败项。

```bash
cd backend
python -m unittest discover -s tests -t .
```

测试是 `unittest.TestCase` 类。Pytest 也能收集它们，但不是必需的。有一个测试文件会在本地 PostgreSQL 上创建并删除临时数据库，使用 `config.txt` 中的登录信息。没有服务器响应时会跳过。

要在没有相机的情况下得到一个待审文件夹，参见 `scripts/reset_test_folder.py`（其文档字符串解释了步骤）和 [AGENTS.md](AGENTS.md) 中的 "Test data without a camera" 一节。

## 配置：`config.txt`

服务器从本文件夹的 `config.txt` 中读取朴素的 `key = value` 行。已安装的服务器把它放在 `<install folder>\config\config.txt`。可以用 `LWCAM_QC_SERVER_CONFIG` 指向另一个文件。控制台的 Settings 页面也会编辑这个文件。`config.example.txt` 用注释列出了每个键。完整列表和默认值在 `backend/app/core/server_settings.py`（`SETTINGS_BY_KEY`）。

| 分组 | 键 |
| --- | --- |
| 数据库 | `dbHost`、`dbPort`、`dbName`、`dbUser`、`dbPassword`、`dbUseSsl` |
| 登录 | `jwtSecret`（至少 32 个随机字符）、`jwtExpireMinutes` |
| Web 控制台 | `bindHost`、`port`、`tlsCertFile`、`tlsKeyFile` |
| 文件夹 | `qcInputRoot`（LWIP 的输出）、`exportWorkRoot`（临时目录，本地）、`qcOutputRoot`（交付包）。使用本地路径或 UNC 共享，绝不要用映射的盘符。 |
| 导出 | `exportZipOutput`、`exportTiffOutput`、`exportAutoEnabled`、`exportWorkerCount`、`exportTempRetentionHours`、`luminanceEnabled`、`previewCacheMaxMb` |
| AI 审核 | `aiReviewEnabled`、`aiPreanalysisEnabled`、`openrouterApiKey`、`openrouterExtractModel`、`openrouterCompareModel` |

机密项（`dbPassword`、`jwtSecret`、`openrouterApiKey`）可以填明文。在 Windows 上，服务器首次启动时会把它们加密（`dpapi:...`，与 PC 绑定）。`config.txt` 已被 git 忽略，绝不要提交。

## 控制台

打开 `https://<pc-name>:8080/`（`tlsCertFile` 为空时是普通的 `http`）。账号在 LWCam Admin 中创建。一个账号同一时间只能有一个有效登录。

| 角色 | 界面 |
| --- | --- |
| QC 审核员 | Pending tasks（`/qc/tasks`）、My tasks（`/qc/my-tasks`）、Completed（`/qc/completed`）、Review（`/qc/review/:id`） |
| Admin / SuperAdmin | Statistics、QC task management、Exports、Settings、System status（`/admin/...`） |

System status 页面列出所有向数据库上报过状态的部分（QC、QC 导出、LWIP、Upload、备份、每台采集 PC），以绿色、红色或灰色显示。每个界面上都有一个横幅链接到它。各个信号的含义见 [../installer/README.md](../installer/README.zh-CN.md)（"System status page"）。

## 接下来读什么

- [AGENTS.md](AGENTS.md)：如何运行服务器、不要再重新争论的决定、测试数据，以及未完成事项。做 QC 工作请从这里开始。
- [../docs/ARCHITECTURE.md](../docs/ARCHITECTURE.zh-CN.md)：整条流水线。
- [../installer/README.md](../installer/README.zh-CN.md)：QC 安装程序和 HTTPS 信任步骤。
- [../LWIP/README.md](../LWIP/README.zh-CN.md) 和 [../LWCam_Upload/README.md](../LWCam_Upload/README.zh-CN.md)：QC 服务器的相邻模块。
