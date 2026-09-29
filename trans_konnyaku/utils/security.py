"""
Security Utilities for Translation Konjac
Validates endpoints to guarantee ZERO external network transmission.
"""

from urllib.parse import urlparse
import ipaddress

ALLOWED_HOSTS = {"127.0.0.1", "localhost", "::1"}

def validate_local_endpoint(url_string: str) -> str:
    """
    LLM接続先が純粋なローカルループバックアドレスであることを厳格に検証する。
    外部URLやLAN内IPが指定された場合は即座にValueErrorを送出する。
    """
    if not url_string:
        raise ValueError("APIエンドポイントが指定されていません。")

    parsed = urlparse(url_string)
    if parsed.scheme not in ("http", "https"):
        raise ValueError(f"無効なURLスキームです: '{parsed.scheme}'. http:// または https:// を使用してください。")

    hostname = parsed.hostname
    if not hostname:
        raise ValueError(f"ホスト名が解析できませんでした: '{url_string}'")

    hostname_lower = hostname.lower()

    if hostname_lower in ALLOWED_HOSTS:
        return url_string

    try:
        ip = ipaddress.ip_address(hostname_lower)
        if ip.is_loopback:
            return url_string
    except ValueError:
        pass

    raise ValueError(
        f"セキュリティ違反: 外部アドレス '{hostname}' への接続は禁止されています。"
        f"127.0.0.1 または localhost のみ許可されます。"
    )
