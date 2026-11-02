#ifndef CSIDEAPTY_H
#define CSIDEAPTY_H

#include <sys/types.h>

/// Starts `path` with `argv` and `envp` on a new pseudo-terminal of `cols` by `rows`. The child only calls execve
/// (Swift must not run between fork and exec in a threaded process). Returns the child's pid and sets `master`,
/// or returns -1 with errno set.
pid_t sidea_pty_spawn(const char *path, char *const argv[], char *const envp[], unsigned short cols, unsigned short rows, int *master);

/// Sets the terminal size the child sees.
int sidea_pty_resize(int master, unsigned short cols, unsigned short rows);

#endif
