LWIP 独立纠偏/裁切工具
======================

英文版本见 README.txt。英文为主文档，更新时以英文版为准，本文件为其翻译。

这是一个纯后端的工具，它监视一个输入根目录下的图片文件夹，一次处理一个文件夹。
在该文件夹内，多进程池对每张图片只解码一次，在内存中完成纠偏和裁切，然后写出暂存
结果。发布暂存结果之前，会先校验源文件夹没有发生变化。

它不使用 FastAPI 服务、LWIP 任务队列、方向预测、分隔页检测、批次处理或源文件清理。

它是一个独立的 Windows 安装（`{autopf}\LWCam LWIP`，由 LWIPSetup.exe 安装），不再由
其他应用监管。名为 "LWCam LWIP" 的计划任务在开机时以 SYSTEM 身份运行
`START_LWIP.bat`（`/SC ONSTART`），启动本工具去读取
`config\deskew_crop_config.json`——安装程序只在首次安装时写入该文件（输入/输出
目录，以及本站自己的
`db_host`/`db_port`/`db_name`/`db_user`/`db_password`/`db_use_ssl`），升级时不会
覆盖。日志写入 `logs\service.log`。处理完成的文件夹会用这些凭据直接上报
PostgreSQL（`cloud_report.py`），因此不需要任何其他进程在运行就能进入 QC 队列——见
下文 "cloud_report"。要优雅地停止它（卸载程序，或手工操作），只需放置
`%ProgramData%\LWCAM\lwip.stop`；正在运行的调度器会在完成当前正在发布的文件夹后
退出，大约需要 90 秒。

若要在开发环境或脱离安装环境手工运行，运行 `SETUP_DESKEW_CROP.bat` 之后再运行
`START_DESKEW_CROP.bat` 仍然照常可用，读取同一个 `config\deskew_crop_config.json`。


配置
----

安装完成后编辑本工具目录下的 config\deskew_crop_config.json。

input_root
    每个待处理任务是一个图片文件夹。folder_depth=1（默认）时，input_root 的每个直接
    子目录是一个任务；folder_depth=2 时，每个孙目录是一个任务（例如
    YYYYMMDD/<folder>）——见下文 folder_depth。当 "recursive" 为 true 时，任务文件夹
    下层的图片会被递归包含。

output_root
    完成的图片写入一个镜像了任务文件夹在 input_root 下相对位置的目录（depth 2 时即
    YYYYMMDD/<folder>）。发布采用在输出卷上暂存、然后整个完成目录原子切换的方式，
    output_root 是 NAS 路径时同样如此。输入图片永远不会被修改或删除。output_root
    不能等于 input_root，也不能位于 input_root 内部。

folder_depth
    1（默认）= input_root 的每个子目录是一个任务，即最初的约定。
    2 = 每个孙目录是一个任务，用于直接监视 LWCAM 的转存目录结构
    （<destination>/YYYYMMDD/<folder>）；日期根目录下的同级项（CSV、日志文件、
    logs\ 目录）既没有标记文件也没有图片，会被跳过。

thumbnail_width / thumbnail_quality / thumbnail_dirname
    thumbnail_width 为 0（默认）表示不生成缩略图。大于 0 时，每张图片在纠偏裁切之后
    还会生成一张限定最大宽度的 JPEG 缩略图（保持比例，只缩不放），写入
    <输出目录>\<thumbnail_dirname>（默认 "thumbs"），文件名取自源图片并改为 .jpg
    扩展名（page1.png -> thumbs\page1.jpg，而不是 page1.png.jpg，以缩短路径长度），
    质量为 thumbnail_quality（默认 85）。缩略图阶段失败不会导致整个文件夹失败——
    清单中的 thumbnails.created 标志记录它是否成功。缩略图也纳入完整性清单与审计。

workers
    图像工作进程数。默认保守地取 4，因为高分辨率扫描件内存占用很大。设为 0 表示取
    逻辑 CPU 数减一（受 Windows 上限 61 约束）。

stable_seconds / minimum_file_age_seconds
    没有完成标记文件时，全部图片路径、大小、修改时间的列表必须在 stable_seconds
    期间保持不变，每张图片都必须可读，且最新的图片至少已存在
    minimum_file_age_seconds。处理期间发生任何变化，都会丢弃暂存成果并让该文件夹
    回到稳定性等待状态。

completion_marker
    要确定性地判断传输完成，可以配置一个文件名（例如 "TRANSFER.COMPLETE"），并让
    发送方在所有图片都已关闭之后才创建该文件。配置之后，只有标记文件存在的文件夹
    才有资格被处理；图片可读性与快照未变的检查依然生效。由生产者写入的标记文件，
    是唯一能确定地区分「传输结束」与「文件之间的长时间停顿」的手段。安装时写入的
    配置把标记设为 "lwcam_capture_marker.json"，这与 LWCAM 自己的
    `processing_marker_service.dart` 相匹配——它仍然会在某个箱子的转存完全校验
    通过之后，向每个文件夹写入这样一个文件（其中带有该文件夹的数据库身份信息）；
    该身份信息会被复制进输出清单的 "source_identity"，本工具正是靠它来解析并
    自行回报该文件夹（见下文 cloud_report）。仍在等待标记的文件夹不会阻塞空闲期的
    完整性审计。

state_file
    已完成文件夹指纹的持久化日志。重启之后，未发生变化的文件夹不会被重复处理。
    修改、新增或删除任何一张图片都会改变指纹，使该文件夹重新变得可处理。

presence_check_interval_seconds
    当没有输入文件夹在等待或处理时，监视器每次检查一个已完成的输出文件夹，查看是否
    有缺失、多余或大小不符的图片。默认每个文件夹每 300 秒检查一次。

checksum_check_interval_seconds
    空闲时，监视器会定期读取已完成的输出图片，把 SHA-256 校验和与持久化的发布清单
    比对。默认每个文件夹每 86400 秒（每天）一次。发现缺失或损坏的图片时，会立即安排
    从保留的源文件重新处理整个文件夹。

cloud_report / db_host / db_port / db_name / db_user / db_password / db_use_ssl
    当 cloud_report 为 true（安装后的默认值）时，带有完成标记身份信息的已完成
    文件夹会直接上报 PostgreSQL（`deskew_crop_tool/cloud_report.py`），使用本站
    自己的 db_* 设置——LWIP 不再保留数据库登录信息的其他副本。db_port 默认 5432，
    db_name 默认 "lwcam"，db_use_ssl 默认 false（sslmode 为 "prefer"；true 则为
    "require"）。若配置中 cloud_report 为 true，而 db_host、db_user 或
    db_password 缺失或为空，加载时会立即失败并指出缺少哪个键，而不是启动一个
    永远无法连上 QC 的监视器。


崩溃与损坏恢复
--------------

每个输出文件都先写入临时文件、刷入稳定存储、再原子重命名。在必需的发布复制过程中，
工具记录每个输出路径、精确大小和 SHA-256 校验和，且不额外增加一遍读取。清单本身的
校验和保存在原子状态日志中。

只有当每个暂存文件和清单都通过存在性/大小校验之后，完成的文件夹才会被切换到位。
完整性审计只在没有新任务进来时运行，因此不会降低处理吞吐。任何缺失、多余、截断或
校验和不符的输出都会触发自动重新处理。恢复过程中输入图片始终保持只读。


运行
----

已安装的情况（正常情况）：名为 "LWCam LWIP" 的计划任务会在开机时以 SYSTEM 身份
运行 START_LWIP.bat，无需手工启动。日志写入 logs\service.log。要优雅地停止它，
放置 %ProgramData%\LWCAM\lwip.stop 并等待约 90 秒。

源码检出或手工运行时的首次安装（安装内置 Python 与离线依赖）：

    SETUP_DESKEW_CROP.bat

然后运行：

    START_DESKEW_CROP.bat

监视器会一直运行到 Ctrl+C。日志写入配置中的 log_file。

处理当前已就绪的文件夹后退出：

    START_DESKEW_CROP.bat --once

等待当前存在的所有文件夹变为稳定、处理完毕后退出：

    START_DESKEW_CROP.bat --once --wait

同一时刻只能有一个调度器使用同一个 work_root。文件夹按修改时间从早到晚处理；后面的
文件夹不会与前面的并发运行。


控制台
------

START_LWIP.bat 现在运行的是 deskew_crop_tool.service，一个监督进程：它把上面的
监视器当作子进程启动，并在旁边提供一个小型网页控制台——默认地址为
http://localhost:8090/（配置中的 ui_port / ui_bind）。即使监视器的配置坏到无法
自行启动，控制台依然可访问，因此这种问题可以由操作员在浏览器里看到并修复，而不
必只靠 logs\service.log。

使用共享 PostgreSQL 用户表中的 Admin 或 SuperAdmin 账号登录（与 LWCAM / LWCam
Admin / QC 共用的同一张表）——纯 qc 账号没有控制台访问权限。如果数据库完全无法
连接，从本机打开的浏览器仍会获得完整权限，以便就地修复数据库设置；从其他机器打
开则只能看到只读的状态与日志，直到数据库恢复为止。保存设置会用新的值重启监视器。


包内容
------

backend\                 独立的 Python 源码（安装包中不含测试）
config\                  工具配置；deskew_crop_config.json 由安装程序在首次
                         安装时写入，升级时保持不变
requirements.txt         锁定的依赖版本
SETUP_DESKEW_CROP.bat    一次性离线安装
START_LWIP.bat           计划任务的启动目标；日志写入 logs\service.log
START_DESKEW_CROP.bat    手工/开发用监视启动脚本（源码检出）
RUN_TESTS.bat            端到端验证（源码检出）

由安装或运行时生成，源码检出中不存在：

runtime\                 私有 Python 运行时，以及本地状态与工作数据
logs\                    service.log（START_LWIP.bat）以及配置中 log_file
                         指向的日志

仅存在于部署包中，源码检出中不存在：

wheels\                  离线的 NumPy、OpenCV、Pillow、pip 包

SETUP_DESKEW_CROP.bat 需要 runtime\ 和 wheels\。从源码检出开始时，请自行创建
虚拟环境；之后 .bat 脚本无需修改即可工作，因为它们调用的就是
runtime\python\python.exe：

    python -m venv venv
    runtime\python\python.exe -m pip install -r requirements.txt
    runtime\python\python.exe -m unittest discover -s backend/tests -v
