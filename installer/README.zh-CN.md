# LWCam 安装程序

[English](README.md) | 简体中文

本文件夹负责从源码树构建五个 Windows 安装程序（Inno Setup 6）。本文件是安装程序的参考手册：每个安装程序包含什么、向导会问什么、静默安装参数、各自会改动 PC 上的哪些内容，以及升级和卸载的行为。

| 需求 | 阅读 |
| --- | --- |
| 在现场逐步安装 LWCam | [../docs/INSTALL.zh-CN.md](../docs/INSTALL.zh-CN.md) |
| 制作发布版本、准备构建输入文件、发布 | [../docs/RELEASING.zh-CN.md](../docs/RELEASING.zh-CN.md) |
| 搭建开发用 PC | [../docs/DEV-SETUP.zh-CN.md](../docs/DEV-SETUP.zh-CN.md) |

## 五个安装程序

| 安装程序 | 安装内容 | 运行方式 |
| --- | --- | --- |
| `LWCamDatabaseSetup.exe` | PostgreSQL 18（或使用已有服务器）、LWCam 数据库结构（schema）、共用账号、局域网访问、每晚备份 | PostgreSQL 服务，计划任务 "LWCam Database Backup" |
| `QCPlatformSetup.exe` | QC 服务器（FastAPI）和已构建的 Vue 控制台 | 计划任务 "LWCam QC Server"（SYSTEM，开机启动），端口 8080 |
| `LWIPSetup.exe` | LWIP 图像处理及其控制台 | 计划任务 "LWCam LWIP"（SYSTEM，开机启动），端口 8090 |
| `LWCamUploadSetup.exe` | 上传服务（S3）及其控制台 | 计划任务 "LWCam Upload"（SYSTEM，开机启动），端口 8091 |
| `LWCamSetup.exe` | LWCAM 采集应用和 LWCam Admin，用于采集 PC | 桌面应用 |

默认安装文件夹：`%ProgramFiles%\LWCam Database`、`LWCam QC Platform`、`LWCam LWIP`、`LWCam Upload`、`LWCam`。

安装顺序：先装数据库（一次），然后装 QC、LWIP 和 Upload（各一次，顺序不限，装在各自的 PC 上），最后在每台采集 PC 上装 `LWCamSetup`。每个部分都需要数据库的主机、端口、名称、用户和密码（一个共用账号，见下文）。QC 和 LWCam Admin 还需要 LWIP 的输出文件夹，Upload 需要 QC 的导出文件夹。这些部分不必放在同一台 PC 上，任何一个停机都不会影响其他部分。

每个部分都会检查数据库结构级别（数据库 `schema_migrations` 表中的最大编号），并拒绝在更旧的数据库上工作。要求的级别：QC 服务器为 8，LWCAM、LWIP 和 Upload 为 7。因此升级时，要先在数据库 PC 上运行 `LWCamDatabaseSetup`，再升级其他部分。

PostgreSQL 安装程序是单独的文件。请把 `postgresql-18.*-windows-x64.exe` 放在 `LWCamDatabaseSetup.exe` 旁边。已经装有 PostgreSQL 的 PC 只需要安装程序本身。

## 构建

你需要 Inno Setup 6、LWCAM 和 LWCam Admin 的 Flutter Windows Release 构建、带 npm 的 Node.js，以及下文列出的构建输入文件。这些输入文件不在 git 中，获取方式见 [../docs/RELEASING.zh-CN.md](../docs/RELEASING.zh-CN.md)。

```powershell
cd ..\LWCAM      ; flutter build windows --release
cd ..\LWCamAdmin ; flutter build windows --release
cd ..\installer
.\build-installer.ps1 -Target All        # or Database, QC, LWIP, Upload, LWCam
```

`build-installer.ps1` 的选项：

| 选项 | 含义 |
| --- | --- |
| `-Target` | `Database`、`QC`、`LWIP`、`Upload`、`LWCam` 或 `All`（默认） |
| `-ResolveOnly` | 打印选定的 `ISCC` 和 `scrcpy` 路径，不构建任何东西。 |
| `-ScrcpyDir <path>` | 为 LWCam 目标使用这个 scrcpy 构建。默认情况下，若 `LWCAM\scrcpy` 中有 `scrcpy.exe` 就用它，否则使用已安装的 scrcpy 软件包。 |
| `-UpdateChecksums` | 为所有目标重写 `SHA256SUMS.txt`，然后退出 |

QC 目标会先在 `LWCam_QC_Platform\frontend` 中运行 `npm ci`（当 `package-lock.json` 存在时）和 `npm run build`。Database 目标会把最新准备好的 `postgresql-18.*-windows-x64.exe` 复制到 `LWCamDatabaseSetup.exe` 旁边。输出文件位于仓库根目录。脚本不会运行安装程序。

**版本。** 仓库根目录中只有一行的 `VERSION` 文件（例如 `1.1.0`）加上简短的 git 提交号，组成 `<version>+<commit>`。从未提交的工作树构建时会追加 `-dirty`。脚本把它们以 `/DAppVer` 和 `/DBuildId` 传给每一次 `ISCC` 运行。每个安装程序会把 `VERSION.txt` 写入自己的安装文件夹。发布时请手工修改 `VERSION`。脚本为此写入 `installer\vendor\VERSION.txt`；如果你直接用 `ISCC` 编译某个 `.iss` 文件，这个文件必须已经存在。

### 构建输入文件（不在 git 中）

```
installer\vendor\python-3.14.8-embed-amd64.zip   嵌入式 Python
installer\vendor\vcruntime\                      Visual C++ 运行库 DLL
installer\vendor\adb\                            adb.exe 及其两个依赖 DLL
installer\vendor\postgresql\                     PostgreSQL 18 安装程序
LWCAM\scrcpy\                                    scrcpy Windows 版
LWIP\tools\                                      jpegtran.exe, jpeg8.dll
LWIP\wheels\                                     LWIP 离线依赖包（也包括数据库安装程序
                                                 所需的 pip、psycopg 和 tzdata）
LWCam_QC_Platform\backend\wheels\                QC 离线依赖包
LWCam_QC_Platform\frontend\dist\                 由 QC 构建目标生成
LWCam_Upload\wheels\                             Upload 离线依赖包
```

每个服务都用 `--no-index` 从 embeddable zip 和自己的 wheel 文件夹安装私有的 Python 运行时。缺少任何一个 wheel，安装就会失败，不会退回到联网下载。

`installer\SHA256SUMS.txt` 固定了所有不是由我们自己的源码构建出来的输入文件：Python zip、`vcruntime`、`adb`、PostgreSQL 安装程序、scrcpy、`LWIP\tools` 以及三个 wheel 文件夹。每个文件一行：`<sha256>  <path from the repo root>`，按路径排序，使用 LF 换行。`build-installer.ps1` 在构建之前会对所选目标的输入文件计算哈希，只要有文件发生变化、缺失或未列入清单，就以退出码 1 停止。在有意的变更（新的 wheel、新的 `adb`）之后，运行 `.\build-installer.ps1 -UpdateChecksums` 并提交该文件。Flutter 构建产物、`frontend\dist` 和 `vendor\VERSION.txt` 不在清单中。

### 安装程序源文件

| 文件 | 用途 |
| --- | --- |
| `Database.iss`、`QCPlatform.iss`、`LWIP.iss`、`Upload.iss`、`LWCam.iss` | 每个安装程序一个脚本 |
| `common.iss` | 所有脚本共用的辅助函数（`PythonProcessesUnder`、`RestrictToAdmins`） |
| `postgres.iss` | PostgreSQL 的检测、安装和恢复。仅被 `Database.iss` 引入。 |
| `build-installer.ps1` | 输入文件检查、前端构建、`ISCC` 编译、复制附带文件 |
| `db\` | `SETUP_DB_RUNTIME.bat`、`SETUP_DATABASE.bat`（根据 `config\database.txt` 建立数据库结构）、`BACKUP_DATABASE.bat`、`RESTORE_DATABASE.bat`、`backup_db.py` |
| `qc\` | `SETUP_QC.bat`（QC 运行时）、`START_QC_SERVER.bat`、`OPEN_QC_LOG.bat` |
| `Trust this LWCam server.cmd` | 复制到每台服务器的安装文件夹，用于浏览器信任步骤 |

`START_QC_SERVER.bat` 有意不接受任何参数，主机地址来自 `config.txt`。

## 各安装程序的内容与改动

### LWCamDatabaseSetup.exe

- 安装 PostgreSQL 18，除非已有服务器，或勾选了任务 "Use an existing PostgreSQL server"。
- 创建或升级数据库结构（运行 `scripts/setup_qc_db.py`，并应用 `database\migrations` 中的每个迁移脚本）。
- 创建那一个共用账号（见"数据库账号"）。
- 在勾选了任务 "Allow other PCs on this network (and Tailscale) to connect" 且数据库在本机时：设置 `listen_addresses`，添加 `pg_hba.conf` 条目，并为每种网络类型添加防火墙规则 "LWCam Database"，范围仅限本地子网和 Tailscale。它还会设置 TCP keepalive（空闲 60 秒、间隔 10 秒、重试 6 次），使数据库能在 2 到 3 分钟内清理掉已断开的客户端会话及其锁。以后再次运行时取消勾选该任务，会移除这些条目和规则。
- 任何改动之前，`pg_hba.conf` 会先复制为 `pg_hba.conf.bak-<time>`。只有拥有该数据文件夹的那个 PostgreSQL 服务会被重启，并且只在 `listen_addresses` 发生变化时才重启。
- 写入 `config\database.txt`（用于安装和备份的 PostgreSQL 管理员账号，加上共用账号）。该文件夹仅限 SYSTEM 和 Administrators 访问。此前卸载时保留下来的 `database.txt` 会被复用；但如果这次运行中重装了 PostgreSQL 本身，则旧文件会改名为 `database.txt.bak-<time>`，并写入一个新文件。
- 锁定程序文件夹（Administrators 和 SYSTEM 可写，其他人只读），然后注册备份任务。如果锁定失败，则不注册该任务，完成页会说明这一点。
- 在完成页上显示主机、端口、数据库、用户，以及你输入的密码。
- 当 `setup_qc_db.py` 拒绝某项操作时，完成页会显示其消息，安装以 "needs attention" 结束。同样的文字也是 `logs\database-setup.log` 的最后一条 `[ERROR]` 行。拒绝不会改动任何东西。典型原因：规则不接受的 `--app-login`（换一个用户或密码再运行），或者因为站点繁忙而出现 "lock timeout"（再运行一次）。
- 卸载时绝不会删除 PostgreSQL 或其数据，因为其他应用可能也在使用它。

**备份。** 向导中有一页询问备份文件夹以及保留多少份备份（默认 14）。如果 PC 有 D: 硬盘，文件夹默认为 `D:\LWCam Backups`，否则为 `C:\ProgramData\LWCam\Backups`。安装程序会拒绝驱动器根目录、`C:\Windows`、Program Files、ProgramData、`C:\Users` 以及任何已存放其他文件的文件夹。如果文件夹与 PostgreSQL 在同一个驱动器上，它会给出警告。网络共享写成 `\\server\share`。任务以 SYSTEM 运行，因此会以这台 PC 的计算机账户（`DOMAIN\PCNAME$`）访问共享，请给该账户写入权限。映射的盘符会被拒绝。本地备份文件夹会被锁定为仅 SYSTEM 和 Administrators 可访问，因为备份中含有每个账号的哈希。计划任务 "LWCam Database Backup" 每天 02:00 以 SYSTEM 身份运行 `BACKUP_DATABASE.bat`。它写出 `lwcam-YYYYMMDD-HHMM.dump`（PostgreSQL 自定义格式）和 `lwcam-globals-YYYYMMDD-HHMM.sql`（`pg_dumpall --globals-only`：角色及其密码哈希），并删除两类文件中超出保留数量的最旧文件。某天夜里失败时会重试 3 次，间隔 10 分钟。结果写入 `logs\backup.log` 和 `service_heartbeat` 表（部件 `backup`）。设置在 `config\backup.txt` 中（`backupDir`、`backupKeep`）。恢复和重建的步骤见 [../docs/INSTALL.zh-CN.md](../docs/INSTALL.zh-CN.md)（备份与恢复）。备份未加密，请妥善保管该文件夹，不要公开。

**数据库账号。** 每个部分都用同一个账号连接。"LWCam database login" 页面会询问数据库名称（默认 `lwcam`）、端口（默认 5432，或已保存的、已有服务器的端口；1024 到 65535）、用户（默认 `lwcam_user`）以及至少 12 个字符的密码（输入两次）。名称须符合 `[a-z_][a-z0-9_]{0,62}`，`postgres` 和 `lwcam_app` 会被拒绝。该用户是组角色 `lwcam_app` 的普通成员。迁移脚本 006 和 008 给这个组恰好授予各部分所需的权限（列级 `UPDATE`；没有 `CREATE`；没有超级用户、`CREATEDB` 或 `CREATEROLE`；导出序列只有 `USAGE`）。请在 `QCPlatformSetup`、`LWIPSetup`、`LWCamUploadSetup` 中，以及每台采集 PC 上 LWCam Admin 的 Station Setup 中填入相同的值。

权衡：所有部分共用一个密码，所以密码泄露后，可以从数据库允许的任何网络读取并修改 LWCam 的表。但它不能在数据库 PC 上运行程序、创建表或删除数据库。要修改密码，请用新密码再次运行 `LWCamDatabaseSetup`，然后更新每个部分。再次运行时，页面会用 `database.txt` 预填。把两个密码框都留空即可保留已保存的密码。在已有服务器上修改端口并不会移动 PostgreSQL，只是改变了防火墙规则和各部分被告知的值。

密码绝不会出现在命令行上。安装程序在运行 `SETUP_DATABASE.bat` 期间，把密码放入自己进程的环境变量 `LWCAM_APP_PASSWORD` 中，运行结束后清除。（静默安装在命令行上使用 `/APPPASSWORD=`，见"无人值守安装"。）

从其他 PC 连接时，只有 `lwcam_app` 的成员才能连接（`pg_hba.conf`）。他们通过 TLS（`hostssl`）连接到配置的数据库，来源限于本地子网和 Tailscale 网段（`100.64.0.0/10`、`fd7a:115c:a1e0::/48`）。位于其他网络且不在 Tailscale 上的 PC 不被放行。请让它加入 Tailscale，或者手工添加一行 `hostssl <database> +lwcam_app <address>/32 scram-sha-256`。

勾选 "Allow other PCs" 时，安装程序会移除旧的 `host all all samenet` 规则，除非 `postgres` 或 `lwcam_app` 之外的某个账号仍从另一台 PC 连接着。此时它保留该规则，安装仍然成功，并打印一行 `[NOTE]`，指出是谁在连接。请把这些部分切换到共用账号，然后再次运行安装程序。范围更宽的非 TLS 行只会在日志中给出警告。较早的五个分部件账号（`lwcam_qc`、`lwcam_lwip`、`lwcam_upload`、`lwcam_capture`、`lwcam_admin`），如果存在，会成为 `lwcam_app` 的成员，因此仍在使用其中某一个的部分可以继续工作。

### QCPlatformSetup.exe

- 安装后端、已构建的 Vue 控制台和离线的 Python 运行时。
- 询问数据库主机、端口、名称、用户和密码。数据库必须已经存在，本安装程序不会创建数据库。
- 仅在全新安装时写入 `config\config.txt`。`config\` 文件夹仅限 SYSTEM 和 Administrators 访问，其中保存着数据库密码和登录密钥；在控制台中保存设置时会写出一个新文件，它沿用该文件夹的权限。安装的其余部分保持 Program Files 的默认权限。
- 创建计划任务 "LWCam QC Server"（SYSTEM，开机启动），并为配置的端口（默认 8080）替换防火墙规则 "LWCam QC Server"，适用于每种网络类型，仅对本地子网和 Tailscale 开放。然后启动该任务。
- 控制台地址为 `https://<pc-name>:8080/`。在分离部署的站点上，请把 `qcInputRoot`（在 `config.txt` 或控制台的 Settings 中）设为与 LWIP 写入的相同 UNC 路径。

### LWIPSetup.exe

- 安装 LWIP，附带它自己的离线 Python 运行时和计划任务 "LWCam LWIP"（SYSTEM，开机启动）。
- 询问输入文件夹（LWCAM 复制完成采集的位置）、输出文件夹（QC 服务器读取的位置），然后是数据库连接。升级时，只要 `config\deskew_crop_config.json` 已存在，就会跳过文件夹页面和数据库页面。
- 两个文件夹都会拒绝映射的盘符，因为 SYSTEM 看不到在用户会话中映射的驱动器。请使用 UNC 路径或本地固定磁盘。
- 在 8090 端口（`ui_port`）上通过 HTTPS 提供控制台。开始菜单中的 "LWIP Console" 快捷方式会打开它。"LWCam LWIP" 防火墙规则对本地子网和 Tailscale 开放该端口。使用 Admin 或 SuperAdmin 账号登录。如果数据库不可达，控制台为只读。
- 接管旧版 LWIP 已处理过的文件夹：停止服务，把旧的日志文件复制到 `{app}\runtime\state.json`，再启动服务。只有 `input_root` 与之前的路径字符串完全相同时才能匹配。没有该日志文件时，LWIP 会重新接管每个页面仍与其清单文件（manifest）一致的已完成文件夹；页面文件此后发生过变化的文件夹（例如 QC 替换了页面），会从原始图片重新处理。
- 用文件 `%ProgramData%\LWCAM\lwip.stop` 来停止它，它会在大约 90 秒内退出。

### LWCamUploadSetup.exe

- 安装 Upload，附带它自己的离线 Python 运行时和计划任务 "LWCam Upload"（SYSTEM，开机启动）。
- 询问监控文件夹（QC 的 `qcOutputRoot`）、Uploaded 文件夹和 Upload Reports 文件夹（`Upload_Summary.db3` 存放的位置）。向导需要这三个全部填写，因为 Inno 的文件夹页面不接受空路径。后两个可以稍后在控制台中清空。然后询问 S3 目标（`s3://bucket/prefix`、区域、访问密钥、私有密钥）和数据库连接。升级时，只要 `config\upload_config.json` 已存在，这三页就会被跳过。
- 三个文件夹都会拒绝映射的盘符。
- 在 8091 端口提供控制台。"Upload Console" 快捷方式和 "LWCam Upload" 防火墙规则的作用与 LWIP 相同。数据库账号只用于控制台登录和状态；S3 上传使用访问密钥和私有密钥。
- 设置会在每次扫描开始时重新读取，所以在控制台中保存设置后无需重启。

### LWCamSetup.exe

- 只安装 LWCAM 和 LWCam Admin，不含 LWIP，也不含 PostgreSQL。
- 没有产品专用参数，也没有数据库或文件夹页面。安装完成后，打开 LWCam Admin，用其他安装程序显示的值完成 Station Setup，然后点击 Save。
- 它沿用原来的 AppId，所以较早的一体版工位可以原地升级。在这样的升级中，它会停止并移除 `{app}\LWCAM\LWIP` 下的旧 LWIP 和旧的一体版 QC 引擎，并删除旧的按用户登录启动的 LWIP 启动项。已有的采集数据保持原样。

## 服务、锁定、升级与卸载

- 三个服务（QC、LWIP、Upload）都是没有运行时限的计划任务。任务计划程序会每分钟重启一次失败的任务。每个 `START_*.bat` 会在崩溃的程序退出 30 秒后重启它（退出码 0 表示有意停止，因此不重启）。
- 凡是运行后台进程的安装程序，在替换任何文件之前都会先停止该进程，停不下来就弹出消息并中止。它会先结束任务，以免重启循环把停止操作抵消掉。
- QC、LWIP 和 Upload 会锁定自己的安装文件夹。LWIP 和 LWCam 还会锁定 `%ProgramData%\LWCAM`，其中存放共享的停止文件。Administrators 和 SYSTEM 可写，其他用户只读。每个 `config\` 文件夹保留更严格的权限列表。
- 卸载会保留无法重建的内容：LWIP 的 `runtime\state.json`（及其 `.bak`，即已处理文件夹的列表，使重装后不会覆盖 QC 的编辑而重新处理这些文件夹）、Upload 的 `runtime\uploads.json`（已发送交付包的列表，使重装后不会重复发送），以及 LWCamDatabaseSetup 的 `config\database.txt`。重装时三者都会被复用。若要彻底重新开始，请手工删除安装文件夹。
- 多 PC 站点的升级顺序、备份与回滚：[../docs/INSTALL.zh-CN.md](../docs/INSTALL.zh-CN.md)（升级）。

## 无人值守安装

所有安装程序都支持 Inno Setup 的标准开关：

```
Setup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG="C:\logs\x.log" /PARAM=value ...
```

`/VERYSILENT` 隐藏向导。`/SUPPRESSMSGBOXES` 用默认选项应答消息框。`/NORESTART` 阻止重启。`/LOG` 写出的是无人值守运行过程的唯一记录。参数名不区分大小写。

静默运行时，每个自定义页面的值都取自参数，并以与向导相同的方式、相同的措辞进行校验。缺少必填值或值无效，安装会在写入任何文件之前失败（Setup 退出码 7）。向导会跳过的页面（升级，且其配置已存在；全新本地 PostgreSQL 安装且没有 `/TASKS=remotedb` 时的数据库页面）在静默安装中同样会被跳过，其参数会被忽略。

示例和参数（在 `cmd` 中用 `^` 作为续行符）：

```
LWCamDatabaseSetup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART ^
  /LOG="C:\logs\db.log" /TASKS="openlan" /APPUSER=lwcam_user /APPPASSWORD=<password>

LWCamDatabaseSetup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART ^
  /LOG="C:\logs\db.log" /TASKS="remotedb" ^
  /DBHOST=<db-host> /DBUSER=postgres /DBPASSWORD=<admin password> ^
  /APPDB=lwcam /DBPORT=5432 /APPUSER=lwcam_user /APPPASSWORD=<password>

QCPlatformSetup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART ^
  /DBHOST=<db-host> /DBPORT=5432 /DBNAME=lwcam /DBUSER=lwcam_user /DBPASSWORD=<password>

LWIPSetup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART ^
  /INPUTROOT="\\<server>\lwcam-input" /OUTPUTROOT="\\<server>\lwcam-output" ^
  /DBHOST=<db-host> /DBPORT=5432 /DBNAME=lwcam /DBUSER=lwcam_user /DBPASSWORD=<password>

LWCamUploadSetup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART ^
  /WATCHROOT="\\<server>\lwcam-output" /DONEROOT="\\<server>\lwcam-uploaded" ^
  /SUMMARYROOT="\\<server>\lwcam-reports" ^
  /S3PATH="s3://<bucket>/<prefix>" /S3REGION=<region> ^
  /S3ACCESSKEY=<key id> /S3SECRET=<secret> ^
  /DBHOST=<db-host> /DBPORT=5432 /DBNAME=lwcam /DBUSER=lwcam_user /DBPASSWORD=<password>
```

| 安装程序 | 参数 |
| --- | --- |
| Database | `DBHOST`（默认 `localhost`）、`DBUSER`（默认 `postgres`）、`DBPASSWORD`：PostgreSQL 管理员账号。只要连接页面不会被跳过就必须提供。`APPDB`（默认 `lwcam`）、`DBPORT`（默认 5432；全新安装时 PostgreSQL 会安装在该端口上，端口被占用则安装失败）、`APPUSER`（默认 `lwcam_user`）、`APPPASSWORD`（无默认值；静默安装缺少它，或不足 12 个字符，会在写入任何内容之前失败；重新运行时省略它即可保留已保存的密码）。`BACKUPDIR`、`BACKUPKEEP`（默认 14，1 到 365；无效值会使安装失败；位于 PostgreSQL 所在驱动器上的文件夹只会在日志中记录警告）。 |
| Database `/TASKS` | `openlan`（默认勾选。从 `/TASKS` 中去掉它，会关闭此前某次运行所开放的访问）和 `remotedb`（默认不勾选）。`/TASKS` 会替换整个选择，要两者都保留请传 `openlan,remotedb`。既没有这两个任务的全新本地安装，还需要把 PostgreSQL 18 安装程序放在安装程序旁边。 |
| QC | `DBHOST`、`DBPORT`（5432）、`DBNAME`（`lwcam`）、`DBUSER`（`lwcam_user`）、`DBPASSWORD` |
| LWIP | `INPUTROOT`、`OUTPUTROOT`（两者都必填，不得使用映射的盘符），外加五个数据库参数 |
| Upload | `WATCHROOT`、`DONEROOT`、`SUMMARYROOT`（三项都必填）、`S3PATH`、`S3REGION`、`S3ACCESSKEY`、`S3SECRET`，外加五个数据库参数 |
| LWCam | 无。可选的 `/DIR=` 用于指定另一个安装文件夹。 |

命令行中的值不是私密的。Setup 运行期间，PC 上的任何进程都可以读取其命令行。Inno 还会把 Setup 的完整命令行写在 `/LOG` 文件的开头，所以 `/DBPASSWORD`、`/APPPASSWORD`、`/S3ACCESSKEY` 和 `/S3SECRET` 都会以明文出现在那里。请从只有管理员能读取的脚本中执行无人值守安装，并在完成后删除或保护该日志。

## 静态加密的密码

安装程序和控制台把这些值存为 `dpapi:...` 形式（Windows DPAPI，与 PC 绑定）。安装程序在写完文件后立即加密它们。如果服务发现某个明文值（较旧的安装），会在启动时将其加密。

| 部件 | 文件 | 加密的键 |
| --- | --- | --- |
| QC | `config\config.txt` | `dbPassword`、`jwtSecret`、`openrouterApiKey` |
| LWIP | `config\deskew_crop_config.json` | `db_password` |
| Upload | `config\upload_config.json` | `db_password`、`s3_secret_key` |
| Database | `config\database.txt` | `dbPassword`、`appPassword` |

安装程序、管理员以及该 PC 上的 SYSTEM 服务都能读取它们。复制到另一台 PC 上的文件无法解密。此时该部分会提示这一点，并要求在其控制台中重新输入密码，或者重新运行安装程序。DPAPI 无法防御在同一台 PC 上登录的管理员。如果安装程序无法加密某个文件，其完成页会说明，请以管理员身份重新运行安装程序。

## SYSTEM 账户与 UNC 共享

QC、LWIP 和 Upload 以 SYSTEM 运行。SYSTEM 看不到在用户会话中映射的驱动器。请对 LWIP 的输入和输出文件夹、QC 的输入根目录以及 Upload 的三个文件夹使用 UNC 路径（`\\server\share`）。每个安装程序都会拒绝映射的盘符。

SYSTEM 以 `<COMPUTERNAME>$`（计算机账户）访问另一台 PC 的共享。在域环境中，请给该账户授予共享权限和 NTFS 权限。在工作组中，另一台 PC 会拒绝它（"Access is denied"），此时请改为保存一个登录凭据。每个控制台（QC 8080、LWIP 8090、Upload 8091）都有一个 "Network folder logins"（网络文件夹登录凭据）区域，在其中填写另一台 PC 的名称、该 PC 上的一个用户及其密码。

- 该列表是按 PC 保存的，而不是按服务。在某个控制台中保存的登录凭据，会被这台 PC 上所有 LWCam 服务使用。Windows 对每台远程 PC 只允许使用一个账户。
- 服务位于不同的 PC 上时：在每台访问该共享的 PC 上各保存一次登录凭据。每个控制台会列出它的文件夹所指向的其他 PC，标出没有登录凭据的那些，而 "Test folder access" 会逐个尝试每个文件夹。
- 使用只能访问 LWCam 文件夹的账户，不要用管理员账户。
- 该列表位于 `%ProgramData%\LWCAM\network-logins\`（仅限 SYSTEM 和 Administrators，密码经 DPAPI 加密，永不显示、永不记入日志）。服务每两分钟重新登录一次，所以重启后共享仍可使用，对方 PC 恢复时也会自动恢复。卸载某一个服务不会删除该列表。
- 当 Upload 的 `done_root` 与导出共享文件夹不在同一个卷上时，已完成的交付包会先被复制，再通过 SMB 删除，速度较慢。Upload 账号需要在导出共享文件夹上拥有删除权限。

## 三个控制台的 HTTPS

在某台服务器 PC 上首次安装 QC、LWIP 或 Upload 时，它会生成自己的证书颁发机构和证书，存放在 `%ProgramData%\LWCAM\tls`（仅限 SYSTEM 和 Administrators，因为其中有私钥）。证书涵盖 PC 名称、它的 IP 地址和它的 Tailscale 名称。服务在每次启动时都会续期证书。IP 变化后，重启服务即可，无需重新安装，也无需重新执行信任步骤。同一台 PC 上的 QC、LWIP 和 Upload 共用一个证书颁发机构。

各控制台的访问地址为 `https://<pc-name>:8080/`（QC）、`:8090/`（LWIP）和 `:8091/`（Upload）。这些端口上的普通 `http` 不会响应。

**信任步骤。** 对每台要打开这些页面的 PC 做一次，并且对它用到的每台服务器 PC 各做一次。不需要管理员权限。

1. 把 `Trust this LWCam server.cmd` 和 `LWCam server certificate.crt` 从服务器的安装文件夹复制到浏览器所在的 PC，两个文件要放在一起。
2. 双击 `.cmd`。
3. 关闭并重新打开浏览器。

Chrome 和 Edge 使用 `.cmd` 写入的 Windows 证书存储。Firefox 有自己的证书存储：Settings、Privacy & Security、Certificates、View Certificates、Authorities、Import。选择 `LWCam server certificate.crt`，并勾选 "Trust this CA to identify websites"。在完成信任步骤之前，浏览器会显示证书警告，但页面仍可使用。

## 数据库结构级别的提示信息

每个部分在启动时以及每次重新连接时都会读取 `schema_migrations`。

- QC 控制台（System status 页面和横幅）、LWIP 和 Upload 会提示："The database is older than this program (needs level N, has M). Run LWCamDatabaseSetup on the database PC."。在数据库升级之前，该部分不做任何数据库工作，升级后会自行继续。
- LWCAM 在其同步处给出同样的提示。采集仍然可以继续，记录在这台 PC 自己的队列中等待。
- LWCam Admin 的 Station Setup 会提示需要重新运行数据库安装程序。
- "has 0" 表示还没有 `schema_migrations` 表，请运行 `LWCamDatabaseSetup`。

## System status 页面（QC 控制台）

QC 控制台的 System status（每个界面上的 "Something needs attention" 横幅都链接到它）列出所有向数据库上报过的部分：QC、QC export、LWIP、Upload、夜间备份和每台采集 PC。时间使用数据库的时钟，所以时钟不同的 PC 之间也能公平比较。它还显示每个部分的版本（`<version>+<commit>`），以及数据库级别与 QC 所需级别的对比。

| 颜色 | 含义 |
| --- | --- |
| 绿色 | 该部分最近有上报，且一切正常。 |
| 红色 | 静默超过 5 分钟（Upload 为 15 分钟），或者它最新的错误比最近一次成功更新，或者存在积压问题（见下文）。采集 PC 只有在出现挂起记录、记录超过一小时未发送，或者出现错误时才显示红色。 |
| 灰色 | 单纯处于关机状态的采集 PC（"offline since ..."），不是故障。 |
| "Never reported"（红色） | QC、QC export、LWIP、Upload 和 backup 始终有一行。该部分未安装、未配置，或无法连接数据库。 |

"Forget this PC" 会移除已退役或已改名的 PC 对应的行；如果那台 PC 再次上报，该行会重新出现。超过 7 天未出现的行会被隐藏，除非勾选 "Show PCs not seen for over 7 days"。数据库 PC 除备份任务外不发送心跳。如果数据库宕机，每个部分都会变红或变灰，页面本身也无法加载。

当某个部分需要的文件夹无法访问时，它也会用一句话说明（例如 "Input folder \\server\input is unreachable"）。当文件夹重新响应时，这句话会消失。

| 部件 | 信号（积压键） | 何时变红 |
| --- | --- | --- |
| LWIP | `unreported`、`oldest_unreported_minutes`（已完成但尚未写入数据库的文件夹） | `oldest_unreported_minutes` > 120 |
| Upload | `last_scan_minutes_ago`、`scan_interval_minutes` | `last_scan_minutes_ago` 大于 15 与 3 x `scan_interval_minutes` 中的较大者 |
| Upload | `db_pending`（已上传，结果尚未写回） | 本身从不变红 |
| Capture | `transfers_waiting`、`oldest_transfer_wait_minutes` | `oldest_transfer_wait_minutes` > 60 |
| QC | `approved_not_exported`、`oldest_approved_minutes` | `approved_not_exported` > 0 且 `oldest_approved_minutes` > 30 |
| QC | `exports_busy`（另一个导出占用了该文件夹的锁） | 本身从不变红 |
| QC | `input_unreachable` | 为 true（QC 看不到 LWIP 的输出） |
| QC export | `last_error`（导出预检错误） | 出现比最近一次成功更新的错误 |

## 当另一台 PC 关机时

每个部分都会排队并重试，没有一个会阻塞采集。

- 数据库宕机：采集 PC 继续采集，并在本机保存每条记录和每张图像。数据库恢复后记录会同步（重试间隔会逐步拉长）。各控制台以只读方式显示状态，没有人能从远程浏览器修改设置。
- 挂起记录（采集 PC）：数据库持续拒绝的记录（失败 20 次）会被挂起，而不是被删除。它留在采集 PC 上，并在状态页上显示为 "held"。排除原因后，在 LWCAM 中点击 "Try again"。
- LWIP 或 QC 的 PC 关机：已完成的采集会等在输入文件夹或数据库队列中。Upload 关机：已导出的交付包留在 QC 的输出文件夹中。
- 另一台 PC 上的共享不可用：服务每两分钟重试一次，文件夹恢复后会自动连上。

## 延伸阅读

- [../docs/INSTALL.zh-CN.md](../docs/INSTALL.zh-CN.md)：逐步说明安装、升级、备份与恢复。
- [../docs/RELEASING.zh-CN.md](../docs/RELEASING.zh-CN.md)：构建并发布一个发布版本。
- [../docs/ARCHITECTURE.zh-CN.md](../docs/ARCHITECTURE.zh-CN.md)：各部分如何连接。
- 各模块 README：[LWCAM](../LWCAM/README.zh-CN.md)、[LWCamAdmin](../LWCamAdmin/README.zh-CN.md)、[LWIP](../LWIP/README.zh-CN.md)、[QC Platform](../LWCam_QC_Platform/README.zh-CN.md)、[Upload](../LWCam_Upload/README.zh-CN.md)。
