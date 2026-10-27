#!/usr/bin/env python3
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
"""HTTP CONNECT proxy that misbehaves like a corporate proxy / firewall / LB.

Used to reproduce the "Storage API Error ... Stream removed" / "RST_STREAM"
failures (b/499198162, b/327025976) with the BigQuery ODBC driver.

The driver is pointed at this proxy with its ``ProxyHost`` / ``ProxyPort`` DSN
keys. Every HTTPS (REST) and gRPC (Storage Read API) connection of the driver
is then tunnelled through ``HTTP CONNECT`` and the proxy relays the encrypted
bytes verbatim - no TLS interception, no certificates to install. Tunnels whose
target matches ``--target-filter`` are killed when they carry no bytes for
``--idle-timeout`` seconds, or after ``--kill-after-bytes`` bytes were relayed
to the client.

Kill modes (what the client observes):

  close        FIN in both directions. Graceful close, e.g. Squid / Zscaler.
  reset        TCP RST in both directions. Most load balancers / firewalls.
  blackhole    Stop relaying and keep the client socket open forever. The
               client is never told; it only notices through its own timeouts
               (stateful firewall / NAT table expiry).
  stale-reset  Like blackhole, but the next bytes sent by the client are
               answered with a TCP RST (firewall that rejects packets that
               belong to an unknown flow).

Python 3.8+, standard library only. Runs on Windows, Linux and macOS.

Examples:

  python3 idle_connect_proxy.py --port 8888 --idle-timeout 10 --mode reset
  python3 idle_connect_proxy.py --port 8888 --mode stale-reset
  python3 idle_connect_proxy.py --port 8888 --idle-timeout 0 \
      --kill-after-bytes 20000000 --mode reset
"""

import argparse
import asyncio
import logging
import socket
import struct
import sys
import time

LOG = logging.getLogger("idle-proxy")

ARGS = None  # populated by main()
TUNNELS = set()
STATS = {"tunnels": 0, "kills": 0}

READ_CHUNK = 64 * 1024


class Tunnel:
    """One CONNECT tunnel: client <-> proxy <-> target."""

    _next_id = 0

    def __init__(self, target, peer):
        Tunnel._next_id += 1
        self.id = Tunnel._next_id
        self.target = target
        self.peer = peer
        self.opened = time.monotonic()
        self.last_activity = self.opened
        self.up_bytes = 0  # client -> target
        self.down_bytes = 0  # target -> client
        # open | killed | blackholed | stale
        self.state = "open"
        self.kill_reason = None
        self.monitored = True
        self.client_writer = None
        self.server_writer = None

    def __str__(self):
        return "#%d %s" % (self.id, self.target)

    def age(self):
        return time.monotonic() - self.opened

    def idle(self):
        return time.monotonic() - self.last_activity


def reset_writer(writer):
    """Closes a StreamWriter with a TCP RST instead of a FIN."""
    if writer is None:
        return
    try:
        sock = writer.get_extra_info("socket")
        if sock is not None:
            # struct linger is {u_short, u_short} on Windows, {int, int}
            # elsewhere. l_onoff=1 + l_linger=0 turns close() into a RST.
            fmt = "hh" if sys.platform == "win32" else "ii"
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER,
                            struct.pack(fmt, 1, 0))
    except OSError as e:  # pragma: no cover - best effort
        LOG.debug("SO_LINGER failed: %s", e)
    writer.transport.abort()


def close_writer(writer):
    """Closes a StreamWriter gracefully (FIN)."""
    if writer is None:
        return
    try:
        writer.close()
    except Exception:  # pragma: no cover - best effort
        pass


def kill(tunnel, reason):
    """Applies the configured kill mode to an open tunnel."""
    if tunnel.state != "open":
        return
    tunnel.kill_reason = reason
    STATS["kills"] += 1
    LOG.warning("%s KILL mode=%s: %s | age=%.1fs idle=%.1fs up=%dB down=%dB",
                tunnel, ARGS.mode, reason, tunnel.age(), tunnel.idle(),
                tunnel.up_bytes, tunnel.down_bytes)
    if ARGS.mode == "close":
        tunnel.state = "killed"
        close_writer(tunnel.client_writer)
        close_writer(tunnel.server_writer)
    elif ARGS.mode == "reset":
        tunnel.state = "killed"
        reset_writer(tunnel.client_writer)
        reset_writer(tunnel.server_writer)
    elif ARGS.mode == "blackhole":
        # Drop the server side quietly; the client never hears about it.
        tunnel.state = "blackholed"
        reset_writer(tunnel.server_writer)
    elif ARGS.mode == "stale-reset":
        tunnel.state = "stale"
        reset_writer(tunnel.server_writer)
    else:  # pragma: no cover - argparse validates the value
        raise ValueError("unknown mode %r" % ARGS.mode)


async def relay(reader, writer, tunnel, direction):
    """Copies bytes in one direction. direction is 'up' or 'down'."""
    try:
        while True:
            data = await reader.read(READ_CHUNK)
            if not data:
                return "eof"
            if tunnel.state in ("blackholed", "stale"):
                if direction == "up" and tunnel.state == "stale":
                    LOG.warning(
                        "%s client sent %d bytes on a stale tunnel -> TCP RST",
                        tunnel, len(data))
                    tunnel.state = "killed"
                    reset_writer(tunnel.client_writer)
                    return "stale-reset"
                LOG.debug("%s swallowing %d bytes (%s)", tunnel, len(data),
                          tunnel.state)
                continue
            writer.write(data)
            await writer.drain()
            tunnel.last_activity = time.monotonic()
            if direction == "up":
                tunnel.up_bytes += len(data)
            else:
                tunnel.down_bytes += len(data)
                if (ARGS.kill_after_bytes > 0 and tunnel.monitored
                        and tunnel.state == "open"
                        and tunnel.down_bytes >= ARGS.kill_after_bytes):
                    kill(tunnel, "%d bytes relayed to the client "
                         ">= --kill-after-bytes %d" %
                         (tunnel.down_bytes, ARGS.kill_after_bytes))
                    return "killed"
    except asyncio.CancelledError:
        raise
    except (ConnectionError, OSError, asyncio.IncompleteReadError) as e:
        return "error: %s" % e


async def handle_client(client_reader, client_writer):
    peer = client_writer.get_extra_info("peername") or ("?", 0)
    try:
        head = await asyncio.wait_for(client_reader.readuntil(b"\r\n\r\n"),
                                      timeout=ARGS.connect_timeout)
    except (asyncio.IncompleteReadError, asyncio.LimitOverrunError,
            asyncio.TimeoutError, ConnectionError, OSError):
        close_writer(client_writer)
        return

    request_line = head.split(b"\r\n", 1)[0].decode("latin-1", "replace")
    parts = request_line.split()
    if len(parts) < 2 or parts[0].upper() != "CONNECT":
        LOG.warning("rejecting non-CONNECT request from %s:%s: %r", peer[0],
                    peer[1], request_line)
        client_writer.write(b"HTTP/1.1 405 Method Not Allowed\r\n"
                            b"Connection: close\r\n\r\n")
        try:
            await client_writer.drain()
        except (ConnectionError, OSError):
            pass
        close_writer(client_writer)
        return

    target = parts[1]
    host, _, port = target.rpartition(":")
    host = host.strip("[]")  # IPv6 literal
    port = int(port) if port.isdigit() else 443

    tunnel = Tunnel(target, peer)
    tunnel.monitored = (not ARGS.target_filter) or (ARGS.target_filter
                                                    in target)
    try:
        server_reader, server_writer = await asyncio.wait_for(
            asyncio.open_connection(host, port),
            timeout=ARGS.connect_timeout)
    except (OSError, asyncio.TimeoutError) as e:
        LOG.error("%s upstream connect failed: %s", tunnel, e)
        client_writer.write(b"HTTP/1.1 502 Bad Gateway\r\n"
                            b"Connection: close\r\n\r\n")
        try:
            await client_writer.drain()
        except (ConnectionError, OSError):
            pass
        close_writer(client_writer)
        return

    tunnel.client_writer = client_writer
    tunnel.server_writer = server_writer
    client_writer.write(b"HTTP/1.1 200 Connection established\r\n\r\n")
    try:
        await client_writer.drain()
    except (ConnectionError, OSError):
        close_writer(client_writer)
        close_writer(server_writer)
        return

    TUNNELS.add(tunnel)
    STATS["tunnels"] += 1
    LOG.info("%s OPEN from %s:%s%s", tunnel, peer[0], peer[1],
             "" if tunnel.monitored else " (not monitored)")

    up = asyncio.ensure_future(relay(client_reader, server_writer, tunnel,
                                     "up"))
    down = asyncio.ensure_future(relay(server_reader, client_writer, tunnel,
                                       "down"))
    try:
        done, _ = await asyncio.wait({up, down},
                                     return_when=asyncio.FIRST_COMPLETED)
        if tunnel.state in ("blackholed", "stale") and up not in done:
            # The server side was dropped on purpose. Keep the client hanging
            # until it gives up by itself (or, in stale mode, sends data).
            await up
        for task in (up, down):
            if not task.done():
                task.cancel()
        await asyncio.gather(up, down, return_exceptions=True)
    finally:
        TUNNELS.discard(tunnel)
        close_writer(client_writer)
        close_writer(server_writer)
        how = ("killed by proxy (%s)" % tunnel.kill_reason
               if tunnel.kill_reason else "closed by a peer")
        LOG.info("%s CLOSED after %.1fs up=%dB down=%dB - %s", tunnel,
                 tunnel.age(), tunnel.up_bytes, tunnel.down_bytes, how)


async def watchdog():
    """Kills tunnels that have been idle for longer than --idle-timeout."""
    while True:
        await asyncio.sleep(0.25)
        if ARGS.idle_timeout <= 0:
            continue
        for tunnel in list(TUNNELS):
            if tunnel.state != "open" or not tunnel.monitored:
                continue
            idle = tunnel.idle()
            if idle >= ARGS.idle_timeout:
                kill(tunnel, "idle for %.1fs >= --idle-timeout %.0fs" %
                     (idle, ARGS.idle_timeout))


async def status_reporter():
    """Prints a heartbeat so that silent stalls are visible in the log."""
    while True:
        await asyncio.sleep(ARGS.status_interval)
        open_tunnels = [t for t in TUNNELS if t.state == "open"]
        LOG.info("status: %d open tunnel(s), %d opened in total, %d killed%s",
                 len(open_tunnels), STATS["tunnels"], STATS["kills"],
                 "".join("\n    %s idle=%.1fs up=%dB down=%dB" %
                         (t, t.idle(), t.up_bytes, t.down_bytes)
                         for t in open_tunnels))


def parse_args(argv):
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="127.0.0.1",
                        help="address to listen on (default: 127.0.0.1)")
    parser.add_argument("--port", type=int, default=8888,
                        help="port to listen on (default: 8888)")
    parser.add_argument("--idle-timeout", type=float, default=10.0,
                        help="kill monitored tunnels after this many seconds "
                        "without traffic in either direction; 0 disables "
                        "(default: 10)")
    parser.add_argument("--kill-after-bytes", type=int, default=0,
                        help="kill monitored tunnels once this many bytes "
                        "were relayed to the client; 0 disables (default: 0)")
    parser.add_argument("--mode", default="reset",
                        choices=["close", "reset", "blackhole", "stale-reset"],
                        help="how to kill a tunnel (default: reset)")
    parser.add_argument("--target-filter", default="bigquerystorage",
                        help="only tunnels whose CONNECT target contains this "
                        "string are killed; '' matches every tunnel "
                        "(default: bigquerystorage)")
    parser.add_argument("--connect-timeout", type=float, default=10.0,
                        help="upstream connect timeout in seconds "
                        "(default: 10)")
    parser.add_argument("--status-interval", type=float, default=30.0,
                        help="seconds between heartbeat log lines; 0 disables "
                        "(default: 30)")
    parser.add_argument("-v", "--verbose", action="store_true",
                        help="debug logging")
    return parser.parse_args(argv)


async def serve():
    server = await asyncio.start_server(handle_client, ARGS.host, ARGS.port,
                                        limit=READ_CHUNK)
    asyncio.ensure_future(watchdog())
    if ARGS.status_interval > 0:
        asyncio.ensure_future(status_reporter())
    LOG.info("listening on %s:%d  mode=%s idle-timeout=%ss "
             "kill-after-bytes=%d target-filter=%r", ARGS.host, ARGS.port,
             ARGS.mode, ARGS.idle_timeout, ARGS.kill_after_bytes,
             ARGS.target_filter)
    LOG.info("point the ODBC driver at it with:  ProxyHost=%s;ProxyPort=%d",
             ARGS.host, ARGS.port)
    async with server:
        await server.serve_forever()


def main(argv=None):
    global ARGS
    ARGS = parse_args(sys.argv[1:] if argv is None else argv)
    logging.basicConfig(
        level=logging.DEBUG if ARGS.verbose else logging.INFO,
        format="%(asctime)s.%(msecs)03d %(levelname)-7s %(message)s",
        datefmt="%H:%M:%S")
    try:
        asyncio.run(serve())
    except KeyboardInterrupt:
        LOG.info("bye: %d tunnel(s) opened, %d killed", STATS["tunnels"],
                 STATS["kills"])


if __name__ == "__main__":
    main()
