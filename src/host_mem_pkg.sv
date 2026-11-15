// src/：Host 内存模型唯一编译入口，依赖 uvm_pkg 与 src include 路径。
// 常量、类型、抽象 API、manager 和 pool 统一属于 host_mem_pkg；测试不纳入本包。
// 包本身不创建对象：环境拥有 pool，pool 持有各 Host 的 manager；独立 manager 由调用者管理。
`ifndef HOST_MEM_PKG_SV
`define HOST_MEM_PKG_SV

package host_mem_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    parameter int unsigned DEFAULT_MIN_GRANULE = 16;
    parameter int unsigned MAX_MIN_GRANULE     = 64;
    parameter byte         DEFAULT_POISON      = 8'hDE;

    typedef enum { MODE_BUDDY, MODE_LINEAR } alloc_mode_e;

    // Placement policy is independent of the allocator data structure.  The
    // default is randomized using the simulator/UVM random stream; FIRST_FIT
    // is retained for deterministic debug and regression runs.
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

    // 保留抽象 API 作为 BFM 的稳定依赖边界；具体 manager 与本接口同属本包。
    // 接口句柄不拥有对象，实例生命周期由创建它的环境或 host_mem_pool 管理。
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
        // 功能：查询设备地址是否由此视图声明，独立于本次读写权限。
        // 输入输出及副作用：addr 为设备地址；返回所有权，不修改 backing。
        // 失败边界：默认按 Host 区域判断；翻译视图必须重载，禁止权限失败后回退其他视图。
        extern virtual function bit claims_dma_address(bit [63:0] addr);
        // 功能：在产生写入或 Completion 前检查 DMA 区间权限。
        // 输入输出及副作用：addr/size/write_access 指定访问；why 返回拒绝原因，无数据副作用。
        // 失败边界：默认拒绝未初始化及超出区域的访问；隔离视图重载自身账本/权限检查。
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

    // 功能：用默认物理区域声明单字节 DMA 地址所有权。
    // 输入输出及副作用：addr 为设备地址；只查询 contains_range。
    // 失败边界：区域之外返回 0；翻译及分账视图重载该函数。
    function bit host_mem_api::claims_dma_address(bit [63:0] addr);
        return contains_range(addr, 1);
    endfunction

    // 功能：预检默认 Host 区域上的 DMA 访问。
    // 输入输出及副作用：addr/size 为完整区间，write_access 对普通 backing 无权限差异；why 输出失败原因。
    // 失败边界：未初始化或区间越界返回 0，不触碰数据。
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

    // 宏随包入口分发，但预处理器宏无 package 作用域；跨编译单元调用者
    // 仍需显式 include 本头文件，不能以 import host_mem_pkg::* 导入宏。
    `include "host_mem_macros.svh"

endpackage : host_mem_pkg

`endif
