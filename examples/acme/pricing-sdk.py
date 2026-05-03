#!/usr/bin/env python3
"""
ACME internal infra (mock) — pricing service + DataDog StatsD agent.

Single-file, stdlib-only, runs anywhere Python 3.9+ runs. One command:

    python3 mock_infra.py

What it boots
-------------
    HTTP :8080   The pricing service.
                   GET  /healthz                              -> 200
                   GET  /pricing/{sku}?region={region}        -> 200 / 404 / 503
                   GET  /admin/metrics                        -> last-hour StatsD captures
                   POST /__chaos { "enabled": bool }          -> toggle chaos modes
                   GET  /                                     -> banner / endpoint list

    UDP  :8125   The DataDog StatsD ingest port. Captures every packet into
                 an in-memory deque so /admin/metrics can return them.

Chaos (default ON, deterministic with --seed)
---------------------------------------------
    * ~10% of GET /pricing/* return 503 (transient backend error)
    *  ~5% of GET /pricing/* respond after a +200ms latency spike
    * Unknown SKUs (anything not matching SKU-\\d+) always return 404
      with a structured `{"error": "sku_not_found", ...}` body

Pricing semantics
-----------------
    Price is deterministic per (sku, region):
        price_usd = round(((hash(sku) * 31 + hash(region)) % 9000 + 100) / 100, 2)
    -> $1.00 .. $90.99
    Same (sku, region) always returns the same price, so cache hits are
    observable end-to-end.
"""
from __future__ import annotations

import argparse
import json
import random
import re
import socket
import sys
import threading
import time
from collections import deque
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Deque, Dict, List, Optional, Tuple


# ---------------------------------------------------------------------------
# Configuration / shared state
# ---------------------------------------------------------------------------
SKU_PATTERN = re.compile(r"^SKU-\d+$")
METRIC_BUFFER_SIZE = 50_000

CHAOS_ENABLED = True
RNG = random.Random()
QUIET = False

# Captured StatsD packets, parsed into structured records.
_METRICS_LOCK = threading.RLock()
_METRICS: Deque[Dict[str, Any]] = deque(maxlen=METRIC_BUFFER_SIZE)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def _price_for(sku: str, region: str) -> float:
    seed = (hash(sku) * 31 + hash(region)) & 0xFFFF_FFFF
    return round((seed % 9000 + 100) / 100, 2)


def _log(method: str, path: str, status: int, note: str = "") -> None:
    if QUIET:
        return
    ts = datetime.now().strftime("%H:%M:%S.") + f"{int(time.time() * 1000) % 1000:03d}"
    line = f"[{ts}] {method:<5} {path:<42} {status:<3}"
    if note:
        line = f"{line}  {note}"
    print(line, flush=True)


def _log_metric(packet: str) -> None:
    if QUIET:
        return
    ts = datetime.now().strftime("%H:%M:%S.") + f"{int(time.time() * 1000) % 1000:03d}"
    print(f"[{ts}] STATSD                                       {packet}", flush=True)


# ---------------------------------------------------------------------------
# StatsD packet parsing
# ---------------------------------------------------------------------------
# DataDog/StatsD line format (one per packet, may be batched with \n):
#     metric.name:value|type|@sample_rate|#tag1:val,tag2:val
# Examples:
#     pricing.cli.requests:1|c|#region:us-west-2,status:200
#     pricing.cli.latency:42.7|h|#region:us-west-2
def _parse_statsd(packet: bytes) -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    text = packet.decode("utf-8", errors="replace").strip()
    for line in text.split("\n"):
        line = line.strip()
        if not line or ":" not in line or "|" not in line:
            continue
        try:
            name, rest = line.split(":", 1)
            parts = rest.split("|")
            value_str = parts[0]
            value = float(value_str) if "." in value_str else int(value_str)
            mtype = parts[1] if len(parts) > 1 else "?"
            tags: Dict[str, str] = {}
            for p in parts[2:]:
                if p.startswith("#"):
                    for kv in p[1:].split(","):
                        if ":" in kv:
                            k, v = kv.split(":", 1)
                            tags[k] = v
                        elif kv:
                            tags[kv] = ""
            out.append(
                {
                    "name": name,
                    "value": value,
                    "type": mtype,
                    "tags": tags,
                    "received_at": _now_iso(),
                }
            )
        except (ValueError, IndexError):
            continue
    return out


# ---------------------------------------------------------------------------
# UDP StatsD listener (DataDog agent mock)
# ---------------------------------------------------------------------------
def _statsd_loop(host: str, port: int, ready: threading.Event) -> None:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((host, port))
    ready.set()
    while True:
        try:
            data, _addr = sock.recvfrom(65535)
        except OSError:
            return
        if not data:
            continue
        records = _parse_statsd(data)
        if not records:
            continue
        with _METRICS_LOCK:
            _METRICS.extend(records)
        # Pretty-print one summary line per packet (truncate if huge).
        first = records[0]
        tags_str = ",".join(f"{k}={v}" for k, v in first["tags"].items()) if first["tags"] else "-"
        suffix = f" (+{len(records) - 1})" if len(records) > 1 else ""
        _log_metric(f"{first['name']}={first['value']} type={first['type']} tags={tags_str}{suffix}")


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------
class PricingHandler(BaseHTTPRequestHandler):
    server_version = "ACMEPricingMock/1.0"

    def log_message(self, fmt: str, *args: Any) -> None:  # silence default
        return

    # ---- Response helpers --------------------------------------------------
    def _send_json(
        self,
        status: int,
        body: Any,
        extra_headers: Optional[Dict[str, str]] = None,
    ) -> None:
        payload = json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        if extra_headers:
            for k, v in extra_headers.items():
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(payload)

    def _send_text(self, status: int, body: str) -> None:
        payload = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _read_body(self) -> Any:
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            return None
        raw = self.rfile.read(length)
        if not raw:
            return None
        try:
            return json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError:
            return None

    def _split_path(self) -> Tuple[str, Dict[str, str]]:
        path = self.path
        query: Dict[str, str] = {}
        if "?" in path:
            path, qs = path.split("?", 1)
            for kv in qs.split("&"):
                if "=" in kv:
                    k, v = kv.split("=", 1)
                    query[k] = v
                elif kv:
                    query[kv] = ""
        return path, query

    # ---- Routing -----------------------------------------------------------
    def do_GET(self) -> None:
        path, query = self._split_path()
        if path == "/":
            self._handle_root()
            return
        if path == "/healthz":
            self._send_json(HTTPStatus.OK, {"ok": True, "chaos": CHAOS_ENABLED})
            _log("GET", "/healthz", 200)
            return
        if path == "/admin/metrics":
            self._handle_admin_metrics(query)
            return
        if path.startswith("/pricing/"):
            sku = path[len("/pricing/"):]
            self._handle_pricing(sku, query)
            return
        self._send_json(HTTPStatus.NOT_FOUND, {"error": "not_found", "path": path})
        _log("GET", path, 404)

    def do_POST(self) -> None:
        path, _ = self._split_path()
        if path == "/__chaos":
            self._handle_toggle_chaos()
            return
        self._send_json(HTTPStatus.NOT_FOUND, {"error": "not_found", "path": path})
        _log("POST", path, 404)

    # ---- Endpoint implementations -----------------------------------------
    def _handle_root(self) -> None:
        body = (
            "ACME Pricing Service (mock)\n"
            "===========================\n"
            "GET  /healthz\n"
            "GET  /pricing/{sku}?region={region}\n"
            "GET  /admin/metrics                  -- captured DataDog StatsD packets\n"
            "POST /__chaos {\"enabled\": bool}\n"
            "\n"
            f"chaos: {'ON' if CHAOS_ENABLED else 'OFF'}\n"
        )
        self._send_text(HTTPStatus.OK, body)
        _log("GET", "/", 200)

    def _handle_pricing(self, sku: str, query: Dict[str, str]) -> None:
        # Latency spike chaos (5%): adds +200ms before any response.
        if CHAOS_ENABLED and RNG.random() < 0.05:
            time.sleep(0.2)
            spike_note = "CHAOS: +200ms latency"
        else:
            spike_note = ""

        # Random 503 chaos (10%).
        if CHAOS_ENABLED and RNG.random() < 0.10:
            self._send_json(
                HTTPStatus.SERVICE_UNAVAILABLE,
                {"error": "backend_unavailable", "message": "transient — please retry"},
                extra_headers={"Retry-After": "1"},
            )
            note = "CHAOS: 503"
            if spike_note:
                note = f"{spike_note} + {note}"
            _log("GET", f"/pricing/{sku}", 503, note)
            return

        region = query.get("region", "")
        if not region:
            self._send_json(
                HTTPStatus.BAD_REQUEST,
                {"error": "missing_region", "message": "query param 'region' is required"},
            )
            _log("GET", f"/pricing/{sku}", 400, "missing region")
            return

        if not SKU_PATTERN.match(sku):
            self._send_json(
                HTTPStatus.NOT_FOUND,
                {"error": "sku_not_found", "sku": sku, "message": f"no pricing record for SKU {sku!r}"},
            )
            note = "unknown SKU"
            if spike_note:
                note = f"{spike_note} + {note}"
            _log("GET", f"/pricing/{sku}", 404, note)
            return

        price = _price_for(sku, region)
        body = {
            "sku": sku,
            "region": region,
            "price_usd": price,
            "currency": "USD",
            "computed_at": _now_iso(),
            "cache_ttl_seconds": 60,
        }
        self._send_json(HTTPStatus.OK, body)
        note = f"{sku}@{region}=${price:.2f}"
        if spike_note:
            note = f"{spike_note}  {note}"
        _log("GET", f"/pricing/{sku}", 200, note)

    def _handle_admin_metrics(self, query: Dict[str, str]) -> None:
        name_filter = query.get("name")
        limit = int(query.get("limit", "1000"))
        with _METRICS_LOCK:
            records = list(_METRICS)
        if name_filter:
            records = [r for r in records if r["name"] == name_filter]
        records = records[-limit:]
        unique_names = sorted({r["name"] for r in records})
        self._send_json(
            HTTPStatus.OK,
            {
                "count": len(records),
                "unique_names": unique_names,
                "metrics": records,
            },
        )
        _log("GET", "/admin/metrics", 200, f"count={len(records)} names={len(unique_names)}")

    def _handle_toggle_chaos(self) -> None:
        global CHAOS_ENABLED
        body = self._read_body() or {}
        if "enabled" not in body:
            self._send_json(
                HTTPStatus.BAD_REQUEST,
                {"error": "bad_request", "message": "body must include 'enabled': bool"},
            )
            _log("POST", "/__chaos", 400)
            return
        CHAOS_ENABLED = bool(body["enabled"])
        self._send_json(HTTPStatus.OK, {"chaos": CHAOS_ENABLED})
        _log("POST", "/__chaos", 200, f"chaos={CHAOS_ENABLED}")


# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------
def main(argv: Optional[List[str]] = None) -> int:
    global CHAOS_ENABLED, QUIET
    parser = argparse.ArgumentParser(
        description="ACME Pricing Service + DataDog StatsD agent — single-file mock.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Example: python3 mock_infra.py --seed 42",
    )
    parser.add_argument("--host", default="127.0.0.1", help="Bind host (default: 127.0.0.1)")
    parser.add_argument("--http-port", type=int, default=8080, help="Pricing HTTP port (default: 8080)")
    parser.add_argument("--statsd-port", type=int, default=8125, help="StatsD UDP port (default: 8125)")
    parser.add_argument("--no-chaos", action="store_true", help="Disable all chaos modes")
    parser.add_argument("--seed", type=int, default=None, help="Seed the chaos RNG (deterministic)")
    parser.add_argument("--quiet", action="store_true", help="Suppress per-request log lines")
    args = parser.parse_args(argv)

    CHAOS_ENABLED = not args.no_chaos
    QUIET = args.quiet
    if args.seed is not None:
        RNG.seed(args.seed)

    # Boot the StatsD UDP listener first so the HTTP server can report it ready.
    statsd_ready = threading.Event()
    statsd_thread = threading.Thread(
        target=_statsd_loop,
        args=(args.host, args.statsd_port, statsd_ready),
        name="statsd-listener",
        daemon=True,
    )
    statsd_thread.start()
    statsd_ready.wait(timeout=2.0)

    server = ThreadingHTTPServer((args.host, args.http_port), PricingHandler)
    chaos_label = "ON" if CHAOS_ENABLED else "OFF"
    seed_label = f"seed={args.seed}" if args.seed is not None else "seed=random"
    banner = (
        "==========================================================\n"
        " ACME Pricing Service + DataDog StatsD agent (mock)\n"
        f" pricing HTTP : http://{args.host}:{args.http_port}\n"
        f" datadog UDP  : udp://{args.host}:{args.statsd_port}  (StatsD)\n"
        f" chaos        : {chaos_label}    {seed_label}\n"
        "----------------------------------------------------------\n"
        " endpoints:\n"
        "   GET  /healthz\n"
        "   GET  /pricing/{sku}?region={region}\n"
        "   GET  /admin/metrics      (captured StatsD packets, JSON)\n"
        "   POST /__chaos            {\"enabled\": bool}\n"
        "----------------------------------------------------------\n"
        " smoke test:\n"
        f"   curl http://{args.host}:{args.http_port}/healthz\n"
        f"   curl 'http://{args.host}:{args.http_port}/pricing/SKU-1234?region=us-west-2'\n"
        " stop:\n"
        "   Ctrl-C\n"
        "==========================================================\n"
    )
    print(banner, flush=True)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[mock_infra] shutting down (Ctrl-C)", flush=True)
        server.server_close()
        return 0


if __name__ == "__main__":
    sys.exit(main())