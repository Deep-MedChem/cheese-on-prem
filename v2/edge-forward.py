"""Loopback edge for the offline CHEESE V2 stack.

backend and ui sit on an `internal: true` Docker network, which has no route
out of the host -- and, for the same reason, Docker cannot publish their ports.
This forwarder is the only container on both that network and a host-only
bridge, so the host reaches the stack through it and nothing else does.
Standard library only: it runs inside the backend image, no extra image ships.

Usage: python -I edge-forward.py LISTEN_PORT=HOST:PORT [...]
"""

import asyncio
import signal
import sys

BUFFER = 64 * 1024


async def _pipe(reader, writer):
    try:
        while data := await reader.read(BUFFER):
            writer.write(data)
            await writer.drain()
    except (ConnectionError, asyncio.CancelledError):
        pass
    finally:
        if writer.can_write_eof():
            try:
                writer.write_eof()
            except OSError:
                pass


async def _handle(client_reader, client_writer, host, port):
    try:
        # Resolved per connection: Docker DNS answers once the target is up,
        # so the edge can start before backend/ui and needs no restart.
        upstream_reader, upstream_writer = await asyncio.wait_for(
            asyncio.open_connection(host, port), timeout=10
        )
    except (OSError, asyncio.TimeoutError):
        client_writer.close()
        return
    await asyncio.gather(
        _pipe(client_reader, upstream_writer), _pipe(upstream_reader, client_writer)
    )
    for writer in (client_writer, upstream_writer):
        writer.close()


def _parse(spec):
    listen, _, target = spec.partition("=")
    host, _, port = target.rpartition(":")
    if not listen.isdigit() or not host or not port.isdigit():
        raise SystemExit(f"bad mapping {spec!r}; expected LISTEN_PORT=HOST:PORT")
    return int(listen), host, int(port)


async def main(specs):
    servers = []
    for listen, host, port in map(_parse, specs):
        server = await asyncio.start_server(
            lambda r, w, h=host, p=port: _handle(r, w, h, p), "0.0.0.0", listen
        )
        servers.append(server)
        print(f"edge: 0.0.0.0:{listen} -> {host}:{port}", flush=True)
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop.set)
    await stop.wait()
    for server in servers:
        server.close()


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    asyncio.run(main(sys.argv[1:]))
