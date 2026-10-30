[English](TESTING.md) | 简体中文

# 测试

本页列出每一个测试套件、运行位置，以及在干净检出的代码上应当看到的结果。请先按 [DEV-SETUP.zh-CN.md](DEV-SETUP.zh-CN.md) 配好工具。

如果某个数量与表中不一致，说明是你的改动导致的。请在发起拉取请求（PR）之前先查明原因。

## 1. 测试套件

| 套件 | 运行位置 | 命令 | 干净检出时的预期结果 |
| --- | --- | --- | --- |
| QC 后端 | `LWCam_QC_Platform/backend` | `python -m unittest discover -s tests -t .` | 405 个测试，跳过 8 个（数据库测试，见第 2 节） |
| QC 前端 | `LWCam_QC_Platform/frontend` | `npm ci`，然后 `npm run build` | 构建成功且没有类型错误。构建会运行 `vue-tsc --noEmit && vite build`。 |
| LWIP | `LWIP/backend` | `python -m unittest discover -s tests` | 328 个测试；跳过数及两项长路径对照结果取决于环境（第 3 节） |
| Upload | `LWCam_Upload/backend` | `python -m unittest discover -s tests` | 160 个测试全部通过 |
| LWCAM | `LWCAM` | `flutter analyze`，然后 `flutter test` | Analyze：5 条 info。Test：546 个通过。 |
| LWCam Admin | `LWCamAdmin` | `flutter analyze`，然后 `flutter test` | Analyze：无任何提示。Test：136 个通过。 |

测试套件使用 `unittest`，不需要 pytest。`LWIP/RUN_TESTS.bat` 使用安装程序构建的私有运行时运行 LWIP 测试套件；在开发用 PC 上请使用上表中的命令。

请使用你安装的 Python 3.14.8 中的 `python`。Python 测试套件请按表中所示，用 `unittest discover -s tests -t .` 或 `-s tests` 运行。这种写法会把工作树放进 `sys.path`。不要用已安装副本的 `._pth` 运行时来测试（参见 [DEV-SETUP.zh-CN.md](DEV-SETUP.zh-CN.md) 中的陷阱）。

QC 测试全部通过时，仍会出现一些正常的日志行。"cv2 is not importable; falling back to Pillow BICUBIC" 来自一个故意隐藏 `cv2` 的测试。"AI review OpenRouter call failed" 来自使用桩（stub）的重试测试。

## 2. QC 后端：数据库测试

数据库测试（位于 `tests/test_setup_qc_db.py`，可能还有其他文件）需要一个可访问的 PostgreSQL。没有凭据时它们会被跳过，这些就是干净检出计数中被跳过的测试。要运行它们，请提供一个能创建临时数据库的管理员账号：

| 变量 | 默认值 | 含义 |
| --- | --- | --- |
| `LWCAM_DB_PASSWORD` | 无（测试被跳过） | PostgreSQL 管理员的密码 |
| `LWCAM_DB_USER` | `postgres` | 管理员用户 |
| `LWCAM_DB_HOST` | `localhost` | 主机 |
| `LWCAM_DB_PORT` | `5432` | 端口 |

示例：

```
set LWCAM_DB_PASSWORD=<postgres password>
python -m unittest discover -s tests -t .
```

如果没有设置 `LWCAM_DB_PASSWORD`，而 `LWCam_QC_Platform/config.txt` 存在，测试会从中读取 `dbHost`、`dbPort`、`dbUser` 和 `dbPassword`。测试会创建并删除一个名称以 `lwcam_setup_test_` 开头的临时数据库，不会触碰你的真实数据库。

未经确认：设置该变量后，被跳过的测试的确切数量。请在你的 PC 上核对，并写进你的拉取请求里。

## 3. LWIP：两个已知失败

`tests/test_long_paths.py` 中有两个反向对照测试：

- `test_a_long_path_is_writable_only_through_fs_path`
- `test_the_same_folder_fails_without_the_guard`

它们检查：超过 260 个字符的路径，在没有 LWIP 所用的 `\\?\` 保护时会失败。在开启了 Windows 长路径支持的 PC 上，即使没有这个保护，长路径也能正常工作，于是测试因为"预期出错却没出错"而失败，这不是代码的问题。在启用长路径的 PC 上，请预期这 2 个失败；未启用长路径支持的 PC 应当通过它们。7 个被跳过的测试针对其他平台或其他条件（例如 `test_non_windows_is_untouched`，它只在 POSIX 上运行）。

## 4. Flutter 说明

- LWCAM 的 `flutter analyze` 会报告 5 条类型为 `curly_braces_in_flow_control_structures` 的 info，位于 `box_session_controller.dart`、`box_integrity.dart`（两处）、`pg_sync_sink.dart` 和 `transfer_queue_service.dart`。出现新的 info 或 warning 就属于回归。
- 在全新克隆的仓库上，请先运行 `flutter pub get`。

## 5. 端到端检查

仓库中没有自动化的端到端测试框架。`verification/` 文件夹里是一些一次性的图像处理研究脚本（几何、色调、导出保真度），它们不是测试套件，并且需要示例图像。它们测得的结果见 [FAMILYSEARCH-FIX.md](FAMILYSEARCH-FIX.md)。

要测试整条流水线，请按 [INSTALL.zh-CN.md](INSTALL.zh-CN.md) 第 9 节（"验证系统是否正常"）的手工流程操作。没有相机时制造测试文件夹，见 [DEV-SETUP.zh-CN.md](DEV-SETUP.zh-CN.md) 第 7 节。

## 6. 发起拉取请求之前

1. 对你改动过的每个模块运行其测试套件。如果改动了共享代码（数据库结构、`lwcam_secrets.py`、导出格式），则全部运行。
2. 把每个结果与第 1 节的表对比。
3. 如果改动了 QC 前端，运行 `npm run build`。
4. 如果新增了数据库迁移脚本，请在设置了 `LWCAM_DB_PASSWORD` 的情况下运行 QC 后端测试，并对一个临时数据库连续运行两次 `python scripts\setup_qc_db.py`。
5. 如果改动了 `lwcam_secrets.py`，必须以同样的方式修改全部四份副本，它们必须逐字节完全相同，安装程序构建时会检查这一点。
6. 检查换行符（`file <path>`）和 `git diff --stat`。一处小改动不应该显示成每一行都变了。
7. 对用户或站点会注意到的任何改动，在 `CHANGELOG.md` 中加一行。
8. 在拉取请求中写明你运行了哪些测试套件以及各自的数量。GitHub 方案没有强制评审，也没有 CI，所以这些本地检查是唯一的关卡。

## 7. 发布前的手工测试清单

请在真实的、相互独立的 PC 上完成这些检查，一台 PC 无法证明它们。完整的检查清单见 [INSTALL.zh-CN.md 第 14 节](INSTALL.zh-CN.md#14-在多台独立-pc-上验证站点)。

- [ ] **SYSTEM 账户登录真实对端。** 在每台服务 PC 上，已保存的网络文件夹登录凭据对 SYSTEM 账户有效（用计划任务或 `psexec -s` 测试）。当 QC、LWIP 和 Upload 共用一台 PC，并以不同账户访问同一台对端 PC 时，会出现错误 1219。每台对端 PC 只用一个账户。
- [ ] **对端重启后共享文件夹恢复。** 重启对端 PC。服务 PC 在无人登录的情况下重新连上共享文件夹，状态提示随之消失。
- [ ] **异地采集通过 Tailscale 写入 LWIP 输入文件夹。** 用一批真实数据测量复制速度。对采集 PC 上交互登录的 Windows 用户运行 `cmdkey`。确认复制超时时间适合你的链路。
- [ ] **`qcInputRoot` 设为 LWIP 的 UNC 共享时的 QC。** 审核并通过一个普通文件夹和一个拆分文件夹（LWIP 分多部分写出的一个批次）。
- [ ] **数据库 PC 强制断电重启**，分别发生在批处理、导出和上传的中途。每个部分都变红，然后自行恢复，没有数据丢失或重复。
- [ ] **QC PC 在导出中途断电。** 该文件夹在大约 2 到 3 分钟内可以再次导出。
- [ ] **浏览器通过 MagicDNS 名称访问每个控制台**（Tailscale 晚于服务启动）。证书仍须与该名称匹配。
- [ ] **一次真实的 S3 上传**，其中包含对此前已上传的某个交付包做客户返工后的重新上传。
- [ ] **升级路径。** 安装上一个发布版本，然后按 [INSTALL.zh-CN.md](INSTALL.zh-CN.md) 第 11 节的顺序升级。检查 System status 页面，以及一次返工往返。
- [ ] **备份与恢复。** 运行一次备份，在临时 PC 上恢复它，并确认某个部分能够登录。

注意：当 Upload 的 `done_root` 与导出共享文件夹不在同一个卷上时，已完成的交付包会先被复制，再通过 SMB 删除，速度较慢。Upload 账号需要在导出共享文件夹上拥有删除权限。
