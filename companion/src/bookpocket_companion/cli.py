import argparse
import hashlib
import ipaddress
import json
from pathlib import Path
import socket
import threading
import tempfile
import webbrowser
import atexit
import os
from datetime import datetime, timedelta, timezone
from urllib.parse import quote
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID
import uvicorn
from .models import Config
from .app import create_app
from .phone_gateway import PhoneGateway


_SAVED_KEYS = ("public_url", "voicestudio_url", "ffmpeg", "public_tls_mode", "phone_gateway_port")


def connection_config(config, saved, *, public_url=None, public_tls_mode=None, phone_gateway_port=None):
    """Validate persisted settings, retaining opt-in tunnel setup across launches."""
    if not isinstance(saved, dict): raise ValueError("config.json must contain a settings object")
    values = {key: saved[key] for key in _SAVED_KEYS if key in saved}
    if public_url is not None: values["public_url"] = public_url
    if public_tls_mode is not None: values["public_tls_mode"] = public_tls_mode
    if phone_gateway_port is not None: values["phone_gateway_port"] = phone_gateway_port or None
    result = Config.model_validate({**config.model_dump(), **values})
    if result.phone_gateway_port in {result.port, result.studio_port}:
        raise ValueError("The phone gateway needs a separate port from HTTPS and the studio")
    return result


def save_connection_config(path, saved, config):
    """Atomically update only nonsecret connection settings, preserving other keys."""
    values = {**saved, **{key: getattr(config, key) for key in ("public_url", "public_tls_mode", "phone_gateway_port")}}
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent, prefix=".config-", suffix=".tmp", delete=False) as output:
            temporary = Path(output.name)
            json.dump(values, output, indent=2)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if temporary is not None: temporary.unlink(missing_ok=True)


class InstanceGuard:
    """OS-held lock: process death releases ownership without trusting a stale PID file."""
    def __init__(self, data_dir):
        data_dir.mkdir(parents=True, exist_ok=True)
        self.file = (data_dir / "companion.lock").open("a+b")
        if self.file.tell() == 0:
            self.file.write(b"0"); self.file.flush()
        self.file.seek(0)
        try:
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(self.file.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(self.file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            self.file.close()
            raise RuntimeError("Book Pocket Open is already running for this data folder. Open the studio from its tray icon") from None

    def close(self):
        if self.file.closed: return
        self.file.seek(0)
        if os.name == "nt":
            import msvcrt
            msvcrt.locking(self.file.fileno(), msvcrt.LK_UNLCK, 1)
        else:
            import fcntl
            fcntl.flock(self.file.fileno(), fcntl.LOCK_UN)
        self.file.close()


def certificate(config):
    root = config.data_dir / "tls"
    root.mkdir(parents=True, exist_ok=True)
    cert_path, key_path = root / "companion.pem", root / "companion.key"
    if not cert_path.exists() or not key_path.exists():
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Book Pocket Open Companion")])
        names = [x509.DNSName("localhost"), x509.DNSName(socket.gethostname()), x509.IPAddress(ipaddress.ip_address("127.0.0.1"))]
        try:
            names += [x509.IPAddress(ipaddress.ip_address(ip)) for ip in socket.gethostbyname_ex(socket.gethostname())[2]]
        except OSError: pass
        cert = (x509.CertificateBuilder().subject_name(subject).issuer_name(subject).public_key(key.public_key())
                .serial_number(x509.random_serial_number()).not_valid_before(datetime.now(timezone.utc)-timedelta(minutes=5))
                .not_valid_after(datetime.now(timezone.utc)+timedelta(days=3650)).add_extension(x509.SubjectAlternativeName(names), critical=False).sign(key, hashes.SHA256()))
        key_path.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
        cert_path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
        try: key_path.chmod(0o600)
        except OSError: pass
    cert = x509.load_pem_x509_certificate(cert_path.read_bytes())
    config.certificate_sha256 = cert.fingerprint(hashes.SHA256()).hex()
    return cert_path, key_path


def main():
    parser = argparse.ArgumentParser(description="Book Pocket Open local audiobook companion")
    parser.add_argument("command", nargs="?", choices=["serve", "install-engine"], default="serve")
    parser.add_argument("engine", nargs="?", choices=["kokoro", "qwen3"])
    parser.add_argument("--data-dir", type=Path)
    parser.add_argument("--port", type=int, default=8783)
    parser.add_argument("--studio-port", type=int, default=8782)
    parser.add_argument("--public-url", help="HTTPS LAN or Tailscale URL phones use to reach this PC")
    parser.add_argument("--public-tls-mode", choices=["pinned", "system"], help="Persist phone TLS verification: pinned LAN certificate or normal system trust for public HTTPS")
    parser.add_argument("--phone-gateway-port", type=int, help="Persist a loopback-only phone API target for a trusted HTTPS tunnel; 0 disables it")
    parser.add_argument("--studio-dir", type=Path)
    parser.add_argument("--voicestudio-url", help="Optional local VoiceStudio base URL, such as http://127.0.0.1:3900")
    parser.add_argument("--dev", action="store_true", help="Loopback HTTP only and explicit Vite dev origins")
    parser.add_argument("--no-browser", action="store_true")
    parser.add_argument("--tray", action="store_true")
    args = parser.parse_args()
    config = Config(port=args.port, studio_port=args.studio_port, dev=args.dev)
    if args.data_dir: config.data_dir = args.data_dir
    saved_path = config.data_dir / "config.json"
    saved = {}
    if saved_path.exists():
        saved = json.loads(saved_path.read_text(encoding="utf-8"))
    try:
        config = connection_config(config, saved, public_url=args.public_url, public_tls_mode=args.public_tls_mode, phone_gateway_port=args.phone_gateway_port)
    except (ValueError, TypeError) as exc: parser.error(str(exc))
    if not args.public_url and "public_url" not in saved:
        try:
            addresses = [ip for ip in socket.gethostbyname_ex(socket.gethostname())[2] if not ipaddress.ip_address(ip).is_loopback]
            address = next((ip for ip in addresses if ip.startswith(("192.168.", "10."))), addresses[0] if addresses else "localhost")
        except OSError: address = "localhost"
        config.public_url = f"https://{address}:{args.port}"
    config.voicestudio_url = args.voicestudio_url or config.voicestudio_url
    config.studio_dir = args.studio_dir or Path(__file__).resolve().parents[3] / "studio" / "dist"
    if args.command == "install-engine":
        if not args.engine: parser.error("Choose kokoro or qwen3")
        from .engines import ManagedEngine
        ManagedEngine(config.data_dir / "engines", args.engine).install()
        return
    try:
        instance = InstanceGuard(config.data_dir)
    except RuntimeError as exc:
        parser.exit(1, str(exc) + "\n")
    atexit.register(instance.close)
    if any(value is not None for value in (args.public_url, args.public_tls_mode, args.phone_gateway_port)):
        save_connection_config(saved_path, saved, config)
    tls = {}
    if not args.dev:
        cert, key = certificate(config)
        tls = {"ssl_certfile": str(cert), "ssl_keyfile": str(key)}
    launch_url = (f"http://127.0.0.1:{args.port}" if args.dev else f"http://127.0.0.1:{config.studio_port}") + "/#session=" + quote(config.admin_token)
    if not args.no_browser: threading.Timer(1.5, lambda: webbrowser.open(launch_url)).start()
    app = create_app(config)
    server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1" if args.dev else "0.0.0.0", port=args.port, proxy_headers=False, **tls))
    secondary_servers = []
    if not args.dev:
        # Same app/state, exactly one worker lifespan; HTTP listener is loopback-only.
        local_server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=config.studio_port, proxy_headers=False, lifespan="off"))
        secondary_servers.append((local_server, "local-studio"))
    if config.phone_gateway_port:
        gateway_server = uvicorn.Server(uvicorn.Config(PhoneGateway(app), host="127.0.0.1", port=config.phone_gateway_port,
                                                      proxy_headers=False, lifespan="off", workers=1))
        secondary_servers.append((gateway_server, "phone-gateway"))
    secondary_threads = []
    for secondary, name in secondary_servers:
        thread = threading.Thread(target=secondary.run, daemon=True, name=name)
        thread.start()
        secondary_threads.append(thread)
    if args.tray:
        import pystray
        from PIL import Image, ImageDraw
        icon_image = Image.new("RGB", (64, 64), "#111416")
        ImageDraw.Draw(icon_image).rounded_rectangle((14, 9, 49, 55), radius=5, fill="#DCC59D")
        def stop(icon, item):
            for secondary, _ in secondary_servers: secondary.should_exit = True
            server.should_exit = True
            icon.stop()
        icon = pystray.Icon("BookPocketOpen", icon_image, "Book Pocket Open", pystray.Menu(pystray.MenuItem("Open studio", lambda: webbrowser.open(launch_url)), pystray.MenuItem("Quit", stop)))
        threading.Thread(target=server.run, daemon=True).start()
        try: icon.run()
        finally:
            for secondary, _ in secondary_servers: secondary.should_exit = True
            server.should_exit = True
    else:
        try: server.run()
        finally:
            for secondary, _ in secondary_servers: secondary.should_exit = True
    for thread in secondary_threads: thread.join(timeout=2)

if __name__ == "__main__": main()
