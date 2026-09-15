LWIP 独立纠偏/裁切工具
======================

英文版本见 README.txt。英文为主文档，更新时以英文版为准，本文件为其翻译。

这是一个纯后端的工具，它监视一个输入根目录下的图片文件夹，一次处理一个文件夹。
在该文件夹内，多进程池对每张图片只解码一次，在内存中完成纠偏和裁切，然后写出暂存
结果。发布暂存结果之前，会先校验源文件夹没有发生变化。

它不使用 FastAPI 服务、PostgreSQL、LWIP 任务队列、方向预测、分隔页检测、批次处理
或源文件清理。

它有两种运行方式：独立运行（START_DESKEW_CROP.bat，手工编辑配置），或由 LWCAM 作为
流水线的图像处理阶段来监管。在被监管模式下，LWCAM 生成配置（folder_depth 2、以采集
标记文件作为完成判据、512px 缩略图），负责启动和重启本工具，并读取输出清单和
state.json 来更新数据库——本工具自身依然不接触任何数据库。参见 LWCAM 的 CLAUDE.md
中的 "Image-processing phase" 一节。


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
    是唯一能确定地区分「传输结束」与「文件之间的长时间停顿」的手段。LWCAM 监管本
    工具时会把标记配置为 "lwcam_capture_marker.json"，并在某个箱子的转存完全校验
    通过之后，向每个文件夹写入一个这样的文件（其中带有该文件夹的数据库身份信息）；
    该身份信息会被复制进输出清单的 "source_identity"，供 LWCAM 把结果回报数据库。
    仍在等待标记的文件夹不会阻塞空闲期的完整性审计。

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

首次安装（安装内置 Python 与离线依赖）：

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


包内容
------

backend\                 独立的 Python 源码与测试
config\                  工具配置
requirements.txt         锁定的依赖版本
SETUP_DESKEW_CROP.bat    一次性离线安装
START_DESKEW_CROP.bat    持续监视启动脚本
RUN_TESTS.bat            端到端验证

由安装或运行时生成，源码检出中不存在：

runtime\                 本地状态、工作数据、输出与日志
venv\                    .bat 脚本调用的虚拟环境

仅存在于部署包中，源码检出中不存在：

wheels\                  离线的 NumPy、OpenCV、Pillow、pip 包

SETUP_DESKEW_CROP.bat 需要后面这两项。从源码检出开始时，请自行创建虚拟环境；之后
.bat 脚本无需修改即可工作，因为它们调用的就是 runtime\python\python.exe：

    python -m venv venv
    runtime\python\python.exe -m pip install -r requirements.txt
    runtime\python\python.exe -m unittest discover -s backend/tests -v
