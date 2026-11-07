"""Per-PC certificate for the LWCam web pages (QC, LWIP and Upload consoles).

ONE file, shipped byte-identical in all three services (a parity test in each
suite keeps them so). It keeps a local CA and issues a server certificate signed
by it, covering this PC's name, IP addresses and Tailscale name.

* The CA carries a critical NameConstraints limited to THIS PC's names and
  address ranges, so a PC that trusts it can be lied to about nothing else.
* The CA is never silently replaced: only a CA that lacks NameConstraints (the
  first, unconstrained builds) is regenerated, and a half-present CA is refused.
* The leaf contains only names/IPs permitted by the existing CA. A new LAN
  outside its constraints is omitted until an administrator updates the CA;
  localhost remains usable. Existing forbidden SANs force leaf renewal.
* The leaf is re-issued when a permitted wanted name/IP is missing, its key does
  not match, it has the wrong issuer, or it has under 30 days left. Extra permitted
  names are retained, so a churning address does not cause re-issues.
* QC, LWIP and Upload all call ensure_certificates on the same folder at boot:
  a lock file serialises them and every file is replaced atomically, cert last.

    python -m <package>.tls ensure <folder>
"""

from __future__ import annotations

import contextlib
import datetime as dt
import ipaddress
import json
import logging
import os
import shutil
import socket
import ssl
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

LOGGER = logging.getLogger("lwcam.tls")

RENEW_BEFORE = dt.timedelta(days=30)
LOCK_WAIT_SECONDS = 60.0
LOCK_STALE_SECONDS = 120.0
_FQDN_TIMEOUT = 2.0
_PROBE_TIMEOUT = 3.0

LOOPBACK_V4 = ipaddress.ip_network("127.0.0.0/8")
LOOPBACK_V6 = ipaddress.ip_network("::1/128")
TAILSCALE_V4 = ipaddress.ip_network("100.64.0.0/10")
TAILSCALE_V6 = ipaddress.ip_network("fd7a:115c:a1e0::/48")

# Adapters that have a default route, with their stable addresses. Virtual
# switches (Hyper-V/WSL/Docker) have no gateway, so their churning addresses
# never appear; link-local (169.254/fe80) and temporary IPv6 are dropped too.
_GATEWAY_IPS_PS = (
    "$i = @(Get-NetRoute -ErrorAction SilentlyContinue | Where-Object "
    "{ $_.DestinationPrefix -in '0.0.0.0/0','::/0' } | "
    "ForEach-Object { $_.InterfaceIndex } | Sort-Object -Unique); "
    "if ($i.Count) { Get-NetIPAddress -InterfaceIndex $i -ErrorAction SilentlyContinue | "
    "Where-Object { $_.AddressState -eq 'Preferred' -and $_.SuffixOrigin -ne 'Random' } | "
    "ForEach-Object { $_.IPAddress } }"
)


def _pem_key(key) -> bytes:
    return key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )


def _now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


# ---- names -----------------------------------------------------------------


def _fqdn() -> str | None:
    """getfqdn can block for a long time on a PC with a dead DNS server."""
    box: list[str] = []
    thread = threading.Thread(target=lambda: box.append(socket.getfqdn()), daemon=True)
    thread.start()
    thread.join(_FQDN_TIMEOUT)
    return box[0] if box else None


def _usable(address: str) -> ipaddress.IPv4Address | ipaddress.IPv6Address | None:
    try:
        ip = ipaddress.ip_address(address.split("%")[0].strip())
    except ValueError:
        return None
    if ip.is_link_local or ip.is_unspecified or ip.is_multicast:
        return None
    return ip


def _gateway_ips() -> set[str]:
    """Addresses of the adapters that have a default gateway."""
    found: set[str] = set()
    root = os.environ.get("SystemRoot")
    shell = Path(root, "System32", "WindowsPowerShell", "v1.0", "powershell.exe") if root else None
    if shell is not None and shell.is_file():
        try:
            out = subprocess.run(
                [str(shell), "-NoProfile", "-NonInteractive", "-Command", _GATEWAY_IPS_PS],
                capture_output=True, text=True, timeout=_PROBE_TIMEOUT + 4, cwd=root,
            )
            for line in out.stdout.splitlines():
                ip = _usable(line)
                if ip is not None:
                    found.add(str(ip))
            if found:
                return found
        except Exception:  # noqa: BLE001 - fall back to the routing-table probe
            pass
    # Fallback (no PowerShell): the address the OS would use to reach the
    # outside. A UDP connect sends nothing. Only the primary adapter.
    for family, target in ((socket.AF_INET, "192.0.2.1"), (socket.AF_INET6, "2001:db8::1")):
        try:
            with socket.socket(family, socket.SOCK_DGRAM) as probe:
                probe.settimeout(_PROBE_TIMEOUT)
                probe.connect((target, 9))
                ip = _usable(probe.getsockname()[0])
                if ip is not None:
                    found.add(str(ip))
        except OSError:
            pass
    return found


def _tailscale() -> tuple[str | None, set[str]]:
    """(MagicDNS name, Tailscale IPs) - optional, any failure means (None, {})."""
    program_files = os.environ.get("ProgramFiles")
    exe = Path(program_files, "Tailscale", "tailscale.exe") if program_files else None
    if exe is None or not exe.is_file():
        # Never a copy that merely sits in the current directory.
        found = shutil.which("tailscale")
        if not found or Path(found).resolve().parent == Path.cwd().resolve():
            return None, set()
        exe = Path(found)
    try:
        out = subprocess.run(
            [str(exe), "status", "--json"], capture_output=True, text=True,
            timeout=_PROBE_TIMEOUT, cwd=os.environ.get("SystemRoot") or None,
        )
        me = json.loads(out.stdout).get("Self", {})
    except Exception:  # noqa: BLE001
        return None, set()
    ips = set()
    for address in me.get("TailscaleIPs", []):
        ip = _usable(str(address))
        if ip is not None and (ip in TAILSCALE_V4 or ip in TAILSCALE_V6):
            ips.add(str(ip))
    name = str(me.get("DNSName") or "").rstrip(".")
    return (name or None), ips


def local_names() -> tuple[set[str], set[str]]:
    """(DNS names, IP addresses) this PC answers to."""
    host = socket.gethostname()
    dns = {host, "localhost"}
    ips = {"127.0.0.1", "::1"} | _gateway_ips()
    fqdn = _fqdn()
    if fqdn:
        dns.add(fqdn)
    magic, tailscale_ips = _tailscale()
    if magic:
        dns.add(magic)
    ips |= tailscale_ips
    return {d for d in dns if d}, ips


def _san_set(cert: x509.Certificate) -> set[str]:
    san = cert.extensions.get_extension_for_class(x509.SubjectAlternativeName).value
    return set(san.get_values_for_type(x509.DNSName)) | {
        str(i) for i in san.get_values_for_type(x509.IPAddress)
    }


# ---- CA name constraints ---------------------------------------------------


def _constraint_nets(ips: set[str]) -> list:
    nets = [LOOPBACK_V4, LOOPBACK_V6, TAILSCALE_V4, TAILSCALE_V6]
    for text in sorted(ips):
        ip = ipaddress.ip_address(text)
        if ip.is_loopback or ip in TAILSCALE_V4 or ip in TAILSCALE_V6:
            continue
        # ponytail: a /24 (not the bare /32) for IPv4, so a DHCP address that
        # moves inside the same LAN does not invalidate the CA every PC trusts.
        nets.append(ipaddress.ip_network(f"{ip}/24", strict=False) if ip.version == 4
                    else ipaddress.ip_network(f"{ip}/128"))
    return nets


ALWAYS_DNS = ("ts.net", "local")  # a PC that joins the tailnet / mDNS later needs no re-trust


def _constraint_dns(dns: set[str]) -> list[str]:
    names = set(dns) | set(ALWAYS_DNS)
    for name in dns:
        if name.endswith(".ts.net") and name.count(".") >= 2:
            names.add(name.split(".", 1)[1])  # the tailnet suffix
    return sorted(names)


def _name_constraints(dns: set[str], ips: set[str]) -> x509.NameConstraints:
    return x509.NameConstraints(
        permitted_subtrees=[x509.DNSName(d) for d in _constraint_dns(dns)]
        + [x509.IPAddress(n) for n in _constraint_nets(ips)],
        excluded_subtrees=None,
    )


def _ca_constraints(ca_cert: x509.Certificate):
    try:
        return ca_cert.extensions.get_extension_for_class(x509.NameConstraints).value
    except x509.ExtensionNotFound:
        return None


def _uncovered(ca_cert: x509.Certificate, dns: set[str], ips: set[str]) -> list[str]:
    """Wanted names/addresses the CA's NameConstraints would forbid."""
    limits = _ca_constraints(ca_cert)
    if limits is None:
        return []
    allowed_dns = [n.value.lower() for n in limits.permitted_subtrees or [] if isinstance(n, x509.DNSName)]
    allowed_ip = [n.value for n in limits.permitted_subtrees or [] if isinstance(n, x509.IPAddress)]
    bad = [
        d for d in sorted(dns)
        if not any(d.lower() == a or d.lower().endswith("." + a) for a in allowed_dns)
    ]
    for text in sorted(ips):
        ip = ipaddress.ip_address(text)
        if not any(ip.version == net.version and ip in net for net in allowed_ip):
            bad.append(text)
    return bad


# ---- files -----------------------------------------------------------------


@contextlib.contextmanager
def _folder_lock(folder: Path):
    """Cross-process lock: a file made with O_EXCL. A lock older than
    LOCK_STALE_SECONDS belongs to a crashed process and is taken over.
    ponytail: two waiters can race the stale takeover; ensure is idempotent."""
    path = folder / ".tls.lock"
    deadline = time.monotonic() + LOCK_WAIT_SECONDS
    while True:
        try:
            os.close(os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY))
            break
        except FileExistsError:
            try:
                if time.time() - path.stat().st_mtime > LOCK_STALE_SECONDS:
                    path.unlink(missing_ok=True)
                    continue
            except OSError:
                pass
            if time.monotonic() > deadline:
                raise TimeoutError(f"another process holds {path}")
            time.sleep(0.2)
    try:
        yield
    finally:
        path.unlink(missing_ok=True)


def _write_atomic(path: Path, data: bytes) -> None:
    temp = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")  # same folder = same permissions
    try:
        temp.write_bytes(data)
        os.replace(temp, path)
    finally:
        temp.unlink(missing_ok=True)


def _ensure_ca(folder: Path, dns: set[str], ips: set[str]):
    key_path, crt_path = folder / "lwcam-ca.key", folder / "lwcam-ca.crt"
    present = [key_path.is_file(), crt_path.is_file()]
    if any(present):
        if not all(present):
            # A half CA cannot be rebuilt without breaking every PC that trusts
            # the old one: the administrator decides, not a boot script.
            LOGGER.error("TLS: only one of %s and %s exists; refusing to regenerate the CA", key_path, crt_path)
            raise RuntimeError(f"incomplete CA in {folder}: restore both lwcam-ca files or delete both")
        try:
            key = serialization.load_pem_private_key(key_path.read_bytes(), None)
            cert = x509.load_pem_x509_certificate(crt_path.read_bytes())
        except (OSError, ValueError) as exc:
            LOGGER.error("TLS: cannot read the CA in %s: %s", folder, exc)
            raise RuntimeError(f"unreadable CA in {folder}: {exc}") from exc
        limits = _ca_constraints(cert)
        have = {n.value.lower() for n in (limits.permitted_subtrees or []) if isinstance(n, x509.DNSName)} if limits else set()
        if limits is not None and set(ALWAYS_DNS) <= have:
            return key, cert
        LOGGER.warning("TLS: replacing the CA in %s (it lacks NameConstraints or the ts.net/.local names); PCs must trust the new one", folder)
    key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name(
        [x509.NameAttribute(NameOID.COMMON_NAME, f"LWCam local CA {socket.gethostname()}")]
    )
    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(_now() - dt.timedelta(days=1))
        .not_valid_after(_now() + dt.timedelta(days=3650))
        .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
        .add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()), critical=False)
        .add_extension(
            x509.KeyUsage(
                digital_signature=True, key_cert_sign=True, crl_sign=True,
                content_commitment=False, key_encipherment=False, data_encipherment=False,
                key_agreement=False, encipher_only=False, decipher_only=False,
            ),
            critical=True,
        )
        .add_extension(_name_constraints(dns, ips), critical=True)
        .sign(key, hashes.SHA256())
    )
    _write_atomic(key_path, _pem_key(key))
    _write_atomic(crt_path, cert.public_bytes(serialization.Encoding.PEM))  # cert last
    return key, cert


def _leaf_usable(crt_path: Path, key_path: Path, ca_cert: x509.Certificate, wanted: set[str]) -> bool:
    try:
        cert = x509.load_pem_x509_certificate(crt_path.read_bytes())
        key = serialization.load_pem_private_key(key_path.read_bytes(), None)
        der = serialization.PublicFormat.SubjectPublicKeyInfo
        if key.public_key().public_bytes(serialization.Encoding.DER, der) != cert.public_key().public_bytes(
            serialization.Encoding.DER, der
        ):
            return False
        cert.verify_directly_issued_by(ca_cert)
        sans = cert.extensions.get_extension_for_class(x509.SubjectAlternativeName).value
        if _uncovered(ca_cert, set(sans.get_values_for_type(x509.DNSName)),
                      {str(ip) for ip in sans.get_values_for_type(x509.IPAddress)}):
            # One forbidden SAN invalidates the whole chain, even for localhost.
            return False
        return wanted <= _san_set(cert) and cert.not_valid_after_utc - _now() > RENEW_BEFORE
    except Exception:  # noqa: BLE001 - anything unreadable or mismatched means re-issue
        return False


def ensure_certificates(folder: Path | str) -> tuple[Path, Path]:
    """Make sure <folder> holds a CA and a current server leaf.
    Returns (server.crt, server.key)."""
    folder = Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    dns, ips = local_names()  # slow probes stay outside the lock
    crt_path, key_path = folder / "server.crt", folder / "server.key"
    with _folder_lock(folder):
        ca_key, ca_cert = _ensure_ca(folder, dns, ips)
        outside = _uncovered(ca_cert, dns, ips)
        if outside:
            LOGGER.warning(
                "TLS: omitting names outside the existing CA's NameConstraints: %s. "
                "Permitted names (including localhost) remain usable; an administrator "
                "must update and re-trust the CA in %s to enable those new addresses", outside, folder,
            )
            dns -= set(outside)
            ips -= set(outside)
        wanted = dns | ips
        if not wanted:
            raise RuntimeError(f"no local names are permitted by the CA in {folder}")
        if _leaf_usable(crt_path, key_path, ca_cert, wanted):
            return crt_path, key_path
        key = ec.generate_private_key(ec.SECP256R1())
        sans = [x509.DNSName(d) for d in sorted(dns)] + [
            x509.IPAddress(ipaddress.ip_address(i)) for i in sorted(ips)
        ]
        cert = (
            x509.CertificateBuilder()
            .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, socket.gethostname())]))
            .issuer_name(ca_cert.subject)
            .public_key(key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(_now() - dt.timedelta(days=1))
            .not_valid_after(_now() + dt.timedelta(days=730))
            .add_extension(x509.SubjectAlternativeName(sans), critical=False)
            .add_extension(
                x509.AuthorityKeyIdentifier.from_issuer_public_key(ca_key.public_key()), critical=False
            )
            .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
            .add_extension(x509.ExtendedKeyUsage([x509.oid.ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
            .sign(ca_key, hashes.SHA256())
        )
        _write_atomic(key_path, _pem_key(key))
        _write_atomic(crt_path, cert.public_bytes(serialization.Encoding.PEM))  # cert last
    return crt_path, key_path


def keep_fresh(folder: Path | str, on_renew, interval: float = 6 * 3600) -> threading.Thread:
    """Daemon thread: re-run ensure_certificates every `interval` seconds and call
    on_renew(crt, key) when the leaf files changed, so a long-running service can
    reload them. Failures are logged, never raised."""
    folder = Path(folder)

    def _mtime(paths):
        try:
            return tuple(p.stat().st_mtime_ns for p in paths)
        except OSError:
            return None

    def loop():
        crt, key = folder / "server.crt", folder / "server.key"
        seen = _mtime((crt, key))
        while True:
            time.sleep(interval)
            try:
                crt, key = ensure_certificates(folder)
                now = _mtime((crt, key))
                if now != seen:
                    seen = now
                    on_renew(crt, key)
            except Exception as exc:  # noqa: BLE001
                LOGGER.warning("TLS: periodic renewal check failed: %s", exc)

    thread = threading.Thread(target=loop, name="tls-renew", daemon=True)
    thread.start()
    return thread


def is_managed(cert: Path | str, key: Path | str) -> bool:
    """True when the configured pair is exactly <dir>/server.crt + server.key of
    a folder this module manages (it holds, or half holds, our CA). Anything
    else is an operator's own certificate and is used as-is, never touched."""
    cert, key = Path(cert), Path(key)
    return (
        cert.name.lower() == "server.crt"
        and key.name.lower() == "server.key"
        and cert.parent == key.parent
        and ((cert.parent / "lwcam-ca.crt").exists() or (cert.parent / "lwcam-ca.key").exists())
    )


def wrap_if_configured(httpd, config_path: Path | str) -> bool:
    """LWIP/Upload consoles: if the JSON settings file names tls_cert_file and
    tls_key_file, renew the certificate and make `httpd` (a stdlib
    ThreadingHTTPServer) speak https only. No such keys = plain http, False.
    A configured but unusable certificate raises (after closing the socket):
    quietly falling back to http would be a downgrade."""
    try:
        raw = json.loads(Path(config_path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False
    cert, key = str(raw.get("tls_cert_file") or "").strip(), str(raw.get("tls_key_file") or "").strip()
    if not (cert and key):
        return False
    try:
        if is_managed(cert, key):
            try:
                ensure_certificates(Path(cert).parent)
            except Exception as exc:  # noqa: BLE001 - the certificate already on disk may still be fine
                LOGGER.error("TLS: could not renew the certificate in %s: %s", Path(cert).parent, exc)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        if is_managed(cert, key):
            # Renewed leaf -> same context, so new connections use it (no restart).
            keep_fresh(Path(cert).parent, lambda c, k: context.load_cert_chain(str(c), str(k)))
        # The handshake runs in the request's own thread, so one silent client
        # cannot stall the accept loop.
        httpd.socket = context.wrap_socket(httpd.socket, server_side=True, do_handshake_on_connect=False)
    except Exception:
        httpd.server_close()
        raise
    return True


def secure_flag(handler) -> str:
    """"; Secure" for a Set-Cookie on an https connection, else ""."""
    return "; Secure" if isinstance(handler.connection, ssl.SSLSocket) else ""


def add_to_config(config: Path | str, folder: Path | str) -> bool:
    """Point a service's settings file at the certificate in <folder> unless it
    already names one (an operator's choice is kept). A .txt file is QC's
    `key = value` lines; anything else is a JSON object. True if it changed."""
    config, folder = Path(config), Path(folder)
    cert, key = str(folder / "server.crt"), str(folder / "server.key")
    with open(config, encoding="utf-8", newline="") as stream:  # keep CRLF as found
        text = stream.read()
    if config.suffix.lower() == ".txt":
        if any(line.split("=")[0].strip() == "tlsCertFile" for line in text.splitlines() if "=" in line):
            return False
        text += "" if text.endswith("\n") or not text else "\r\n"
        text += f"tlsCertFile = {cert}\r\ntlsKeyFile = {key}\r\n"
    else:
        data = json.loads(text)
        if data.get("tls_cert_file"):
            return False
        data.update(tls_cert_file=cert, tls_key_file=key)
        text = json.dumps(data, indent=2, ensure_ascii=False).replace("\n", "\r\n") + "\r\n"
    temp = config.with_name(config.name + ".tls.tmp")  # same folder = same (private) permissions
    temp.write_text(text, encoding="utf-8", newline="")
    temp.replace(config)
    return True


if __name__ == "__main__":
    args = sys.argv[1:]
    if len(args) not in (2, 4) or args[0] != "ensure" or (len(args) == 4 and args[2] != "--config"):
        raise SystemExit("usage: python -m <package>.tls ensure <folder> [--config <settings file>]")
    crt, _ = ensure_certificates(args[1])
    if len(args) == 4:
        add_to_config(args[3], args[1])
    print(f"certificates ready in {crt.parent}")
