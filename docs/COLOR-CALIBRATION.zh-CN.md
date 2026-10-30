# Issue #1：独立模块的逐页色彩校准

## 实现边界

LWCAM 只拍色卡并向 `destinationPath/.calibration/<UUID>` 提交文件任务。
LWIP 在原有服务内独立扫描该目录，使用自身 Python 启动短生命周期分析进程；
LWCAM 读取结果，操作员确认后才激活。采集电脑不需要 Python 或本机 LWIP。
不会增加 Calibration 服务、计划任务、端口或供采集端调用的 HTTP API。
算法完整包位于 `LWIP/backend/color_cal_tool`；QC 只携带参数校验及应用代码。

任务协议、字段、样例及状态机见 [CALIBRATION-PROTOCOL.md](CALIBRATION-PROTOCOL.md)。

本版本支持 Box Mode 及补拍。Normal Mode 保持原有图像流程并提示不支持校准。
Station Setup 的 `colorCalEnabled` 默认关闭。没有当天、当前业务设备和当前手机对应的
有效参数时，操作员必须明确选择返回或不校色继续；不得自动使用昨天的参数。
旧照片或无法确认采集边界的照片标记为 historical，不套用当前参数。

## 图像与参数如何流转

1. 进入 Box Mode 前可拍摄色卡，自动检测失败时可指定四角后重算；操作员保存后才激活。
2. 新照片分配到文件夹时，将当时的参数内容与照片名绑定到本地 SQLite；不是到传输完成时再读 active.json。
3. 图像复制验证完成后，交接标记 `lwcam_capture_marker.json` 写入 `color_calibration`。
   `profiles` 按原始 UTF-8 JSON 字符串的 SHA-256 存储参数；`images` 按最终传输文件名引用。
   未校色页保存明确原因：disabled、skipped、historical 或 external。
4. LWIP 校验绑定、哈希与参数结构，在原有几何处理后只给缩略图校色。
   完整图像继续走原有无损裁切/原字节复制流程；清单保存参数与校准摘要。
   只改参数也会触发重新处理。损坏标记、缺失引用或校准参数非法会阻止发布并记录失败。
5. QC 预览按同一份参数渲染，缓存键包含参数摘要。已校色的 LWIP 缩略图不会再次校色；
   校准页当前从源图重建预览，避免无法验证缩略图版本时重复应用。
6. Approve 保存几何操作。TIFF 导出先重放几何，再校色，最后编码一次；JPEG 导出也遵守
   校色开关，只有无几何且无校色时可以直接复制。输入图像不因校色而改写。
   TIFF Software 标签和导出日志记录 profile ID；校色后不沿用相机 ICC。
7. QC 上传、插入或替换的外部图像默认不套用采集校准。分卷保留对应页的绑定，
   去掉无关参数。恢复原图时重新采用其采集绑定。

亮度调整仍是既有的显式像素编辑例外，默认关闭；本改动不改变其授权与配置。

## 补拍与异常恢复

- QC 退回补拍：先将新图、参数侧文件及两者摘要保存到用户目录的 `color_rework`。
  提交时先设置 `rework_in_progress`，原子替换图像，再更新该页参数和本地绑定。
  全部完成后才清除标记、关闭补拍任务。进程重启后不自动提交旧 intent；未提交的
  返工照片保留但作废，需重新拍摄（照片清理属于后续任务生命周期工作）。
- 任一写入失败，保留补拍 intent 与阻塞标记；排除共享目录/权限故障后重新提交。
  标记损坏或缺失时先恢复备份，不能手工删除标记来绕过交接检查。
- 纯 Metadata 提交不解析或访问照片输入共享目录；新协议先持久化本地 applying，再写远端门闩。
  同目录中尚未完成的替换（包括不在当前工作列表中的页）仍会阻止关单；完成恢复后可重试。
  返工 closure 同一 SQLite 事务记录精确代次的提交凭据，避免事务已提交但 intent 清理失败
  卡住后续资料修正；旧凭据不能豁免新的替换。该凭据使用现有 sync_meta，不改 schema。
  只有旧协议留下、无法从本地证明未开始的 intent 才检查共享目录、门闩及目标摘要；
  此类恢复例外在共享目录离线时明确提示，不能当成普通 Metadata 自动放行。
- 传输前的槽位补拍：保存持久化副本后才替换；中断时本地 pending 记录会阻止传输。
  打开该箱时逐页恢复；某页记录损坏只报告该页（页名、原因、记录目录），其他页照常加载，
  该页的 intent、副本和 pending 保留，传输继续拒绝。重新补拍该页并正常保存即可解除；
  无法读取的旧 intent 先另存为 `intent.unreadable-*.json`，新一代沿用“已开始”状态。
- 手机暂时无法识别（序列号或列表读取失败）时暂停入库和绑定，已建立的拍摄边界和
  “不校色继续”决定保留；同一手机当天恢复后，期间拍的新照片仍按原决定绑定。
  确认更换手机或跨日会重新建立边界，不沿用其他手机的参数。
- 输入共享目录路径改变后，替换中断的页面按文件夹与页名查找。只有在新旧路径被证明是
  同一目录（经旧路径写入的探测文件可经新路径看到）时，才在新路径继续该操作；旧记录在
  新一代 closure 提交后才退役。提交前在新路径再次补拍该页时，新一代沿用同一旧代次的
  退役关联（重启后同样）；旧记录只按该精确代次退役，旧路径上更新的代次仍然阻塞。
  旧位置不可达或是另一目录时不自动处理：提示页名、旧路径
  与记录目录，该文件夹保持阻塞（旧位置的门闩可能仍被持有）。管理员应暂时恢复 Station
  Setup 中原输入目录，重新进入返工完成提交，再改回新路径。
- 每条补拍记录的 `owner.json` 记录设备、目标路径和文件夹；目录名是目标路径的哈希，
  因此 intent 损坏时仍可证明归属，只阻塞其所属文件夹，重新补拍该页即可替换。
  intent 可读但字段类型错误（如 `folder_key` 不是文本）同样按记录问题处理：文件夹由
  intent 或已验证的 `owner.json` 证明时只阻塞该文件夹；两者所记文件夹不一致时两个都阻塞；
  `folder_key` 损坏且 `owner.json` 没有已验证的文件夹时无法排除任何文件夹，阻塞本机全部。
  `owner.json` 写着其他设备时，只有“该设备 + 目标路径”的哈希等于记录目录名才视为其他设备
  的记录而跳过；否则按归属矛盾的损坏记录处理，照常阻塞并在提示中写明。
  intent 的代次文件名缺失、类型错误或不合法时，在返工列表中重新补拍该页即可替换：原 intent
  原样另存为 `intent.damaged-*.json`，新一代沿用“已开始”状态和仍有效的旧路径关联。
  提示只在补拍确实能替换时才建议补拍；未知协议、`applying` 类型错误等补拍不能替换的情况
  提示由管理员处理。损坏记录对应的页面不在返工列表中时，无法在程序内补拍（残留限制）。
  旧版记录没有目标路径，intent 又无法读取时无法归属，会阻塞本机所有文件夹的资料提交
  （残留限制）。处理办法：管理员按提示的记录目录，从其中照片确认对应页面，检查该文件夹
  输入目录的标记 `rework_in_progress` 与目标照片；在该页重新补拍并提交成功后，关闭 LWCAM，
  将该记录目录移入 `LWCAM_DBs\color_rework_quarantine\`（不要删除），并记录审计说明。
  未确认目标页状态前不得隔离，否则可能把替换了一半的页面按资料修正关单。
- 旧版文件夹如有有效的 `color_profile.calibrated_today=true`，补拍转换为逐页绑定时
  保留其他页原参数；历史日期不会使已经绑定的交付页突然失去校准。
- 数据库恢复会携带校准表。若无法恢复，记录完整性阻塞，不能悄悄把已校准页当旧页导出。
  传输前会显示真实原因；操作员可对无绑定页明确确认按 historical 传输（写入审计），
  已绑定页保留原参数；所有 OPEN 页都有有效决定后才清除全局标记。损坏绑定（含参数丢失）
  只能在本箱重新补拍该页解决；程序内没有恢复校准数据的功能。不要直接清空
  `color_integrity` 绕过检查。

## 部署步骤

1. 备份采集端 `LWCAM_DBs`（包括 SQLite、color_cal、color_rework）、LWIP 状态与配置、
   QC 配置和业务图像目录。保留现有安装包，以便回退。
2. 构建并升级 QC，再升级 LWIP，最后升级 LWCAM + Admin。完成三端升级前保持开关关闭。
   老版消费者不认识新参数，不能让其接收已启用校准的新批次。
3. 由构建机准备 `installer/README.md` 的全部输入：Release Flutter 构建、Python 嵌入式包、
   VC DLL 和离线 wheel。只有 LWIP 安装完整分析算法，安装自检导入算法、协议及工作进程入口。
   QC 使用本地消费者副本，构建脚本及测试检查它与 LWIP 的五个消费者文件字节一致。
4. 构建 `QC`、`LWIP`、`LWCam` 三个目标；采集安装包不包含 ColorCal Python、依赖或初始化脚本。
   LWIP 仍只注册 “LWCam LWIP” 启动任务。升级前按安装目录匹配停止 Python，覆盖分析子进程。
   不删除旧 ColorCal 用户记录、已绑定页面或历史工具目录。
5. Station Setup 打开 Colour calibration 开关并保存。LWCAM 重新读取配置/重新登录，
   进入 Box Mode，拍色卡并保存。确认手机更换、跨日时不会沿用旧参数。
6. 先完成下列验收，再用于真实批次。本次不需要升级 PostgreSQL schema，
   本地采集 SQLite 从 v2 自动迁移到 v3；Upload 和数据库安装器无需改动。

## 验收清单

- 同一文件夹混合“参数 A / 明确跳过 / 参数 B”三页，检查标记绑定、QC 预览及 TIFF 各自正确。
- 对比输入图像 SHA-256，确认校准和审批不改原图；无校准、无操作的 TIFF 像素与相机解码一致。
- 修改参数但不改图像，LWIP 应重新处理，QC 预览缓存应失效。
- 修改参数内容但保留旧哈希，或删掉引用的 profile，LWIP 不发布，QC 不审批/导出。
- QC 外部插入/替换页不校色；分卷、保存、重开后规则不变。
- 补拍 A 页，B 页原绑定保持不变；共享目录断开、进程中断后重新提交，图像与参数必须成对恢复。
- 校准分析超时或失败时给出稳定错误；共享目录失联时保持等待，文档服务继续独立工作。
- 在未安装 LWIP 的采集 PC 上完成校准，在另一台 QC PC 上预览并导出。

## 验证范围

自动化覆盖算法、参数校验、源图保护、缓存、导出、分卷、逐页存储、v2 迁移和补拍侧文件。
真实手机/色卡、跨电脑共享目录、离线安装修复及生产安装包仍需上述现场验收。
本工作区缺少安装器 vendor/wheel/Release 输入，不能把源码测试通过当作安装包已构建。

## 不打包的源码验证

在测试电脑上准备 Python 3.14 环境和 `LWIP/requirements.txt` 的依赖，复制示例配置。
设置 `input_root`、`output_root`、本地 `work_root`，使用独立测试数据库或关闭测试配置的 cloud_report。
从 `LWIP/backend` 运行：

```powershell
python -m deskew_crop_tool.service --config ..\config\deskew_crop_config.json
```

必须启动 `service`，单独运行文档 `--once` 不启动色卡协调器。安装版仍运行原有 START_LWIP.bat。
采集端使用 Flutter 运行，Station Setup 的 destinationPath 指向同一物理输入目录；
不要修改 processingInputRoot。开发版手机连接仍需要 adb/scrcpy，参见项目开发指南。

```powershell
# 分别进入相应目录后执行
flutter analyze
flutter test
# LWIP/backend
python -m unittest discover -s tests
# LWCam_QC_Platform/backend
python -m unittest discover -s tests -t .
# LWCam_QC_Platform/frontend
npm run build
# installer（先准备 Release 和离线输入）
powershell -File build-installer.ps1 -Target QC
powershell -File build-installer.ps1 -Target LWIP
powershell -File build-installer.ps1 -Target LWCam
```

## 两机验收和恢复

采集 PC 仅部署 LWCAM/Admin 并接手机；处理 PC 部署 LWIP/QC，使用独立测试数据库。
例如采集端 destinationPath 为 `\\PROCESS-PC\LWIP-Input`，处理端 input_root 为
`D:\LWIP\1.Images`，两者必须指向同一目录。SYSTEM 服务通过已有网络登录配置访问共享目录；
不能使用交互登录用户的映射盘符。一个物理输入根只允许一个 LWIP 消费者。

1. 开启校准，提交色卡。关闭采集程序后，确认 LWIP 能完成任务；重开后点击 Resume saved calibration task，查看并确认。
2. 任务等待期间离开页面或点击 Cancel，只停止本地等待。超过 120 秒的客户端提示不代表远端失败。
3. 多台采集设备提交，逐个核对 device_id、phone_serial、task_id 和照片摘要，不得串结果。
4. 分析过程中重启 LWIP。未完成任务重新校验执行；成功但尚未发布的任务恢复后只重试发布。
5. 断开共享目录再恢复，结果应仍可取回；不得自动激活。任务失败后用新 UUID 重试，不编辑 ready 后的请求。
6. 换手机、跨采集电脑当地午夜、重拍后取得旧结果，均不得激活旧任务。
7. 查看 QC 和导出包，确认没有色卡页；校准目录在深度 1、2 下均被排除。
8. 先跑 10～20 页，再跑接近现场规模的批次。执行上面的逐页混合、补拍、分卷、导出验收。
9. 比较输入照片前后 SHA-256；不要要求无损裁切前后 JPEG 文件哈希相同。
10. 检查 Windows 任务：没有新增 Calibration 任务；在原有 8090 网页查看校准队列、失败和待发布状态。

“明确不校色继续”只冻结随后采集页面的 skipped 状态，不删除旧页面绑定。
首版不自动清理任务照片和本地诊断记录。已交接文档自带参数，删除已完成色卡任务副本后仍应可导出。
回退时先停新任务提交、关闭开关，备份未完成任务和 runtime/calibration；不得删除逐页 SQLite 表。
不得让不支持协议的旧 LWIP 接手新的校准队列。实机验收结果单独填写，未测项目不得填通过。
