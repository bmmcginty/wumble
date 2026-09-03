#!/usr/bin/env python3
"""End-to-end test of Wumble's WebRTC signalling.

`crystal spec` covers the pieces in isolation, which is not enough: the gateway
once shipped with every unit spec passing and no speaker ever receiving an
audio section, because the bug was in how the publishing fiber was spawned.
Nothing below reaches into the gateway -- it is driven entirely through a stub
Mumble server and a WebSocket client, the two interfaces it actually has.

Run it with `python3 spec/integration/signalling_test.py`; pass `--binary` to
test an already-built gateway instead of building one.
"""

import argparse
import base64
import json
import os
import re
import shutil
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import threading
import time

VERSION, AUTHENTICATE, SERVER_SYNC, USER_REMOVE, USER_STATE = 0, 2, 5, 8, 9
FINGERPRINT = ("8F:1A:2B:3C:4D:5E:6F:70:81:92:A3:B4:C5:D6:E7:F8:"
               "09:1A:2B:3C:4D:5E:6F:70:81:92:A3:B4:C5:D6:E7:F8")


def varint(value):
    out = b""
    while True:
        byte = value & 0x7F
        value >>= 7
        out += bytes([byte | (0x80 if value else 0)])
        if not value:
            return out


def field_varint(number, value):
    return bytes([number << 3]) + varint(value)


def field_string(number, value):
    encoded = value.encode()
    return bytes([number << 3 | 2]) + varint(len(encoded)) + encoded


def packet(kind, payload):
    return struct.pack(">HI", kind, len(payload)) + payload


class MurmurStub:
    """Just enough Murmur to get the gateway synchronized and hand it a roster."""

    def __init__(self, certificate, key):
        self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.context.load_cert_chain(certificate, key)
        self.listener = socket.socket()
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(1)
        self.port = self.listener.getsockname()[1]
        self.connection = None
        self.synchronized = threading.Event()

    def start(self):
        threading.Thread(target=self._serve, daemon=True).start()

    def _serve(self):
        raw, _ = self.listener.accept()
        self.connection = self.context.wrap_socket(raw, server_side=True)
        while True:
            header = self._read_exactly(6)
            if not header:
                return
            kind, length = struct.unpack(">HI", header)
            self._read_exactly(length)
            # The gateway authenticates immediately after its Version, so this
            # is the point at which a real server would sync it.
            if kind == AUTHENTICATE:
                self.send(VERSION, field_varint(1, 0x010500) + field_string(2, "stub"))
                self.user_state(161, "tsp")
                self.user_state(165, "bmc-wumble")
                self.send(SERVER_SYNC, field_varint(1, 165))
                self.synchronized.set()

    def _read_exactly(self, count):
        buffer = b""
        while len(buffer) < count:
            try:
                chunk = self.connection.recv(count - len(buffer))
            except OSError:
                return None
            if not chunk:
                return None
            buffer += chunk
        return buffer

    def send(self, kind, payload):
        self.connection.sendall(packet(kind, payload))

    def user_state(self, session, name):
        self.send(USER_STATE, field_varint(1, session) + field_string(3, name))

    def user_remove(self, session):
        self.send(USER_REMOVE, field_varint(1, session))


class Signalling:
    """The browser's half: a WebSocket over the gateway's Unix socket."""

    def __init__(self, path):
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.connect(path)
        key = base64.b64encode(os.urandom(16)).decode()
        self.socket.sendall(
            f"GET /ws HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
            f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
            f"Sec-WebSocket-Version: 13\r\n\r\n".encode())
        time.sleep(0.3)
        if b"101" not in self.socket.recv(4096):
            raise RuntimeError("gateway refused the WebSocket upgrade")
        self.buffer = b""
        self.received = []
        threading.Thread(target=self._read, daemon=True).start()

    def send(self, message):
        payload = json.dumps(message).encode()
        mask = os.urandom(4)
        length = len(payload)
        if length < 126:
            header = bytes([0x81, 0x80 | length])
        elif length < 65536:
            header = bytes([0x81, 0x80 | 126]) + length.to_bytes(2, "big")
        else:
            header = bytes([0x81, 0x80 | 127]) + length.to_bytes(8, "big")
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.socket.sendall(header + mask + masked)

    def _read(self):
        while True:
            try:
                chunk = self.socket.recv(65536)
            except OSError:
                return
            if not chunk:
                return
            self.buffer += chunk
            while len(self.buffer) >= 2:
                length = self.buffer[1] & 0x7F
                offset = 2
                if length == 126:
                    if len(self.buffer) < 4:
                        break
                    length = int.from_bytes(self.buffer[2:4], "big")
                    offset = 4
                elif length == 127:
                    if len(self.buffer) < 10:
                        break
                    length = int.from_bytes(self.buffer[2:10], "big")
                    offset = 10
                if len(self.buffer) < offset + length:
                    break
                frame = self.buffer[offset:offset + length]
                self.buffer = self.buffer[offset + length:]
                message = json.loads(frame.decode("utf-8", "replace"))
                self.received.append(message)
                # Answer every offer, as the browser does. Nothing here needs a
                # media path, only a description the gateway will accept.
                if message.get("type") == "offer":
                    self.send({"type": "answer", "sdp": answer_for(message["sdp"])})

    def wait_for(self, kind, after=0, timeout=10):
        deadline = time.time() + timeout
        while time.time() < deadline:
            for index in range(after, len(self.received)):
                if self.received[index].get("type") == kind:
                    return index, self.received[index]
            for message in self.received:
                if message.get("type") == "error":
                    raise AssertionError(f"gateway reported an error: {message}")
            time.sleep(0.05)
        kinds = [message.get("type") for message in self.received[after:]]
        raise AssertionError(f"timed out waiting for {kind!r}; saw {kinds}")

    def kinds_between(self, start, end):
        return [message.get("type") for message in self.received[start:end]]


def answer_for(offer):
    mids = re.findall(r"^a=mid:(\S+)", offer, re.M)
    lines = ["v=0", "o=- 1 2 IN IP4 127.0.0.1", "s=-", "t=0 0",
             "a=group:BUNDLE " + " ".join(mids), "a=msid-semantic: WMS *"]
    for mid in mids:
        # The gateway offers the microphone recvonly and speakers sendonly, so
        # the browser sends on mid 0 and receives on every other section.
        sending = mid == "0"
        lines += ["m=audio 9 UDP/TLS/RTP/SAVPF 111", "c=IN IP4 0.0.0.0",
                  "a=rtcp:9 IN IP4 0.0.0.0", "a=ice-ufrag:abcd",
                  "a=ice-pwd:0123456789abcdef0123456789ab", "a=ice-options:trickle",
                  f"a=fingerprint:sha-256 {FINGERPRINT}", "a=setup:active",
                  f"a=mid:{mid}", "a=extmap:1 urn:ietf:params:rtp-hdrext:sdes:mid",
                  "a=sendonly" if sending else "a=recvonly", "a=rtcp-mux",
                  "a=rtpmap:111 opus/48000/2", "a=fmtp:111 minptime=10;useinbandfec=1"]
        if sending:
            lines.append("a=ssrc:5000 cname:browser")
    return "\r\n".join(lines) + "\r\n"


def mids_of(offer):
    return re.findall(r"^a=mid:(\S+)", offer["sdp"], re.M)


def named(message):
    return [(entry["mid"], entry["name"], entry["session"]) for entry in message["sections"]]


def run(binary, root):
    certificate = os.path.join(root, "cert.pem")
    key = os.path.join(root, "key.pem")
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-keyout", key,
                    "-out", certificate, "-days", "1", "-nodes", "-subj", "/CN=localhost"],
                   check=True, capture_output=True)

    murmur = MurmurStub(certificate, key)
    murmur.start()

    socket_path = os.path.join(root, "wumble.sock")
    log = open(os.path.join(root, "gateway.log"), "w+")
    group = subprocess.run(["id", "-gn"], capture_output=True, text=True).stdout.strip()
    gateway = subprocess.Popen([binary, "--socket", socket_path, "--group", group],
                               stdout=log, stderr=subprocess.STDOUT)
    try:
        for _ in range(100):
            if os.path.exists(socket_path):
                break
            time.sleep(0.05)
        else:
            raise AssertionError("gateway never created its socket")

        client = Signalling(socket_path)
        client.send({"type": "connect", "options": {
            "server": "127.0.0.1", "port": murmur.port,
            "username": "bmc-wumble", "password": ""}})

        # The microphone is offered on its own, before Mumble has synchronized:
        # the browser has to be audible whether or not anybody else is here.
        index, offer = client.wait_for("offer")
        assert mids_of(offer) == ["0"], mids_of(offer)
        assert offer["sections"] == [], offer["sections"]
        assert "a=recvonly" in offer["sdp"]
        print("ok  microphone offered alone")

        # A speaker already in the channel at ServerSync gets a new section.
        index, offer = client.wait_for("offer", after=index + 1)
        assert mids_of(offer) == ["0", "1"], mids_of(offer)
        assert named(offer) == [("1", "tsp", 161)], named(offer)
        reused_ssrc = offer["sections"][0]["ssrc"]
        print("ok  first speaker gets a section")

        # A second speaker needs a section that has never existed, so this one
        # does have to be a renegotiation.
        murmur.user_state(170, "bmmcginty")
        index, offer = client.wait_for("offer", after=index + 1)
        assert mids_of(offer) == ["0", "1", "2"], mids_of(offer)
        assert named(offer) == [("1", "tsp", 161), ("2", "bmmcginty", 170)], named(offer)
        print("ok  second speaker gets a second section")

        # Leaving frees a section. Nothing in the SDP changes, so the browser
        # is told with a plain signalling message.
        murmur.user_remove(161)
        index, message = client.wait_for("sections", after=index + 1)
        assert named(message) == [("2", "bmmcginty", 170)], named(message)
        print("ok  departure publishes a mapping, not an offer")

        # The point of fixing the SSRC to the section: the same person
        # reconnecting arrives under a new Mumble session and costs no
        # renegotiation at all.
        murmur.user_state(173, "tsp")
        rejoin, message = client.wait_for("sections", after=index + 1)
        assert named(message) == [("1", "tsp", 173), ("2", "bmmcginty", 170)], named(message)
        assert message["sections"][0]["ssrc"] == reused_ssrc, "reused section changed SSRC"
        assert "offer" not in client.kinds_between(index + 1, rejoin + 1), \
            client.kinds_between(index + 1, rejoin + 1)
        print("ok  rejoin reuses the freed section without renegotiating")
    finally:
        gateway.terminate()
        gateway.wait(timeout=5)
        log.seek(0)
        contents = log.read()
        log.close()
        if "skipped publishing" in contents:
            raise AssertionError("the gateway skipped publishing:\n" + contents)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", help="path to an already-built wumble")
    arguments = parser.parse_args()

    if not shutil.which("openssl"):
        print("skip: openssl is required to generate the stub server's certificate")
        return 0

    with tempfile.TemporaryDirectory(prefix="wumble-integration-") as root:
        binary = arguments.binary
        if not binary:
            binary = os.path.join(root, "wumble")
            source = os.path.join(os.path.dirname(__file__), "..", "..", "src", "wumble.cr")
            print("building the gateway...")
            subprocess.run(["crystal", "build", os.path.abspath(source), "-o", binary], check=True)
        try:
            run(binary, root)
        except AssertionError as failure:
            print(f"FAIL: {failure}")
            return 1
    print("\nall signalling checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
