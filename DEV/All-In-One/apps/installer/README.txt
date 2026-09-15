LW Suite installer sources
==========================

Recovered 2026-08-18 from Downloads\LWCAM Deploy\LWSuite.exe. Until then the build
script, the four QC launchers and every bundled runtime existed ONLY inside that
binary: losing the exe would have meant rebuilding the deployment story from scratch.

Verified by compiling: 155 MB output against the shipped 159 MB, and the only
remaining differences are the content-hashed frontend asset filenames (expected, the
console was rebuilt) and two README.md files that were deliberately deleted in
August.

Contents
--------
  build-installer.ps1          compiles LWSuite.exe - use this, not iscc directly
  LWSuite.iss                  Inno Setup script. Read its header before editing.
  qc\SETUP_QC.bat              builds the offline QC runtime on the target
  qc\SETUP_QC_DB.bat           applies the QC schema
  qc\START_QC_BACKEND.bat      uvicorn on 8080, sets LWCAM_NODE_CONFIG
  qc\START_QC_FRONTEND.bat     no longer shipped - see "The QC console" below
  vendor\python-3.13.14-embed-amd64.zip   offline Python for the QC runtime
  vendor\adb\                  adb.exe + AdbWinApi.dll + AdbWinUsbApi.dll
  vendor\vcruntime\            msvcp140.dll, vcruntime140.dll, vcruntime140_1.dll
  vendor\postgresql\           PostgreSQL 18.6-1 installer, 358 MB (gitignored)

setup_qc_db.py is NOT copied here. It already lives in
LWCam_QC_Platform\scripts\ and was byte-identical to the shipped version apart
from line endings, so the script installs it straight from there.

Building
--------
  .\build-installer.ps1                 writes LWSuite.exe to the All-In-One root
  .\build-installer.ps1 -ResolveOnly    prints the resolved tool paths, builds nothing

The output lands at the top of the All-In-One folder, beside START-HERE.md, not in a
subfolder here. An operator handed that folder to set up a station should find the
installer without navigating into apps\installer\. OutputDir in LWSuite.iss and $out
in build-installer.ps1 both encode that location - change them together.

It resolves two inputs that are not in this repository and whose paths move on
their own: ISCC.exe (Inno Setup is a winget package here, so it lands under
%LOCALAPPDATA%\Programs and puts nothing on PATH) and scrcpy (the winget package
folder carries the version in its name, so `winget upgrade` renames it). Both are
globbed, newest wins. Calling iscc by hand with a literal /DScrcpyDir works until
the next scrcpy upgrade silently breaks it.

The QC console
--------------
The Vue console on port 5174 is no longer shipped. QC review moved into LWCAM
itself (LWCAM\lib\pages\qc_review_page.dart, route /qc, gated on UserRole.qc), so
one binary is both the capture station and the QC review station, split by role at
login. The "qcfront" component, QC\dist, START_QC_FRONTEND.bat and serve_frontend.py
are all gone from the payload, as is the old "qc" install type - it was identical to
"full" once the console was dropped.

START_QC_FRONTEND.bat stays in this folder as the recovered original; it is simply
not referenced by LWSuite.iss any more.

What is deliberately kept out of the payload
--------------------------------------------
Beyond build state (.venv, caches, .env), the [Files] Excludes drop repository
furniture that has no job on a target: the QC backend test suite, the Docker build
(this deployment is Docker-free by design), .gitignore files, pyproject.toml, and
LWIP's benchmark script.

Two exclusions that would be mistakes:

  wheels\        SETUP_QC.bat and SETUP_DESKEW_CROP.bat install from these with
                 --no-index, so a missing wheelhouse is a hard failure on the target.
  LWIP tests\    RUN_TESTS.bat ships and discovers backend\tests. It is the on-target
                 check that the LWIP venv built correctly, so both stay.

Two things that look optional and are not
-----------------------------------------
adb.exe beside lwcam.exe. LWCAM resolves adb next-to-exe FIRST
(gallery_page.dart, _resolveAdbPath). Bundling it is what makes capture work on a PC
with no Android platform-tools installed and nothing on PATH.

The VC++ runtime DLLs. `flutter build` does not emit them. Without them both apps die
at startup with a missing-DLL error on any Windows image that has never had a VC++
redistributable installed. The shipped installer carried them for both apps.

Neither gap is visible on a development machine. Both are fatal on a clean one.

Staged build inputs (gitignored, ~480 MB)
-----------------------------------------
These are recovered or third-party binaries, not source, so they are out of git:

  LWCAM\LWIP\wheels\                  numpy, opencv-python, pillow
  (the LWIP CPython installer is gone - see "The LWIP runtime" below)
  LWCam_QC_Platform\backend\wheels\   44 wheels for the QC backend
  installer\vendor\postgresql\        PostgreSQL 18.6-1 installer, 358 MB

Re-fetch the PostgreSQL installer from the URL in the winget manifest and verify the
hash - it is a third-party binary that ships to every station:

  curl -L -o vendor\postgresql\postgresql-18.6-1-windows-x64.exe ^
      https://get.enterprisedb.com/postgresql/postgresql-18.6-1-windows-x64.exe

  SHA256 cae561e98d09f3f4a1a95759249240f86f66d71dcf33d14b6f7be894078401d1

Both setup scripts install with `pip --no-index --find-links <wheels>`, i.e. strictly
offline, so a missing wheelhouse is a hard failure on the target rather than a slow
download. Re-stage them with:

  py -3.13 -m pip download -r LWCam_QC_Platform\backend\requirements.txt ^
      -d LWCam_QC_Platform\backend\wheels --only-binary :all:
  py -3.13 -m pip download -r LWCAM\LWIP\requirements.txt ^
      -d LWCAM\LWIP\wheels --only-binary :all:

  py -3.13 -m pip download pip -d LWCAM\LWIP\wheels --only-binary :all:

That second line is not optional. LWIP builds its runtime from the embeddable
Python package, which ships without pip, and bootstraps pip by running it out of
its own wheel via zipimport - so a wheelhouse with no pip-*.whl cannot install
anything at all.

Verify a wheelhouse with a dry run rather than by eye - it is the only way to catch
a requirement with no wheel behind it, because the development .venv already has the
package and hides the gap:

  .venv\Scripts\python.exe -m pip install --no-index --find-links wheels ^
      -r requirements.txt --dry-run

openai was exactly that case. requirements.txt asks for openai>=2.0.0 (imported by
app\services\ai_review.py), no openai wheel had ever been staged, and the .venv here
had it from PyPI - so SETUP_QC.bat would have exited 1 at "Installing bundled offline
dependencies" on the first clean machine it touched. openai plus its transitive deps
(httpx2, httpcore2, idna, jiter, sniffio, tqdm, typing_inspection) are staged now.

The recovered wheelhouse had also accreted six duplicate package versions, including
two pip wheels - and SETUP_QC.bat picks a pip wheel with `for %%W in ("%WHEELS%\pip-*.whl")`,
which silently takes whichever the glob yields last. Only the versions the resolver
actually selects are kept now, and exactly one pip wheel remains.

Test dependencies are not staged. requirements.txt is runtime-only and matches
[project].dependencies in pyproject.toml; pytest, httpx, ruff and mypy live in
requirements-dev.txt, matching [project.optional-dependencies].dev. Anything added
to requirements.txt has to be staged as a wheel and then installs on every station,
so put development tools in the dev file.

Prerequisites
-------------
  Inno Setup 6      winget install JRSoftware.InnoSetup
  Flutter release builds of both apps:
      cd ..\LWCamAdmin && flutter build windows --release
      cd ..\LWCAM      && flutter build windows --release
  Built QC console:
      cd ..\LWCam_QC_Platform\frontend && npm ci && npm run build
  scrcpy, a Windows build. Not in the repository (licence + size).

Build
-----
  iscc LWSuite.iss

  With scrcpy somewhere other than ..\LWCAM\scrcpy:
  iscc /DScrcpyDir="%LOCALAPPDATA%\Microsoft\WinGet\Packages\Genymobile.scrcpy_Microsoft.Winget.Source_8wekyb3d8bbwe\scrcpy-win64-v4.1" LWSuite.iss

  Output lands in Output\LWSuite.exe unless /O redirects it.

What NOT to change
------------------
AppId. It is the shipped GUID, and it is what makes a new installer upgrade an
existing station instead of installing a second copy beside it.

Permissions: users-modify on the [Dirs] entries. The data folders sit under Program
Files but every app writes to them unelevated.

Verifying a build
-----------------
Install into a throwaway directory, then as a NORMAL (unelevated) user create a file
in each of LWCam Capture\1.Images, 2.Batches and 3.Export. If any of those fail, the
users-modify permission was lost again and capture will break on customer machines.

Still missing
-------------
build_installers.ps1. SETUP_QC.bat refers to it ("Re-stage the wheels with
build_installers.ps1") but it is not inside LWSuite.exe, so it exists only on
whichever machine produced the original build. The pip download commands above cover
what it did for the wheelhouses; anything else it automated is unknown.

The wizard images (WizardImage0.png, WizardSmallImage0.png) were embedded resources
rather than [Files] entries and are not recoverable from the exe. The script falls
back to the stock Inno wizard appearance; supply branded images if wanted.

The bundled PostgreSQL server
-----------------------------
LWSuite.exe carries the 358 MB PostgreSQL 18 installer, which is why the output is
~500 MB rather than ~158 MB. It is the one prerequisite the suite cannot satisfy by
copying files: SETUP_QC_DB.bat applies a schema to a server that already exists.

[Code] decides whether it runs. PsqlOnDisk() looks for a real psql.exe under
%ProgramFiles%\PostgreSQL\<version>\bin - not the registry key alone and not the
directory alone, because an uninstall leaves both standing and would silently skip
the install. A PC that already has any PostgreSQL major version is left untouched.

Two things to know before editing that code:

  The unattended switches in [Run] are EnterpriseDB's documented ones but are NOT
  verified by this repository. The installer needs elevation even to print --help,
  and its option strings sit inside a compressed payload, so neither can be checked
  on a build machine. CurStepChanged therefore verifies the OUTCOME with
  PsqlOnDisk() and shows a recovery message if the server did not appear. Keep that
  check if you change the switches - without it a renamed switch produces a station
  with no database and no error, surfacing much later as an authentication failure.

  The superuser password is generated by shelling out to PowerShell's
  RandomNumberGenerator, not Pascal Script's Random, which is clock-seeded and must
  not choose a credential. Generation failure raises rather than falling back to a
  guessable default. The value is written to {app}\postgres-password.txt and shown
  once, because the operator has to retype it into Station Setup.

Station Setup's Password box only stores the credential LWCAM connects with, so it
cannot rotate anything on its own. The "Change password on server" button beside
Test connection does that: StationSetupController.rotatePgPassword runs ALTER ROLE
through the gateway (authenticating with the current password), then writes the new
one to lwcam_node_config.json and re-applies AdminBootstrap. Server first, then
config - a config saved ahead of a failed ALTER ROLE would leave the station holding
a password the server never accepted.

This script serves the All-In-One product. Module will need its own, because its
components differ: Module keeps qcfront and port 5174, while All-In-One drops both
and folds the QC engine into the lwcam component as a local sidecar.

The LWIP runtime
----------------
LWIP builds its interpreter from the SAME embeddable Python zip as the QC backend
(shipped once, at the install root). It used to run a full CPython installer,
python-3.13.14-amd64.exe, into a private folder and build a venv from it. That is
gone, and must not come back: the installer aborts with

    Error 0x80070666: Cannot install a product when a newer version is installed.

on any PC that already has a newer 3.13. The check is machine-wide and ignores
TargetDir, so a private install is refused too - and because Inno discards the
exit code of a [Run] entry, that failure reported a clean install and left the
station with no image processing at all.

Two consequences worth knowing:

  The runtime now lives at LWIPuntime\python, which is inside the folder
  [Dirs] already grants users-modify. The old venv\ and python\ dirs had no
  grant and only worked because [Run] runs elevated.

  msvcp140.dll is copied into the runtime by SETUP_DESKEW_CROP.bat. cv2.pyd links
  it, and neither the embeddable zip nor the OpenCV wheel carries it - so on a
  clean Windows image with no C++ redistributable, `import cv2` fails without it.

[InstallDelete] removes a pre-existing venv\ and python\ on upgrade. That is
correctness, not tidying: an upgraded station still has a logon entry pointing at
venv\Scripts\pythonw.exe, and if that interpreter survives it takes the
orchestrator lock first and the new runtime loses the race at every logon.
