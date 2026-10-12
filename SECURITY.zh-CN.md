# 安全

[English](SECURITY.md) | 简体中文

## 报告漏洞

**不要**为安全问题公开提 issue。请私下给项目负责人 Jackson Choy（jackson.choy@lifewood.com）发消息，内容包括：你发现了什么、涉及的模块和版本，以及复现步骤。消息中不要包含真实的密码、密钥或客户数据。

## 密钥如何存储

| 密钥 | 位置 | 保护方式 |
| --- | --- | --- |
| 数据库账号（共用） | QC `config\config.txt`、LWIP `config\deskew_crop_config.json`、Upload `config\upload_config.json`、LWCAM/LWCam Admin `lwcam_node_config.json` | 使用 Windows DPAPI 加密（见下） |
| QC 登录令牌密钥（`jwtSecret`） | QC `config\config.txt` | DPAPI |
| OpenRouter API 密钥 | QC `config\config.txt` | DPAPI |
| S3 密钥 | Upload `config\upload_config.json`（`s3_secret_key`） | DPAPI |
| PostgreSQL 管理员和应用账号 | 数据库 `config\database.txt` | DPAPI |
| 采集 PC 的数据库密码 | `lwcam_node_config.json`（`pgPasswordProtected`） | DPAPI，当前用户范围 |
| 每台 PC 的证书颁发机构和密钥 | `%ProgramData%\LWCAM\tls` | 仅 SYSTEM 和 Administrators 可访问的文件夹 |
| 已保存的网络共享登录凭据 | `%ProgramData%\LWCAM\network-logins\` | 仅 SYSTEM 和 Administrators 可访问的文件夹 |

**DPAPI 值。** 受保护的值写成 `dpapi:<base64>`。相关代码是 `lwcam_secrets.py`，这是一个逐字节复制到每个模块中的文件。它使用 Windows DPAPI 的 **LOCAL_MACHINE** 范围，并带一个固定的 entropy 字符串。因此，安装程序（由管理员运行）和服务（以 SYSTEM 运行）都能读取对方写入的内容，而被复制到另一台 PC 上的配置文件无法在那里解密。它**不能**做到的是：它拦不住同一台 PC 上的管理员，或以 SYSTEM 身份运行的进程，他们可以像服务一样解密。它的作用是让密钥不出现在备份、截图、支持邮件和随手翻看的场合里。不带前缀的明文值仍然会被接受（旧文件、手工编辑），服务启动时会把文件改写成受保护的形式。代码中有意不提供解密命令。

（LWCAM 和 LWCam Admin 使用另一个独立的 DPAPI 辅助模块 `lib/services/dpapi.dart`，采用当前用户范围、entropy 为 `LWCam`，用于保护采集 PC 的密码。）

**锁定的文件夹。** 每个安装程序都会设置其 `config\` 文件夹，使只有 SYSTEM 和 Administrators 能读取（`installer/common.iss` 中的 `RestrictToAdmins`）。程序文件夹 `{app}` 和 `%ProgramData%\LWCAM` 只有管理员可写，因为 SYSTEM 任务会从中运行代码。

**一个共用的数据库账号。** 每个组件都用一个账号连接，在运行 `LWCamDatabaseSetup` 时选定。它是组角色 `lwcam_app` 的成员，该角色恰好拥有各组件所需的权限。它没有 CREATE，不是 superuser，没有 createdb，没有 createrole。代价是：一个泄露的密码可以从网络允许的任何位置读取和编辑 LWCam 的表，但它不能在数据库 PC 上运行程序、创建表或删除数据库。

**TLS。** 数据库连接使用 TLS（`pg_hba.conf` 中的 `hostssl` 规则）。QC、LWIP 和 Upload 控制台只提供 https。每台服务端 PC 生成自己的证书颁发机构（`tls.py`），并通过 NameConstraints 限制为只能用于该 PC 自己的名称和地址。每个控制台自行续期证书，CA 不会被悄悄替换。浏览器需要一次性信任该 CA（见 `installer/README.md` 的 HTTPS 一节）。

**控制台登录。** QC、LWIP 和 Upload 控制台使用数据库中的账号（bcrypt 哈希），并有频率限制。每个账号同时只能有一个有效登录。

**SuperAdmin 恢复账号。** LWCam Admin 内置了一个 SuperAdmin，其出厂密码哈希被编译进每个构建。在你于 LWCam Admin 的 App Settings → SuperAdmin password 中设置自己的密码（作为覆盖值存入数据库）之前，每个安装上的出厂密码都相同。请在每个站点都修改它。

**备份没有加密。** 每晚备份生成的转储文件和 globals 文件包含所有账号的哈希。请让备份文件夹保持私有。

## 绝不能放进 git 的内容

真实的 `config.txt`、`upload_config.json`、含登录信息的 `deskew_crop_config.json`、`lwcam_node_config.json`、`database.txt`、证书和私钥、PostgreSQL 转储文件、构建产物、安装程序（`*.exe`）以及客户图像。只提交 `*.example` 文件。见 `CONTRIBUTING.md`。

## 轮换密钥

任何一次轮换之后，都要检查 QC 的 **System status** 页：每个组件都必须重新变为绿色。

| 密钥 | 修改方法 |
| --- | --- |
| **数据库密码** | 在数据库 PC 上用新密码重新运行 `LWCamDatabaseSetup`（相同的用户、名称和端口）。然后在每个组件中输入新密码：重新运行 `QCPlatformSetup`、`LWIPSetup` 和 `LWCamUploadSetup`（或在 LWIP 和 Upload 控制台中修改），并在每台采集 PC 上的 LWCam Admin → Station Setup 中修改。 |
| **`jwtSecret`（QC）** | 编辑 QC `config\config.txt` 中的 `jwtSecret`（至少 32 个随机字符；第一个由安装程序生成）。重启 "LWCam QC Server" 计划任务。所有人都会被登出。 |
| **S3 密钥** | 在 Upload 控制台（端口 8091）的 Settings 中修改。服务无需重新安装即可应用保存的设置。在 AWS 中吊销旧密钥。 |
| **OpenRouter 密钥** | 在 QC 控制台的 Admin → Settings 中修改。该值在那里只能写入，不能读回。 |
| **SuperAdmin 密码** | LWCam Admin → App Settings → SuperAdmin password。 |
| **用户密码** | LWCam Admin → User Management（重置为共用的临时密码；用户必须在下次登录时修改）。 |
| **证书** | 自动处理。IP 地址变化时，需要重启该服务，而不是重新安装。 |

如果密钥已经泄露，先轮换它，再告知项目负责人。
