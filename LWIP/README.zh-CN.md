# LWIP：纠偏、裁切与缩略图服务

[English](README.md) | 简体中文

LWIP 是一个面向 Windows 的 Python 服务。它监控一个输入文件夹，里面是相机拍摄的图像文件夹。对每个文件夹，它测量每一页的倾斜角，在内存中裁切页面，并写出暂存的输出。它自己从不旋转任何像素：倾斜超过 `deskew_min_degrees` 的页面，其纠偏信息会以一小串操作（`qc_ops`）的形式记录在输出清单文件（manifest）中，由 QC Platform 在预览和导出时一次性重放。LWIP 会先确认源文件夹没有变化，再发布输出文件夹。

它是独立安装的（`LWIPSetup.exe`），没有其他应用会启动或监控它。

## 在流水线中的位置

```
LWCAM -> input folder -> LWIP -> output folder -> QC Platform
                          |
                          +-> reports each finished folder to PostgreSQL
```

- 输入：LWCAM 复制过来的文件夹。LWCAM 在传输完成时向文件夹中写入 `lwcam_capture_marker.json`。这个标记带有该文件夹在数据库中的身份和图像数量（`image_count`）。LWIP 会等待标记出现，并等到图像数量达标。
- 输出：处理后的图像、`thumbs\`（可选），以及带有 `qc_ops` 的清单文件。清单文件中还有从标记复制来的 `source_identity`。
- 上报：LWIP 把该文件夹的结果直接写入 PostgreSQL（`cloud_report.py`）。这样即使 LWCAM 已关闭，该文件夹也会出现在 QC 队列中。

## 目录结构

| 路径 | 内容 |
| --- | --- |
| `backend/deskew_crop_tool/orchestrator.py` | 监控器：稳定性检查、日志（journal）、发布、完整性审计 |
| `backend/deskew_crop_tool/image_ops.py` | 页面检测、纠偏角度、无损裁切 |
| `backend/deskew_crop_tool/geometry_replay.py` | 重放 `qc_ops`（与 QC Platform 共用） |
| `backend/deskew_crop_tool/service.py` | 监督进程：启动监控器和 Web 控制台（默认端口 8090） |
| `backend/deskew_crop_tool/cloud_report.py` | 把完成的文件夹上报到 PostgreSQL |
| `backend/deskew_crop_tool/web/` | 控制台（HTML） |
| `backend/deskew_crop_tool/{tls,netlogin,lwcam_secrets,health}.py` | HTTPS 证书、网络文件夹登录凭据、DPAPI 机密、状态心跳 |
| `backend/tests/` | 单元测试 |
| `config/deskew_crop_config.example.json` | 配置示例 |
| `START_LWIP.bat` | 计划任务运行的脚本（监督进程和控制台） |
| `SETUP_DESKEW_CROP.bat`、`START_DESKEW_CROP.bat`、`RUN_TESTS.bat` | 源码检出环境下的辅助脚本（见下文） |

## 运行、构建、测试

LWIP 需要 Python 3.14，以及 `requirements.txt` 中的包（OpenCV、NumPy、Pillow 等）。无损裁切使用 `LWIP\tools` 中的 `jpegtran.exe`（不在 git 中，见 [docs/DEV-SETUP.md](../docs/DEV-SETUP.zh-CN.md)）。没有它时，页面会被重新编码。

从源码检出运行，使用你自己的 Python：

```bash
cd LWIP
python -m venv venv
venv\Scripts\python -m pip install -r requirements.txt
cd backend
..\venv\Scripts\python -m unittest discover -s tests -v
..\venv\Scripts\python -m deskew_crop_tool --config ..\config\deskew_crop_config.json --once
```

`__main__` 的选项：`--config <file>`、`--once`（处理已就绪的文件夹后退出）、`--wait`（与 `--once` 合用：先等文件夹稳定）、`--verbose`。

这些 `.bat` 文件需要 `runtime\python` 中的私有运行环境，它由 `SETUP_DESKEW_CROP.bat` 根据嵌入式 Python zip 和离线的 `wheels\` 文件夹构建（两者都随构建输入一起提供）。有了这个运行环境，`RUN_TESTS.bat` 运行测试，`START_DESKEW_CROP.bat` 启动监控器（`--once`、`--once --wait` 会透传）。

有两个长路径测试在部分 PC 上会失败。已知的失败项和基线见 [docs/TESTING.md](../docs/TESTING.zh-CN.md)。

同一个 `work_root` 只能由一个 orchestrator 使用。文件夹一次处理一个，最早的优先。

## 配置

把 `config/deskew_crop_config.example.json` 复制为 `config/deskew_crop_config.json` 再编辑。安装程序只写一次这个文件，升级时不会覆盖。每个键、默认值和检查规则都在 `backend/deskew_crop_tool/config.py` 里。

| 键 | 含义 |
| --- | --- |
| `input_root` | 存放任务的文件夹。`folder_depth` 为 1（默认）时，每个子目录是一个任务；为 2 时，每个孙目录是一个任务（`YYYYMMDD/<folder>`，即 LWCAM 的目录结构）。 |
| `output_root` | 完成的文件夹的存放位置，镜像输入的目录结构。不能是输入文件夹本身，也不能在其内部。输出先在输出卷上暂存，再整体切换进来。输入从不被修改或删除。 |
| `completion_marker` | 标记文件名，例如 `lwcam_capture_marker.json`（安装程序会设置）。只有标记存在且 `image_count` 达标，文件夹才算就绪。留空表示不使用标记。 |
| `stable_seconds`、`minimum_file_age_seconds` | 没有标记时：文件列表必须在这么长时间内保持不变，且最新的文件必须已存在这么久。 |
| `rework_settle_seconds` | 返工文件夹发生变化之后的等待时间（默认 30）。 |
| `crop_padding` | 页面周围保留的背景像素数（默认 200）。对于倾斜的页面，它是在摆正之后度量的。LWIP 会把加了边距的框映射回相机原始画面，所以旋转不会吃掉边距。页面超出照片的那一侧会被缩短。 |
| `deskew_min_degrees` | 低于该值时，倾斜角按 0 上报，也不记录操作（默认 0.5）。 |
| `mat_fill` | `true`（默认）：在预览和导出时，末尾的 `matfill` 操作用背景色填充旋转产生的角落。需要认识该操作的 QC Platform，请先升级 QC。 |
| `jpeg_quality` | 默认 100（4:4:4）。归档工作中不要调低。 |
| `thumbnail_width`、`thumbnail_quality`、`thumbnail_dirname` | `thumbnail_width` 为 0 表示不生成缩略图；否则 JPEG 缩略图写入 `<output>\thumbs\`。 |
| `workers` | 图像工作进程数。0 表示逻辑 CPU 数减一（最多 61）。处理 6144x8192 的 JPEG 时，每个工作进程可能占用约 0.5 GB。 |
| `state_file` | 已完成文件夹指纹的日志。指纹变化后，该文件夹会重新变为可处理。 |
| `presence_check_interval_seconds`、`checksum_check_interval_seconds` | 空闲时的审计：缺失或多余的文件（默认每个文件夹 300 秒）、输出的 SHA-256（默认每天一次）。发现坏文件会从源重新处理。 |
| `cloud_report`、`db_host`、`db_port`、`db_name`、`db_user`、`db_password`、`db_use_ssl` | 用于上报的 PostgreSQL 连接。安装程序会把 `cloud_report` 设为 true。开启后，缺少主机、用户或密码会让启动中止，并给出明确提示。 |
| `ui_bind`、`ui_port`、`tls_cert_file`、`tls_key_file` | 控制台地址（端口 8090）。安装程序会填好证书文件。 |

输出是如何写出的：

- 找到页面的 JPEG，通过 `jpegtran` 的无损裁剪重新写出。其他所有文件（PNG、TIFF、BMP、JPEG XL，或没找到页面的 JPEG）都按源文件的原始字节交付，其裁切、纠偏和 matfill 以整幅源画面为基准记录在 `qc_ops` 中。EXIF 方向不是 1 的文件会被解码并重新编码。`.jxl` 需要可选的 `pillow-jxl-plugin` 包。
- 页面检测使用 OpenCV 的 Triangle 阈值。Otsu 会把装订成册的书的深色封面板算进背景，损失边距和角度的精度。
- 每个输出文件先写入临时文件，刷新到磁盘，再重命名。清单文件记录每个输出的路径、大小和 SHA-256。
- 只有每个文件和清单文件都通过大小检查后，文件夹才会被发布。恢复过程中输入保持只读。

## 控制台

`START_LWIP.bat` 运行 `deskew_crop_tool.service`。它以子进程方式启动监控器，并在 `https://<pc-name>:8090/` 提供一个小型 Web 控制台（`ui_port`、`ui_bind`）。即使监控器的配置有误，控制台也保持运行，这样可以在浏览器里修正。

- 用共享 PostgreSQL `users` 表中的 Admin 或 SuperAdmin 账号登录。只有 QC 角色的账号不能登录。
- 数据库不可达时，控制台为只读。同一台 PC 上的浏览器可以查看状态和日志。曾经登录过的管理员可以通过保存的名单登录（配置旁边的 `admin_cache.json`）。
- 保存 Settings 会用新值重启监控器。
- "Network folder logins"（网络文件夹登录凭据）保存本 PC 访问另一台 PC 上共享文件夹所用的账号。见 [installer/README.md](../installer/README.zh-CN.md)。
- `db_password` 加密存储（`dpapi:...`，Windows DPAPI，与 PC 绑定）。把文件复制到另一台 PC 时需要重新输入。
- 控制台只支持 HTTPS。见 [installer/README.md](../installer/README.zh-CN.md) 中的 "HTTPS"。

本服务会向 QC 控制台的 System status 页面上报状态。如果数据库或 QC 所在 PC 关机，LWIP 会继续处理，稍后再上报。如果数据库结构（schema）比本程序要求的旧，LWIP 不做任何数据库操作，并给出提示。请先升级数据库所在 PC。

## 安装后的目录与停止方式

`LWIPSetup.exe` 安装到 `%ProgramFiles%\LWCam LWIP`。计划任务 "LWCam LWIP" 在开机时以 SYSTEM 身份运行 `START_LWIP.bat`。日志在 `logs\service.log`。要干净地停止服务，创建文件 `%ProgramData%\LWCAM\lwip.stop`。LWIP 会在发布完当前文件夹之后退出，约 90 秒之内。安装程序对 PC 做了哪些改动，见 [installer/README.md](../installer/README.zh-CN.md)。

## 接下来读什么

- [../docs/ARCHITECTURE.md](../docs/ARCHITECTURE.zh-CN.md)：LWIP 与其他部分如何配合。
- [../installer/README.md](../installer/README.zh-CN.md)：LWIP 安装程序及其参数。
- [../LWCam_QC_Platform/README.md](../LWCam_QC_Platform/README.zh-CN.md)：读取 LWIP 输出的应用。
- LWIP 没有单独的 `AGENTS.md`，工作区指南是 [../AGENTS.md](../AGENTS.md)。
