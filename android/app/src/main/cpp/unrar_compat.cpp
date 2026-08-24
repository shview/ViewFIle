// Android bionic 无 getpass()。unrar 只在命令行交互取密码时用到；
// 我们以 DLL API 方式集成，永远不会走到该分支，给个空实现满足链接。
extern "C" char *getpass(const char *) {
  static char empty[1] = {0};
  return empty;
}
