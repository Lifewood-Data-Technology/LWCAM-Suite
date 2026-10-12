[English](INSTALL.md) | 简体中文

# 在现场安装 LWCam

本指南面向负责搭建站点的人员，内容包括：五个安装程序、运行顺序、每个安装程序会问的问题，以及如何检查、升级、备份和卸载整套系统。构建安装程序请参阅 [RELEASING.zh-CN.md](RELEASING.zh-CN.md)，术语请参阅 [GLOSSARY.md](GLOSSARY.md)。

最详细的参考资料是 [installer/README.md](../installer/README.zh-CN.md)。

## 1. 安装内容

| 安装程序 | 安装内容 | 运行位置 |
| --- | --- | --- |
| `LWCamDatabaseSetup.exe` | PostgreSQL 18（或使用已有服务器）、LWCam 数据库结构（schema）、共用数据库账号、每晚备份 | 数据库 PC（每个站点一次） |
| `QCPlatformSetup.exe` | QC 服务器和 Web 控制台（审核、通过、退回、导出） | QC PC |
| `LWIPSetup.exe` | LWIP：纠偏、裁切和生成缩略图，以 Windows 服务方式运行 | LWIP PC |
| `LWCamUploadSetup.exe` | 上传服务：把导出的交付包发送到 S3 | Upload PC |
| `LWCamSetup.exe` | LWCAM（采集）和 LWCam Admin | 每台采集 PC |

`LWCamDatabaseSetup.exe` 需要 PostgreSQL 安装文件（`postgresql-18.*-windows-x64.exe`）放在同一个文件夹中，请把这两个文件一起分发。如果 PC 上已有 PostgreSQL，或者站点使用另一台 PC 上的服务器，则只需要这个安装程序本身。

你可以把所有部分装在同一台 PC 上，也可以让每个部分各占一台 PC，甚至分布在不同站点。任何一个部分停机都不会影响其他部分：每个部分都会把任务排队并自动重试。

## 2. 环境要求

| 项目 | 要求 |
| --- | --- |
| 操作系统 | 64 位 Windows。安装程序需要管理员权限。 |
| 网络 | 各部分之间通过 TCP 互相访问。默认端口：数据库 5432，QC 8080，LWIP 控制台 8090，Upload 控制台 8091。 |
| 防火墙 | 每个安装程序会添加自己的规则。规则只放行本地子网和 Tailscale。 |
| 多个站点 | 使用 Tailscale，或者为每个远程地址手工在 `pg_hba.conf` 中添加一行 `hostssl`。MagicDNS 名称可以作为主机名使用。 |
| 共享文件夹 | 使用 UNC 路径（`\\server\share`）或本地固定磁盘。映射的盘符（`Z:`）会被拒绝，因为服务以 SYSTEM 身份运行，看不到映射驱动器。 |
| S3 | Upload PC 需要一个存储桶、区域、访问密钥（access key）和私有密钥（secret key）。 |
| 采集 | 一部已开启 USB 调试的 Android 手机和一根 USB 线。LWCAM 使用 adb 和 scrcpy，二者都已包含在 `LWCamSetup.exe` 中。 |
| 浏览器 | Chrome 或 Edge。Firefox 需要手动操作一步（第 8 节）。 |

安装程序自带 Python 运行时和离线软件包，PC 无需联网，也无需预装 Python。

## 3. 安装顺序

1. **数据库 PC。** 运行 `LWCamDatabaseSetup.exe`，记下完成页上显示的各项值。
2. **QC、LWIP 和 Upload 的 PC。** 在各自的 PC 上运行对应的安装程序，顺序不限。每个安装程序都会询问数据库账号。
3. **每台采集 PC。** 运行 `LWCamSetup.exe`，然后打开 LWCam Admin，完成 Station Setup（工位设置，第 7 节）。

有些值来自其他安装程序：

- QC 需要 LWIP 的输出文件夹（`qcInputRoot`），它显示在 `LWIPSetup.exe` 的完成页上。
- Upload 需要 QC 的导出输出文件夹（`qcOutputRoot`），它显示在 `QCPlatformSetup.exe` 的完成页上。

## 4. 单台 PC 部署

适用于测试或小型站点。在同一台 PC 上按以下顺序运行安装程序：Database、LWIP、QC、Upload、LWCam。数据库主机填 `localhost`，使用本地文件夹，例如：

- `C:\LWCam\1.Images`：LWIP 的输入文件夹（LWCAM 把采集结果复制到这里）
- `C:\LWCam\2.Batches`：LWIP 的输出文件夹，同时也是 QC 的输入文件夹
- `C:\LWCam\3.Export`：QC 的输出文件夹，同时也是 Upload 的监控文件夹

## 5. 多台 PC 部署

1. 规划 PC：一台数据库 PC，QC、LWIP、Upload 各一台或多台，以及若干采集 PC。
2. 在文件服务器或其中一台 PC 上创建共享文件夹，并让各服务 PC 有权访问（参见 [installer/README.md](../installer/README.zh-CN.md) 中的 "SYSTEM account and UNC shares"）。
3. 按第 3 节的顺序运行安装程序，数据库主机填数据库 PC 的名称或地址。
4. 在数据库安装程序中，勾选 "Allow other PCs on this network (and Tailscale) to connect"。
5. 在每台需要打开控制台的 PC 上完成 HTTPS 信任步骤（第 8 节）。

## 6. 各安装向导的提问

### LWCamDatabaseSetup

| 问题 | 说明 |
| --- | --- |
| Use an existing PostgreSQL server instead of installing one | 默认不勾选。勾选后使用另一台 PC 上的服务器，此时会询问主机、PostgreSQL 管理员用户及其密码。 |
| Allow other PCs on this network (and Tailscale) to connect | 默认勾选。它会向网络开放 PostgreSQL，并添加防火墙规则 "LWCam Database"。以后再次运行时取消勾选，会重新关闭该访问。 |
| Database name | 默认 `lwcam`。 |
| Port | 默认 `5432`，范围 1024 到 65535。已被占用的端口会被拒绝。使用已有服务器时，请填服务器实际使用的端口。 |
| User | 默认 `lwcam_user`。格式 `[a-z_][a-z0-9_]{0,62}`。`postgres` 和 `lwcam_app` 会被拒绝。 |
| Password | 至少 12 个字符，需输入两次。 |
| Backup folder and number to keep | 如果 PC 有 D: 盘，默认文件夹为 `D:\LWCam Backups`，否则为 `C:\ProgramData\LWCam\Backups`。默认保留 14 份。请使用一个新的空文件夹，并且放在与 PostgreSQL 不同的磁盘上。 |

所有部分共用同一个数据库账号。请记下主机、端口、数据库名、用户和密码，你需要把它们填入 QC、LWIP、Upload 和 LWCam Admin；完成页上也会显示这些信息。PostgreSQL 管理员密码保存在 `config\database.txt` 中（仅 Administrators 和 SYSTEM 可读）。

### QCPlatformSetup

会询问数据库主机、端口（默认 5432）、名称（默认 `lwcam`）、用户（默认 `lwcam_user`）和密码。全新安装时会写入 `<install>\config\config.txt`。控制台监听 8080 端口。要修改端口或文件夹，请编辑 `config.txt` 或使用控制台的 Settings 页面。在分离部署的站点上，请把 `qcInputRoot` 设为 LWIP 的输出文件夹（UNC 路径）。

### LWIPSetup

会询问输入文件夹（LWCAM 复制完成采集的位置）、输出文件夹（QC 读取的位置）和数据库账号。升级时会跳过这些页面。控制台在 8090 端口。

### LWCamUploadSetup

会询问监控文件夹（QC 的导出输出文件夹）、Uploaded 文件夹、Upload Reports 文件夹、S3 目标（`s3://bucket/prefix`、区域、访问密钥、私有密钥）和数据库账号。控制台在 8091 端口。之后可以在 Upload 控制台中修改 S3 设置。

### LWCamSetup

不会询问数据库或文件夹相关内容。安装完成后，打开 LWCam Admin 并完成 Station Setup。

## 7. 首次登录、用户和项目

1. 在能访问数据库的 PC 上打开 **LWCam Admin**。只有超级管理员（SuperAdmin）可以登录。出厂 SuperAdmin 密码请向项目负责人索取。
2. 打开 **Station Setup**。填写数据库主机、端口、名称、用户和密码，设置图像目标文件夹，保持采集同步开启，然后点击 **Save**。Save 会测试连接。
3. 打开 **User Management** 创建用户账号，打开 **Projects** 创建项目。
4. QC、LWIP 和 Upload 控制台接受数据库中的 Admin 和 SuperAdmin 账号。
5. **每台采集 PC** 都要做 Station Setup。请先安装或升级 `LWCamSetup.exe`，再填写账号。

## 8. 信任 HTTPS 控制台

安装 QC、LWIP 或 Upload 时，每台服务器 PC 会生成自己的证书。控制台使用 `https://`，普通的 `http://` 不会响应。

| 控制台 | 地址 |
| --- | --- |
| QC | `https://<pc-name>:8080/` |
| LWIP | `https://<pc-name>:8090/` |
| Upload | `https://<pc-name>:8091/` |

在完成信任步骤之前，浏览器会显示证书警告，但页面仍可使用。要消除警告，请在每台需要打开控制台的 PC 上，针对每台服务器 PC 执行以下操作：

1. 把 `Trust this LWCam server.cmd` 和 `LWCam server certificate.crt` 从该服务器的安装文件夹复制到这台 PC，两个文件要放在一起。
2. 双击 `.cmd` 文件，无需管理员权限。
3. 关闭并重新打开浏览器。

Chrome 和 Edge 使用 `.cmd` 文件写入的 Windows 证书存储。Firefox 有自己的证书存储：依次打开 Settings、Privacy and Security、Certificates、View Certificates、Authorities、Import，选择 `LWCam server certificate.crt`，并勾选 "Trust this CA to identify websites"。

## 9. 验证系统是否正常

1. 打开 QC 控制台，进入 **System status**（系统状态页）。页面列出 QC、QC export、LWIP、Upload、backup 和每台采集 PC。
   - 绿色：该部分最近有上报，且没有问题。
   - 红色：静默超过 5 分钟（Upload 为 15 分钟），或者出现错误或积压。
   - 灰色：采集 PC 处于关机状态，这不是故障。
   - "Never reported"：该部分未安装、未配置，或无法连接数据库。
2. 最多等待 5 分钟（Upload 为 15 分钟），并处理所有红色行。
3. 端到端跑一个测试文件夹：
   1. 用 LWCAM 采集一个小文件夹。
   2. 等待 LWIP 处理，LWIP 控制台会显示它。
   3. 该文件夹出现在 QC 队列中，审核并通过它。
   4. QC 把交付包导出到输出文件夹。
   5. Upload 把交付包发送到 S3，并移动到 Uploaded 文件夹。
4. 可选：退回一页、重拍，然后再次通过该文件夹，以测试返工流程。

如果某个部分提示 "The database is older than this program"，请重新运行 `LWCamDatabaseSetup.exe`（第 11 节）。

## 10. 静默安装

所有安装程序都支持 Inno Setup 的标准开关：

```
Setup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG="C:\install-logs\x.log" /NAME=value ...
```

缺少必填值或值无效时，安装会在写入任何文件之前停止（退出码 7）。参数名不区分大小写。向导会跳过的页面（升级，或全新的本地数据库）在静默安装中同样会被跳过，其参数会被忽略。

| 安装程序 | 参数（默认值） |
| --- | --- |
| `LWCamDatabaseSetup.exe` | PostgreSQL 管理员：`DBHOST`（localhost）、`DBUSER`（postgres）、`DBPASSWORD`（空）。共用账号：`APPDB`（lwcam）、`DBPORT`（5432）、`APPUSER`（lwcam_user）、`APPPASSWORD`（无默认值；12 个字符或更多）。备份：`BACKUPDIR`、`BACKUPKEEP`（14；1 到 365）。任务：`/TASKS="openlan"`（默认）、`"remotedb"` 或 `"openlan,remotedb"`。 |
| `QCPlatformSetup.exe` | `DBHOST`（localhost）、`DBPORT`（5432）、`DBNAME`（lwcam）、`DBUSER`（lwcam_user）、`DBPASSWORD`（空） |
| `LWIPSetup.exe` | `INPUTROOT`、`OUTPUTROOT`（均为空）、`DBHOST`（空）、`DBPORT`（5432）、`DBNAME`（lwcam）、`DBUSER`（lwcam_user）、`DBPASSWORD`（空） |
| `LWCamUploadSetup.exe` | `WATCHROOT`、`DONEROOT`、`SUMMARYROOT`（三项都必填）、`S3PATH`、`S3REGION`、`S3ACCESSKEY`、`S3SECRET`（空）、`DBHOST`（空）、`DBPORT`（5432）、`DBNAME`（lwcam）、`DBUSER`（lwcam_user）、`DBPASSWORD`（空） |
| `LWCamSetup.exe` | 没有产品专用参数。使用标准开关；如需更换安装文件夹，用 `/DIR=`。 |

示例：

```
LWCamDatabaseSetup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG="C:\install-logs\db.log" /TASKS="openlan" /APPUSER=lwcam_user /APPPASSWORD=<password>

QCPlatformSetup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG="C:\install-logs\qc.log" /DBHOST=<db-host> /DBPORT=5432 /DBNAME=lwcam /DBUSER=lwcam_user /DBPASSWORD=<password>
```

警告：PC 上的其他进程可以读到命令行中的密码，而且 Inno 会把完整命令行写入 `/LOG` 文件。请从只有管理员能读取的脚本中执行静默安装，并在完成后删除或保护该日志。

## 11. 升级

数据库结构（schema）有一个级别：`schema_migrations` 表中的最大编号。每个部分都会拒绝在更旧的数据库结构上工作，所以升级顺序很重要。

1. **备份。** 在数据库 PC 上运行 `BACKUP_DATABASE.bat`（或等待 02:00 的计划任务）。确认备份文件夹中有最新的 `lwcam-*.dump` 和 `lwcam-globals-*.sql`，并保留旧版安装程序。
2. **数据库 PC：** 运行新的 `LWCamDatabaseSetup.exe`，并勾选 "Allow other PCs"。必须先于升级其他任何部分之前完成。凡是会新增迁移脚本的 QC 升级，之前都要再运行一次。只要还有部分在使用旧的 `postgres` 访问规则，该规则就会保留，因此不会有部分被切断，完成页随后会显示一条 `[NOTE]`。
3. 记下你在 "LWCam database login" 页面输入的账号（或完成页上的值）。只能通过仅管理员可读的渠道转交，不要通过邮件或聊天工具。然后执行一次备份，使角色也进入 globals 文件。
4. **QC、LWIP 和 Upload 的 PC：** 在旧版本之上运行各自的新安装程序，按提示填写共用账号（数据库、用户、密码）。仍在使用旧的分部件账号（`lwcam_qc`、`lwcam_lwip` 或 `lwcam_upload`）的部分，在你把它切换到共用账号之前仍可继续工作。
5. 打开 QC 的 System status 页面。QC、QC export、LWIP、Upload 和 backup 必须全部为绿色，请等待五分钟（Upload 为十五分钟）。
6. **每台采集 PC，逐台进行：** 先升级 `LWCamSetup.exe`，然后在 LWCam Admin 的 Station Setup 中填写共用账号。切勿在仍运行旧版 LWCAM 的采集 PC 上填写新账号，旧程序不认识新的授权，会失败。
7. 确认新的采集结果能进入 QC 队列，并确认该采集 PC 在状态页上显示正常，没有 "held"（挂起）记录。
8. 当所有部分都使用共用账号后，再运行一次 `LWCamDatabaseSetup.exe`，它会移除旧的开放数据库规则。如果仍有部分使用其他账号，安装程序会保留该规则，并在 `[NOTE]` 中列出这些账号。
9. 在每台需要打开控制台的 PC 上再次执行 HTTPS 信任步骤（第 8 节）：对每台服务器 PC 的证书，各运行一次 `Trust this LWCam server.cmd`。
10. 在整整一个工作日无问题运行之前，保留旧安装程序和升级前的备份。这一天必须包含一次完整的返工往返（退回、重拍、通过）和一次夜间备份。

## 12. 卸载

通过 Windows 设置中的 "Apps" 卸载。每个安装程序会先停止自己的服务。PostgreSQL 及其数据不会被删除。

以下内容会被有意保留，这样重新安装时不会丢失工作成果：

| 保留内容 | 所属 |
| --- | --- |
| `runtime\state.json`（已处理文件夹的列表） | LWIP |
| `runtime\uploads.json`（已发送交付包的列表） | Upload |
| `config\database.txt` | Database 安装程序 |
| 已导出的交付包 | QC |
| 备份文件 | Database 安装程序 |
| `%ProgramData%\LWCAM\network-logins` 中的网络文件夹登录凭据 | 所有服务 |

若要彻底清理，请手工删除安装文件夹。

## 13. 备份与恢复

Database 安装程序会注册计划任务 **LWCam Database Backup**。它每天 02:00 以 SYSTEM 身份运行，向备份文件夹写入两个文件，并删除超出保留数量的最旧文件：

- `lwcam-YYYYMMDD-HHMM.dump`：数据库（PostgreSQL 自定义格式）
- `lwcam-globals-YYYYMMDD-HHMM.sql`：数据库角色及其密码哈希

日志为 `logs\backup.log`，设置在 `config\backup.txt` 中。备份未加密，请妥善保管该文件夹，不要公开。

在同一台 PC 上恢复（恢复会替换当前数据库）：

1. 停止采集应用。停止运行在其他 PC 上的 QC、LWIP 和 Upload 服务。
2. 在数据库 PC 上以管理员身份打开命令提示符。
3. 运行 `"C:\Program Files\LWCam Database\RESTORE_DATABASE.bat" "D:\LWCam Backups\lwcam-20260930-0200.dump"`，路径和文件名请换成你自己的安装文件夹和文件。
4. 出现提示时输入 `YES`。
5. 启动其他 PC 上的服务。

脚本会先保存当前数据库的一份安全转储，然后在一个事务中完成恢复。如果原 PC 已经损坏，请看下一小节。

### 在新硬件上重建数据库 PC

适用于原数据库 PC 已经不存在的情况。

在旧 PC 出故障之前，请把以下内容保存在另一台 PC 或另一块磁盘上：

- 备份文件夹：最新的 `.dump` 文件及其 `lwcam-globals-*.sql` 文件。
- 旧 PC 的 `config\database.txt`，其中保存着 LWCam 账号。

然后在新 PC 上执行以下步骤：

1. 运行 `LWCamDatabaseSetup.exe`（PostgreSQL 安装文件放在旁边）。让新 PC 使用其他 PC 一直在用的名称或地址；如果做不到，之后需要在每个部分里修改数据库主机。勾选 "Allow other PCs on this network (and Tailscale) to connect"。在 "LWCam database login" 页面输入与之前相同的数据库名、端口、用户和密码（它们在旧的 `database.txt` 中），这样各部分就不需要任何新设置。这一次运行会创建一个空的数据库结构。
2. 如果没有旧账号信息，请应用 globals 文件，它会带回角色及其原有的密码哈希。以管理员身份打开命令提示符并运行：

   ```
   "C:\Program Files\PostgreSQL\18\bin\psql.exe" -h localhost -U postgres -d postgres -f "D:\LWCam Backups\lwcam-globals-YYYYMMDD-HHMM.sql"
   ```

   提示某个角色 "already exists"（已存在）的消息无害。
3. 恢复数据：按上文所述，用最新的 `.dump` 文件运行 `RESTORE_DATABASE.bat`。
4. 再次运行 `LWCamDatabaseSetup.exe`，它会把数据库结构和授权升级到当前级别。勾选 "Allow other PCs" 后，它还会重新开放网络访问。
5. 打开 QC 控制台的 System status 页面。随着各部分重新连接，几分钟内它们都会变绿。如果某个部分无法登录，说明账号没有被恢复，请在该部分中填入旧 `database.txt` 里的账号。

## 14. 在多台独立 PC 上验证站点

一台 PC 无法验证以下各点，请在真实机器上逐项确认。

- [ ] **SYSTEM 的已保存网络登录凭据。** 在每台服务 PC 上，已保存的网络登录凭据对 SYSTEM 账户有效。可用计划任务或 `psexec -s` 测试。当 QC、LWIP 和 Upload 共用一台 PC，并以不同账户访问同一台对端 PC 时，会出现错误 1219。每台对端 PC 只用一个账户。
- [ ] **对端重启。** 重启持有共享文件夹的 PC。服务 PC 必须在无人登录的情况下重新连上该共享文件夹，关于无法访问文件夹的状态提示必须消失。
- [ ] **异地采集。** 从另一个站点的采集 PC，通过 Tailscale 把一批真实数据发送到 LWIP 的输入文件夹。测量复制速度。针对采集 PC 上运行 LWCAM 的 Windows 用户运行 `cmdkey`。确认复制超时时间对你的链路足够长。
- [ ] **QC 通过共享读取 LWIP 的输出。** 把 `qcInputRoot` 设为 LWIP 的 UNC 共享。审核并通过一个普通文件夹，再审核并通过一个拆分文件夹（LWIP 分多部分写出的一个批次）。
- [ ] **数据库 PC 断电。** 在批处理、导出和上传进行到一半时硬断电。每个部分都必须变红，然后自行恢复，不得丢失或重复任何数据。
- [ ] **QC PC 在导出期间断电。** 该文件夹必须在大约 2 到 3 分钟内重新可导出。数据库会在 TCP keepalive 时间之后清理掉断开的会话及其锁。勾选 "Allow other PCs" 时，`LWCamDatabaseSetup.exe` 会设置这个值：空闲 60 秒，间隔 10 秒，重试 6 次。
- [ ] **控制台名称。** 即使 Tailscale 晚于服务启动，浏览器也能通过 MagicDNS 名称访问每个控制台，且证书仍须与该名称匹配。
- [ ] **真实 S3 上传。** 上传到真实的存储桶，并包含对此前已上传的某个交付包做客户返工后的重新上传。

注意：当 Upload 的 `done_root` 与导出共享文件夹不在同一个卷上时，Upload 会先复制已完成的交付包，再通过 SMB 删除它，速度较慢。Upload 账号需要在导出共享文件夹上拥有删除权限。
