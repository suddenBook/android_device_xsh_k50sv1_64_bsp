#include <errno.h>
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc < 3 || getuid() != 0) return 2;
    char *end; errno = 0;
    unsigned long uid = strtoul(argv[1], &end, 10);
    if (errno || *end || !(uid == 1001 || (uid >= 10000 && uid < 20000))) return 2;
    if (setgroups(0, NULL) || setgid((gid_t)uid) || setuid((uid_t)uid)) {
        perror("drop uid"); return 1;
    }
    execv(argv[2], argv + 2);
    perror("execv"); return 1;
}
