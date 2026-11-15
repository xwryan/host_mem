// Host 内存模型唯一编译入口：类型、抽象 API、manager、view、pool 与便捷宏均由本包提供。
`ifndef HOST_MEM_PKG_SV
`define HOST_MEM_PKG_SV

package host_mem_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    parameter int unsigned DEFAULT_MIN_GRANULE = 16;
    parameter int unsigned MAX_MIN_GRANULE     = 64;
    parameter byte         DEFAULT_POISON      = 8'hDE;

    typedef enum { MODE_BUDDY, MODE_LINEAR } alloc_mode_e;

    // Placement policy is independent of the allocator structure: RANDOM (default) follows the
    // simulator seed; FIRST_FIT is kept for deterministic debug and regression runs.
    typedef enum { HOST_MEM_RANDOM, HOST_MEM_FIRST_FIT } host_mem_alloc_policy_e;

    typedef struct {
        bit [63:0] base;
        bit [63:0] size;
        string     owner;
        string     caller_file;
        int        caller_line;
    } host_mem_reservation_t;

    typedef struct {
        bit [63:0]       addr;
        longint unsigned size;
    } free_seg_t;

    typedef struct {
        bit [63:0]   base_addr;
        int unsigned buddy_size;
        int unsigned req_size;
        int unsigned align;
        string       caller_file;
        int          caller_line;
        realtime     alloc_time;
    } alloc_info_t;

    typedef struct {
        string       op;
        bit [63:0]   base_addr;
        int unsigned size;
        string       caller_file;
        int          caller_line;
        realtime     timestamp;
    } mem_history_t;

    typedef struct {
        bit [63:0] base_addr;
        bit [63:0] end_addr;
    } region_info_t;

    // 抽象 API 是 BFM 的稳定依赖边界；句柄不拥有对象，生命周期由环境或 host_mem_pool 管理。
    virtual class host_mem_api extends uvm_object;
        function new(string name = "host_mem_api"); super.new(name); endfunction
        pure virtual function void init_region(bit [63:0] base_addr, bit [63:0] end_addr,
                                               alloc_mode_e m = MODE_BUDDY,
                                               int unsigned granule = DEFAULT_MIN_GRANULE,
                                               byte poison = DEFAULT_POISON);
        pure virtual function void set_alloc_policy(host_mem_alloc_policy_e policy);
        pure virtual function host_mem_alloc_policy_e get_alloc_policy();
        pure virtual function void set_host_id(int unsigned id);
        pure virtual function int unsigned get_host_id();
        pure virtual function bit is_initialized();
        pure virtual function bit contains_range(bit [63:0] base, bit [63:0] size);
        pure virtual function bit intersects_region(bit [63:0] base, bit [63:0] size);
        // 地址归属查询，与本次读写权限无关；翻译视图必须重载，权限失败后不得回退到其他视图。
        extern virtual function bit claims_dma_address(bit [63:0] addr);
        // 写入或生成 Completion 前的 DMA 权限预检；why 返回拒绝原因，无数据副作用。
        extern virtual function bit validate_dma_access(bit [63:0] addr, int unsigned size,
                                                       bit write_access, output string why);
        pure virtual function bit reserve_range(bit [63:0] base, bit [63:0] size,
                                                string owner = "", string file = "", int line = 0);
        pure virtual function bit [63:0] alloc(int unsigned size, int unsigned align = 1, string file = "", int line = 0);
        pure virtual function void free(bit [63:0] addr, string file = "", int line = 0);
        pure virtual function void write_mem(bit [63:0] addr, byte data[], string file = "", int line = 0);
        pure virtual function void read_mem(bit [63:0] addr, int unsigned size, ref byte data[], input string file = "", input int line = 0);
        pure virtual function bit mem_compare(bit [63:0] addr1, bit [63:0] addr2, int unsigned size, output int unsigned mismatch_offset, input string file = "", input int line = 0);
        pure virtual function void leak_check(string file = "", int line = 0);
    endclass

    function bit host_mem_api::claims_dma_address(bit [63:0] addr);
        return contains_range(addr, 1);
    endfunction

    function bit host_mem_api::validate_dma_access(bit [63:0] addr, int unsigned size,
                                                   bit write_access, output string why);
        why = "DMA address is outside initialized Host memory";
        if (!is_initialized() || !contains_range(addr, size)) return 0;
        why = "";
        return 1;
    endfunction

    // 按依赖顺序纳入全部生产类，避免调用方 include 产生不同作用域的类身份。
    `include "host_mem_manager.sv"
    `include "host_mem_view.sv"
    `include "host_mem_pool.sv"

    // 宏没有 package 作用域：跨编译单元的调用者仍需显式 include host_mem_macros.svh。
    `include "host_mem_macros.svh"

endpackage : host_mem_pkg

`endif
