# LWCam Upload（上传服务）

[English](README.md) | 简体中文

LWCam Upload 是一个面向 Windows 的 Python 服务。它监控一个存放导出包的文件夹（每个 Group ID 一个文件夹或 ZIP），把每个包上传到 S3 存储桶，并检查每个已上传文件的大小。随后它把这个包记录到 `Upload_Summary.db3`（设置了 `summary_root` 时），并移动到 `done_root`。因此 `watch_root` 里只剩下还没到达存储桶的内容。

如果 QC 以相同的 Group ID 重新发布了一个包（客户返工），Upload 会通过内容指纹检测到，重新上传，并替换存储桶和 `done_root` 中较早的副本。

一个包只有在其内容保持 10 秒不变之后才会上传（`engine.py` 中的 `SETTLE_SECONDS`）。手工复制进来的包不会在复制到一半时被发送。

它自行运行。它是从 QC 服务器中拆分出来的，因此可以在自己的 PC 和计划任务上运行，无论那台 PC 上是否安装了 QC 或 LWIP。

## 在流水线中的位置

```
QC Platform -> export folder (qcOutputRoot) -> LWCam Upload -> S3 bucket
```

`watch_root` 就是 QC 的 `qcOutputRoot`。Upload 只在控制台登录和状态上报时需要数据库，上传本身不需要。

## 目录结构

| 路径 | 内容 |
| --- | --- |
| `backend/lwcam_upload/engine.py` | 扫描、上传、重试和重新上传的逻辑 |
| `backend/lwcam_upload/config.py` | 每个配置键、默认值和检查规则 |
| `backend/lwcam_upload/ledger.py` | `uploads.json`，已发送包的台账 |
| `backend/lwcam_upload/summary.py` | `Upload_Summary.db3` |
| `backend/lwcam_upload/console.py`、`web/` | Web 控制台（端口 8091） |
| `backend/lwcam_upload/{health,tls,netlogin,lwcam_secrets}.py` | 状态心跳、HTTPS 证书、网络文件夹登录凭据、DPAPI 机密 |
| `backend/tests/` | 单元测试 |
| `config/upload_config.example.json` | 配置示例 |
| `SETUP_UPLOAD.bat`、`START_UPLOAD.bat` | 构建私有运行环境；启动服务（计划任务运行的就是它）。 |

## 运行、构建、测试

需要 Python 3.14，以及 `requirements.txt` 中的包（`boto3`、`psycopg`、`bcrypt`、`cryptography`）。详情见 [docs/DEV-SETUP.md](../docs/DEV-SETUP.zh-CN.md)。测试基线见 [docs/TESTING.md](../docs/TESTING.zh-CN.md)。

```bash
cd LWCam_Upload
python -m venv venv
venv\Scripts\python -m pip install -r requirements.txt
cd backend
..\venv\Scripts\python -m unittest discover -s tests -v
..\venv\Scripts\python -m lwcam_upload --config ..\config\upload_config.json
```

请先把 `config/upload_config.example.json` 复制为 `config/upload_config.json`。不要提交你的副本，里面有 S3 密钥。

## 配置

`config/upload_config.json`（JSON）。每个键、默认值和校验规则都在 `backend/lwcam_upload/config.py` 里。

| 键 | 含义 |
| --- | --- |
| `watch_root` | 必填。QC 发布包的目标文件夹。 |
| `done_root` | 已发送的包移动到的位置。留空表示保留在原处。 |
| `summary_root` | `Upload_Summary.db3` 的写入位置。留空表示不生成汇总。 |
| `enabled` | `true`（默认）。`false` 会暂停上传，控制台仍然保持运行。 |
| `s3_path` | `s3://bucket/optional/prefix`。启用时必填。 |
| `s3_region`、`s3_access_key`、`s3_secret_key` | 启用时必填。 |
| `https_proxy` | S3 流量的可选代理。 |
| `interval_seconds` | 扫描间隔。默认 60。代码接受 10 到 3600。 |
| `db_host`、`db_port`、`db_name`、`db_user`、`db_password`、`db_use_ssl` | PostgreSQL 登录。用于控制台登录和状态上报。 |
| `ui_bind`、`ui_port`、`tls_cert_file`、`tls_key_file` | 控制台地址（端口 8091）。安装程序会填好证书文件。 |

服务在每次扫描开始时都会重新读取设置。在控制台保存后，下一次扫描即生效，无需重启。配置无效时，它会记录一行 `[CONFIG]` 日志，并且在修好之前不上传任何内容。

`db_password` 和 `s3_secret_key` 加密存储（`dpapi:...`，Windows DPAPI，与 PC 绑定）。把文件复制到另一台 PC，那里无法解密它们，需要在那台 PC 的控制台中重新输入。

## 控制台

控制台地址是 `https://<pc-name>:8091/`，只支持 HTTPS。

- 用共享 PostgreSQL `users` 表中的 Admin 或 SuperAdmin 账号登录。
- 数据库不可达时，控制台为只读。同一台 PC 上的浏览器可以查看状态和日志。曾经登录过的管理员可以通过保存的名单登录（配置旁边的 `admin_cache.json`）。
- "Network folder logins"（网络文件夹登录凭据）保存本 PC 访问另一台 PC 上共享文件夹所用的账号（不在域环境中时需要）。见 [installer/README.md](../installer/README.zh-CN.md)。
- HTTPS 证书和一次性的浏览器信任步骤：见 [installer/README.md](../installer/README.zh-CN.md) 中的 "HTTPS"。

## 失败与重试

- 失败的包留在原处，按退避策略重试，并在 QC 控制台的 System status 页面上显示为红色，直到上传成功。
- 如果存放 `watch_root` 的共享文件夹不可用，Upload 每两分钟重试一次。
- 数据库或 QC 所在 PC 关机期间，Upload 继续扫描和上传，稍后再发送状态上报。
- 如果数据库结构（schema）比本程序要求的旧，Upload 不做任何数据库操作，并给出提示。请先升级数据库所在 PC。

## 日志与安装后的目录

`LWCamUploadSetup.exe` 安装到 `%ProgramFiles%\LWCam Upload`。计划任务 "LWCam Upload" 在开机时以 SYSTEM 身份运行 `START_UPLOAD.bat`。`logs\service.log` 记录 `START_UPLOAD.bat` 的输出。每一次扫描、上传、重试和错误也会写入 `log_file`（默认 `logs\upload.log`，按 10 MB x 5 轮转），并实时显示在控制台中。`runtime\` 存放私有 Python 和 `uploads.json`。安装程序对 PC 做了哪些改动，见 [installer/README.md](../installer/README.zh-CN.md)。

## 接下来读什么

- [../docs/ARCHITECTURE.md](../docs/ARCHITECTURE.zh-CN.md)：Upload 与其他部分如何配合。
- [../LWCam_QC_Platform/README.md](../LWCam_QC_Platform/README.zh-CN.md)：写出这些包的应用。
- [../installer/README.md](../installer/README.zh-CN.md)：Upload 安装程序及其参数。
- Upload 没有单独的 `AGENTS.md`，工作区指南是 [../AGENTS.md](../AGENTS.md)。
