#!/usr/bin/env python3
"""Provision the riscv64 guest over its serial console (RUST.md R0).

FreeBSD publishes no CLOUDINIT image for riscv64, so this does what
make-seed.sh's user-data does for the amd64 guests: the build user and its
key, sshd, the base held at the image's snapshot, pkg. It types at the
console socket run.sh opens (ABYSS_DAEMON=1), logs in as root (the VM
images ship with an empty root password) and reads each command's exit
status back from a marker. Run once, after the first boot:

    ABYSS_VM_ROLE=rv64 ABYSS_DAEMON=1 ./run.sh
    ABYSS_VM_ROLE=rv64 ./provision-rv64.sh

Usage: provision-rv64.py SOCK USER HOSTNAME PUBKEY_FILE
"""
import re
import socket
import sys
import time


class Console:
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.connect(path)
        self.s.settimeout(1.0)
        self.buf = b""

    def send(self, text):
        self.s.sendall(text.encode())

    def expect(self, pattern, timeout):
        """Read until the regex matches; return the match, drop what it consumed."""
        rx = re.compile(pattern.encode())
        end = time.monotonic() + timeout
        while True:
            m = rx.search(self.buf)
            if m:
                self.buf = self.buf[m.end():]
                return m
            if time.monotonic() > end:
                tail = self.buf[-800:].decode(errors="replace")
                raise SystemExit(f"[provision] timed out on {pattern!r}:\n{tail}")
            try:
                chunk = self.s.recv(4096)
            except socket.timeout:
                continue
            if not chunk:
                raise SystemExit("[provision] console closed")
            self.buf += chunk

    def sh(self, cmd, timeout=120):
        """Run cmd at the root shell; stop on a non-zero status."""
        n = int(time.monotonic() * 1000)
        # The quotes split the marker in the echoed command line, so only
        # the echo's own output matches.
        self.send(f"{cmd}; echo AB''YSS{n}=$?=\r")
        status = self.expect(rf"ABYSS{n}=(\d+)=", timeout).group(1).decode()
        print(f"[provision] {cmd[:72]} -> {status}", flush=True)
        if status != "0":
            raise SystemExit(f"[provision] failed: {cmd}")


def main():
    sock, user, host, keyfile = sys.argv[1:5]
    pub = open(keyfile).read().strip()
    c = Console(sock)

    c.send("\r")
    c.expect(r"login: ", 600)
    c.send("root\r")
    c.expect(r"# ", 60)

    c.sh(f"sysrc hostname={host} sshd_enable=YES firstboot_pkg_upgrade_enable=NO")
    c.sh(f"hostname {host}")
    # Hold the base at the image's snapshot, as make-seed.sh does.
    c.sh("mkdir -p /usr/local/etc/pkg/repos")
    c.sh("echo 'FreeBSD-base: { enabled: no }' > /usr/local/etc/pkg/repos/FreeBSD.conf")
    c.sh(f"pw usershow {user} >/dev/null 2>&1 || pw useradd {user} -m -G wheel -s /bin/sh -w no")
    # operator: shutdown(8) is setuid for it, so `ssh.sh shutdown -p now`
    # stops the guest with no sudo (there is no pkg to install it from).
    c.sh(f"pw groupmod operator -m {user}")
    c.sh(f"install -d -o {user} -g {user} -m 700 /home/{user}/.ssh")
    c.sh(f"echo '{pub}' > /home/{user}/.ssh/authorized_keys")
    c.sh(f"chown {user}:{user} /home/{user}/.ssh/authorized_keys")
    c.sh(f"chmod 600 /home/{user}/.ssh/authorized_keys")
    # Host keys are generated here, which under TCG takes a while.
    c.sh("service sshd onestatus >/dev/null || service sshd start", 600)
    # FreeBSD builds no ports packages for riscv64 (2026-10-30: only
    # base_* and kmods_* exist on pkg.freebsd.org, for 14, 15 and 16), so
    # pkg cannot even bootstrap from it. Best-effort, recorded, as
    # make-seed.sh records a missing package; RUST.md §5 has the plan.
    c.sh("env ASSUME_ALWAYS_YES=yes pkg bootstrap -f >/dev/null 2>&1"
         f" || echo pkg >> /home/{user}/.pkg-missing", 1200)
    c.sh("if command -v pkg >/dev/null && pkg -N >/dev/null 2>&1; then"
         " pkg install -y sudo rsync && mkdir -p /usr/local/etc/sudoers.d &&"
         f" echo '{user} ALL=(ALL) NOPASSWD: ALL' > /usr/local/etc/sudoers.d/{user};"
         f" else echo 'sudo rsync' >> /home/{user}/.pkg-missing; fi", 1800)
    c.sh(f"touch /home/{user}/.provision-done")
    c.sh(f"chown {user} /home/{user}/.provision-done")
    c.send("exit\r")
    print("[provision] done")


if __name__ == "__main__":
    main()
