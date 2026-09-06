#!/usr/bin/env python3
"""
Capture and locally approve the C1-Slim adbAdmit request on macOS.

macOS port of adb_admit_local.py. Replaces WinDivert packet injection with a
pf `rdr` redirect, and PowerShell host discovery with ifconfig/arp/dhcpd_leases.

pf performs the NAT in kernel and reverses the translation on the way back, so
unlike the Windows version there is no need to rewrite response source
addresses by hand.

Requires: macOS, sudo, Python 3.9+, `pip3 install cryptography`.
"""

from __future__ import annotations

import argparse
import datetime as dt
import ipaddress
import json
import os
import re
import signal
import socket
import ssl
import subprocess
import tempfile
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

try:
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import NameOID
except ModuleNotFoundError as error:
    raise SystemExit(
        f"Missing Python dependency {error.name!r}. Run: pip3 install cryptography"
    ) from error

HERE = Path(__file__).resolve().parent
LOG_PATH = HERE / "adb-admit-plaintext.log"
DEFAULT_HOST = "api.mpen.com.cn"
DEFAULT_DEVICE_MAC = "58:c5:87:15:f1:49"
DEFAULT_LISTEN_PORT = 8443
ORIGIN_PORT = 443
PF_ANCHOR = "com.apple/c1slim-adb"
MAX_REQUEST_BYTES = 64 * 1024
ADB_ROUTE = re.compile(r"/v1/pens/([^/]+)")
APPROVAL_BODY = json.dumps(
    {"errorCode": "200", "errorMsg": "", "data": {"success": True}},
    separators=(",", ":"),
).encode("utf-8")


@dataclass(frozen=True)
class Config:
    host: str
    origin_ip: str
    bridge: str
    gateway_ip: str
    device_ip: str
    listen_port: int
    keep_running: bool


class Logger:
    def __init__(self, path: Path) -> None:
        self._path = path
        self._lock = threading.Lock()
        path.write_text("", encoding="utf-8")

    def write(self, message: str) -> None:
        line = f"{dt.datetime.now().astimezone().isoformat()} {message}"
        with self._lock:
            print(line, flush=True)
            with self._path.open("a", encoding="utf-8") as output:
                output.write(line + "\n")

    def plaintext(self, peer: str, payload: bytes) -> None:
        text = payload.decode("iso-8859-1", "replace")
        self.write(
            f"HTTP_PLAINTEXT_BEGIN peer={peer}\n{text}\nHTTP_PLAINTEXT_END peer={peer}"
        )


def sh(args: list[str], check: bool = True) -> str:
    completed = subprocess.run(args, capture_output=True, text=True)
    if check and completed.returncode != 0:
        detail = (completed.stderr or completed.stdout).strip()
        raise RuntimeError(f"{args[0]} failed ({completed.returncode}): {detail}")
    return completed.stdout


def require_macos() -> None:
    if os.uname().sysname != "Darwin":
        raise RuntimeError("this script only supports macOS; use adb_admit_local.py on Windows")


def require_root() -> None:
    if os.geteuid() != 0:
        raise RuntimeError("run this script with sudo (pf and the listener need root)")


def validate_ip(value: str, label: str) -> str:
    try:
        return str(ipaddress.IPv4Address(value))
    except ipaddress.AddressValueError as error:
        raise ValueError(f"invalid {label}: {value!r}") from error


def normalize_mac(value: str) -> str:
    """Return a mac as lowercase colon-separated with no leading zeros stripped."""
    parts = re.split(r"[:-]", value.strip().lower())
    if len(parts) != 6 or any(not re.fullmatch(r"[0-9a-f]{1,2}", p) for p in parts):
        raise ValueError(f"invalid MAC address: {value!r}")
    return ":".join(f"{int(p, 16):02x}" for p in parts)


def discover_bridge(requested: str | None) -> tuple[str, str]:
    """Find the Internet Sharing bridge interface and its IPv4 gateway address."""
    output = sh(["ifconfig"])
    blocks: dict[str, str] = {}
    current = None
    for line in output.splitlines():
        if line and not line[0].isspace():
            current = line.split(":", 1)[0]
            blocks[current] = ""
        elif current is not None:
            blocks[current] += line + "\n"

    candidates: list[tuple[str, str]] = []
    for name, body in blocks.items():
        if requested is not None and name != requested:
            continue
        if requested is None and not name.startswith("bridge"):
            continue
        if "status: active" not in body and requested is None:
            continue
        match = re.search(r"inet (\d+\.\d+\.\d+\.\d+)", body)
        if match:
            candidates.append((name, match.group(1)))

    if not candidates:
        raise RuntimeError(
            "no active Internet Sharing bridge found. Turn on System Settings -> "
            "General -> Sharing -> Internet Sharing, connect the device, then retry. "
            "Pass --bridge to name the interface explicitly."
        )
    if len(candidates) > 1:
        names = ", ".join(f"{n}={a}" for n, a in candidates)
        raise RuntimeError(f"multiple bridges found: {names}; pass --bridge")
    name, address = candidates[0]
    return name, validate_ip(address, "bridge gateway IP")


def leases_by_mac() -> dict[str, str]:
    """Parse /var/db/dhcpd_leases written by the Internet Sharing bootpd."""
    path = Path("/var/db/dhcpd_leases")
    if not path.exists():
        return {}
    mapping: dict[str, str] = {}
    ip = mac = None
    for line in path.read_text(errors="replace").splitlines():
        line = line.strip()
        if line == "{":
            ip = mac = None
        elif line == "}":
            if ip and mac:
                mapping[mac] = ip
        elif line.startswith("ip_address="):
            ip = line.split("=", 1)[1].strip()
        elif line.startswith("hw_address="):
            # format is hw_address=1,58:c5:87:15:f1:49
            value = line.split("=", 1)[1].strip()
            mac = normalize_mac(value.split(",", 1)[-1])
    return mapping


def arp_by_mac(bridge: str) -> dict[str, str]:
    output = sh(["arp", "-an", "-i", bridge], check=False)
    mapping: dict[str, str] = {}
    for line in output.splitlines():
        match = re.search(r"\((\d+\.\d+\.\d+\.\d+)\) at ([0-9a-fA-F:]{11,17})", line)
        if not match:
            continue
        try:
            mapping[normalize_mac(match.group(2))] = match.group(1)
        except ValueError:
            continue
    return mapping


def discover_device_ip(
    bridge: str,
    gateway_ip: str,
    requested_ip: str | None,
    requested_mac: str | None,
) -> str:
    if requested_ip:
        return validate_ip(requested_ip, "device IP")

    combined = {**arp_by_mac(bridge), **leases_by_mac()}
    prefix = gateway_ip.rsplit(".", 1)[0] + "."

    if requested_mac:
        wanted = normalize_mac(requested_mac)
        address = combined.get(wanted)
        if address is None:
            known = ", ".join(f"{m}={a}" for m, a in sorted(combined.items())) or "none"
            raise RuntimeError(
                f"MAC {wanted} was not found on {bridge}. Seen clients: {known}. "
                "Connect the device to the Mac hotspot, or pass --device-ip / --device-mac."
            )
        return validate_ip(address, "device IP")

    candidates = sorted(
        {a for a in combined.values() if a.startswith(prefix) and a != gateway_ip}
    )
    if not candidates:
        raise RuntimeError(
            f"no clients found on {bridge}; connect the device first or pass --device-ip"
        )
    if len(candidates) > 1:
        raise RuntimeError(f"multiple clients found: {candidates}; pass --device-ip")
    return validate_ip(candidates[0], "device IP")


def resolve_origin(host: str, requested_ip: str | None) -> str:
    if requested_ip:
        return validate_ip(requested_ip, "origin IP")
    return validate_ip(socket.gethostbyname(host), "resolved origin IP")


class PfRedirect:
    """Load a scoped rdr rule into a pf sub-anchor, and remove it on exit."""

    def __init__(self, config: Config, logger: Logger) -> None:
        self._config = config
        self._logger = logger
        self._token: str | None = None
        self._loaded = False

    def _rule(self) -> str:
        c = self._config
        return (
            f"rdr pass on {c.bridge} inet proto tcp "
            f"from {c.device_ip} to {c.origin_ip} port {ORIGIN_PORT} "
            f"-> {c.gateway_ip} port {c.listen_port}\n"
        )

    def acquire(self) -> None:
        enable = subprocess.run(
            ["pfctl", "-E"], capture_output=True, text=True
        )
        match = re.search(r"Token\s*:\s*(\d+)", enable.stderr + enable.stdout)
        if match:
            self._token = match.group(1)
        rule = self._rule()
        completed = subprocess.run(
            ["pfctl", "-a", PF_ANCHOR, "-f", "-"],
            input=rule,
            capture_output=True,
            text=True,
        )
        if completed.returncode != 0:
            raise RuntimeError(
                f"pfctl failed to load the redirect rule: "
                f"{(completed.stderr or completed.stdout).strip()}"
            )
        self._loaded = True
        self._logger.write(f"PF_RULE_LOADED anchor={PF_ANCHOR} rule={rule.strip()!r}")

    def release(self) -> None:
        if self._loaded:
            subprocess.run(
                ["pfctl", "-a", PF_ANCHOR, "-F", "all"],
                capture_output=True,
                text=True,
            )
            self._logger.write(f"PF_RULE_REMOVED anchor={PF_ANCHOR}")
            self._loaded = False
        if self._token:
            subprocess.run(
                ["pfctl", "-X", self._token], capture_output=True, text=True
            )
            self._logger.write(f"PF_RELEASED token={self._token}")
            self._token = None


def create_certificate(directory: Path, config: Config) -> tuple[Path, Path]:
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    subject = issuer = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, config.host)])
    now = dt.datetime.now(dt.timezone.utc)
    certificate = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - dt.timedelta(minutes=5))
        .not_valid_after(now + dt.timedelta(days=1))
        .add_extension(
            x509.SubjectAlternativeName(
                [
                    x509.DNSName(config.host),
                    x509.IPAddress(ipaddress.ip_address(config.origin_ip)),
                ]
            ),
            critical=False,
        )
        .sign(key, hashes.SHA256())
    )
    cert_path = directory / "certificate.pem"
    key_path = directory / "private-key.pem"
    cert_path.write_bytes(certificate.public_bytes(serialization.Encoding.PEM))
    key_path.write_bytes(
        key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
    )
    return cert_path, key_path


def build_tls_context(directory: Path, config: Config, logger: Logger) -> ssl.SSLContext:
    cert_path, key_path = create_certificate(directory, config)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(cert_path, key_path)

    def record_sni(
        _socket: ssl.SSLObject, server_name: str | None, _context: ssl.SSLContext
    ) -> None:
        logger.write(f"TLS_SNI server_name={server_name!r}")

    context.sni_callback = record_sni
    return context


def expected_request_size(request: bytes) -> int | None:
    marker = b"\r\n\r\n"
    header_end = request.find(marker)
    if header_end < 0:
        return None
    content_length = 0
    for line in request[:header_end].split(b"\r\n")[1:]:
        name, separator, value = line.partition(b":")
        if separator and name.strip().lower() == b"content-length":
            content_length = int(value.strip())
            break
    return header_end + len(marker) + content_length


def receive_request(connection: ssl.SSLSocket) -> bytes:
    request = bytearray()
    expected_size: int | None = None
    while expected_size is None or len(request) < expected_size:
        chunk = connection.recv(8192)
        if not chunk:
            break
        request.extend(chunk)
        if len(request) > MAX_REQUEST_BYTES:
            raise ValueError(f"request exceeds {MAX_REQUEST_BYTES} bytes")
        expected_size = expected_request_size(request)
    return bytes(request)


def parse_request(request: bytes) -> tuple[str, str, dict[str, list[str]]]:
    header_block = request.split(b"\r\n\r\n", 1)[0]
    lines = header_block.decode("iso-8859-1").split("\r\n")
    if not lines or len(lines[0].split()) != 3:
        raise ValueError("invalid HTTP request line")
    method, target, _version = lines[0].split()
    parsed = urlsplit(target)
    return method, parsed.path, parse_qs(parsed.query, keep_blank_values=True)


def is_adb_admit(method: str, path: str, query: dict[str, list[str]]) -> bool:
    if method != "GET" or ADB_ROUTE.fullmatch(path) is None:
        return False
    if set(query) - {"action", "random"} or query.get("action") != ["adbAdmit"]:
        return False
    random_values = query.get("random")
    return random_values is None or (
        len(random_values) == 1 and random_values[0].isdigit()
    )


def http_response(status: str, body: bytes) -> bytes:
    return (
        f"HTTP/1.1 {status}\r\n"
        "Content-Type: application/json; charset=utf-8\r\n"
        f"Content-Length: {len(body)}\r\n"
        "Cache-Control: no-store\r\n"
        "Connection: close\r\n"
        "\r\n"
    ).encode("ascii") + body


def handle_connection(
    client: socket.socket,
    address: tuple[str, int],
    context: ssl.SSLContext,
    config: Config,
    logger: Logger,
    approved: threading.Event,
) -> None:
    peer = f"{address[0]}:{address[1]}"
    logger.write(f"TCP_ACCEPT peer={peer}")
    if address[0] != config.device_ip:
        logger.write(f"TCP_REJECT peer={peer} expected_ip={config.device_ip}")
        client.close()
        return
    try:
        with context.wrap_socket(client, server_side=True) as tls:
            logger.write(f"TLS_OK peer={peer} version={tls.version()} cipher={tls.cipher()}")
            tls.settimeout(5)
            request = receive_request(tls)
            logger.plaintext(peer, request)
            method, path, query = parse_request(request)
            if is_adb_admit(method, path, query):
                tls.sendall(http_response("200 OK", APPROVAL_BODY))
                pen_match = ADB_ROUTE.fullmatch(path)
                pen_id = pen_match.group(1) if pen_match else ""
                logger.write(
                    f"APPROVED peer={peer} pen_id={pen_id!r} "
                    f"response={APPROVAL_BODY.decode('utf-8')}"
                )
                approved.set()
            else:
                body = b'{"error":"not found"}'
                tls.sendall(http_response("404 Not Found", body))
                logger.write(
                    f"REJECTED_ROUTE peer={peer} method={method!r} path={path!r} query={query!r}"
                )
    except ssl.SSLError as error:
        logger.write(f"TLS_FAIL peer={peer} error={error!r}")
    except Exception as error:  # noqa: BLE001
        logger.write(f"CONNECTION_ERROR peer={peer} error={error!r}")
    finally:
        try:
            client.close()
        except OSError:
            pass


def run(config: Config, logger: Logger) -> None:
    stop = threading.Event()
    approved = threading.Event()
    redirect = PfRedirect(config, logger)

    def request_stop(_signal: int, _frame: object) -> None:
        logger.write("STOP_REQUESTED")
        stop.set()

    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGTERM, request_stop)

    with tempfile.TemporaryDirectory(prefix="c1slim-adb-admit-") as temp:
        context = build_tls_context(Path(temp), config, logger)
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
                listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                listener.bind((config.gateway_ip, config.listen_port))
                listener.listen(8)
                listener.settimeout(0.5)
                logger.write(
                    f"HTTPS_READY address={config.gateway_ip}:{config.listen_port} "
                    f"device={config.device_ip}"
                )
                # HTTPS is listening before the redirect opens, so the first SYN
                # can never arrive ahead of the listener.
                redirect.acquire()
                logger.write(
                    "READY open About-device and press keyboard Enter 10 times within 5 seconds"
                )

                exit_deadline: float | None = None
                while not stop.is_set():
                    if approved.is_set() and not config.keep_running:
                        if exit_deadline is None:
                            exit_deadline = time.monotonic() + 2
                            logger.write("APPROVAL_SENT automatic cleanup in 2 seconds")
                        elif time.monotonic() >= exit_deadline:
                            break
                    try:
                        client, address = listener.accept()
                    except (TimeoutError, socket.timeout):
                        continue
                    threading.Thread(
                        target=handle_connection,
                        args=(client, address, context, config, logger, approved),
                        daemon=True,
                    ).start()
        finally:
            stop.set()
            redirect.release()
            logger.write("STOPPED cleanup_complete=true")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Capture and locally approve the C1-Slim adbAdmit request through "
            "macOS Internet Sharing and a scoped pf redirect"
        )
    )
    parser.add_argument("--host", default=DEFAULT_HOST)
    parser.add_argument("--origin-ip", help="override the resolved API IPv4 address")
    parser.add_argument("--bridge", help="Internet Sharing interface, usually bridge100")
    parser.add_argument("--gateway-ip", help="override the bridge IPv4, usually 192.168.2.1")
    parser.add_argument("--device-ip")
    parser.add_argument("--device-mac", default=DEFAULT_DEVICE_MAC)
    parser.add_argument("--listen-port", type=int, default=DEFAULT_LISTEN_PORT)
    parser.add_argument(
        "--keep-running",
        action="store_true",
        help="do not stop automatically after one approved request",
    )
    return parser.parse_args()


def build_config(args: argparse.Namespace) -> Config:
    require_macos()
    require_root()
    if not 1 <= args.listen_port <= 65535:
        raise ValueError(f"invalid TCP port: {args.listen_port}")
    bridge, gateway_ip = discover_bridge(args.bridge)
    if args.gateway_ip:
        gateway_ip = validate_ip(args.gateway_ip, "gateway IP")
    device_ip = discover_device_ip(bridge, gateway_ip, args.device_ip, args.device_mac)
    origin_ip = resolve_origin(args.host, args.origin_ip)
    return Config(
        host=args.host,
        origin_ip=origin_ip,
        bridge=bridge,
        gateway_ip=gateway_ip,
        device_ip=device_ip,
        listen_port=args.listen_port,
        keep_running=args.keep_running,
    )


def main() -> None:
    args = parse_args()
    logger = Logger(LOG_PATH)
    try:
        config = build_config(args)
        logger.write(
            f"START bridge={config.bridge} gateway={config.gateway_ip} "
            f"device={config.device_ip} origin={config.origin_ip}:{ORIGIN_PORT} "
            f"listen={config.listen_port} log={LOG_PATH}"
        )
        logger.write(
            "PRIVACY plaintext log may contain account identifiers and cookies; "
            "do not publish it"
        )
        run(config, logger)
    except Exception as error:  # noqa: BLE001
        logger.write(f"FATAL error={error!r}")
        raise


if __name__ == "__main__":
    main()
