#!/usr/bin/env python3
"""
NexusPacket Proxy — original WebSocket <-> TCP relay.

Purpose: accept WebSocket connections and relay raw bytes bidirectionally
to a local TCP target (e.g. sshd on 127.0.0.1:22). This lets a client tunnel
TCP traffic (SSH, etc.) inside a WebSocket connection, which is useful when
a network only allows outbound HTTP(S)/WS traffic.

This is an original implementation using only the Python standard library
(asyncio) plus a minimal hand-rolled WebSocket frame handler — no
third-party proxy binaries, no copied code.

Usage:
    python3 nexuspacket_proxy.py --listen-port 8080 --target-host 127.0.0.1 --target-port 22

Protocol notes:
    - Implements just enough of RFC 6455 to accept a WS upgrade and relay
      binary frames both ways (client -> target, target -> client).
    - Not meant to be a general-purpose WS library; it is intentionally
      small and auditable.
"""

import argparse
import asyncio
import base64
import hashlib
import logging
import struct

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
LOG = logging.getLogger("nexuspacket_proxy")


def compute_accept_key(client_key: str) -> str:
    sha1 = hashlib.sha1((client_key + WS_GUID).encode()).digest()
    return base64.b64encode(sha1).decode()


async def read_http_headers(reader: asyncio.StreamReader) -> dict:
    headers = {}
    request_line = await reader.readline()
    if not request_line:
        return {}
    while True:
        line = await reader.readline()
        if line in (b"\r\n", b""):
            break
        if b":" in line:
            k, v = line.decode(errors="ignore").split(":", 1)
            headers[k.strip().lower()] = v.strip()
    headers["_request_line"] = request_line.decode(errors="ignore").strip()
    return headers


async def ws_handshake(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> bool:
    headers = await read_http_headers(reader)
    if not headers or "sec-websocket-key" not in headers:
        writer.write(b"HTTP/1.1 400 Bad Request\r\n\r\n")
        await writer.drain()
        return False
    accept_key = compute_accept_key(headers["sec-websocket-key"])
    response = (
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Accept: {accept_key}\r\n"
        "\r\n"
    )
    writer.write(response.encode())
    await writer.drain()
    return True


def encode_ws_frame(payload: bytes, opcode: int = 0x2) -> bytes:
    """Server -> client frames are sent unmasked (per RFC 6455)."""
    length = len(payload)
    header = bytes([0x80 | opcode])
    if length < 126:
        header += bytes([length])
    elif length < 65536:
        header += bytes([126]) + struct.pack(">H", length)
    else:
        header += bytes([127]) + struct.pack(">Q", length)
    return header + payload


async def read_ws_frame(reader: asyncio.StreamReader):
    first2 = await reader.readexactly(2)
    b1, b2 = first2[0], first2[1]
    opcode = b1 & 0x0F
    fin = (b1 & 0x80) != 0
    masked = (b2 & 0x80) != 0
    length = b2 & 0x7F

    if length == 126:
        length = struct.unpack(">H", await reader.readexactly(2))[0]
    elif length == 127:
        length = struct.unpack(">Q", await reader.readexactly(8))[0]

    mask_key = await reader.readexactly(4) if masked else None
    payload = await reader.readexactly(length) if length else b""

    if masked and mask_key:
        payload = bytes(b ^ mask_key[i % 4] for i, b in enumerate(payload))

    return opcode, payload, fin


async def relay_target_to_ws(target_reader: asyncio.StreamReader, ws_writer: asyncio.StreamWriter):
    try:
        while True:
            data = await target_reader.read(4096)
            if not data:
                break
            ws_writer.write(encode_ws_frame(data))
            await ws_writer.drain()
    except (asyncio.IncompleteReadError, ConnectionResetError):
        pass


async def relay_ws_to_target(ws_reader: asyncio.StreamReader, target_writer: asyncio.StreamWriter):
    try:
        while True:
            opcode, payload, _fin = await read_ws_frame(ws_reader)
            if opcode == 0x8:  # close
                break
            if opcode in (0x1, 0x2) and payload:  # text or binary
                target_writer.write(payload)
                await target_writer.drain()
            elif opcode == 0x9:  # ping -> ignore (could pong)
                continue
    except (asyncio.IncompleteReadError, ConnectionResetError):
        pass


async def handle_client(reader, writer, target_host: str, target_port: int):
    peer = writer.get_extra_info("peername")
    LOG.info("connection from %s", peer)

    ok = await ws_handshake(reader, writer)
    if not ok:
        writer.close()
        return

    try:
        target_reader, target_writer = await asyncio.open_connection(target_host, target_port)
    except OSError as e:
        LOG.warning("failed to connect to target %s:%s (%s)", target_host, target_port, e)
        writer.close()
        return

    task1 = asyncio.create_task(relay_ws_to_target(reader, target_writer))
    task2 = asyncio.create_task(relay_target_to_ws(target_reader, writer))

    done, pending = await asyncio.wait({task1, task2}, return_when=asyncio.FIRST_COMPLETED)
    for t in pending:
        t.cancel()

    for w in (writer, target_writer):
        try:
            w.close()
        except Exception:
            pass

    LOG.info("connection closed %s", peer)


async def main():
    parser = argparse.ArgumentParser(description="NexusPacket Proxy — WebSocket to TCP relay")
    parser.add_argument("--listen-host", default="0.0.0.0")
    parser.add_argument("--listen-port", type=int, default=8080)
    parser.add_argument("--target-host", default="127.0.0.1")
    parser.add_argument("--target-port", type=int, default=22)
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.INFO if args.verbose else logging.WARNING,
        format="%(asctime)s [NexusPacket Proxy] %(message)s",
    )

    server = await asyncio.start_server(
        lambda r, w: handle_client(r, w, args.target_host, args.target_port),
        args.listen_host,
        args.listen_port,
    )
    print(f"NexusPacket Proxy listening on {args.listen_host}:{args.listen_port} "
          f"-> forwarding to {args.target_host}:{args.target_port}")
    print("Channel: https://t.me/NexusPacket_Official")

    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
