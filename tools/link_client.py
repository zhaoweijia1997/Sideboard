#!/usr/bin/env python3
"""A small stand-in for Sideboard's side of Sideboard Link (android/link), for trying the app
without the Mac app:

    tools/link_client.py HOST[:PORT] info
    tools/link_client.py HOST[:PORT] video SECONDS FILE.h264 [LONGEST_SIDE]
    tools/link_client.py HOST[:PORT] tap X Y            (0…1 across and down the screen)
    tools/link_client.py HOST[:PORT] swipe X1 Y1 X2 Y2
    tools/link_client.py HOST[:PORT] key back|home|recents|notifications
    tools/link_client.py HOST[:PORT] text "some words"

The first connection asks on the device; allow it there. The token made up for that is kept in
~/.sideboard-link-token (override with LINK_TOKEN).
"""
import os
import pathlib
import secrets
import socket
import struct
import sys
import time

PORT = 47600


def token():
    given = os.environ.get("LINK_TOKEN")
    if given:
        return given
    path = pathlib.Path.home() / ".sideboard-link-token"
    if not path.exists():
        path.write_text(secrets.token_hex(16))
        path.chmod(0o600)
    return path.read_text().strip()


def line(sock):
    data = b""
    while not data.endswith(b"\n"):
        got = sock.recv(1)
        if not got:
            break
        data += got
    return data.decode().strip()


def connect(target, wish):
    host, _, port = target.partition(":")
    sock = socket.create_connection((host, int(port or PORT)), timeout=10)
    sock.settimeout(90)
    sock.sendall(f"SIDEBOARD-LINK 1\n{token()}\n{socket.gethostname().split('.')[0]}\n{wish}\n".encode())
    answer = line(sock)
    if answer == "pairing":
        print("Asked on the device; waiting for an answer there…", file=sys.stderr)
        answer = line(sock)
    if answer != "ok":
        sys.exit(f"The device said: {answer or 'nothing'}")
    return sock


def spot(x, y):
    return struct.pack(">HH", round(float(x) * 65535), round(float(y) * 65535))


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    target, what, rest = sys.argv[1], sys.argv[2], sys.argv[3:]
    if what == "info":
        print(line(connect(target, "info")))
    elif what == "video":
        seconds, path = float(rest[0]), rest[1]
        sock = connect(target, f"video {rest[2] if len(rest) > 2 else 1280} 6000000")
        print(line(sock))
        end, size = time.time() + seconds, 0
        sock.settimeout(1)
        with open(path, "wb") as out:
            while time.time() < end:
                try:
                    data = sock.recv(65536)
                except socket.timeout:
                    continue
                if not data:
                    break
                out.write(data)
                size += len(data)
        print(size, "bytes")
    else:
        sock = connect(target, "control")
        print(line(sock))
        if what == "tap":
            sock.sendall(b"\x00" + spot(*rest[:2]))
            time.sleep(0.06)
            sock.sendall(b"\x02" + spot(*rest[:2]))
        elif what == "swipe":
            x1, y1, x2, y2 = map(float, rest[:4])
            sock.sendall(b"\x00" + spot(x1, y1))
            for step in range(1, 21):
                time.sleep(0.02)
                sock.sendall(b"\x01" + spot(x1 + (x2 - x1) * step / 20, y1 + (y2 - y1) * step / 20))
            time.sleep(0.05)
            sock.sendall(b"\x02" + spot(x2, y2))
        elif what == "key":
            sock.sendall(bytes([3, ["back", "home", "recents", "notifications", "quick", "lock"].index(rest[0])]))
        elif what == "text":
            data = rest[0].encode()
            sock.sendall(b"\x04" + struct.pack(">H", len(data)) + data)
        else:
            sys.exit(__doc__)
        time.sleep(0.6)


main()
