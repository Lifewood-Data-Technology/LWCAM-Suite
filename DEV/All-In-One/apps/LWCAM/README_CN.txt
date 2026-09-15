================================================================================
 LWCAM (Lifewood Capture) 采集端
================================================================================

英文版本见 README.txt。英文为主文档，更新时以英文版为准，本文件为其翻译。

LWCAM 是文档数字化流程的采集端 Flutter Windows 桌面应用。它通过 ADB 从 Android
设备的 DCIM 目录拉取扫描图像，先暂存到本地，再复制到本地或 NAS 目标目录，全程带
超时控制、停滞检测、文件加锁和审计日志。采集结果记录在按设备划分的本地 SQLite
数据库中，并同步到共享的 PostgreSQL 库。

包名 `lwcam`。仅支持 Windows。


文档
--------------------------------------------------------------------------------

  CLAUDE.md          请先读这个。逐个服务讲解完整架构，并说明设计沿革以及每一处
                     不显而易见的取舍背后的原因。是本仓库最有价值的文档。
  CHANGELOG.txt      带日期和原因的变更记录。任何用户可见或行为层面的改动都要在
                     这里补一条。
  LWIP\README.txt    本应用所监管的 Python 纠偏/裁切/缩略图守护工具。
                     中文版：LWIP\README_CN.txt。
  LWCam Workflow & SQL update\
                     采集侧数据库结构 SQL 与 ERD 图。


常用命令
--------------------------------------------------------------------------------

    flutter pub get                          安装依赖
    flutter run -d windows                   运行
    flutter build windows --release          发布构建
    flutter analyze                          静态分析
    flutter test                             全部测试
    flutter test test/services/transfer_destination_service_test.dart

基于 Flutter 3.44.4 stable（Dart 3.12.2）构建。`flutter build windows` 需要
Visual Studio 2022 并勾选「使用 C++ 的桌面开发」工作负载。

当前状态：`flutter analyze` 报告 6 条 info 级提示，无错误。


运行前提
--------------------------------------------------------------------------------

  adb.exe    按以下顺序查找：exe 同级目录、项目根目录、
             C:\Android\platform-tools\adb.exe、PATH。

  scrcpy     Windows 版本，放在 exe 同级目录。仅 Box Mode 的实时手机投屏需要。

  已配置好的工作站。LWCAM 没有设置页面。PostgreSQL 连接、图像目标根目录、LWIP
  开关全部来自 %USERPROFILE%\LWCAM_DBs\lwcam_node_config.json，该文件由同族应用
  LWCam Admin 的 Station Setup 页面写入。请先运行 LWCam Admin。如果应用提示目标
  目录为空，那是 Station Setup 该做的事，不是本应用的缺陷。


两种采集流程
--------------------------------------------------------------------------------

两者由 LWCam Admin 中按账号设置的 metadata keying 开关切换。

  Normal Mode（/gallery，keying 关闭）
      传统流程。从手机拉取，转存到按日期组织的目标目录。

  Box Mode（/boxes，keying 开启）
      采集箱（capture box）包含若干已录入元数据的文件夹（cover tag、image tags、
      title、volume、起止日期、档案参考号、记录类型）。转存时每个文件夹得到自己
      的目标子目录。转存在后台按箱排队执行；每个箱子的卡片显示实时进度，并持久化
      保存结果状态，重启后依然存在，中断、部分完成或失败的箱子提供单独的重试。

转存产生的目标目录结构：

    <根目录>\<工作周，例如 "June 15-19">\<YYYYMMDD>\<文件夹>\

工作周为周一至周五；周末日期归入前一个工作周。这是唯一一段从分叉前应用原样继承
且有单元测试覆盖的代码（test/services/transfer_destination_service_test.dart）。


可靠性机制
--------------------------------------------------------------------------------

改动转存流程前请先理解这一节。

  超时         单文件复制硬性上限 10 分钟；停滞检测 30 秒，每 5 秒检查一次；
               目标可用性轮询并弹出重连对话框。常量位于
               lib/controllers/upload_contoller.dart 顶部。

  崩溃恢复     基于数据库，而非检查点。`upload_records` 行只在复制校验通过之后
               才写入，重启后的批次会跳过已记录的文件名。基于序号续传的检查点已
               于 2026-07-20 被刻意移除——每次运行都根据磁盘现状重新分配文件名，
               所以保存下来的序号在重启后永远对不上。请不要再加回来。

  采集完整性   每张图片的 `capture_images` 归属记录是箱子成员关系的唯一凭据，
               因此采集时写入失败绝不能悄无声息。写入失败会把已拉取的字节存入
               文件系统上的孤儿账本——刻意不用数据库表，因为出问题的正是数据库
               ——并且 `verifyBoxComplete` 会拦住每一次「转存完成」标记。数量对
               不上时箱子停留在 'partial'，绝不会标记为已转存。

  加锁         批次执行期间用操作系统级文件锁和 WAL checkpoint 保护 SQLite 数据
               库（lib/services/file_lock_service.dart，111 行，代码自解释）。


以下不是笔误，是刻意保留
--------------------------------------------------------------------------------

  * lib/controllers/upload_contoller.dart 拼写有误，但这个错误是有依赖的——
    import 依赖该文件名。

  * lib/pages/settings_page.dart 里只有 `SettingsController`。没有设置页面；
    文件名保留的原因同上。

  * 带 emoji 前缀的 print() 日志是本项目既定风格。analysis_options.yaml 中刻意
    忽略了 `avoid_print`、`deprecated_member_use` 和
    `no_leading_underscores_for_local_identifiers`。

  * lib/pages/gallery_page.dart 约 5900 行，承载 ADB 通信、图像重拍流程和 QC
    返工回路。项目惯例是：除非必须，不为新功能改动此文件。其中 ADB/转存的那一半
    请当作不可触碰。

  * windows/runner/resources/LWCAM.iss 手工列出要打包的插件 DLL 和 scrcpy 目录，
    没有任何自动化。新增插件而不更新 .iss，发布版会在干净机器上运行时失败。

  * win32、ffi、hotkey_manager 保留在 pubspec.yaml 中，即使目前用得很少——手机
    投屏和远程快门的底层依赖它们。


相关应用
--------------------------------------------------------------------------------

  LWCam Admin        users、projects、app_settings 的唯一写入方，也是工作站配置
                     的唯一编辑入口。LWCAM 只拉取、不写入，仅有三个白名单调用
                     例外：修改自己的密码、记录登录时间、置位项目 `has_data`。

  LWCam QC Platform  网页版 QC 控制台。打回的结果以 `rework_logs` 行回到 LWCAM，
                     在箱子列表上显示为 "Needs Rework" 徽标。

  LWRework           独立的返工专用分支应用，不在本次交接范围内。注意 LWCAM 自身
                     也有一套返工回路（2026-07-30 加入），那是位于
                     gallery_page.dart 内的另一套设计，与 LWRework 中的独立
                     Rework Mode 不是一回事。
