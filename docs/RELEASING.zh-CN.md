[English](RELEASING.md) | 简体中文

# 发布流程

本页说明如何为发布版本编号、构建和发布。安装程序不放在 git 中，而是附加在 GitHub Release 上。所需工具请参阅 [DEV-SETUP.zh-CN.md](DEV-SETUP.zh-CN.md)，发布前要先跑的测试请参阅 [TESTING.zh-CN.md](TESTING.zh-CN.md)。

## 1. 版本号

| 内容 | 位置 | 规则 |
| --- | --- | --- |
| 发布版本 | 仓库根目录的 `VERSION`（一行，例如 `1.1.0`） | 发布时手工修改。 |
| 构建 ID | 简短的 git 提交号；如果工作树有未提交的改动，则加上 `-dirty` | 由 `installer/build-installer.ps1` 生成。 |
| 版本戳 | `<version>+<commit>`，例如 `1.1.0+a1b2c3d` | 写入每个安装文件夹中的 `VERSION.txt`（LWCam 则写在 `lwcam.exe` 和 `lwcam_admin.exe` 旁边以及根目录）。QC 的 System status 页面会显示每个部分的版本戳。 |

构建脚本读取 `VERSION`，并以 `/DAppVer` 和 `/DBuildId` 传给 Inno Setup。它会先写入 `installer/vendor/VERSION.txt`。如果你直接用 `ISCC` 编译某个 `.iss` 文件，这个文件必须已经存在。

发布版本的版本戳不能以 `-dirty` 结尾，请先提交所有改动。

`LWCAM/pubspec.yaml` 和 `LWCamAdmin/pubspec.yaml` 中的 `version:` 行（`1.0.0+1`）不是发布版本，安装程序的版本戳来自 `VERSION`。

## 2. 构建安装程序

你需要：Inno Setup 6、Flutter、Node.js 以及构建输入文件（见 [DEV-SETUP.zh-CN.md](DEV-SETUP.zh-CN.md) 第 3 节）。

1. 更新源码，并确认工作树干净：`git status`。
2. 运行测试（[TESTING.zh-CN.md](TESTING.zh-CN.md)）。
3. 构建两个 Flutter 应用。安装程序打包的是 Release 构建，所以过期的构建会带上过期的代码：

```
cd LWCAM      && flutter build windows --release
cd LWCamAdmin && flutter build windows --release
```

4. 构建安装程序：

```
cd installer
powershell -File build-installer.ps1 -Target All
```

目标（Target）：`Database`、`QC`、`LWIP`、`Upload`、`LWCam`、`All`。

| 目标 | 输出（位于仓库根目录） |
| --- | --- |
| `Database` | `LWCamDatabaseSetup.exe`，以及复制到其旁边的 PostgreSQL 安装程序 |
| `QC` | `QCPlatformSetup.exe`（脚本会先在前端目录运行 `npm ci` 和 `npm run build`） |
| `LWIP` | `LWIPSetup.exe` |
| `Upload` | `LWCamUploadSetup.exe` |
| `LWCam` | `LWCamSetup.exe` |

编译之前，脚本会检查：所有输入文件都存在；`lwcam_secrets.py` 的四份副本逐字节完全相同；内置的第三方文件与 `installer/SHA256SUMS.txt` 一致（第 3 节）。`-ResolveOnly` 只打印 Inno Setup 和 scrcpy 的路径，不构建任何东西。`-ScrcpyDir <folder>` 用于选择另一个 scrcpy 构建。

输出文件被 git 忽略（`*.exe`）。

## 3. 两种校验和

**`installer/SHA256SUMS.txt`**（在 git 中）固定了内置的第三方输入文件：Python zip、Visual C++ DLL、adb、PostgreSQL 安装程序、scrcpy、`LWIP/tools` 以及三个 wheel 文件夹。每个文件一行：`<sha256>  <path from the repository root>`。如果某个内置文件发生变化，构建会以 "Bundled file changed" 停止。在有意的变更之后（新的 wheel、新的 adb），运行：

```
powershell -File build-installer.ps1 -UpdateChecksums
```

然后提交 `installer/SHA256SUMS.txt`。Flutter 构建产物、`frontend/dist` 和 `vendor/VERSION.txt` 不在该列表中。

**发布校验和文件**是另一个文件，需要附加到 GitHub Release 上，其中列出你发布的安装程序。在仓库根目录生成它：

```
powershell -Command "Get-FileHash -Algorithm SHA256 LWCamDatabaseSetup.exe, QCPlatformSetup.exe, LWIPSetup.exe, LWCamUploadSetup.exe, LWCamSetup.exe | ForEach-Object { $_.Hash.ToLower() + '  ' + (Split-Path $_.Path -Leaf) } | Set-Content -Encoding ascii SHA256SUMS.txt"
```

如果你也发布 PostgreSQL 安装程序，请把它那一行也加进去。在 Release 中把文件命名为 `SHA256SUMS.txt`，它与 `installer/` 中的那个不是同一个文件。

## 4. 打标签并发布

标签采用 `v<version>` 格式。模块版使用 `v1.1.0`，一体版使用 `v1.1.0-all-in-one`，并打在 `lwcam-all-in-one` 分支上。

1. 确认 `VERSION` 和 `CHANGELOG.md` 无误，并且两者都已在 `lwcam-module` 上提交并推送。
2. 打标签并推送：

```
git tag -a v1.1.0 -m "LWCam v1.1.0"
git push origin v1.1.0
```

3. 从带标签的提交构建安装程序（版本戳必须显示该提交）。
4. 在 GitHub 上为该标签创建 Release。使用 `CHANGELOG.md` 中对应的章节作为发布说明。附加五个安装程序、PostgreSQL 安装程序（如果你发布它）和发布用的 `SHA256SUMS.txt`。

使用 GitHub CLI：

```
gh release create v1.1.0 LWCamDatabaseSetup.exe QCPlatformSetup.exe LWIPSetup.exe LWCamUploadSetup.exe LWCamSetup.exe SHA256SUMS.txt --title "LWCam v1.1.0" --notes-file release-notes.md
```

对于首个发布版本（v1.1.0），两个版本共用一个 Release 页面：模块版安装程序附加在 `v1.1.0` 下，一体版安装程序附加在 `v1.1.0-all-in-one` 下，各自附带校验和。

5. 在一台干净的 PC 上从 Release 下载这些文件，并核对哈希值。
6. 通知各站点，并让他们按 [INSTALL.zh-CN.md](INSTALL.zh-CN.md) 第 11 节的升级顺序操作。

## 5. 更新构建输入文件

名为 `build-inputs` 的私有 Release 存放着对 git 来说太大的文件（Python zip、vcruntime、adb、PostgreSQL 安装程序、wheel 包、scrcpy、LWIP 工具）。当其中任何一个发生变化时：

1. 在你的工作副本中替换该文件，路径见 [DEV-SETUP.zh-CN.md](DEV-SETUP.zh-CN.md) 第 3 节。
2. 运行 `powershell -File installer/build-installer.ps1 -UpdateChecksums`，并提交 `installer/SHA256SUMS.txt`。
3. 更新 `build-inputs` Release：上传新资源，删除旧资源；如果文件名变了，同时更新解包脚本。
4. 如果 Python 版本变了，还要修改 `build-installer.ps1` 中的文件名（`python-3.14.8-embed-amd64.zip`）以及各个 `.iss` 文件，并在整个仓库中搜索旧名称。
5. 在 `CHANGELOG.md` 中说明改了什么。

## 6. CHANGELOG 规则

- `CHANGELOG.md` 位于仓库根目录，最新版本排在最前面。
- 每个会被用户或站点注意到的拉取请求，都要在 "Unreleased" 下加一行。写明对用户而言改变了什么，而不是改了哪些文件。
- 发布时，把 "Unreleased" 改名为版本号和日期，并新建一个空的 "Unreleased"。
- 对应章节不存在，发布就不算准备好。GitHub Release 的说明从这里复制。
- 各模块在自己的文件夹里保留各自较早的变更历史，新条目写入根目录的文件。
