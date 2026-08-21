/*
 * vfwatch — root 模式前台监听辅助进程
 * 用法：su -c libvfwatch.so
 * 协议：stdin 逐行输入要监听的目录绝对路径，读到 "." 结束清单；
 *       清单读完后 stdout 输出 "R requested installed" 并 flush；只有全部
 *       目录安装成功才进入事件循环。之后任何文件系统事件输出一行 "E"，
 *       不传递事件内容——由 app 侧做增量对账来获得精确结果）。
 * 以 root 运行，因此能对 /data/media/0、/data/data 等原始路径挂 inotify。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/inotify.h>
#include <sys/syscall.h>

#ifndef RENAME_NOREPLACE
#define RENAME_NOREPLACE (1 << 0)
#endif

#define MAX_WATCH 200000
#define BUF_SZ (1 << 16)
#define LINE_SZ 4096

/*
 * 原子无覆盖重命名。arm64-v8a 与 armeabi-v7a 的 NDK syscall headers 都提供
 * __NR_renameat2；若目标内核缺失则稳定返回 ENOSYS(38)。errno 直接作为退出码，
 * EEXIST=17、EXDEV=18，供 Kotlin 做明确映射。
 */
static int rename_noreplace(const char *old_path, const char *new_path) {
#ifdef __NR_renameat2
    if (syscall(__NR_renameat2, AT_FDCWD, old_path,
                AT_FDCWD, new_path, RENAME_NOREPLACE) == 0)
        return 0;
    return errno > 0 && errno < 256 ? errno : 1;
#else
    (void)old_path;
    (void)new_path;
    return ENOSYS;
#endif
}

int main(int argc, char **argv) {
    if (argc > 1) {
        if (argc == 4 && strcmp(argv[1], "--rename-noreplace") == 0)
            return rename_noreplace(argv[2], argv[3]);
        fprintf(stderr, "usage: %s --rename-noreplace OLD NEW\n", argv[0]);
        return 64;
    }

    int fd = inotify_init1(IN_CLOEXEC);
    if (fd < 0) {
        fprintf(stderr, "inotify_init: %s\n", strerror(errno));
        return 1;
    }

    int requested = 0;
    int installed = 0;
    char line[LINE_SZ];
    while (fgets(line, sizeof(line), stdin)) {
        int len = strlen(line);
        while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r'))
            line[--len] = 0;
        if (len == 0) continue;
        if (strcmp(line, ".") == 0) break;
        requested++;
        /* 超过内部容量后仍必须继续读完 stdin，避免写端永久阻塞。 */
        if (requested > MAX_WATCH) continue;
        int wd = inotify_add_watch(fd, line,
            IN_CREATE | IN_DELETE | IN_MOVED_TO | IN_MOVED_FROM |
            IN_CLOSE_WRITE | IN_ATTRIB | IN_DELETE_SELF | IN_MOVE_SELF);
        if (wd >= 0) installed++;
    }
    printf("R %d %d\n", requested, installed);
    fflush(stdout);
    fprintf(stderr, "requested %d dirs, watching %d\n", requested, installed);

    if (requested > MAX_WATCH || requested != installed) {
        close(fd);
        return 2;
    }

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
