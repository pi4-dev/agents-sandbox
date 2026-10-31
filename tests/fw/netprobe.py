#!/usr/bin/env python3
"""Tiny TCP/UDP listener and client for the fw.sh tests.

  netprobe.py listen tcp|udp HOST:PORT [HOST:PORT ...]   answer every peer with "ok"
  netprobe.py connect tcp|udp HOST PORT [--src IP]        exit 0 only if "ok" came back
  netprobe.py spoof SRC DST NAME                          raw UDP DNS query for NAME to DST:53
                                                          with a forged source address SRC
  netprobe.py ping HOST [--src IP]                        exit 0 only if an ICMP echo reply came back
"""
import argparse
import random
import socket
import struct
import sys
import threading

TIMEOUT = 1.5


def split_addr(addr):
    host, _, port = addr.rpartition(":")
    return host.strip("[]"), int(port)


def family(host):
    return socket.AF_INET6 if ":" in host else socket.AF_INET


def listen_tcp(host, port):
    srv = socket.socket(family(host), socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((host, port))
    srv.listen()
    while True:
        conn, _ = srv.accept()
        with conn:
            conn.sendall(b"ok")


def listen_udp(host, port):
    srv = socket.socket(family(host), socket.SOCK_DGRAM)
    srv.bind((host, port))
    while True:
        _, peer = srv.recvfrom(64)
        srv.sendto(b"ok", peer)


def connect(proto, host, port, src):
    kind = socket.SOCK_STREAM if proto == "tcp" else socket.SOCK_DGRAM
    sock = socket.socket(family(host), kind)
    sock.settimeout(TIMEOUT)
    if src:
        sock.bind((src, 0))
    try:
        if proto == "tcp":
            sock.connect((host, port))
        else:
            sock.sendto(b"ping", (host, port))
        return sock.recv(64) == b"ok"
    except OSError:
        return False
    finally:
        sock.close()


def spoof(src, dst, name):
    """Send one DNS query for NAME from a forged source address (needs CAP_NET_RAW)."""
    qname = b"".join(bytes([len(p)]) + p.encode() for p in name.split(".")) + b"\0"
    dns = struct.pack(">HHHHHH", random.getrandbits(16), 0x0100, 1, 0, 0, 0) + qname + struct.pack(">HH", 1, 1)
    udp = struct.pack(">HHHH", random.randint(1024, 65535), 53, 8 + len(dns), 0) + dns
    # version/IHL, TOS, total length (kernel fills), id, flags/fragment, TTL, UDP, checksum (kernel fills)
    ip = struct.pack(">BBHHHBBH4s4s", 0x45, 0, 0, 0, 0, 64, socket.IPPROTO_UDP, 0,
                     socket.inet_aton(src), socket.inet_aton(dst))
    sock = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_RAW)
    try:
        sock.sendto(ip + udp, (dst, 0))
        return True
    except OSError:
        return False
    finally:
        sock.close()


def icmp_checksum(data):
    if len(data) % 2:
        data += b"\0"
    s = sum(struct.unpack(f">{len(data) // 2}H", data))
    s = (s >> 16) + (s & 0xFFFF)
    s += s >> 16
    return ~s & 0xFFFF


def ping(host, src):
    """One ICMP echo request to HOST; True when the matching reply arrives (needs CAP_NET_RAW)."""
    ident, payload = random.getrandbits(16), b"netprobe"
    header = struct.pack(">BBHHH", 8, 0, 0, ident, 1)
    packet = struct.pack(">BBHHH", 8, 0, icmp_checksum(header + payload), ident, 1) + payload
    sock = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_ICMP)
    sock.settimeout(TIMEOUT)
    try:
        if src:
            sock.bind((src, 0))
        sock.sendto(packet, (host, 0))
        while True:
            data, peer = sock.recvfrom(1024)
            icmp = data[(data[0] & 0x0F) * 4:]
            if peer[0] == host and icmp[0] == 0 and struct.unpack(">H", icmp[4:6])[0] == ident:
                return True
    except OSError:
        return False
    finally:
        sock.close()


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)
    lis = sub.add_parser("listen")
    lis.add_argument("proto", choices=["tcp", "udp"])
    lis.add_argument("addrs", nargs="+")
    con = sub.add_parser("connect")
    con.add_argument("proto", choices=["tcp", "udp"])
    con.add_argument("host")
    con.add_argument("port", type=int)
    con.add_argument("--src")
    spf = sub.add_parser("spoof")
    spf.add_argument("src")
    spf.add_argument("dst")
    spf.add_argument("name")
    png = sub.add_parser("ping")
    png.add_argument("host")
    png.add_argument("--src")
    args = parser.parse_args()

    if args.cmd == "ping":
        sys.exit(0 if ping(args.host, args.src) else 1)
    if args.cmd == "spoof":
        sys.exit(0 if spoof(args.src, args.dst, args.name) else 1)
    if args.cmd == "connect":
        sys.exit(0 if connect(args.proto, args.host, args.port, args.src) else 1)

    target = listen_tcp if args.proto == "tcp" else listen_udp
    for addr in args.addrs:
        threading.Thread(target=target, args=split_addr(addr), daemon=True).start()
    threading.Event().wait()


if __name__ == "__main__":
    main()
