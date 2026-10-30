# Metadata 提交解除照片共享目录依赖（2026-10-28）

本轮补齐负责人 Minor 中的 Metadata-only share 意见。修复基于 `ef29c64`，作为后续提交更新原 PR。下列测试和证据是在本次提交前采集，不代表最终安装升级验收。

## 现在的行为

- 普通“通过修改资料解决”提交，不调用 `_resolveReworkInput`，不读取照片、capture marker 或校准侧文件；共享目录离线、照片不存在也不妨碍排入本地 SQLite/outbox。数据库同步仍走现有机制。
- 新暂存记录带本地 apply protocol 2 和文件夹业务键。照片替换开始前，先持久化 applying，再写远端门闩和照片，关闭此前“远端已动、本地尚未标记”的窗口。
- 对同目录检查本地未完成替换，包含未出现在当前工作列表中的其他页面；它们不能通过 Metadata 绕过。其他目录、其他采集设备不受该目录状态影响。
- 混合返工的照片读取、替换或参数写入失败时，不关同目录的资料修正待办，也不错误重置 QC；修复后可完整重试。
- 返工 closure 同一 SQLite 事务写入精确代次的提交凭据，存于已有 `sync_meta`。若提交后删除 intent 失败，后续 Metadata 可识别已完成的代次；事务回滚不产生凭据，旧凭据不能豁免新替换。每个目标只保留最新凭据。
- 新协议未开始的暂存可在本地 Undo，不需要读取目标照片。已经开始的操作继续保留恢复记录。

## 旧版恢复例外

旧 intent 没有新协议的写入顺序保证，可能已经写远端门闩，但还没记录 applying。只有发现这种具体遗留记录时，才限时检查旧目标、门闩与摘要。源不可达或记录损坏时保留记录并明确要求恢复；不能把“不知道是否已替换”当成普通 Metadata 放行。旧记录在重新拍摄时同样不得丢失此不确定状态。

本地检查针对本机仍存在的恢复记录；不声称能推断其他电脑或已被人为删除的记录。跨真实电脑及 SYSTEM/SMB 权限仍需原计划的现场验收。

## 验证

- 修复前对照：使用旧生产 Submit/Undo/button 方法，普通 Undo 后模拟输入共享目录不可达，出现 2 次源探测且无法关单；新回归确实失败。
- LWCAM 完整 suite：**544 tests passed**（原 526 + 新 18）。
- Flutter analyze：无 error/warning，只有既有 **5 infos**；其命令因 infos 返回 1，不冒充退出码 0。
- 扩展生产方法／真实原子替换／SQLite／真实 PG 接受宿主：**25 tests passed**（原 16 + 新 9）。普通 Metadata 的源解析调用数为 0；实际 PG 收到 CLOSED / Metadata 与 PENDING。
- 覆盖新旧暂存、正常 Undo、共享目录离线、替换中断、同目录隐藏 sibling、路径变化、混合提交、事务回滚、marker 首次写入失败、提交后 intent 残留与旧凭据保护。
- 当前修改未触及 Python 服务、Admin、几何或色彩算法，无新依赖、无 schema migration。既有 Python/Admin 测试结果为上一轮证据，本轮未重跑。

证据见 `evidence-metadata-share-20261028/`，含修复前失败、完整测试、扩展宿主、分析日志和源码 SHA256。Windows Release 构建结果另见该目录的构建日志与最终结果 JSON。

本轮未重新点击完整原生/浏览器 UI 闭环，不能把提取生产方法的集成宿主描述为新的 Computer Use 验收。最终安装包和覆盖升级验收仍待构建输入准备完成。

## 复跑

在仓库根目录执行（需现有 Flutter/Python 开发环境和可访问的本机 PG 配置）：

```powershell
$env:PUB_CACHE = 'D:\LwcamDev\pub-cache'
& D:\LwcamDev\venvs\lwip\Scripts\python.exe verification/pr-review-20261027/build_metadata_share_acceptance.py
& D:\LwcamDev\venvs\lwip\Scripts\python.exe verification/pr-review-20261027/run_blocking_fix_review.py --flutter D:\LwcamDev\tools\flutter\bin\flutter.bat --template verification/pr-review-20261027/metadata_share_acceptance.template
```

纯 Metadata 已不再属于正常业务路径对共享目录的依赖差异。关闭校准后未知历史仍需明确确认的另一项策略没有在本轮改变，继续交负责人复审。
