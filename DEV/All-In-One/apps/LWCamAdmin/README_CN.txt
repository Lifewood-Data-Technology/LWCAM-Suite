================================================================================
 LWCam Admin 管理端
================================================================================

英文版本见 README.txt。英文为主文档，更新时以英文版为准，本文件为其翻译。

LWCam Admin 是 Flutter Windows 桌面应用，集中了 LWCAM 套件的全部 SuperAdmin 能力：
用户管理（账号、角色、Device ID、重置密码）、项目管理（增删改查、元数据模板）、
设备改绑、共享应用设置，以及每台机器的工作站配置。

它是共享 PostgreSQL 库中 `users`、`projects`、`app_settings` 的唯一写入方，也是
lwcam_node_config.json 的唯一编辑入口——LWCAM、LWIP、QC 后端都读这个文件。任何新
机器都请先运行本应用。

包名 `lwcam_admin`。仅支持 Windows。没有采集流程，不用 ADB，不用 sqflite，不连手机。


文档
--------------------------------------------------------------------------------

  CLAUDE.md       请先读这个。完整架构、PostgreSQL 网关、离线队列式写入模型，以及
                  本应用存在的原因。
  CHANGELOG.txt   自 2026-07-21 起的带日期变更记录，那天本应用从 LWCAM 拆分出来。
                  在此之前没有历史。


常用命令
--------------------------------------------------------------------------------

    flutter pub get                          安装依赖
    flutter run -d windows                   运行
    flutter build windows --release          发布构建
    flutter analyze                          静态分析
    flutter test                             全部测试

基于 Flutter 3.44.4 stable（Dart 3.12.2）构建。`flutter build windows` 需要
Visual Studio 2022 并勾选「使用 C++ 的桌面开发」工作负载。

当前状态：`flutter analyze` 无任何问题。


登录
--------------------------------------------------------------------------------

只有 SuperAdmin 能登录本应用。这里没有多用户登录——本应用创建的账号只能登录
LWCAM，永远登录不了这里。

登录按以下顺序校验：

  1. PostgreSQL 的 `app_settings.superadmin_password_hash`（覆盖值）
  2. 本地快照中同一覆盖值的副本
  3. 编译进 lib/auth/super_admin.dart 的 bcrypt 出厂哈希

因此在离线、全新机器、数据库不可达、尚未配置存储的情况下都能登录。出厂哈希只生成
过一次，无法从本仓库的任何内容推导出来。

  >>> 出厂 SuperAdmin 密码请向 Lifewood 索取。本次交接刻意没有写下该密码。


本应用负责的范围
--------------------------------------------------------------------------------

  PostgreSQL   users、projects、user_projects、roles、app_settings。
               唯一写入方。LWCAM 只做拉取。

  工作站配置   lwcam_node_config.json，默认位于 %USERPROFILE%\LWCAM_DBs。
               Station Setup 是整个套件中唯一的编辑入口：本应用的 PostgreSQL
               连接、LWCAM 的采集 outbox 同步开关、图像目标根目录、LWIP 图像处理
               开关及其目录覆盖项。整个套件没有任何需要手工编辑的配置文件。

新机器的引导流程是刻意这样设计的：在新采集机上运行一次便携版 LWCam Admin，填好
Station Setup，LWCAM 下次启动时就会读到同一个文件。


动手改代码前需要知道的设计约束
--------------------------------------------------------------------------------

  * 所有写操作都走 lib/services/admin_store_service.dart 里的 `_mutate`：先对账
    （先拉取再变换，避免把线上编辑套在过期的本地副本上），再执行并校验，然后要么
    在线推送、要么带 tombstone 离线入队。推送中途失败会降级到离线分支，而不是丢
    掉这次编辑。改这个文件前请先读这个方法。

  * 所有 SQL 都在 lib/services/admin_pg_statements.dart 中，是不 import
    `postgres` 的纯 Dart 构造器，无需数据库连接即可单测。
    test/services/fake_admin_gateway.dart 是网关本身的测试替身。

  * upsert 的冲突键是 projects(project_key)，绝不是 project_id。`project_id` 是
    本应用可以随意重命名的人类可读标签；用它做冲突键会在每次重命名时产生一条重复
    的云端记录。

  * 用户 upsert 的 DO UPDATE 刻意排除了 LWCAM 拥有的列：`last_login_at`、
    `password`、`must_change_password`。整库推送若携带过期快照，绝不能把采集端用户
    刚改的密码回退掉。管理员主动改密码走的是定向的 `userPasswordResetSql`。

  * projectSoftDeleteSql 会把 `country_location_code` 改写成 `~deleted~<id>`。
    该列是 `devices` 引用的唯一 FK 目标，真实编码必须释放出来供重新使用。

  * `buildUsersStoreFromPgRows` 从 `users.roles` 读取全局角色，不从
    `user_projects` 反推——否则没有任何项目的管理员会在下次拉取时悄悄丢掉角色。

  * lib/theme/ 与 LWCAM 的副本逐字节相同，请保持这样；Lifewood 品牌主题是共享的
    设计语言，不是各应用私有的。三个 Flutter 应用是 fork 式副本而非共享库，这是
    刻意的——它们各自独立发版。

  * windows/runner/resources/LWCamAdmin.iss 有独立的 AppId GUID，因此可与 LWCAM
    并存安装。它手工列出要打包的插件 DLL；新增插件而不更新它，发布版会在干净机器
    上运行时失败。

  * 带 emoji 前缀的 print() 日志是既定风格，与 LWCAM 一致。analysis_options.yaml
    中忽略了 `avoid_print`、`deprecated_member_use` 和
    `no_leading_underscores_for_local_identifiers`。
