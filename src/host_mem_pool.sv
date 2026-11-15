// Host 到 manager 的所有权映射；仅由 host_mem_pkg.sv 在 manager 之后包含。
`ifndef HOST_MEM_POOL_SV
`define HOST_MEM_POOL_SV

// Host-scoped owner of managers: repeated lookups return the same handle, and service
// environments must share it rather than construct private allocators.
class host_mem_pool extends uvm_object;
    `uvm_object_utils(host_mem_pool)

    protected host_mem_manager managers[int unsigned];

    function new(string name = "host_mem_pool");
        super.new(name);
    endfunction

    // Mirror the allocator's representability checks before constructing a manager:
    // init_region() returns void, so the pool must not publish one that would be rejected.
    protected function bit valid_region(
        input bit [63:0] base_addr,
        input bit [63:0] end_addr,
        input alloc_mode_e mode,
        input int unsigned granule
    );
        bit [64:0] span;
        bit [64:0] aligned_base;
        bit [64:0] aligned_end_excl;
        bit [64:0] usable;

        if (end_addr < base_addr)
            return 0;
        if (granule == 0 || granule > MAX_MIN_GRANULE ||
            (granule & (granule - 1)) != 0)
            return 0;

        span = {1'b0, end_addr} - {1'b0, base_addr} + 65'd1;
        // A complete 2^64-byte aperture cannot be represented by the
        // manager's 64-bit size/statistics fields.
        if (span[64] || span[63:0] < granule)
            return 0;

        if (mode == MODE_LINEAR) begin
            aligned_base = (({1'b0, base_addr} + granule - 1) /
                            granule) * granule;
            aligned_end_excl = (({1'b0, end_addr} + 65'd1) /
                                granule) * granule;
            usable = aligned_end_excl - aligned_base;
            if (aligned_end_excl <= aligned_base || usable[64] ||
                usable[63:0] < granule)
                return 0;
        end
        return 1;
    endfunction

    function bit create_host(
        input int unsigned host_id,
        input bit [63:0] base_addr,
        input bit [63:0] end_addr,
        input alloc_mode_e mode = MODE_BUDDY,
        input int unsigned granule = DEFAULT_MIN_GRANULE,
        input host_mem_alloc_policy_e policy = HOST_MEM_RANDOM
    );
        host_mem_manager manager;

        if (managers.exists(host_id)) begin
            `uvm_error("HOST_MEM_POOL", $sformatf(
                "Host %0d already has a memory manager", host_id))
            return 0;
        end
        if (!valid_region(base_addr, end_addr, mode, granule)) begin
            `uvm_error("HOST_MEM_POOL", $sformatf(
                "Host %0d has invalid region [0x%016h,0x%016h]",
                host_id, base_addr, end_addr))
            return 0;
        end
        manager = host_mem_manager::type_id::create(
            $sformatf("host_mem_%0d", host_id));
        manager.set_host_id(host_id);
        manager.set_alloc_policy(policy);
        manager.init_region(base_addr, end_addr, mode, granule);
        if (!manager.is_initialized()) begin
            `uvm_error("HOST_MEM_POOL", $sformatf(
                "Host %0d manager rejected region [0x%016h,0x%016h]",
                host_id, base_addr, end_addr))
            return 0;
        end
        managers[host_id] = manager;
        return 1;
    endfunction

    function host_mem_manager get_host(input int unsigned host_id);
        if (!managers.exists(host_id)) begin
            `uvm_error("HOST_MEM_POOL", $sformatf(
                "Host %0d has no memory manager", host_id))
            return null;
        end
        return managers[host_id];
    endfunction

    function bit has_host(input int unsigned host_id);
        return managers.exists(host_id);
    endfunction
endclass

`endif
