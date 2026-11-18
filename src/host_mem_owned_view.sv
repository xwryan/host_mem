// 只认领经本视图分配的地址：多个 env 给同一 Requester 注册 DMA 视图时，RC 按地址唯一归属选择，互不冲突。
// 读写仍转发给 backing；free 只接受本视图分配的起始地址。

class host_mem_owned_view extends host_mem_view;
    protected int unsigned m_owned[bit [63:0]];   // 起始地址 -> 字节数

    function new(string name = "host_mem_owned_view");
        super.new(name);
    endfunction

    virtual function bit [63:0] alloc(int unsigned size, int unsigned align = 1,
                                      string file = "", int line = 0);
        bit [63:0] addr;

        addr = super.alloc(size, align, file, line);
        if (addr != '1)
            m_owned[addr] = size;
        return addr;
    endfunction

    virtual function void free(bit [63:0] addr, string file = "", int line = 0);
        if (!m_owned.exists(addr)) begin
            `uvm_error("HOST_MEM", $sformatf("%s: 0x%016h was not allocated by this view (%s:%0d)",
                                             get_name(), addr, file, line))
            return;
        end
        m_owned.delete(addr);
        super.free(addr, file, line);
    endfunction

    function void free_all(string file = "", int line = 0);
        bit [63:0] addrs[$];

        foreach (m_owned[a])
            addrs.push_back(a);
        foreach (addrs[i])
            free(addrs[i], file, line);
    endfunction

    function int unsigned owned_count();
        return m_owned.num();
    endfunction

    // [addr, addr+size) 整体落在本视图的一次分配内。
    function bit owns_range(bit [63:0] addr, bit [63:0] size);
        bit [63:0] base;

        if (size == 0)
            return 0;
        base = addr;
        if (!m_owned.exists(base) && !m_owned.prev(base))
            return 0;
        return ({1'b0, addr} + size) <= ({1'b0, base} + m_owned[base]);
    endfunction

    virtual function bit claims_dma_address(bit [63:0] addr);
        return owns_range(addr, 1);
    endfunction

    virtual function bit validate_dma_access(bit [63:0] addr, int unsigned size,
                                             bit write_access, output string why);
        why = "DMA range is not inside one allocation of this view";
        if (!is_initialized() || !owns_range(addr, size))
            return 0;
        why = "";
        return 1;
    endfunction
endclass : host_mem_owned_view
