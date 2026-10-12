[English](DEV-SETUP.md) | 简体中文

# 开发环境搭建

本指南带你从一台全新的 Windows PC 出发，把各个模块都从源码跑起来。测试请参阅 [TESTING.zh-CN.md](TESTING.zh-CN.md)，安装程序请参阅 [RELEASING.zh-CN.md](RELEASING.zh-CN.md)，术语请参阅 [GLOSSARY.md](GLOSSARY.md)。

## 1. 工具链

| 工具 | 版本 | 用途 |
| --- | --- | --- |
| Windows | 64 位 Windows 10 或 11 | 所有环节。LWCAM、LWCam Admin 和安装程序都只支持 Windows。 |
| Git | 任意较新版本 | 源码管理 |
| Flutter / Dart | 需要 Dart `^3.8.1` 或更新版本（两个 `pubspec.yaml` 都有此要求）。最近一次验证过的工具链是 Flutter 3.47.0 配 Dart 3.13.0。 | LWCAM、LWCam Admin |
| Visual Studio 2022 | "Desktop development with C++" 工作负载 | `flutter build windows` |
| Python | 3.14.8（64 位）。安装程序内置 3.14.8 的 embeddable zip。 | QC 后端、LWIP、Upload、安装脚本 |
| Node.js 和 npm | 较新的发行版。最近一次验证过的版本是 Node 26.1.0。 | QC 前端（Vue 3、Vite 6、TypeScript 5.6） |
| Inno Setup | 6 | 构建安装程序（`ISCC.exe`） |
| PostgreSQL | 18（内置的安装文件是 `postgresql-18.*-windows-x64.exe`） | 数据库 |

Python 依赖包（所有模块）：见 `LWCam_QC_Platform/backend/requirements.txt`、`LWIP/requirements.txt` 和 `LWCam_Upload/requirements.txt`。后两个文件固定了精确版本（例如 `psycopg[binary]==3.3.4`、`bcrypt==5.0.0`、`cryptography==50.0.1`、`boto3==1.43.88`），QC 后端的文件则只写最低版本。

测试套件使用 `unittest`，不需要 pytest。

## 2. 获取源码

```
git clone https://github.com/djchoy-LW/LWCAM-Suite.git
cd LWCAM-Suite
```

默认分支是 `lwcam-module`。如需一体版，运行 `git switch lwcam-all-in-one`，该版本的目录结构不同。本指南描述的是模块版。

## 3. 获取构建输入文件

部分文件对 git 来说太大，存放在名为 `build-inputs` 的私有 GitHub Release 中。下载其中的资源，并运行发布版本自带的解包脚本，然后确认以下路径存在（它们都被 git 忽略）：

| 路径 | 内容 |
| --- | --- |
| `installer/vendor/python-3.14.8-embed-amd64.zip` | Python embeddable zip |
| `installer/vendor/vcruntime/` | Visual C++ 运行库 DLL（`msvcp140.dll`、`vcruntime140.dll`、`vcruntime140_1.dll`） |
| `installer/vendor/adb/` | `adb.exe`、`AdbWinApi.dll`、`AdbWinUsbApi.dll` |
| `installer/vendor/postgresql/` | PostgreSQL 18 安装文件 |
| `LWCAM/scrcpy/` | scrcpy 的 Windows 构建（包含 `scrcpy.exe`） |
| `LWIP/tools/` | `jpegtran.exe` |
| `LWIP/wheels/` | LWIP 的离线 wheel 包（Database 安装程序也会用到） |
| `LWCam_QC_Platform/backend/wheels/` | QC 后端的离线 wheel 包 |
| `LWCam_Upload/wheels/` | Upload 的离线 wheel 包 |

只有构建安装程序，以及（adb 和 scrcpy 部分）运行 LWCAM 时才需要这些文件。运行 Python 模块或测试，只需 `pip install -r requirements.txt`。

示例图像不在仓库中，请向项目负责人（Jackson Choy，jackson.choy@lifewood.com）索取。

## 4. 本地 PostgreSQL 与数据库结构

1. 安装 PostgreSQL 18（运行内置安装程序，或使用已有服务器），记下 `postgres` 的密码。
2. 为数据库结构脚本写一个小文件 `setup.txt`（不要提交到 git）。它保存 PostgreSQL 管理员的登录信息，每行一个 `key = value`：

```
dbHost = localhost
dbPort = 5432
dbName = lwcam
dbUser = postgres
dbPassword = <postgres 用户的密码>
```

3. 在 `LWCam_QC_Platform` 目录下运行：

```
python scripts\setup_qc_db.py --server-config setup.txt --app-login lwcam_user
```

该脚本会在数据库不存在时创建它，在空数据库上加载统一的数据库结构，按文件名顺序应用 `database/migrations/` 中的每个迁移脚本，并把每一个记录到 `schema_migrations` 中。可以安全地重复运行。

`--app-login <name>` 会创建所有部分共用的那个账号。脚本从环境变量 `LWCAM_APP_PASSWORD` 读取其密码（绝不从命令行读取），密码至少 12 个字符。在开发用 PC 上，请先设置它：

```
set LWCAM_APP_PASSWORD=<a-password-of-12-or-more-characters>
```

然后把同一个账号填入每个模块的配置文件（第 5 节）。已安装的 Database 安装程序运行的是同一个脚本。其他选项（`--open-lan`、`--close-lan`、`--database-dir`）请运行 `python scripts\setup_qc_db.py --help` 查看。

## 5. 配置文件

每个模块都有一个 `*.example` 文件：复制它，去掉 `.example` 后缀，再填写。真实的配置文件已被 git 忽略，切勿提交。

| 复制 | 到 | 需要填写 |
| --- | --- | --- |
| `LWCam_QC_Platform/config.example.txt` | `LWCam_QC_Platform/config.txt` | `dbHost`、`dbPort`、`dbName`、`dbUser`、`dbPassword`。`jwtSecret`：32 个或更多随机字符（可用 `python -c "import secrets; print(secrets.token_urlsafe(48))"` 生成）。`qcInputRoot`、`exportWorkRoot`、`qcOutputRoot`：三个互相独立的本地文件夹。开发时 `bindHost = 127.0.0.1` 和 `port = 8080` 即可。 |
| `LWIP/config/deskew_crop_config.example.json` | `LWIP/config/deskew_crop_config.json` | `input_root`、`output_root`。若要向数据库上报：`cloud_report: true` 以及 `db_*` 各项。 |
| `LWCam_Upload/config/upload_config.example.json` | `LWCam_Upload/config/upload_config.json` | `watch_root`、`done_root`、`summary_root`、`s3_*` 各项、`db_*` 各项。 |
| `LWCAM/lwcam_node_config.example.json` | `%USERPROFILE%\LWCAM_DBs` 中的 `lwcam_node_config.json`（或使用 LWCam Admin 的 Station Setup） | `pg*` 各项、`destinationPath`。 |

说明：

- 使用真实的文件夹路径。使用 UNC 路径或本地磁盘，绝不要使用映射的盘符。
- 开发配置中的密码可以是明文。运行中的服务会在首次启动时将其加密（变为 `dpapi:` 值），这些值只在当前这台 PC 上有效。
- QC 服务器从 `LWCam_QC_Platform/config.txt` 读取配置，或读取环境变量 `LWCAM_QC_SERVER_CONFIG` 指定的文件。它不会读取 LWCAM 的 `lwcam_node_config.json`。
- LWCAM 和 LWCam Admin 共用同一个 `lwcam_node_config.json`。最简单的写入方式是 LWCam Admin 的 Station Setup 页面。
- `db_*` 和 `pg*` 各项使用第 4 节中的共用账号。

## 6. 从源码运行各模块

### QC 后端

```
cd LWCam_QC_Platform\backend
pip install -r requirements.txt
python run_server.py
```

请使用 `run_server.py`，**不要**使用 `python -m app.main`（见"已知陷阱"）。服务器读取 `config.txt`，并监听其中的 `port`（8080）。`run_server.py` 会打印它所服务的是哪一棵代码树。

### QC 前端

```
cd LWCam_QC_Platform\frontend
npm ci
npm run dev        # Vite dev server on port 5174, proxies /api to http://localhost:8080
npm run build      # vue-tsc --noEmit && vite build, output in dist/
```

设置 `VITE_API_TARGET` 可以代理到另一个后端。后端会提供 `frontend/dist`，所以先运行一次 `npm run build`，就可以通过后端自己的地址使用控制台（配置了 TLS 时为 `https://` 地址）。

使用数据库中已存在的 Admin 或 SuperAdmin 账号登录，账号在 LWCam Admin 中创建。

### LWIP

```
cd LWIP\backend
python -m deskew_crop_tool.service --config ..\config\deskew_crop_config.json
```

这会运行监督进程和控制台（端口 8090，来自 `ui_port`）。请先安装依赖包：`pip install -r LWIP\requirements.txt`。详情见 `LWIP\README.md`。

### Upload

```
cd LWCam_Upload\backend
python -m lwcam_upload --config ..\config\upload_config.json
```

控制台在 8091 端口（`ui_port`）。请先安装依赖包：`pip install -r LWCam_Upload\requirements.txt`。

### LWCAM 和 LWCam Admin

```
cd LWCamAdmin
flutter pub get
flutter run -d windows

cd ..\LWCAM
flutter pub get
flutter run -d windows
```

开发构建的 LWCAM 找不到位于已构建 exe 旁边的工具，请按下表提供：

| 工具 | 做法 |
| --- | --- |
| `adb.exe`、`AdbWinApi.dll`、`AdbWinUsbApi.dll` | 复制到 `LWCAM\build\windows\x64\runner\Debug\`（或 Release 文件夹），或者把 `adb` 加入 PATH。 |
| scrcpy | 把 Windows 构建放到 `LWCAM\scrcpy`（应用会在 exe 上方最多 7 层文件夹中查找 `scrcpy\scrcpy.exe`）。 |

没有 adb，采集无法工作（无法裁切、无法拍照、没有图像）。`flutter clean` 会删除复制进去的文件。

## 7. 没有相机时制造测试文件夹

`LWCam_QC_Platform/scripts/reset_test_folder.py <folder_id>` 会把一个已通过或已导出的文件夹放回 QC 队列，状态变回 PENDING。它根据 LWCAM 的本地 SQLite 文件（`%USERPROFILE%\LWCAM_DBs\lwcam_stats_<device>.db`）重建数据库行，并在 `1.Images` 上重新运行 LWIP。

如果没有相机，也没有 `1.Images`，请把一个已完成的 LWIP 输出文件夹复制到 `qcInputRoot`，然后运行：

```
python scripts\reset_test_folder.py <folder_id> --skip-lwip --yes --batch-dir "<folder under qcInputRoot>"
```

`--skip-lwip` 保持批次输出原样，只重建数据库行。当数据库记录的是另一个路径时，用 `--batch-dir` 指定文件夹。最后一行 "every row resolves to a file" 表示该文件夹可用。这需要已经存在一条文件夹记录（由之前的某次采集生成）。其余选项请运行 `python scripts\reset_test_folder.py --help` 查看。

示例图像请向项目负责人索取。

## 8. 已知陷阱

| 陷阱 | 处理办法 |
| --- | --- |
| **`._pth` 陷阱。** 随安装程序分发的（embeddable）运行时带有 `python314._pth`。它把 `sys.path` 固定为已安装的后端，忽略 `PYTHONPATH`，也不会加入当前文件夹。在已安装 QC 服务器的 PC 上，`python -m app.main` 会悄悄启动已安装的那一份，或者无输出直接退出。 | 用 `python run_server.py` 启动 QC。在任何临时脚本中，先执行 `sys.path.insert(0, ".")`，并用 `print(module.__file__)` 确认加载的是哪一份。`python -m unittest discover -s tests -t .` 是安全的。 |
| **用户 site-packages 泄漏。** 私有运行时可能导入运行安装程序的那个用户自己的 Python 的包，导致 pip 跳过某些包，运行时随之损坏。 | 每个运行私有运行时的脚本都会设置 `PYTHONNOUSERSITE=1`。手工运行这些运行时时也请设置它。 |
| **混用的换行符。** `.gitattributes` 设置了 `* -text`，git 不做任何转换，有些文件是 CRLF，有些是 LF。重写整个文件的工具可能改动每一行。 | 编辑前先检查文件风格（`file <path>`），保持每个文件原有的风格。对 CRLF 文件请使用编辑器，不要用 `sed -i`。提交前检查 `git diff --stat`。 |
| **长路径。** 文件夹名来自操作员输入，可能很长。超过 260 个字符后，Windows 会报一个普通的 "file not found"。LWIP 为此使用 `\\?\` 前缀（`fs_path`）。 | 让你的克隆路径保持简短。在新的 LWIP 文件操作代码中使用 `fs_path`。PC 是否启用长路径支持，会改变两个 LWIP 测试的结果（见 [TESTING.zh-CN.md](TESTING.zh-CN.md)）。 |
| **安装程序中的过期构建。** 安装程序打包的是 LWCAM 和 LWCam Admin 的 Release 构建。 | 构建安装程序之前，先用 `flutter build windows --release` 重新构建这两者。 |
| **映射的盘符。** 服务以 SYSTEM 身份运行。 | 所有文件夹设置都使用 UNC 路径或本地磁盘。 |
| **Debug 构建的时间戳。** 只改 Dart 代码后，debug 版 exe 的时间不会更新。 | 改为检查 `data/flutter_assets/kernel_blob.bin`。 |
