cmake_minimum_required(VERSION 3.22)
project(vfwatch C)

# 可执行目标必须命名成 lib*.so 才会被打进 APK 并保留执行权限
add_executable(vfwatch vfwatch.c)
set_target_properties(vfwatch PROPERTIES PREFIX "lib" SUFFIX ".so")
