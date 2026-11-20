// host_mem 主 filelist：用大写 -F 引用（vcs -F <路径>/host_mem/host_mem.f），文件与 +incdir+ 都相对本文件目录，可在任意目录编译。
// 不拉入依赖；无前置项目（UVM 即可）。
// 只编译根入口 host_mem_pkg.sv；在自己的 package/module 内 `include "host_mem_import.svh" 即可 import 本项目的 package。
+incdir+./
+incdir+./src
./host_mem_pkg.sv
