/*
 * CPlatform — platform facts Swift cannot reach on its own.
 *
 * Swift's imported libc module (Glibc, on FreeBSD as on Linux) does not surface
 * <sys/sysctl.h>, so `sysctl`/`sysctlbyname` are simply invisible from Swift on
 * FreeBSD — the same class of problem as libwayland's static-inline requests
 * (HANDOFF §2.1). Anything that needs them goes through a shim like this one,
 * where the #ifdef is natural.
 *
 * Currently one call: "what is my own executable?", which is how the Dock
 * launches another copy of the shell. Linux answers with /proc/self/exe;
 * FreeBSD has no procfs mounted by default and answers with the
 * KERN_PROC_PATHNAME sysctl.
 */
#ifndef ABYSS_CPLATFORM_H
#define ABYSS_CPLATFORM_H

#include <stddef.h>

/* Write the absolute path of this process's executable into `buf` (NUL
 * terminated). Returns the length written (> 0), or -1 if it cannot be
 * determined. */
int ap_self_executable(char *buf, size_t len);

/*
 * File-descriptor passing over a unix socket (SCM_RIGHTS) — the reason the
 * control plane exists: a message can hand over an shm/dmabuf handle with no
 * pixel copies.
 *
 * This lives in C because the whole cmsg(3) interface is *macros*
 * (CMSG_FIRSTHDR, CMSG_DATA, CMSG_SPACE, CMSG_LEN) and Swift's C importer
 * cannot see macros — the same wall as libwayland's static-inline requests
 * (HANDOFF §2.1).
 */

/* Longest fd array either call will carry. A control message is a handful of
 * handles, never a bulk transfer; a fixed cap keeps the cmsg buffer on the
 * stack and bounds what a peer can make us allocate. */
#define AP_MAX_FDS 16

/* sendmsg(2) `buf` (which must be non-empty — SCM_RIGHTS needs at least one
 * byte of payload to ride with) plus `nfds` descriptors. Returns the number of
 * bytes sent, or -1 with errno set (EPIPE if the peer has gone). */
long ap_sendmsg_fds(int sock, const void *buf, size_t len, const int *fds, int nfds);

/*
 * Write every byte of `buf` to a connected socket, resuming on a short write.
 * Returns 0, or -1 with errno set (EPIPE if the peer has gone).
 *
 * This exists instead of a plain write(2) loop in Swift so that **writing to a
 * socket whose peer has closed can never kill the process**: it passes
 * MSG_NOSIGNAL, which is a macro Swift cannot see. Losing a client mid-message
 * has to be an error the caller reports, not a silent death — a control plane
 * where `abyssctl quit` dies from SIGPIPE looks exactly like a supervisor that
 * ignored the request.
 */
int ap_send_all(int sock, const void *buf, size_t len);

/* Ask the kernel never to raise SIGPIPE for this socket (SO_NOSIGPIPE, where it
 * exists — FreeBSD and Darwin). A no-op returning 0 on platforms without it,
 * which rely on MSG_NOSIGNAL per-call instead. */
int ap_socket_nosigpipe(int sock);

/* recvmsg(2) up to `len` bytes into `buf`, collecting any descriptors into
 * `fds` (at most `max_fds`, which must be <= AP_MAX_FDS) and writing how many
 * arrived to `*nfds_out`. Returns bytes received (0 = peer closed), or -1 with
 * errno set. Descriptors that arrive beyond `max_fds` are closed rather than
 * leaked. */
long ap_recvmsg_fds(int sock, void *buf, size_t len, int *fds, int max_fds, int *nfds_out);

/*
 * Who is on the other end of this connected unix socket?
 *
 * The installer is the reason this exists: `abyss-install` runs as root and is
 * commanded by an unprivileged GUI, so "may this caller command me" cannot be
 * answered by the socket's permissions. CurrentIPC creates its runtime
 * directory 0700 and its sockets 0600 — the right default for a desktop, and
 * exactly wrong here, because a root-owned 0600 socket is one the GUI cannot
 * open at all. Loosening the mode until it works hands the installer to every
 * process on the machine; asking the kernel does not.
 *
 * In C because it is two different calls: FreeBSD has getpeereid(3) and no
 * SO_PEERCRED; glibc has SO_PEERCRED (behind _GNU_SOURCE, with a struct ucred)
 * and no getpeereid. Same shape as the cmsg macros above.
 *
 * Writes the peer's effective uid to *uid. Returns 0, or -1 with errno set.
 */
int ap_peer_uid(int sock, unsigned int *uid);

/*
 * Hash a password the way the installed system will check it.
 *
 * The installer's plan carries a *hash*, never a plaintext password — it is a
 * value that gets logged, rendered into a golden test and passed between
 * processes (see de/install/Plan.swift). Somewhere between the text field and
 * the plan, therefore, something has to call crypt(3), and it happens in the
 * unprivileged GUI so that no plaintext ever crosses the control plane.
 *
 * SHA-512 ($6$), with a random salt from arc4random_buf. In C because crypt(3)
 * needs -lcrypt on both platforms and the salt wants a byte buffer.
 *
 * Writes a NUL-terminated hash into `out`. Returns 0, or -1 on failure.
 */
int ap_crypt_sha512(const char *password, char *out, size_t len);

/*
 * Ask for real-time scheduling for this process (PHASE4 §5.13) — the
 * compositor's present loop, whose largest remaining margin term on metal was
 * the OS waking it late.
 *
 * FreeBSD: rtprio(2), RTP_PRIO_REALTIME at `priority` (0 is highest, 31
 * lowest). Permitted to root, and to members of group `realtime` when
 * mac_priority(4) is loaded — no kernel patch. Linux: SCHED_FIFO, which needs
 * CAP_SYS_NICE; `priority` counts down from the highest FIFO priority.
 *
 * Returns 0, or -1 with errno set (EPERM when not permitted).
 */
int ap_request_realtime(int priority);

/*
 * A program on a pseudo-terminal (PHASE15 P15.4a) — Terminal's shell.
 *
 * In C because the child's half must be async-signal-safe (HANDOFF §2.25):
 * after fork it only calls setsid, open, ioctl(TIOCSCTTY), dup2, close, execve
 * and _exit. Everything it touches — the argv, the environment, the slave's
 * path — is prepared by the caller or here before the fork. The master comes
 * from posix_openpt, which is in libc on both FreeBSD and Linux (openpty is in
 * libutil on one and libc on the other).
 *
 * `path` must be absolute; `argv` and `envp` are NULL-terminated. The master is
 * returned close-on-exec and non-blocking. Returns the child's pid, or -1 with
 * errno set (and no child).
 */
int ap_pty_spawn(const char *path, char *const argv[], char *const envp[],
                 unsigned short rows, unsigned short cols, int *master_out);

/* Tell the terminal its size (TIOCSWINSZ); the kernel sends the foreground
 * process group SIGWINCH. Returns 0, or -1 with errno set. */
int ap_pty_resize(int master, unsigned short rows, unsigned short cols);

#endif /* ABYSS_CPLATFORM_H */
