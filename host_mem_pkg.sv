// host_mem 根入口：host_mem.f 唯一编译的源文件，按原编译顺序 include 本项目的全部源码（package、interface、module）；
// 路径相对仓库根目录，经 host_mem.f 的 +incdir+./ 解析。依赖项目须先经各自的 filelist 编译。
// HOST_MEM_PKG_SV 由 src/host_mem_pkg.sv 自身的 guard 定义，这里只判断不定义，否则会跳过该文件。
`ifndef HOST_MEM_PKG_SV
`include "src/host_mem_pkg.sv"
`endif // HOST_MEM_PKG_SV
