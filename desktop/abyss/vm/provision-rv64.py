#!/usr/bin/env python3
"""Provision the riscv64 guest over its serial console (RUST.md R0).

FreeBSD publishes no CLOUDINIT image for riscv64, so this does what
make-seed.sh's user-data does for the amd64 guests: the build user and its
key, sshd, the base held at the image's snapshot. It types at the
console socket run.sh opens (ABYSS_DAEMON=1), logs in as root (the VM
images ship with an empty root password) and reads each command's exit
status back from a marker. Run once, after the first boot:

    ABYSS_VM_ROLE=rv64 ABYSS_DAEMON=1 ./run.sh
    ABYSS_VM_ROLE=rv64 ./provision-rv64.sh

FreeBSD builds no packages for riscv64, so pkg comes from ours: phase
`pkg` (provision-rv64.sh runs it once the repository from rv64-sysroot.sh
has been copied to ~/pkgs) installs pkg from it, points pkg at it alone,
and installs what the guest runs.

Usage: provision-rv64.py SOCK USER HOSTNAME PUBKEY_FILE [base|pkg]
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


# What the guest runs: the drawlist spike's libraries and a font (R0),
# and the two tools the scripts lean on.
PACKAGES = "sudo rsync cairo fontconfig freetype2 harfbuzz dejavu"


def login(c):
    """A root shell on the console, whether or not one is already open."""
    c.send("\r")
    if c.expect(r"login: |# ", 600).group(0) == b"login: ":
        c.send("root\r")
        # resizewin(1) asks the terminal its size at login, and eats what is
        # typed while it waits: wait for it to give up.
        c.expect(r"resizewin|# ", 60)
        c.expect(r"# ", 60)


def phase_pkg(c, user):
    repo = f"/home/{user}/pkgs"
    pkg = "env IGNORE_OSVERSION=yes pkg"   # our world is newer than the image's
    c.sh(f"ls {repo}/All/pkg-[0-9]*.pkg >/dev/null")
    c.sh(f"{pkg} add {repo}/All/pkg-[0-9]*.pkg >/dev/null 2>&1 || pkg -N >/dev/null", 1800)
    # pkg 2 names the stock repositories FreeBSD-ports and FreeBSD-ports-kmods.
    c.sh("printf 'FreeBSD: { enabled: no }\\nFreeBSD-ports: { enabled: no }\\n"
         "FreeBSD-ports-kmods: { enabled: no }\\nFreeBSD-base: { enabled: no }\\n'"
         " > /usr/local/etc/pkg/repos/FreeBSD.conf")
    c.sh(f"printf 'abyss: {{ url: \"file://{repo}\", enabled: yes, signature_type: \"none\" }}\\n'"
         " > /usr/local/etc/pkg/repos/abyss.conf")
    c.sh(f"{pkg} update -f >/tmp/pkg-update.log 2>&1", 1800)
    c.sh(f"{pkg} install -y {PACKAGES} >/tmp/pkg-install.log 2>&1", 3600)
    c.sh("mkdir -p /usr/local/etc/sudoers.d")
    c.sh(f"echo '{user} ALL=(ALL) NOPASSWD: ALL' > /usr/local/etc/sudoers.d/{user}")


def main():
    sock, user, host, keyfile = sys.argv[1:5]
    phase = sys.argv[5] if len(sys.argv) > 5 else "base"
    pub = open(keyfile).read().strip()
    c = Console(sock)
    login(c)
    if phase == "pkg":
        phase_pkg(c, user)
        c.send("exit\r")
        print("[provision] pkg done")
        return

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
    # No pkg here: FreeBSD builds no ports packages for riscv64 (2026-10-30:
    # only base_* and kmods_* on pkg.freebsd.org, for 14, 15 and 16), so
    # `pkg bootstrap` fails. Phase pkg installs it from our repository.
    c.sh(f"touch /home/{user}/.provision-done")
    c.sh(f"chown {user} /home/{user}/.provision-done")
    c.send("exit\r")
    print("[provision] done")


if __name__ == "__main__":
    main()
