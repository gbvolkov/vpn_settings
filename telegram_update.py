#!/usr/bin/env python3
"""
telegram_update.py

Fetch Telegram IPv4 networks from public sources and update a managed block
inside unblock.txt.

Primary sources:
- Telegram official CIDR list: https://core.telegram.org/resources/cidr.txt
- RIPE as-sets:
  - AS-TELEGRAM
  - AS211157:AS-TELEGRAM-CDN
- RIPE Stat announced prefixes for ASNs discovered from those as-sets

Optional source:
- Telegram MTProto help.getConfig.dc_options. If Telegram API credentials are
  available, uncovered IPv4 endpoints are added as /32 entries.

Usage examples:
  python3 telegram_update.py --unblock ./unblock.txt

  TELEGRAM_API_ID=12345 TELEGRAM_API_HASH=abcd... \
    python3 telegram_update.py --unblock ./unblock.txt

  TELEGRAM_API_ID=12345 TELEGRAM_API_HASH=abcd... \
  TELEGRAM_SESSION_STRING='...' \
    python3 telegram_update.py --unblock ./unblock.txt --no-interactive

Notes:
- Public REST sources do not require Telegram credentials.
- Only IPv4 addresses/ranges are written because the current router scheme
  uses IPv4 iptables/ipset.
"""

from __future__ import annotations

import argparse
import asyncio
import datetime as dt
import ipaddress
import json
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Sequence
from urllib import error as urlerror
from urllib import parse as urlparse
from urllib import request as urlrequest

try:
    from telethon import TelegramClient, functions
    from telethon.sessions import StringSession

    TELETHON_IMPORT_ERROR: Exception | None = None
except Exception as exc:  # pragma: no cover
    TelegramClient = None
    functions = None
    StringSession = None
    TELETHON_IMPORT_ERROR = exc

BEGIN_MARKER = "# BEGIN TELEGRAM_AUTO"
END_MARKER = "# END TELEGRAM_AUTO"
DEFAULT_SESSION_FILE = ".telegram_update.session"
ENV_API_ID = "TELEGRAM_API_ID"
ENV_API_HASH = "TELEGRAM_API_HASH"
ENV_SESSION_STRING = "TELEGRAM_SESSION_STRING"
HTTP_TIMEOUT_SECONDS = 30.0
HTTP_USER_AGENT = "tgupd/0.1"
TELEGRAM_OFFICIAL_CIDR_URL = "https://core.telegram.org/resources/cidr.txt"
RIPE_AS_SET_NAMES = ("AS-TELEGRAM", "AS211157:AS-TELEGRAM-CDN")
RIPE_AS_SET_URL_TEMPLATE = "https://rest.db.ripe.net/ripe/as-set/{name}.json"
RIPE_STAT_PREFIX_URL_TEMPLATE = (
    "https://stat.ripe.net/data/announced-prefixes/data.json?resource={resource}"
)
ASN_RE = re.compile(r"^AS[0-9]+$")


class FetchError(RuntimeError):
    """Raised when a required upstream resource cannot be fetched or parsed."""


@dataclass(slots=True)
class NetworkSnapshot:
    official_cidrs: list[ipaddress.IPv4Network]
    asns: list[str]
    asn_cidrs: list[ipaddress.IPv4Network]
    asn_extra_cidrs: list[ipaddress.IPv4Network]
    mtproto_ips: list[str]
    mtproto_extra_cidrs: list[ipaddress.IPv4Network]
    mtproto_status: str

    def combined_cidrs(self) -> list[ipaddress.IPv4Network]:
        return sort_networks(
            [
                *self.official_cidrs,
                *self.asn_extra_cidrs,
                *self.mtproto_extra_cidrs,
            ]
        )


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description=(
            "Fetch Telegram IPv4 networks from public CIDR/ASN sources and "
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
        help="Telethon session file path if optional MTProto source is used",
    )
    p.add_argument(
        "--api-id",
        type=int,
        default=None,
        help=f"Telegram API ID for optional MTProto source (or env {ENV_API_ID})",
    )
    p.add_argument(
        "--api-hash",
        default=None,
        help=f"Telegram API hash for optional MTProto source (or env {ENV_API_HASH})",
    )
    p.add_argument(
        "--session-string",
        default=None,
        help=f"Telethon StringSession for optional MTProto source (or env {ENV_SESSION_STRING})",
    )
    p.add_argument(
        "--no-interactive",
        action="store_true",
        help="Fail instead of prompting for login if optional MTProto source has no valid session",
    )
    p.add_argument(
        "--print-only",
        action="store_true",
        help="Print the generated managed block and do not modify unblock.txt",
    )
    p.add_argument(
        "--http-timeout",
        type=float,
        default=HTTP_TIMEOUT_SECONDS,
        help="HTTP timeout in seconds for public source requests (default: %(default)s)",
    )
    return p.parse_args()


def get_optional_api_credentials(args: argparse.Namespace) -> tuple[int, str] | None:
    api_id = args.api_id or os.getenv(ENV_API_ID)
    api_hash = args.api_hash or os.getenv(ENV_API_HASH)
    session_string = args.session_string or os.getenv(ENV_SESSION_STRING)

    if not api_id and not api_hash and not session_string:
        return None

    if not api_id or not api_hash:
        raise ValueError(
            f"Optional MTProto source requires both {ENV_API_ID} and {ENV_API_HASH}."
        )

    try:
        api_id_int = int(api_id)
    except ValueError as exc:
        raise ValueError(f"{ENV_API_ID} must be an integer.") from exc

    return api_id_int, str(api_hash)


def build_client(args: argparse.Namespace, api_id: int, api_hash: str) -> TelegramClient:
    if TELETHON_IMPORT_ERROR is not None or TelegramClient is None or StringSession is None:
        raise RuntimeError(
            "Telethon is not installed. Install it with: pip install telethon"
        )

    session_string = args.session_string or os.getenv(ENV_SESSION_STRING)
    if session_string:
        session = StringSession(session_string)
    else:
        session = args.session_file
    return TelegramClient(session, api_id, api_hash)


async def fetch_mtproto_ipv4_endpoints(client: TelegramClient) -> list[str]:
    config = await client(functions.help.GetConfigRequest())
    ips: list[str] = []
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
        ips.append(str(ip_obj))
    return dedupe_and_sort_ips(ips)


def dedupe_and_sort_ips(values: Iterable[str]) -> list[str]:
    unique = {ipaddress.ip_address(value) for value in values}
    return [str(ip) for ip in sorted(unique, key=int)]


def sort_networks(
    values: Iterable[ipaddress.IPv4Network],
) -> list[ipaddress.IPv4Network]:
    return sorted(set(values), key=lambda network: (int(network.network_address), network.prefixlen))


def keep_only_uncovered_networks(
    candidates: Iterable[ipaddress.IPv4Network],
    covered_by: Iterable[ipaddress.IPv4Network],
) -> list[ipaddress.IPv4Network]:
    covered = sort_networks(covered_by)
    kept: list[ipaddress.IPv4Network] = []
    for candidate in sort_networks(candidates):
        if any(candidate.subnet_of(network) for network in covered):
            continue
        kept.append(candidate)
        covered.append(candidate)
    return sort_networks(kept)


def parse_ipv4_network(value: str) -> ipaddress.IPv4Network | None:
    candidate = value.strip()
    if not candidate or candidate.startswith("#"):
        return None

    try:
        network = ipaddress.ip_network(candidate, strict=False)
    except ValueError:
        return None

    if network.version != 4:
        return None

    return ipaddress.IPv4Network(network)


def parse_ipv4_networks(values: Iterable[str]) -> list[ipaddress.IPv4Network]:
    networks: list[ipaddress.IPv4Network] = []
    for value in values:
        network = parse_ipv4_network(value)
        if network is not None:
            networks.append(network)
    return sort_networks(networks)


def http_get_bytes(url: str, *, timeout: float) -> bytes:
    request = urlrequest.Request(
        url,
        headers={
            "Accept": "application/json, text/plain;q=0.9, */*;q=0.1",
            "User-Agent": HTTP_USER_AGENT,
        },
    )
    try:
        with urlrequest.urlopen(request, timeout=timeout) as response:
            return response.read()
    except (urlerror.URLError, TimeoutError, OSError) as exc:
        raise FetchError(f"request failed for {url}: {exc}") from exc


def http_get_text(url: str, *, timeout: float) -> str:
    try:
        return http_get_bytes(url, timeout=timeout).decode("utf-8")
    except UnicodeDecodeError as exc:
        raise FetchError(f"response for {url} is not valid UTF-8: {exc}") from exc


def http_get_json(url: str, *, timeout: float) -> dict:
    try:
        return json.loads(http_get_text(url, timeout=timeout))
    except json.JSONDecodeError as exc:
        raise FetchError(f"response for {url} is not valid JSON: {exc}") from exc


def fetch_official_ipv4_cidrs(timeout: float) -> list[ipaddress.IPv4Network]:
    cidrs = parse_ipv4_networks(http_get_text(TELEGRAM_OFFICIAL_CIDR_URL, timeout=timeout).splitlines())
    if not cidrs:
        raise FetchError(
            f"no IPv4 CIDRs were found in official Telegram list: {TELEGRAM_OFFICIAL_CIDR_URL}"
        )
    return cidrs


def fetch_as_set_members(as_set_name: str, timeout: float) -> set[str]:
    encoded_name = urlparse.quote(as_set_name, safe="")
    payload = http_get_json(
        RIPE_AS_SET_URL_TEMPLATE.format(name=encoded_name),
        timeout=timeout,
    )
    objects = payload.get("objects", {}).get("object", [])
    if not objects:
        raise FetchError(f"RIPE as-set response is missing objects for {as_set_name}")

    members: set[str] = set()
    for obj in objects:
        attributes = obj.get("attributes", {}).get("attribute", [])
        for attr in attributes:
            if str(attr.get("name", "")).lower() != "members":
                continue
            for raw_member in str(attr.get("value", "")).split(","):
                member = raw_member.strip().upper()
                if ASN_RE.fullmatch(member):
                    members.add(member)

    return members


def sort_asns(values: Iterable[str]) -> list[str]:
    return sorted(set(values), key=lambda asn: int(asn[2:]))


def fetch_routing_asns(timeout: float) -> list[str]:
    members: set[str] = set()
    for as_set_name in RIPE_AS_SET_NAMES:
        members.update(fetch_as_set_members(as_set_name, timeout))

    asns = sort_asns(members)
    if not asns:
        raise FetchError(
            f"no ASNs were found in RIPE as-sets: {', '.join(RIPE_AS_SET_NAMES)}"
        )
    return asns


def fetch_asn_ipv4_cidrs(asn: str, timeout: float) -> list[ipaddress.IPv4Network]:
    payload = http_get_json(
        RIPE_STAT_PREFIX_URL_TEMPLATE.format(resource=urlparse.quote(asn, safe="")),
        timeout=timeout,
    )
    prefixes = payload.get("data", {}).get("prefixes", [])
    cidrs = parse_ipv4_networks(str(item.get("prefix", "")) for item in prefixes)
    return cidrs


def fetch_all_asn_ipv4_cidrs(asns: Sequence[str], timeout: float) -> list[ipaddress.IPv4Network]:
    cidrs: list[ipaddress.IPv4Network] = []
    for asn in asns:
        cidrs.extend(fetch_asn_ipv4_cidrs(asn, timeout))

    sorted_cidrs = sort_networks(cidrs)
    if not sorted_cidrs:
        raise FetchError(f"no IPv4 CIDRs were found via RIPE Stat for ASNs: {', '.join(asns)}")
    return sorted_cidrs


def find_uncovered_mtproto_cidrs(
    mtproto_ips: Sequence[str],
    public_cidrs: Sequence[ipaddress.IPv4Network],
) -> list[ipaddress.IPv4Network]:
    extras: list[ipaddress.IPv4Network] = []
    for ip_text in mtproto_ips:
        ip_obj = ipaddress.IPv4Address(ip_text)
        if any(ip_obj in network for network in public_cidrs):
            continue
        extras.append(ipaddress.IPv4Network(f"{ip_text}/32"))
    return sort_networks(extras)


def describe_mtproto_status(status: str) -> str:
    return {
        "included": "included",
        "skipped_no_credentials": "skipped (no credentials)",
        "skipped_unavailable": "skipped (Telethon unavailable)",
        "skipped_error": "skipped (runtime error)",
    }.get(status, status)


def make_block(snapshot: NetworkSnapshot) -> str:
    now = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%M:%SZ")
    combined_cidrs = snapshot.combined_cidrs()

    lines: list[str] = [
        BEGIN_MARKER,
        f"# generated_utc={now}",
        f"# total_ipv4_networks={len(combined_cidrs)}",
        f"# official_ipv4_cidrs={len(snapshot.official_cidrs)}",
        f"# ripe_as_sets={','.join(RIPE_AS_SET_NAMES)}",
        f"# ripe_asns={','.join(snapshot.asns)}",
        f"# ripe_asn_ipv4_cidrs={len(snapshot.asn_cidrs)}",
        f"# ripe_asn_additional_ipv4_cidrs={len(snapshot.asn_extra_cidrs)}",
        f"# mtproto_status={snapshot.mtproto_status}",
        f"# mtproto_ipv4_endpoints={len(snapshot.mtproto_ips)}",
        f"# mtproto_uncovered_ipv4={len(snapshot.mtproto_extra_cidrs)}",
        f"# source_official={TELEGRAM_OFFICIAL_CIDR_URL}",
        "# source_ripe_as_set=https://rest.db.ripe.net/ripe/as-set/<AS-SET>.json",
        "# source_ripe_stat=https://stat.ripe.net/data/announced-prefixes/data.json?resource=<ASN>",
        "# source_mtproto=Telegram MTProto help.getConfig.dc_options (optional, /32 only if uncovered)",
    ]
    lines.extend(str(network) for network in combined_cidrs)
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


async def collect_optional_mtproto_data(
    args: argparse.Namespace,
    public_cidrs: Sequence[ipaddress.IPv4Network],
) -> tuple[list[str], list[ipaddress.IPv4Network], str]:
    try:
        credentials = get_optional_api_credentials(args)
    except ValueError as exc:
        print(f"[ERR] {exc}", file=sys.stderr)
        raise SystemExit(2) from exc

    if credentials is None:
        return [], [], "skipped_no_credentials"

    if TELETHON_IMPORT_ERROR is not None:
        print(
            "[WARN] Optional MTProto source skipped: Telethon is not installed.",
            file=sys.stderr,
        )
        return [], [], "skipped_unavailable"

    client = build_client(args, *credentials)
    try:
        await client.connect()
        if not await client.is_user_authorized():
            if args.no_interactive:
                print(
                    "[WARN] Optional MTProto source skipped: no authorized session and --no-interactive was set.",
                    file=sys.stderr,
                )
                return [], [], "skipped_error"
            await client.start()

        mtproto_ips = await fetch_mtproto_ipv4_endpoints(client)
        mtproto_extra_cidrs = find_uncovered_mtproto_cidrs(mtproto_ips, public_cidrs)
        return mtproto_ips, mtproto_extra_cidrs, "included"
    except Exception as exc:
        print(f"[WARN] Optional MTProto source skipped: {exc}", file=sys.stderr)
        return [], [], "skipped_error"
    finally:
        try:
            await client.disconnect()
        except Exception:
            pass


async def run(args: argparse.Namespace) -> int:
    unblock_path = Path(args.unblock)
    if not unblock_path.exists() and not args.print_only:
        print(f"[ERR] unblock file not found: {unblock_path}", file=sys.stderr)
        return 2

    try:
        official_cidrs = fetch_official_ipv4_cidrs(args.http_timeout)
        asns = fetch_routing_asns(args.http_timeout)
        asn_cidrs = fetch_all_asn_ipv4_cidrs(asns, args.http_timeout)
    except FetchError as exc:
        print(f"[ERR] Failed to fetch Telegram public networks: {exc}", file=sys.stderr)
        return 4

    asn_extra_cidrs = keep_only_uncovered_networks(asn_cidrs, official_cidrs)
    public_cidrs = sort_networks([*official_cidrs, *asn_extra_cidrs])
    mtproto_ips, mtproto_extra_cidrs, mtproto_status = await collect_optional_mtproto_data(
        args,
        public_cidrs,
    )

    snapshot = NetworkSnapshot(
        official_cidrs=official_cidrs,
        asns=asns,
        asn_cidrs=asn_cidrs,
        asn_extra_cidrs=asn_extra_cidrs,
        mtproto_ips=mtproto_ips,
        mtproto_extra_cidrs=mtproto_extra_cidrs,
        mtproto_status=mtproto_status,
    )
    combined_cidrs = snapshot.combined_cidrs()
    if not combined_cidrs:
        print("[ERR] No IPv4 Telegram networks were collected.", file=sys.stderr)
        return 4

    block = make_block(snapshot)

    if args.print_only:
        sys.stdout.write(block)
        return 0

    original = unblock_path.read_text(encoding="utf-8")
    updated = replace_managed_block(original, block)
    write_unblock(unblock_path, updated)

    print(f"[OK] Updated managed Telegram block in: {unblock_path}")
    print(f"[OK] IPv4 networks written: {len(combined_cidrs)}")
    print(f"[OK] Official IPv4 CIDRs: {len(official_cidrs)}")
    print(f"[OK] RIPE ASN IPv4 CIDRs: {len(asn_cidrs)}")
    print(f"[OK] Additional RIPE ASN IPv4 CIDRs kept: {len(asn_extra_cidrs)}")
    print(f"[OK] RIPE ASNs: {', '.join(asns)}")
    print(f"[OK] Optional MTProto source: {describe_mtproto_status(mtproto_status)}")
    if mtproto_ips:
        print(f"[OK] MTProto IPv4 endpoints observed: {len(mtproto_ips)}")
    if mtproto_extra_cidrs:
        print(f"[OK] Additional MTProto /32 entries added: {len(mtproto_extra_cidrs)}")
    return 0


def main() -> int:
    args = parse_args()
    return asyncio.run(run(args))


if __name__ == "__main__":
    raise SystemExit(main())
