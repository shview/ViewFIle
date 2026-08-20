/*
 * vfwatch — root 模式前台监听辅助进程
 * 用法：su -c libvfwatch.so
 * 协议：stdin 逐行输入要监听的目录绝对路径，读到 "." 结束清单；
 *       之后任何文件系统事件都在 stdout 输出一行 "E"（作为触发信号，
 *       不传递事件内容——由 app 侧做增量对账来获得精确结果）。
 * 以 root 运行，因此能对 /data/media/0、/data/data 等原始路径挂 inotify。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/inotify.h>

#define MAX_WATCH 200000
#define BUF_SZ (1 << 16)
#define LINE_SZ 4096

int main(void) {
    int fd = inotify_init1(IN_CLOEXEC);
    if (fd < 0) {
        fprintf(stderr, "inotify_init: %s\n", strerror(errno));
        return 1;
    }

    int n = 0;
    char line[LINE_SZ];
    while (fgets(line, sizeof(line), stdin)) {
        int len = strlen(line);
        while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r'))
            line[--len] = 0;
        if (len == 0) continue;
        if (strcmp(line, ".") == 0) break;
        if (n >= MAX_WATCH) break;
        int wd = inotify_add_watch(fd, line,
            IN_CREATE | IN_DELETE | IN_MOVED_TO | IN_MOVED_FROM |
            IN_CLOSE_WRITE | IN_ATTRIB | IN_DELETE_SELF | IN_MOVE_SELF);
        if (wd >= 0) n++;
    }
    fprintf(stderr, "watching %d dirs\n", n);

    /* stdin 清单读完后不再需要，关掉避免对端写阻塞 */
    char buf[BUF_SZ] __attribute__((aligned(8)));
    for (;;) {
        ssize_t r = read(fd, buf, sizeof(buf));
        if (r <= 0) {
            if (r < 0 && errno == EINTR) continue;
            break;
        }
        fputs("E\n", stdout);
        fflush(stdout);
    }
    return 0;
}
