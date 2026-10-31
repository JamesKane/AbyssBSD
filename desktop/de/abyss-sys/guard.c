/*
 * A supervised child stopped when this process is told to stop
 * (abyss-model's llama-server, P18.7b). From a signal handler, because the
 * signal may come while the process is blocked in a long call (a
 * completion): ask the child to stop, wait for it (5 s at most) with
 * waitpid and nanosleep, the only calls a handler may make here, and exit.
 * On FreeBSD the kernel would kill a process descriptor's child anyway,
 * but SIGKILL, mid-shutdown; on Linux this is what does it at all.
 */
#include <signal.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static volatile pid_t guarded;

static void
stop(int s)
{
	if (guarded > 0) {
		struct timespec ts = { 0, 100000000 };

		kill(guarded, SIGTERM);
		for (int i = 0; i < 50 && waitpid(guarded, NULL, WNOHANG) == 0; i++)
			nanosleep(&ts, NULL);
	}
	_exit(128 + s);
}

void
abg_stop_child_on_signals(pid_t pid)
{
	struct sigaction sa;

	guarded = pid;
	sa.sa_handler = stop;
	sa.sa_flags = 0;
	sigemptyset(&sa.sa_mask);
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGINT, &sa, NULL);
	sigaction(SIGHUP, &sa, NULL);
}
