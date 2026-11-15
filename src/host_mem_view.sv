// src/：Host memory 视图基类，仅由 host_mem_pkg.sv 包内包含。
// 职责：为 PCIe、VirtIO、RDMA 等 requester 提供不拥有 backing 的 host_mem_api
//   转发边界；派生类可重载地址翻译、权限和脏页等 requester 语义。
// 依赖：host_mem_api 及其枚举类型，均在同一 host_mem_pkg 中声明。
// 所有权/生命周期：本类只借用 mem；调用者负责 backing 的初始化和销毁，视图
//   可以在 backing 销毁前解除引用或随 requester 一起销毁。

class host_mem_view extends host_mem_api;
    // 兼容现有调用者的公共 backing 句柄。视图不拥有该对象，也不在析构时释放。
    host_mem_api mem;

    // 功能：构造未绑定 backing 的通用 Host memory 视图。
    // 输入输出及副作用：name 传给 uvm_object；mem 置空，不分配或初始化任何 Host 区域。
    // 失败边界：未绑定时所有转发操作返回空值/失败值，写读不会产生副作用。
    function new(string name = "host_mem_view");
        super.new(name);
        mem = null;
    endfunction

    // 功能：绑定一个共享 Host memory backing，并保持重复绑定幂等。
    // 输入输出及副作用：backing 成为非拥有引用；why 在失败时给出可定位原因。
    // 失败边界：backing 为空，或已绑定到不同对象时拒绝且保留原绑定。
    virtual function bit bind_backing(host_mem_api backing, output string why);
        why = "";
        if (backing == null) begin
            why = "host memory backing is null";
            return 0;
        end
        if ((mem != null) && (mem != backing)) begin
            why = "host memory view is already bound to another backing";
            return 0;
        end
        mem = backing;
        return 1;
    endfunction

    // 功能：返回当前 backing 是否已经绑定。
    // 输入输出及副作用：只读取 mem，不修改视图或 backing。
    // 失败边界：未绑定返回 0；backing 的初始化状态由 is_initialized() 单独报告。
    virtual function bit is_bound();
        return mem != null;
    endfunction

    // 功能：返回视图当前借用的 backing 句柄，供环境做身份一致性检查。
    // 输入输出及副作用：只返回非拥有引用，不创建、替换或释放 backing。
    // 失败边界：未绑定返回 null；调用者不得通过返回句柄绕过视图的访问策略。
    virtual function host_mem_api backing();
        return mem;
    endfunction

    // 功能：初始化 backing 的 Host 地址区间。
    // 输入输出及副作用：参数原样转发给 backing，可能建立其 allocator 状态。
    // 失败边界：未绑定时静默忽略；已初始化 backing 的具体拒绝规则由 backing 决定。
    virtual function void init_region(bit [63:0] base_addr, bit [63:0] end_addr,
                                      alloc_mode_e m = MODE_BUDDY,
                                      int unsigned granule = DEFAULT_MIN_GRANULE,
                                      byte poison = DEFAULT_POISON);
        if (mem != null)
            mem.init_region(base_addr, end_addr, m, granule, poison);
    endfunction

    // 功能：设置 backing 的分配策略。
    // 输入输出及副作用：policy 转发给共享 allocator，影响后续分配布局。
    // 失败边界：未绑定时不改变任何对象；策略合法性由 backing 的枚举契约保证。
    virtual function void set_alloc_policy(host_mem_alloc_policy_e policy);
        if (mem != null)
            mem.set_alloc_policy(policy);
    endfunction

    // 功能：读取 backing 当前的分配策略。
    // 输入输出及副作用：返回共享 allocator 的策略，不修改状态。
    // 失败边界：未绑定返回 HOST_MEM_FIRST_FIT，避免调用者误用随机默认值。
    virtual function host_mem_alloc_policy_e get_alloc_policy();
        return (mem == null) ? HOST_MEM_FIRST_FIT : mem.get_alloc_policy();
    endfunction

    // 功能：设置 backing 的 Host ID。
    // 输入输出及副作用：id 转发给 backing，影响 Host 域检查。
    // 失败边界：未绑定时忽略；已绑定 backing 的共享语义由 backing 管理。
    virtual function void set_host_id(int unsigned id);
        if (mem != null)
            mem.set_host_id(id);
    endfunction

    // 功能：读取 backing 的 Host ID。
    // 输入输出及副作用：返回 backing 域标识，不修改状态。
    // 失败边界：未绑定返回 0；调用者应先用 is_bound() 区分默认值和真实 Host 0。
    virtual function int unsigned get_host_id();
        return (mem == null) ? 0 : mem.get_host_id();
    endfunction

    // 功能：报告 backing 是否完成区域初始化。
    // 输入输出及副作用：只查询 backing。
    // 失败边界：未绑定返回 0；初始化失败语义由 backing 的 is_initialized() 提供。
    virtual function bit is_initialized();
        return (mem != null) && mem.is_initialized();
    endfunction

    // 功能：检查 backing 是否完整包含指定地址区间。
    // 输入输出及副作用：base/size 原样查询，不分配或修改数据。
    // 失败边界：未绑定、零长度或跨区域时返回 0。
    virtual function bit contains_range(bit [63:0] base, bit [63:0] size);
        return (mem != null) && mem.contains_range(base, size);
    endfunction

    // 功能：检查区间是否与 backing 的任一区域相交。
    // 输入输出及副作用：只读查询，不修改 allocator。
    // 失败边界：未绑定、零长度或地址回绕时返回 0。
    virtual function bit intersects_region(bit [63:0] base, bit [63:0] size);
        return (mem != null) && mem.intersects_region(base, size);
    endfunction

    // 功能：在 backing 中保留一段不可分配区间。
    // 输入输出及副作用：owner/file/line 随请求转发，成功后影响后续分配。
    // 失败边界：未绑定、越界、重叠或零长度时返回 0，具体诊断由 backing 记录。
    virtual function bit reserve_range(bit [63:0] base, bit [63:0] size,
                                       string owner = "", string file = "",
                                       int line = 0);
        return (mem != null) && mem.reserve_range(base, size, owner, file, line);
    endfunction

    // 功能：从 backing 分配一段满足 size/align 的 Host memory。
    // 输入输出及副作用：返回 backing 的地址，并更新其分配表。
    // 失败边界：未绑定返回全 1；size/align 不合法或资源不足由 backing 判定。
    virtual function bit [63:0] alloc(int unsigned size, int unsigned align = 1,
                                      string file = "", int line = 0);
        return (mem == null) ? '1 : mem.alloc(size, align, file, line);
    endfunction

    // 功能：释放 backing 中以 addr 为起点的分配。
    // 输入输出及副作用：释放成功后地址不可继续作为已分配区间访问。
    // 失败边界：未绑定或未知地址时不执行释放，错误记录由 backing 负责。
    virtual function void free(bit [63:0] addr, string file = "", int line = 0);
        if (mem != null)
            mem.free(addr, file, line);
    endfunction

    // 功能：向 backing 写入 data 字节。
    // 输入输出及副作用：修改共享 backing 的字节存储，并记录访问来源。
    // 失败边界：未绑定、越界或未分配区间时不写入，拒绝语义由 backing 定义。
    virtual function void write_mem(bit [63:0] addr, byte data[],
                                    string file = "", int line = 0);
        if (mem != null)
            mem.write_mem(addr, data, file, line);
    endfunction

    // 功能：从 backing 读取 size 字节到 data。
    // 输入输出及副作用：data 被替换为读取副本，backing 内容保持不变。
    // 失败边界：未绑定、越界或未分配区间时由 backing 返回空/诊断结果。
    virtual function void read_mem(bit [63:0] addr, int unsigned size,
                                   ref byte data[], input string file = "",
                                   input int line = 0);
        data = new[0];
        if (mem != null)
            mem.read_mem(addr, size, data, file, line);
    endfunction

    // 功能：比较 backing 中两段字节并返回首个不一致位置。
    // 输入输出及副作用：mismatch_offset 输出差异偏移，不修改 backing。
    // 失败边界：未绑定返回 0；越界访问由 backing 拒绝并保持其错误语义。
    virtual function bit mem_compare(bit [63:0] addr1, bit [63:0] addr2,
                                     int unsigned size,
                                     output int unsigned mismatch_offset,
                                     input string file = "", input int line = 0);
        mismatch_offset = 0;
        return (mem != null) && mem.mem_compare(addr1, addr2, size,
                                                mismatch_offset, file, line);
    endfunction

    // 功能：请求 backing 检查当前未释放分配。
    // 输入输出及副作用：可能记录泄漏诊断，不释放对象或修改分配表。
    // 失败边界：未绑定时忽略；具体泄漏判定由 backing 执行。
    virtual function void leak_check(string file = "", int line = 0);
        if (mem != null)
            mem.leak_check(file, line);
    endfunction
endclass : host_mem_view
