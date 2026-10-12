# 0008. Services run as SYSTEM and refuse mapped drive letters

- **Status:** Accepted

## Context

QC, LWIP and Upload start at boot as scheduled tasks, before anyone logs on. They run as SYSTEM. SYSTEM does not see a drive that a user mapped in a logon session. On Python 3.13, `Path.is_dir()` also raises for some access errors where 3.14 returns False.

## Decision

- Every folder setting must be a local fixed drive or a UNC path (`\\server\share\...`). The installers and the consoles refuse a mapped drive letter.
- Without a login, SYSTEM reaches another PC's share as this PC's computer account. Outside a domain that fails. The "Network folder logins" section of a console saves a login instead. The list is kept per PC, because Windows allows one account per remote PC for all SYSTEM services on a PC.
- Services sign in again every 2 minutes, so shares come back after a reboot of either PC.
- `app/core/netlogin.py` is identical in QC, LWIP and Upload. A test fails when the copies differ.

## Consequences

- `fs_path()` converts paths to the `\\?\` form at the system-call boundary, for long paths and UNC.
- Keep the work folder local. Export writes about ten times the output size in scratch files.
- Keep the guard around `is_dir()` while 3.13 installs exist.

## Don't change this unless

The services stop running as SYSTEM. Then test boot start, UNC access and the login keeper again.
