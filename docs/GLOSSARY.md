# Glossary / 术语表

| English term | 简体中文 | Meaning (English) |
| --- | --- | --- |
| LWCAM | LWCAM（采集端） | Flutter Windows capture app. Pulls photos from a phone and copies them to the input folder. |
| LWCam Admin | LWCam Admin（管理端） | Flutter Windows app for the SuperAdmin: users, projects, devices, Station Setup. |
| LWIP | LWIP（图像处理服务） | Python service that measures page tilt, crops pages losslessly, makes thumbnails and writes a manifest. |
| QC Platform | QC Platform（质检平台） | FastAPI server and Vue web console for review, approval, rejection, separation, client rework and export. |
| LWCam Upload | LWCam Upload（上传服务） | Python service that sends delivery packages to S3. |
| Module edition | 模块版 | The edition with five installers, one per part. Branch `lwcam-module`. |
| All-In-One edition | 一体版 | The older edition with one installer. Branch `lwcam-all-in-one`. |
| station | 工位 / 采集站 | One capture PC with its phone and its LWCAM install. |
| node config | 节点配置文件 | `lwcam_node_config.json`. The capture PC's settings: database login, destination folder. Written by Station Setup. |
| Station Setup | 工位设置 | The LWCam Admin screen that edits the node config and tests the database connection. |
| box | 箱 | A physical container of records. A capture box holds keyed folders. One unit in Box Mode. |
| folder | 文件夹 / 卷宗 | One group of pages (one volume or file) inside a box. Also the directory on disk that holds its images. |
| keyed folder | 已录入元数据的文件夹 | A folder whose metadata (cover tag, title, volume, dates, record type and so on) the operator typed in before transfer. |
| Box Mode | 箱模式 | The capture workflow with metadata keying on: box, then folders, with a live phone mirror. |
| Normal Mode | 普通模式 | The older capture workflow with keying off. |
| metadata keying | 元数据录入 | Typing descriptive fields for each folder during capture. Turned on or off per account. |
| batch | 批次 | The set of processed folders LWIP writes to its output folder (`2.Batches`), grouped by day (`YYYYMMDD`). |
| input root (LWIP) | 输入根目录 | The folder LWIP watches. LWCAM copies finished captures here. |
| QC input root | QC 输入根目录 | `qcInputRoot`. LWIP's output folder, where QC finds folders to review. |
| QC output root | QC 输出根目录 | `qcOutputRoot`. Where QC publishes delivery packages (`3.Export`). Upload watches it. |
| work folder | 工作目录（临时） | `exportWorkRoot`. Scratch space for export. Keep it local and separate from the other roots. |
| capture marker | 采集完成标记 | `lwcam_capture_marker.json`. LWCAM writes it into a folder when the transfer is verified. LWIP waits for it. |
| manifest | 清单文件 | `.deskew_crop_manifest.json`. LWIP's record of each page: checksum, size, baseline operations. |
| PENDING | 待审（PENDING） | QC status. The folder waits for review. |
| PASS | 通过（PASS） | QC status. A reviewer approved the folder. It is ready for export. |
| REWORK | 返工（REWORK） | QC status. Pages were rejected. The folder waits for recapture. The database CHECK allows PASS, REWORK and PENDING. |
| approve | 通过（审批） | A reviewer commits their edits and sets the folder to PASS. |
| reject | 退回 | A reviewer sends pages back for recapture (capture rework). |
| rework (capture rework) | 返工 | QC rejects pages, the operator recaptures them, LWIP rebuilds the folder. |
| recapture | 重拍 | The operator photographs rejected pages again in LWCAM's rework list. |
| client rework | 客户返工 | The client asks for changes to a delivered package. The folder returns to PENDING and is republished under the same Group ID. |
| revert | 撤回（回退） | The QC action that returns an exported folder to review as a client rework. |
| Group ID | 分组编号（Group ID） | The unique ID of a delivery package. Built from the project ingest ID, location code, capture user, YYMMDD and a 6-digit sequence. A client rework keeps it. |
| export package | 交付包 | The folder or `.zip` QC publishes for one Group ID: TIFF or JPEG pages plus `GroupMetadataImage.csv`. |
| export sweep | 自动导出扫描 | The QC background job that exports approved folders by itself every 30 seconds. |
| separation | 分卷（拆分） | Splitting one folder into several child folders at marked start pages. A child cannot be rejected for recapture. |
| pending ops | 待执行操作 | Edits a reviewer made but did not yet commit (rotate, crop, and so on). |
| qc_ops | QC 图像操作记录 | The list of image operations (deskew, crop, rotate, matfill) stored as data. `qc_ops.json` holds the committed ones. |
| geometry is data | 几何即数据 | The rule that rotations and crops are recorded, not applied to pixels, until export. |
| deskew | 纠偏 | Straightening a tilted page. LWIP only measures the angle. QC applies it at export. |
| crop | 裁切 | Cutting the page out of the photo with a margin (`crop_padding`). LWIP crops losslessly in JPEG blocks. |
| mat fill | 衬底填充 | A `matfill` operation. Paints the empty corners that rotation leaves outside the photo with the surrounding background. |
| lossless crop | 无损裁切 | A crop made with `jpegtran` that does not re-encode the JPEG. |
| thumbnail | 缩略图 | A 512 px preview image LWIP makes for the QC page rail. |
| luminance correction | 亮度校正 | The only tool that changes pixels in review. Off by default. |
| baseline | 基线 | The operations LWIP recorded for a page. QC adds committed and draft operations on top. |
| kept pages | 保留页面 | Pages QC inserted or replaced. QC keeps a copy and restores it after a capture rework. |
| outbox | 发件箱（待同步队列） | The queue of database changes on a capture PC. It keeps records when the database is down. |
| held record | 挂起记录 | An outbox record the database refused 20 times. It stays on the capture PC until fixed and retried. |
| heartbeat | 心跳 | A status row each part writes to the database about every 60 seconds. |
| System status page | 系统状态页 | The QC console page that shows every part's heartbeat as green, red or grey. |
| schema | 数据库结构（schema） | The tables and columns of the database. |
| migration | 迁移脚本 | A numbered SQL file (`001` to `008`) that upgrades the schema. Each is safe to re-run. |
| schema level | 结构版本级别 | The highest migration number in `schema_migrations`. A part refuses to work if the database level is lower than it needs. |
| shared login | 共用数据库账号 | The one database login every part uses. A member of the group role `lwcam_app`. |
| SuperAdmin | 超级管理员 | The role that manages users and projects. Uses LWCam Admin. |
| Admin | 管理员 | The role that manages QC settings, export and the LWIP and Upload consoles. |
| QC (role) | 质检员 | The role that reviews folders in the QC console. |
| Capture (role) | 采集员 | The role that operates LWCAM. |
| project | 项目 | A digitisation job with its own metadata template, location code and users. |
| metadata template | 元数据模板 | The per-project list of fields, which are required, mapped, or disabled. |
| DPAPI | DPAPI（Windows 数据保护接口） | Windows encryption tied to a PC. Config secrets are stored as `dpapi:...`. |
| SYSTEM account | SYSTEM 账户 | The Windows account the services run as. It cannot see mapped drive letters. |
| UNC path | UNC 路径 | A network path like `\\server\share\folder`. Use it instead of a mapped drive. |
| network folder logins | 网络文件夹登录凭据 | Saved logins a service uses to reach a share on another PC. Kept per PC, encrypted. |
| Tailscale | Tailscale（组网工具） | The VPN the project uses to link PCs at different sites. |
| scheduled task | 计划任务 | A Windows task. `LWCam QC Server`, `LWCam LWIP` and `LWCam Upload` start at boot. |
| watch_root / done_root | 监控目录 / 已上传目录 | Upload settings: the folder it scans, and where it moves a package after S3 accepted it. |
| ledger | 台账 | Upload's list of packages already sent (`uploads.json`), with a content fingerprint. |
| fingerprint | 内容指纹 | A hash of a package's files. Upload uses it to see that a client-rework package changed. |
