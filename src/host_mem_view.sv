// Host memory 视图基类：为 PCIe/VirtIO/RDMA 等 requester 转发 host_mem_api，只借用 backing；
// 派生类可重载地址翻译、权限和脏页等语义。

class host_mem_view extends host_mem_api;
    // 公共句柄仅为兼容现有调用者；视图不拥有 backing，也不负责释放。
    host_mem_api mem;

    function new(string name = "host_mem_view");
        super.new(name);
        mem = null;
    endfunction

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

    virtual function bit is_bound();
        return mem != null;
    endfunction

    // 仅供环境做身份一致性检查；调用者不得借此句柄绕过视图的访问策略。
    virtual function host_mem_api backing();
        return mem;
    endfunction

    // 以下 host_mem_api 方法均转发给 backing；未绑定时忽略写操作并返回空/失败值。
    virtual function void init_region(bit [63:0] base_addr, bit [63:0] end_addr,
                                      alloc_mode_e m = MODE_BUDDY,
                                      int unsigned granule = DEFAULT_MIN_GRANULE,
                                      byte poison = DEFAULT_POISON);
        if (mem != null)
            mem.init_region(base_addr, end_addr, m, granule, poison);
    endfunction

    virtual function void set_alloc_policy(host_mem_alloc_policy_e policy);
        if (mem != null)
            mem.set_alloc_policy(policy);
    endfunction

    // 未绑定时返回 FIRST_FIT，避免调用者误用随机默认值。
    virtual function host_mem_alloc_policy_e get_alloc_policy();
        return (mem == null) ? HOST_MEM_FIRST_FIT : mem.get_alloc_policy();
    endfunction

    virtual function void set_host_id(int unsigned id);
        if (mem != null)
            mem.set_host_id(id);
    endfunction

    // 未绑定返回 0；调用者需用 is_bound() 区分默认值与真实的 Host 0。
    virtual function int unsigned get_host_id();
        return (mem == null) ? 0 : mem.get_host_id();
    endfunction

    virtual function bit is_initialized();
        return (mem != null) && mem.is_initialized();
    endfunction

    virtual function bit contains_range(bit [63:0] base, bit [63:0] size);
        return (mem != null) && mem.contains_range(base, size);
    endfunction

    virtual function bit intersects_region(bit [63:0] base, bit [63:0] size);
        return (mem != null) && mem.intersects_region(base, size);
    endfunction

    virtual function bit reserve_range(bit [63:0] base, bit [63:0] size,
                                       string owner = "", string file = "",
                                       int line = 0);
        return (mem != null) && mem.reserve_range(base, size, owner, file, line);
    endfunction

    virtual function bit [63:0] alloc(int unsigned size, int unsigned align = 1,
                                      string file = "", int line = 0);
        return (mem == null) ? '1 : mem.alloc(size, align, file, line);
    endfunction

    virtual function void free(bit [63:0] addr, string file = "", int line = 0);
        if (mem != null)
            mem.free(addr, file, line);
    endfunction

    virtual function void write_mem(bit [63:0] addr, byte data[],
                                    string file = "", int line = 0);
        if (mem != null)
            mem.write_mem(addr, data, file, line);
    endfunction

    virtual function void read_mem(bit [63:0] addr, int unsigned size,
                                   ref byte data[], input string file = "",
                                   input int line = 0);
        data = new[0];
        if (mem != null)
            mem.read_mem(addr, size, data, file, line);
    endfunction

    virtual function bit mem_compare(bit [63:0] addr1, bit [63:0] addr2,
                                     int unsigned size,
                                     output int unsigned mismatch_offset,
                                     input string file = "", input int line = 0);
        mismatch_offset = 0;
        return (mem != null) && mem.mem_compare(addr1, addr2, size,
                                                mismatch_offset, file, line);
    endfunction

    virtual function void leak_check(string file = "", int line = 0);
        if (mem != null)
            mem.leak_check(file, line);
    endfunction
endclass : host_mem_view
