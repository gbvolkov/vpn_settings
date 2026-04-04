#!/usr/bin/env python3
"""
telegram_update.py

Fetch current Telegram DC/CDN IPv4 endpoints via MTProto help.getConfig and
update a managed block inside unblock.txt.

Designed for the Keenetic/XRay/ipset workflow where unblock.txt is the source
of truth, and downstream scripts rebuild dnsmasq/ipset from it.

Usage examples:
  TELEGRAM_API_ID=12345 TELEGRAM_API_HASH=abcd... \
    python3 telegram_update.py --unblock ./unblock.txt

  TELEGRAM_API_ID=12345 TELEGRAM_API_HASH=abcd... \
  TELEGRAM_SESSION_STRING='...' \
    python3 telegram_update.py --unblock ./unblock.txt --no-interactive

Notes:
- First run can be interactive: Telethon will ask for phone/code/password and
  create a local session file (default: .telegram_update.session).
- For unattended runs, prefer TELEGRAM_SESSION_STRING or a pre-created session
  file and pass --no-interactive.
- Only IPv4 addresses are written because the current router scheme uses
  IPv4 iptables/ipset.
"""

from __future__ import annotations

import argparse
import asyncio
import datetime as dt
import ipaddress
import os
import sys
from pathlib import Path
from typing import Iterable, List, Sequence

try:
    from telethon import TelegramClient, functions
    from telethon.sessions import StringSession
except Exception as exc:  # pragma: no cover
    print(
        "[ERR] Telethon is not installed. Install it with: pip install telethon",
        file=sys.stderr,
    )
    raise SystemExit(1) from exc

BEGIN_MARKER = "# BEGIN TELEGRAM_AUTO"
END_MARKER = "# END TELEGRAM_AUTO"
DEFAULT_SESSION_FILE = ".telegram_update.session"
ENV_API_ID = "TELEGRAM_API_ID"
ENV_API_HASH = "TELEGRAM_API_HASH"
ENV_SESSION_STRING = "TELEGRAM_SESSION_STRING"


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description=(
            "Fetch Telegram DC/CDN endpoints via MTProto help.getConfig and "
            "update a managed block in unblock.txt"
        )
    )
    p.add_argument(
        "--unblock",
        default="unblock.txt",
        help="Path to unblock.txt (default: %(default)s)",
    )
    p.add_argument(
        "--session-file",
        default=DEFAULT_SESSION_FILE,
        help="Telethon session file path for interactive or saved sessions",
    )
    p.add_argument(
        "--api-id",
        type=int,
        default=None,
        help=f"Telegram API ID (or env {ENV_API_ID})",
    )
    p.add_argument(
        "--api-hash",
        default=None,
        help=f"Telegram API hash (or env {ENV_API_HASH})",
    )
    p.add_argument(
        "--session-string",
        default=None,
        help=f"Telethon StringSession (or env {ENV_SESSION_STRING})",
    )
    p.add_argument(
        "--no-interactive",
        action="store_true",
        help="Fail instead of prompting for login if no valid session is available",
    )
    p.add_argument(
        "--print-only",
        action="store_true",
        help="Print the generated managed block and do not modify unblock.txt",
    )
    return p.parse_args()


def get_api_credentials(args: argparse.Namespace) -> tuple[int, str]:
    api_id = args.api_id or os.getenv(ENV_API_ID)
    api_hash = args.api_hash or os.getenv(ENV_API_HASH)

    if not api_id or not api_hash:
        print(
            f"[ERR] API credentials are required. Set --api-id/--api-hash or env {ENV_API_ID}/{ENV_API_HASH}.",
            file=sys.stderr,
        )
        raise SystemExit(2)

    try:
        api_id_int = int(api_id)
    except ValueError as exc:
        print("[ERR] TELEGRAM_API_ID must be an integer.", file=sys.stderr)
        raise SystemExit(2) from exc

    return api_id_int, str(api_hash)


def build_client(args: argparse.Namespace, api_id: int, api_hash: str) -> TelegramClient:
    session_string = args.session_string or os.getenv(ENV_SESSION_STRING)
    if session_string:
        session = StringSession(session_string)
    else:
        session = args.session_file
    return TelegramClient(session, api_id, api_hash)


async def fetch_ipv4_endpoints(client: TelegramClient) -> list[dict]:
    config = await client(functions.help.GetConfigRequest())
    rows: list[dict] = []
    for dc in config.dc_options:
        ip = getattr(dc, "ip_address", None)
        if not ip:
            continue
        try:
            ip_obj = ipaddress.ip_address(ip)
        except ValueError:
            continue
        if ip_obj.version != 4:
            continue
        rows.append(
            {
                "ip": str(ip_obj),
                "dc_id": int(dc.id),
                "port": int(dc.port),
                "cdn": bool(getattr(dc, "cdn", False)),
                "media_only": bool(getattr(dc, "media_only", False)),
                "tcpo_only": bool(getattr(dc, "tcpo_only", False)),
                "static": bool(getattr(dc, "static", False)),
                "this_port_only": bool(getattr(dc, "this_port_only", False)),
            }
        )
    return rows


def dedupe_and_sort_ips(rows: Sequence[dict]) -> List[str]:
    unique = {row["ip"] for row in rows}
    return [str(ip) for ip in sorted((ipaddress.ip_address(x) for x in unique), key=int)]


def make_block(rows: Sequence[dict], ips: Sequence[str]) -> str:
    now = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%M:%SZ")
    total = len(ips)
    cdn_count = len({r["ip"] for r in rows if r["cdn"]})
    media_count = len({r["ip"] for r in rows if r["media_only"]})
    tcpo_count = len({r["ip"] for r in rows if r["tcpo_only"]})

    lines: list[str] = [
        BEGIN_MARKER,
        f"# generated_utc={now}",
        f"# total_ipv4={total}",
        f"# cdn_ipv4={cdn_count}",
        f"# media_only_ipv4={media_count}",
        f"# tcpo_only_ipv4={tcpo_count}",
        "# source=Telegram MTProto help.getConfig.dc_options (IPv4 only)",
    ]
    lines.extend(ips)
    lines.append(END_MARKER)
    return "\n".join(lines) + "\n"


def replace_managed_block(text: str, block: str) -> str:
    begin = text.find(BEGIN_MARKER)
    end = text.find(END_MARKER)
    if begin != -1 and end != -1 and end > begin:
        end += len(END_MARKER)
        prefix = text[:begin].rstrip("\n")
        suffix = text[end:].lstrip("\n")
        out = prefix + "\n" + block
        if suffix:
            out += suffix if suffix.startswith("\n") else "\n" + suffix
        return out

    insertion_anchor = "###Messagengers.Telegram"
    pos = text.find(insertion_anchor)
    if pos != -1:
        line_end = text.find("\n", pos)
        if line_end == -1:
            line_end = len(text)
        prefix = text[: line_end + 1]
        suffix = text[line_end + 1 :]
        if prefix and not prefix.endswith("\n"):
            prefix += "\n"
        return prefix + block + suffix

    if text and not text.endswith("\n"):
        text += "\n"
    return text + block


def write_unblock(path: Path, new_text: str) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(new_text, encoding="utf-8")
    tmp.replace(path)


async def run(args: argparse.Namespace) -> int:
    api_id, api_hash = get_api_credentials(args)
    unblock_path = Path(args.unblock)
    if not unblock_path.exists() and not args.print_only:
        print(f"[ERR] unblock file not found: {unblock_path}", file=sys.stderr)
        return 2

    client = build_client(args, api_id, api_hash)

    try:
        await client.connect()
        if not await client.is_user_authorized():
            if args.no_interactive:
                print(
                    "[ERR] No authorized session available and --no-interactive was set.",
                    file=sys.stderr,
                )
                return 3
            await client.start()

        rows = await fetch_ipv4_endpoints(client)
        ips = dedupe_and_sort_ips(rows)
        if not ips:
            print("[ERR] No IPv4 DC/CDN endpoints returned by Telegram.", file=sys.stderr)
            return 4

        block = make_block(rows, ips)

        if args.print_only:
            sys.stdout.write(block)
            return 0

        original = unblock_path.read_text(encoding="utf-8")
        updated = replace_managed_block(original, block)
        write_unblock(unblock_path, updated)

        print(f"[OK] Updated managed Telegram block in: {unblock_path}")
        print(f"[OK] IPv4 endpoints written: {len(ips)}")
        if not (args.session_string or os.getenv(ENV_SESSION_STRING)):
            print(f"[OK] Session file: {Path(args.session_file).resolve()}")
        return 0
    finally:
        try:
            await client.disconnect()
        except Exception:
            pass


def main() -> int:
    args = parse_args()
    return asyncio.run(run(args))


if __name__ == "__main__":
    raise SystemExit(main())
