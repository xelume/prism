#include <signal.h>
#include <unistd.h>

/* This standalone test child never reads files, credentials, or network data. */
int main(void) {
    signal(SIGTERM, SIG_IGN);
    const char ready = 1;
    if (write(STDOUT_FILENO, &ready, 1) != 1) return 1;
    for (;;) pause();
}
