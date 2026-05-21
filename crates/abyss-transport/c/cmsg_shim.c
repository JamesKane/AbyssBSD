/* SPDX-License-Identifier: BSD-2-Clause */
/*
 * SOCK_SEQPACKET + SCM_RIGHTS shim for abyss-transport.
 *
 * sendmsg(2) and recvmsg(2) are ordinary libc functions, but the
 * control-message API that carries file descriptors is C macros —
 * CMSG_FIRSTHDR, CMSG_NXTHDR, CMSG_DATA, CMSG_SPACE, CMSG_LEN. This shim
 * does the cmsg work in C and exposes a flat, callable ABI. See
 * docs/design/broker-and-transport.md §2 and §6.
 *
 * Compiled by build.rs on FreeBSD only.
 */
#include <sys/types.h>
#include <sys/socket.h>
#include <fcntl.h>
#include <stddef.h>
#include <string.h>

/* The largest descriptor count one datagram may carry — must match MAX_FDS
 * in src/freebsd.rs. */
#define ABYSS_MAX_FDS 64

/*
 * socketpair(AF_UNIX, SOCK_SEQPACKET) into sv[2]. Returns 0 on success, or
 * -1 with errno set. AF_UNIX and SOCK_SEQPACKET are resolved here, in C, so
 * the Rust side never hard-codes their values.
 */
int
abyss_seqpacket_pair(int *sv)
{
	return socketpair(AF_UNIX, SOCK_SEQPACKET, 0, sv);
}

/*
 * Send one datagram of `len` bytes from `data` on `sock`, passing `nfds`
 * descriptors from `fds` as SCM_RIGHTS ancillary data. Returns the number
 * of bytes sent, or -1 with errno set.
 */
ssize_t
abyss_send_fds(int sock, const void *data, size_t len,
    const int *fds, size_t nfds)
{
	struct iovec iov;
	struct msghdr msg;
	char cbuf[CMSG_SPACE(ABYSS_MAX_FDS * sizeof(int))];

	if (nfds > ABYSS_MAX_FDS)
		return -1;

	iov.iov_base = (void *)data;
	iov.iov_len = len;

	memset(&msg, 0, sizeof(msg));
	msg.msg_iov = &iov;
	msg.msg_iovlen = 1;

	if (nfds > 0) {
		memset(cbuf, 0, sizeof(cbuf));
		msg.msg_control = cbuf;
		msg.msg_controllen = CMSG_SPACE(nfds * sizeof(int));

		struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
		cmsg->cmsg_level = SOL_SOCKET;
		cmsg->cmsg_type = SCM_RIGHTS;
		cmsg->cmsg_len = CMSG_LEN(nfds * sizeof(int));
		memcpy(CMSG_DATA(cmsg), fds, nfds * sizeof(int));
	}

	/*
	 * MSG_EOR ends the record. FreeBSD's AF_UNIX SOCK_SEQPACKET delimits
	 * records by MSG_EOR: without it, consecutive sends coalesce into one
	 * record on the reader's side. (Linux treats every send as an
	 * implicit record; FreeBSD does not.) One send is therefore one
	 * datagram, as broker-and-transport.md §2.2 requires.
	 */
	return sendmsg(sock, &msg, MSG_EOR);
}

/*
 * Receive one datagram on `sock` into `buf` (capacity `buflen`). Any
 * descriptors received via SCM_RIGHTS are written to `fds` (capacity
 * `fdcap`) and `*nfds` is set to the count; received descriptors are
 * close-on-exec. Returns the number of body bytes received, or -1.
 */
ssize_t
abyss_recv_fds(int sock, void *buf, size_t buflen,
    int *fds, size_t fdcap, size_t *nfds)
{
	struct iovec iov;
	struct msghdr msg;
	char cbuf[CMSG_SPACE(ABYSS_MAX_FDS * sizeof(int))];
	ssize_t n;

	*nfds = 0;

	iov.iov_base = buf;
	iov.iov_len = buflen;

	memset(&msg, 0, sizeof(msg));
	msg.msg_iov = &iov;
	msg.msg_iovlen = 1;
	msg.msg_control = cbuf;
	msg.msg_controllen = sizeof(cbuf);

	n = recvmsg(sock, &msg, MSG_CMSG_CLOEXEC);
	if (n < 0)
		return -1;

	for (struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg); cmsg != NULL;
	    cmsg = CMSG_NXTHDR(&msg, cmsg)) {
		if (cmsg->cmsg_level != SOL_SOCKET ||
		    cmsg->cmsg_type != SCM_RIGHTS)
			continue;

		size_t bytes = cmsg->cmsg_len - CMSG_LEN(0);
		size_t count = bytes / sizeof(int);
		if (count > fdcap)
			count = fdcap;
		memcpy(fds, CMSG_DATA(cmsg), count * sizeof(int));
		*nfds = count;
	}

	return n;
}

/*
 * Put `fd` into non-blocking mode, so send/recv fail with EAGAIN rather
 * than blocking — the mode the async ring needs (§2.3). Returns 0, or -1
 * with errno set.
 */
int
abyss_set_nonblocking(int fd)
{
	int flags = fcntl(fd, F_GETFL, 0);
	if (flags < 0)
		return -1;
	return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}
