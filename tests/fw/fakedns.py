#!/usr/bin/env python3
"""Minimal authoritative UDP DNS server standing in for as-dns in the fw.sh tests.

  fakedns.py LISTEN_IP NAME=IP [NAME=IP ...]

Known names get their A record (other types: NODATA), anything else NXDOMAIN.
Every query is appended to the file in $FAKEDNS_LOG, if set.
"""
import os
import socket
import struct
import sys


def parse_name(msg, pos):
    labels = []
    while msg[pos]:
        labels.append(msg[pos + 1:pos + 1 + msg[pos]].decode())
        pos += msg[pos] + 1
    return ".".join(labels).lower(), pos + 1


def answer(query, records):
    ident, flags = struct.unpack(">HH", query[:4])
    name, end = parse_name(query, 12)
    qtype = struct.unpack(">H", query[end:end + 2])[0]
    question = query[12:end + 4]
    known = name in records
    rcode = 0 if known else 3
    answers = b""
    if known and qtype == 1:
        answers = b"\xc0\x0c" + struct.pack(">HHIH", 1, 1, 30, 4) + socket.inet_aton(records[name])
    header = struct.pack(">HHHHHH", ident, 0x8400 | (flags & 0x0100) | rcode, 1, 1 if answers else 0, 0, 0)
    return name, qtype, header + question + answers


def main():
    listen = sys.argv[1]
    records = dict(arg.lower().split("=", 1) for arg in sys.argv[2:])
    log = os.environ.get("FAKEDNS_LOG")
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((listen, 53))
    while True:
        query, peer = sock.recvfrom(512)
        try:
            name, qtype, reply = answer(query, records)
        except (IndexError, struct.error, UnicodeDecodeError):
            continue
        if log:
            with open(log, "a") as f:
                f.write(f"{peer[0]} {qtype} {name}\n")
        sock.sendto(reply, peer)


if __name__ == "__main__":
    main()
