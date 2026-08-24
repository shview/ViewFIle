// vfunrar: RAR 列表/单文件解压 CLI（unrar 官方 dll.hpp API）
//   vfunrar list <rar>                          → 行: F|size|mtime|name 或 D|0|0|name
//   vfunrar extract <rar> <inner> <destAbsPath> → rc=0 成功
#include <cstdio>
#include <cstdint>
#include <cwchar>

// dll.hpp 由 rar.hpp 在 RARDLL 下带入（提供 HANDLE/PASCAL 与 API 声明）
#include "unrar_src/rar.hpp"
#ifndef _UNRAR_DLL_
#include "unrar_src/dll.hpp"
#endif

static long long dosOrFiletimeToEpoch(unsigned int dosTime,
                                       unsigned int ftLow, unsigned int ftHigh) {
  if (ftLow != 0 || ftHigh != 0) {
    // Windows FILETIME: 100ns since 1601-01-01 → epoch 秒
    long long ft = ((long long)ftHigh << 32) | (unsigned int)ftLow;
    return ft / 10000000LL - 11644473600LL;
  }
  // DOS 时间
  int sec = (dosTime & 0x1F) * 2;
  int min = (dosTime >> 5) & 0x3F;
  int hour = (dosTime >> 11) & 0x1F;
  int day = (dosTime >> 16) & 0x1F;
  int mon = ((dosTime >> 21) & 0x0F);
  int year = 1980 + ((dosTime >> 25) & 0x7F);
  // 粗略儒略日换算（1970-1-1 = 2440588）
  long long a = (mon < 3 ? year - 1 : year);
  long long m = (mon < 3 ? mon + 13 : mon + 1);
  long long jdn = (1461 * (a + 4800)) / 4 + (153 * m) / 5 + day - 32075;
  return (jdn - 2440588) * 86400LL + hour * 3600 + min * 60 + sec;
}

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: vfunrar list <rar> | extract <rar> <inner> <dest>\n");
    return 2;
  }
  const char *mode = argv[1];
  const char *rarPath = argv[2];

  RAROpenArchiveDataEx arc;
  memset(&arc, 0, sizeof(arc));
  arc.ArcName = (char *)rarPath;
  wchar_t wpath[1024];
  mbstowcs(wpath, rarPath, 1023);
  arc.ArcNameW = wpath;
  arc.OpenMode = strcmp(mode, "list") == 0 ? RAR_OM_LIST : RAR_OM_EXTRACT;

  HANDLE h = RAROpenArchiveEx(&arc);
  if (arc.OpenResult != 0) {
    fprintf(stderr, "open failed: %d\n", arc.OpenResult);
    return 3;
  }

  int rc = 0;
  if (strcmp(mode, "list") == 0) {
    RARHeaderDataEx hd;
    memset(&hd, 0, sizeof(hd));
    while (RARReadHeaderEx(h, &hd) == 0) {
      char name[2048];
      // UTF-8：unrar 在 UNIX 下 FileName 已是 UTF-8 字节
      snprintf(name, sizeof(name), "%s", hd.FileName);
      long long size = ((long long)hd.UnpSizeHigh << 32) | (unsigned int)hd.UnpSize;
      long long mtime = dosOrFiletimeToEpoch(hd.FileTime, hd.MtimeLow, hd.MtimeHigh);
      if (hd.Flags & RHDF_DIRECTORY) {
        printf("D|0|%lld|%s\n", mtime, name);
      } else {
        printf("F|%lld|%lld|%s\n", size, mtime, name);
      }
      fflush(stdout);
      if (RARProcessFileW(h, RAR_SKIP, NULL, NULL) != 0) {
        rc = 4;
        break;
      }
    }
  } else if (strcmp(mode, "extract") == 0 && argc == 5) {
    const char *inner = argv[3];
    const char *dest = argv[4];
    RARHeaderDataEx hd;
    memset(&hd, 0, sizeof(hd));
    bool found = false;
    while (RARReadHeaderEx(h, &hd) == 0) {
      if (strcmp(hd.FileName, inner) == 0) {
        found = true;
        wchar_t wdest[1024];
        mbstowcs(wdest, dest, 1023);
        int prc = RARProcessFileW(h, RAR_EXTRACT, NULL, wdest);
        if (prc != 0) {
          fprintf(stderr, "extract failed: %d\n", prc);
          rc = 5;
        }
        break;
      }
      if (RARProcessFileW(h, RAR_SKIP, NULL, NULL) != 0) {
        rc = 4;
        break;
      }
    }
    if (!found && rc == 0) {
      fprintf(stderr, "not found\n");
      rc = 6;
    }
  } else {
    fprintf(stderr, "bad args\n");
    rc = 2;
  }
  RARCloseArchive(h);
  return rc;
}
