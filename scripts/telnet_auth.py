#!/usr/bin/env python3
"""
Check whether the camera's telnet service (port 23) accepts shell access.

This is a legitimate device-ownership check: the goal is to reach the camera's
own configuration so we can find the real streaming settings.

Credentials are read from the environment - never hardcoded here:
    export CAM_PASS='your-password'
    python3 telnet_auth.py [host] [user]

Default password list is the small set of factory defaults published for the
XM / XiongMai IP-camera SDK that this firmware appears to be built on.
"""
import os
import socket
import sys
import time

HOST = sys.argv[1] if len(sys.argv) > 1 else "192.168.1.46"
PORT = 23
USERS = ["root", "admin"]

# Factory defaults known for the XM/XiongMai SDK family.
# Your own camera password (if set) is tried first from $CAM_PASS.
DEFAULTS = ["", "xmhdipc", "xc3511", "vizxv", "juantech", "xmuser",
             "hi3518", "12345", "123456", "54321", "888888", "7ujMko0admin"]


def strip_iac(data: bytes) -> str:
    """Remove telnet IAC (0xFF) option negotiations from the stream."""
    out = bytearray()
    i = 0
    while i < len(data):
        if data[i] == 0xFF:
            i += 3
            continue
        out.append(data[i])
        i += 1
    return out.decode("utf8", "replace")


def read_until(sock: socket.socket, seconds: float = 3.0) -> str:
    sock.settimeout(seconds)
    buf = b""
    end = time.time() + seconds
    while time.time() < end:
        try:
            chunk = sock.recv(4096)
        except socket.timeout:
            break
        if not chunk:
            break
        buf += chunk
    return strip_iac(buf)


def try_login(user: str, password: str):
    """Return (ok, transcript) for one credential attempt."""
    transcript = []
    try:
        s = socket.create_connection((HOST, PORT), timeout=5)
    except OSError as exc:
        return False, [f"connect failed: {exc}"]

    try:
        transcript.append(read_until(s, 2.0))          # banner / login prompt
        s.sendall(user.encode() + b"\r\n")
        transcript.append(read_until(s, 2.0))           # Password: prompt
        s.sendall(password.encode() + b"\r\n")
        resp = read_until(s, 3.5)                       # shell prompt or failure
        transcript.append(resp)

        low = resp.lower()
        failure = any(k in low for k in
                      ("login incorrect", "incorrect", "denied",
                       "authentication fail", "closed", "bad password"))
        # A successful busybox login greets with a shell prompt and/or MOTD.
        success = (not failure) and any(k in resp for k in ("#", "~", "$", "BusyBox"))
        return success, transcript
    finally:
        s.close()


def main() -> int:
    own = os.environ.get("CAM_PASS")
    passwords = ([own] if own else []) + DEFAULTS

    print(f"Target: {HOST}:{PORT}")
    print(f"Trying {len(USERS)} users x {len(passwords)} passwords\n")

    for user in USERS:
        for pw in passwords:
            label = pw if pw else "(empty)"
            ok, transcript = try_login(user, pw)
            status = "SUCCESS" if ok else "no"
            print(f"  [{status:>7}] {user}:{label}")
            if ok:
                print("\n--- transcript ---")
                for line in transcript:
                    print(line.replace("\r\n", "\n").strip())
                print("--- end ---\n")
                print(f"Shell access via telnet with {user}:{label}")
                return 0

    print("\nNo shell access with the tested credentials.")
    return 1


if __name__ == "__main__":
    sys.exit(main())