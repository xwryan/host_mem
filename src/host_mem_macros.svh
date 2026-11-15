// 调用端便捷宏：宏不属于 package 命名空间，独立编译的调用端需显式 include 本文件。
`ifndef HOST_MEM_MACROS_SVH
`define HOST_MEM_MACROS_SVH

// Auto-inject `__FILE__ and `__LINE__ so callers don't need to pass them manually.

`define host_mem_alloc(mem, addr, size, align = 1) \
    addr = mem.alloc(size, align, `__FILE__, `__LINE__)

`define host_mem_free(mem, addr) \
    mem.free(addr, `__FILE__, `__LINE__)

`define host_mem_write(mem, addr, data) \
    mem.write_mem(addr, data, `__FILE__, `__LINE__)

`define host_mem_read(mem, addr, size, data) \
    mem.read_mem(addr, size, data, `__FILE__, `__LINE__)

`define host_mem_set(mem, addr, value, size) \
    mem.mem_set(addr, value, size, `__FILE__, `__LINE__)

`define host_mem_cpy(mem, dst, src, size) \
    mem.mem_cpy(dst, src, size, `__FILE__, `__LINE__)

`define host_mem_compare(mem, result, addr1, addr2, size, mismatch) \
    result = mem.mem_compare(addr1, addr2, size, mismatch, `__FILE__, `__LINE__)

`define host_mem_release_range(mem, addr, size) \
    mem.release_range(addr, size, `__FILE__, `__LINE__)

`define host_mem_leak_check(mem) \
    mem.leak_check(`__FILE__, `__LINE__)

`endif
