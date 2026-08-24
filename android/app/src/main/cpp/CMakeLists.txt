cmake_minimum_required(VERSION 3.22)
project(vfwatch C)

# 可执行目标必须命名成 lib*.so 才会被打进 APK 并保留执行权限
add_executable(vfwatch vfwatch.c)
set_target_properties(vfwatch PROPERTIES PREFIX "lib" SUFFIX ".so")

# ---------- vfunrar：RAR 列表/解压（unrar 官方源码，仅解压器用途） ----------
project(vfunrar CXX)

# 与官方 makefile 的 OBJECTS+LIB_OBJ 完全一致；其余 .cpp 是被父文件
# #include 的片段（crypt1/2/3/5、unpack15/20/30/50、blake2sp 等），单独编译必炸
set(UNRAR_BASE
    rar strlist strfn pathfn smallfn global file filefn filcreat
    archive arcread unicode system crypt crc rawread encname
    resource match timefn rdwrfn consio options errhnd rarvm secpassword
    rijndael getbits sha1 sha256 blake2s hash extinfo extract volume
    list find unpack headers threadpool rs16 cmddata ui largepage
    filestr scantree dll qopen)
set(UNRAR_SRC "")
foreach(f IN LISTS UNRAR_BASE)
    list(APPEND UNRAR_SRC ${CMAKE_CURRENT_SOURCE_DIR}/unrar_src/${f}.cpp)
endforeach()
# bionic 无 getpass（仅命令行交互分支用，DLL 模式不会真调到）
list(APPEND UNRAR_SRC ${CMAKE_CURRENT_SOURCE_DIR}/unrar_compat.cpp)

add_library(unrar_core STATIC ${UNRAR_SRC})
# RARDLL：官方库构建开关——rar.hpp 据此包含 dll.hpp（HANDLE/PASCAL 平台类型）；
# 不要手动 -DUNIX，clang 的 __ANDROID__/__linux__ 会让 raros.hpp 自行推导 _UNIX。
# 各 .cpp 均自带 include（global.cpp 靠自身 INCLUDEGLOBAL 展开全局变量定义，
# 强制前缀头反而会让 include guard 提前锁死成 extern）
target_compile_definitions(unrar_core PRIVATE
    -DRARDLL -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -DNDEBUG)
target_compile_options(unrar_core PRIVATE -Wno-unused-parameter)
target_compile_features(unrar_core PUBLIC cxx_std_17)

add_executable(vfunrar vfunrar.cpp)
set_target_properties(vfunrar PROPERTIES PREFIX "lib" SUFFIX ".so")
target_compile_definitions(vfunrar PRIVATE -DRARDLL -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE)
target_link_libraries(vfunrar PRIVATE unrar_core)
