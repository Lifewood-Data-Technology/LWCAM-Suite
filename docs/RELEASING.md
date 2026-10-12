English | [简体中文](RELEASING.zh-CN.md)

# Releasing

This page explains how to version, build and publish a release. Installers are not in git. They are attached to a GitHub Release. For the tools you need, see [DEV-SETUP.md](DEV-SETUP.md). For the tests to run first, see [TESTING.md](TESTING.md).

## 1. Version numbers

| What | Where | Rule |
| --- | --- | --- |
| Release version | `VERSION` (one line, for example `1.1.0`) at the repository root | Change it by hand for a release. |
| Build id | The short git commit, with `-dirty` added if the working tree has uncommitted changes | Made by `installer/build-installer.ps1`. |
| Stamp | `<version>+<commit>`, for example `1.1.0+a1b2c3d` | Written to `VERSION.txt` in every install folder (for LWCam: beside `lwcam.exe` and `lwcam_admin.exe`, and in the root). The QC System status page shows it for each part. |

The build script reads `VERSION` and passes it to Inno Setup as `/DAppVer` and `/DBuildId`. It writes `installer/vendor/VERSION.txt` first. If you compile an `.iss` file with `ISCC` directly, that file must exist.

The stamp of a release build must not end in `-dirty`. Commit everything first.

The `version:` line in `LWCAM/pubspec.yaml` and `LWCamAdmin/pubspec.yaml` (`1.0.0+1`) is not the release version. The installer stamp comes from `VERSION`.

## 2. Build the installers

You need: Inno Setup 6, Flutter, Node.js and the build inputs (see [DEV-SETUP.md](DEV-SETUP.md), section 3).

1. Update the source and check the working tree is clean: `git status`.
2. Run the tests ([TESTING.md](TESTING.md)).
3. Build the two Flutter apps. The installer packs the Release builds, so a stale build ships stale code:

```
cd LWCAM      && flutter build windows --release
cd LWCamAdmin && flutter build windows --release
```

4. Build the installers:

```
cd installer
powershell -File build-installer.ps1 -Target All
```

Targets: `Database`, `QC`, `LWIP`, `Upload`, `LWCam`, `All`.

| Target | Output (in the repository root) |
| --- | --- |
| `Database` | `LWCamDatabaseSetup.exe`, and the PostgreSQL installer copied beside it |
| `QC` | `QCPlatformSetup.exe` (the script runs `npm ci` and `npm run build` in the frontend first) |
| `LWIP` | `LWIPSetup.exe` |
| `Upload` | `LWCamUploadSetup.exe` |
| `LWCam` | `LWCamSetup.exe` |

Before it compiles, the script checks that every input exists, that the four copies of `lwcam_secrets.py` are byte-identical, and that the bundled third-party files match `installer/SHA256SUMS.txt` (section 3). `-ResolveOnly` prints the Inno Setup and scrcpy paths and builds nothing. `-ScrcpyDir <folder>` selects another scrcpy build.

The output files are ignored by git (`*.exe`).

## 3. Two kinds of checksum

**`installer/SHA256SUMS.txt`** (in git) pins the bundled third-party inputs: the Python zip, the Visual C++ DLLs, adb, the PostgreSQL installer, scrcpy, `LWIP/tools` and the three wheel folders. It has one line per file: `<sha256>  <path from the repository root>`. If a bundled file changes, the build stops with "Bundled file changed". After an intended change (a new wheel, a new adb), run:

```
powershell -File build-installer.ps1 -UpdateChecksums
```

Then commit `installer/SHA256SUMS.txt`. Flutter builds, `frontend/dist` and `vendor/VERSION.txt` are not in the list.

**The release checksum file** is a separate file that you attach to the GitHub Release. It lists the installers you publish. Make it from the repository root:

```
powershell -Command "Get-FileHash -Algorithm SHA256 LWCamDatabaseSetup.exe, QCPlatformSetup.exe, LWIPSetup.exe, LWCamUploadSetup.exe, LWCamSetup.exe | ForEach-Object { $_.Hash.ToLower() + '  ' + (Split-Path $_.Path -Leaf) } | Set-Content -Encoding ascii SHA256SUMS.txt"
```

Add the PostgreSQL installer line too if you ship it. Name the file `SHA256SUMS.txt` in the release. It is not the same file as the one in `installer/`.

## 4. Tag and publish

Tags use `v<version>`. The module edition uses `v1.1.0`. The all-in-one edition uses `v1.1.0-all-in-one`, tagged on the `lwcam-all-in-one` branch.

1. Check that `VERSION` and `CHANGELOG.md` are right, and that both are committed and pushed on `lwcam-module`.
2. Tag and push:

```
git tag -a v1.1.0 -m "LWCam v1.1.0"
git push origin v1.1.0
```

3. Build the installers from the tagged commit (the stamp must show that commit).
4. On GitHub, create a Release for the tag. Use the matching section of `CHANGELOG.md` as the notes. Attach the five installers, the PostgreSQL installer (if you ship it), and the release `SHA256SUMS.txt`.

With the GitHub CLI:

```
gh release create v1.1.0 LWCamDatabaseSetup.exe QCPlatformSetup.exe LWIPSetup.exe LWCamUploadSetup.exe LWCamSetup.exe SHA256SUMS.txt --title "LWCam v1.1.0" --notes-file release-notes.md
```

For the first release (v1.1.0), use one Release page for both editions: attach the module installers under `v1.1.0` and the all-in-one installer under `v1.1.0-all-in-one`, with checksums for each.

5. Download the files from the Release on a clean PC and check the hashes.
6. Tell the sites. Tell them to follow the upgrade order in [INSTALL.md](INSTALL.md), section 11.

## 5. Update the build inputs

The private Release named `build-inputs` holds the files that are too big for git (Python zip, vcruntime, adb, PostgreSQL installer, wheels, scrcpy, LWIP tools). When one of them changes:

1. Replace the file in your working copy, in the path from [DEV-SETUP.md](DEV-SETUP.md), section 3.
2. Run `powershell -File installer/build-installer.ps1 -UpdateChecksums` and commit `installer/SHA256SUMS.txt`.
3. Update the `build-inputs` Release: upload the new asset, remove the old one, and update the unpack script if a name changed.
4. If the Python version changes, also change the file name in `build-installer.ps1` (`python-3.14.8-embed-amd64.zip`) and in the `.iss` files. Search the repository for the old name.
5. Say what changed in `CHANGELOG.md`.

## 6. CHANGELOG rule

- `CHANGELOG.md` is at the repository root. Newest version first.
- Every pull request that a user or a site would notice adds one line under "Unreleased". Write what changed for the user, not which files changed.
- At release time, rename "Unreleased" to the version and the date, and start a new empty "Unreleased".
- A release is not ready until its section exists. The GitHub Release notes are copied from it.
- Each module keeps its own older change history in its folder. New entries go to the root file.
