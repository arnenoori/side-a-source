#include "CSideAPTY.h"

#include <errno.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

pid_t sidea_pty_spawn(const char *path, char *const argv[], char *const envp[], unsigned short cols, unsigned short rows, int *master) {
    struct winsize size = { .ws_row = rows, .ws_col = cols };
    int fd = -1;
    pid_t pid = forkpty(&fd, NULL, NULL, &size);
    if (pid < 0) return -1;
    if (pid == 0) {
        // Nothing of the app's (its listening sockets, other viewers' terminals) goes to tmux.
        int highest = getdtablesize();
        for (int other = 3; other < highest; other++) close(other);
        execve(path, argv, envp);
        _exit(127);
    }
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    *master = fd;
    return pid;
}

int sidea_pty_resize(int master, unsigned short cols, unsigned short rows) {
    struct winsize size = { .ws_row = rows, .ws_col = cols };
    return ioctl(master, TIOCSWINSZ, &size);
}
