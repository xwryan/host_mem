`ifndef HOST_MEM_RANDOM_TB_SV
`define HOST_MEM_RANDOM_TB_SV

import uvm_pkg::*;
import host_mem_pkg::*;
import virtio_net_pkg::*;
`include "uvm_macros.svh"

class expected_host_mem_pool_error extends uvm_report_catcher;
    `uvm_object_utils(expected_host_mem_pool_error)

    bit caught;

    function new(string name = "expected_host_mem_pool_error");
        super.new(name);
        caught = 0;
    endfunction

    function action_e catch();
        if (get_id() == "HOST_MEM_POOL") begin
            caught = 1;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass

// Focused UVM test for Host-memory placement, deliberately independent of PCIe/DPU topology.
class host_mem_random_test extends uvm_test;
    `uvm_component_utils(host_mem_random_test)

    function new(string name = "host_mem_random_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        host_mem_pool pool;
        host_mem_manager h0_a;
        host_mem_manager h0_b;
        host_mem_manager h1;
        host_mem_manager first_fit;
        host_mem_manager huge_buddy;
        host_mem_manager high_linear;
        host_mem_manager high_reserved;
        host_mem_manager imported_mem;
        virtio_net_env_config env_cfg;
        dpu_env_cfg	device_cfg;
        host_mem_bar_reservation_importer bar_importer;
        dpu_device_snapshot bar_snapshot;
        dpu_dut_caps bar_caps;
        dpu_function_key_t bar_function;
        dpu_pcie_function_id_t bar_pcie_id;
        dpu_bar_pair_lease_t bar_lease;
        string bar_why;
        bit [63:0] buddy_addrs[$];
        bit [63:0] linear_addrs[$];
        bit [63:0] addr;
        bit [63:0] reserved_base;
        byte       write_data[];
        byte       read_data[];
        int unsigned i;
        expected_host_mem_pool_error invalid_region_catcher;
        bit invalid_region_created;

        phase.raise_objection(this);

        pool = host_mem_pool::type_id::create("pool");
        // A full 2^64-byte aperture is unrepresentable: the pool must reject it before publishing
        // a manager whose init_region() failed.
        invalid_region_catcher = expected_host_mem_pool_error::type_id::create(
            "invalid_region_catcher");
        uvm_report_cb::add(null, invalid_region_catcher);
        invalid_region_created = pool.create_host(
            99, 64'h0, 64'hffff_ffff_ffff_ffff,
            MODE_LINEAR, 16, HOST_MEM_RANDOM);
        uvm_report_cb::delete(null, invalid_region_catcher);
        if (!invalid_region_catcher.caught || invalid_region_created ||
            pool.has_host(99))
            `uvm_fatal("HOST_MEM_TEST",
                       "pool published a manager for an unrepresentable region")
        if (!pool.create_host(0, 64'h1000, 64'h1ffff,
                              MODE_BUDDY, 16, HOST_MEM_RANDOM))
            `uvm_fatal("HOST_MEM_TEST", "failed to create Host 0")
        if (!pool.create_host(1, 64'h1000, 64'h1ffff,
                              MODE_BUDDY, 16, HOST_MEM_RANDOM))
            `uvm_fatal("HOST_MEM_TEST", "failed to create Host 1")

        // Service environments resolve their Host-local manager from the owning pool by host_id
        // instead of constructing a private allocator.
        env_cfg = virtio_net_env_config::type_id::create("env_cfg");
        env_cfg.host_id = 0;
        env_cfg.host_mem_pool_binding = pool;
        if (env_cfg.host_mem_pool_binding != pool)
            `uvm_fatal("HOST_MEM_TEST", "pool binding was not retained")
        device_cfg = dpu_env_cfg::type_id::create("dpu_env_cfg");
        device_cfg.host_mem_pool_ref = pool;
        if (device_cfg.host_mem_pool_ref != pool)
            `uvm_fatal("HOST_MEM_TEST",
                       "DPU environment did not retain Host pool owner")

        // A frozen device snapshot can be lowered into Host-local BAR
        // reservations before service allocations begin.
        bar_snapshot = dpu_device_snapshot::type_id::create("bar_snapshot");
        bar_caps = dpu_dut_caps::type_id::create("bar_caps");
        bar_caps.vio_global_qpair_count = 2048;
        bar_caps.max_vio_net_qpairs_per_device = 32;
        bar_function.host_id = 0;
        bar_function.pf_id = 0;
        bar_function.kind = DPU_FUNCTION_PF;
        bar_function.vf_id = 0;
        bar_pcie_id.domain.host_id = 0;
        bar_pcie_id.domain.segment_id = 0;
        bar_pcie_id.bdf = 16'h0010;
        bar_lease.role = DPU_BAR_DEVICE_MEMORY;
        bar_lease.even_bar_id = 0;
        bar_lease.base = 64'h6000;
        bar_lease.size = 64'h1000;
        if (!bar_snapshot.set_dut_caps(bar_caps, bar_why) ||
            !bar_snapshot.add_function(bar_function, bar_pcie_id, bar_why) ||
            !bar_snapshot.add_bar(bar_function, bar_lease, bar_why) ||
            !bar_snapshot.set_expected_af(bar_function, bar_why) ||
            !bar_snapshot.freeze(bar_why))
            `uvm_fatal("HOST_MEM_TEST", {"could not build BAR snapshot: ", bar_why})
        imported_mem = host_mem_manager::type_id::create("imported_mem");
        imported_mem.init_region(64'h1000, 64'h1ffff, MODE_LINEAR, 16);
        bar_importer = host_mem_bar_reservation_importer::type_id::create(
            "bar_importer");
        if (!bar_importer.import_snapshot(bar_snapshot, imported_mem, 0,
                                          bar_why))
            `uvm_fatal("HOST_MEM_TEST", {"BAR reservation import failed: ", bar_why})
        addr = imported_mem.alloc(64, 64);
        if (addr == '1 || (addr >= 64'h6000 && addr < 64'h7000))
            `uvm_fatal("HOST_MEM_TEST", "allocator returned an imported BAR range")
        imported_mem.free(addr);

        h0_a = pool.get_host(0);
        h0_b = pool.get_host(0);
        h1   = pool.get_host(1);
        if (h0_a == null || h1 == null || h0_a != h0_b || h0_a == h1)
            `uvm_fatal("HOST_MEM_TEST", "Host pool identity/isolation failed")
        if (h0_a.get_host_id() != 0 || h1.get_host_id() != 1 ||
            h0_a.get_alloc_policy() != HOST_MEM_RANDOM)
            `uvm_fatal("HOST_MEM_TEST", "Host metadata/policy binding failed")
        if (!h0_a.reserve_range(64'h4000, 64'h1000, "BAR0"))
            `uvm_fatal("HOST_MEM_TEST", "reservation before allocation failed")
        if (!h0_a.reserve_range(64'h4000, 64'h1000, "BAR0"))
            `uvm_fatal("HOST_MEM_TEST",
                       "re-importing the same BAR reservation was rejected")
        addr = h0_a.alloc(256, 256);
        if (addr == '1 || !h0_a.reserve_range(64'h4000, 64'h1000, "BAR0"))
            `uvm_fatal("HOST_MEM_TEST",
                       "idempotent BAR import failed after another allocation")
        h0_a.free(addr);

        // Buddy random placement: every allocation is aligned, backed, and
        // disjoint from the BAR reservation and previous allocations.
        for (i = 0; i < 16; i++) begin
            addr = h0_a.alloc(256, 256);
            if (addr == '1 || (addr % 256) != 0 ||
                (addr < 64'h5000 && addr + 256 > 64'h4000))
                `uvm_fatal("HOST_MEM_TEST", "invalid/random buddy placement")
            write_data = new[16];
            foreach (write_data[k]) write_data[k] = byte'(i + k);
            h0_a.write_mem(addr, write_data);
            h0_a.read_mem(addr, write_data.size(), read_data);
            if (read_data.size() != write_data.size())
                `uvm_fatal("HOST_MEM_TEST", "backing storage read size mismatch")
            foreach (write_data[k]) begin
                if (read_data[k] != write_data[k])
                    `uvm_fatal("HOST_MEM_TEST", "backing storage data mismatch")
            end
            foreach (buddy_addrs[j]) begin
                if (!((addr + 256 <= buddy_addrs[j]) ||
                      (buddy_addrs[j] + 256 <= addr)))
                    `uvm_fatal("HOST_MEM_TEST", "buddy allocations overlap")
            end
            buddy_addrs.push_back(addr);
        end
        foreach (buddy_addrs[j]) h0_a.free(buddy_addrs[j]);

        first_fit = host_mem_manager::type_id::create("first_fit");
        first_fit.set_alloc_policy(HOST_MEM_FIRST_FIT);
        first_fit.init_region(64'h1000, 64'h1ffff);
        addr = first_fit.alloc(256, 256);
        if (addr != 64'h1000)
            `uvm_fatal("HOST_MEM_TEST", "FIRST_FIT did not return lowest address")
        first_fit.free(addr);

        // Linear mode uses the same policy and reservation semantics.
        if (!pool.create_host(2, 64'h1000, 64'h1ffff,
                              MODE_LINEAR, 16, HOST_MEM_RANDOM))
            `uvm_fatal("HOST_MEM_TEST", "failed to create Host 2")
        h1 = pool.get_host(2);
        if (!h1.reserve_range(64'h8000, 64'h1000, "BAR2"))
            `uvm_fatal("HOST_MEM_TEST", "linear reservation failed")
        for (i = 0; i < 8; i++) begin
            addr = h1.alloc(384, 64);
            if (addr == '1 || (addr % 64) != 0 ||
                (addr < 64'h9000 && addr + 384 > 64'h8000))
                `uvm_fatal("HOST_MEM_TEST", "invalid/random linear placement")
            foreach (linear_addrs[j]) begin
                if (!((addr + 384 <= linear_addrs[j]) ||
                      (linear_addrs[j] + 384 <= addr)))
                    `uvm_fatal("HOST_MEM_TEST", "linear allocations overlap")
            end
            linear_addrs.push_back(addr);
        end
        foreach (linear_addrs[j]) h1.free(linear_addrs[j]);

        // A second Host has an independent address domain and may reuse the
        // same numeric GPA without conflicting with Host 0.
        addr = h1.alloc(256, 256);
        reserved_base = h0_a.alloc(256, 256);
        if (addr == '1 || reserved_base == '1)
            `uvm_fatal("HOST_MEM_TEST", "cross-Host allocation failed")
        h1.free(addr);
        h0_a.free(reserved_base);

        // A 32-TiB buddy aperture yields a level-41 free block for a level-0 request; the search
        // must find it instead of stopping at a target+40 limit.
        huge_buddy = host_mem_manager::type_id::create("huge_buddy");
        huge_buddy.set_alloc_policy(HOST_MEM_FIRST_FIT);
        huge_buddy.init_region(64'h0, 64'h0000_1FFF_FFFF_FFFF,
                               MODE_BUDDY, 16);
        addr = huge_buddy.alloc(16, 16);
        if (addr == '1 || addr >= 64'h0000_2000_0000_0000)
            `uvm_fatal("HOST_MEM_TEST",
                       "buddy allocation failed in >40-level aperture")
        huge_buddy.free(addr);

        // end_addr == 64'hffff_ffff_ffff_ffff is a valid inclusive endpoint; linear setup must not
        // wrap end_addr+1 in a 64-bit temporary.
        high_linear = host_mem_manager::type_id::create("high_linear");
        high_linear.set_alloc_policy(HOST_MEM_FIRST_FIT);
        high_linear.init_region(64'hFFFF_FFFF_F000,
                                64'hFFFF_FFFF_FFFF,
                                MODE_LINEAR, 16);
        addr = high_linear.alloc(64, 64);
        if (addr == '1 || addr < 64'hFFFF_FFFF_F000 ||
            addr > 64'hFFFF_FFFF_FFC0)
            `uvm_fatal("HOST_MEM_TEST",
                       "linear allocation failed at 64-bit region end")
        high_linear.free(addr);

        // A reservation may end exactly at 2^64: extended-range validation must accept it and keep
        // the reserved top page out of the free lists.
        high_reserved = host_mem_manager::type_id::create("high_reserved");
        high_reserved.set_alloc_policy(HOST_MEM_FIRST_FIT);
        high_reserved.init_region(64'hFFFF_FFFF_E000,
                                  64'hFFFF_FFFF_FFFF,
                                  MODE_BUDDY, 16);
        if (!high_reserved.reserve_range(64'hFFFF_FFFF_F000, 64'h1000,
                                         "BAR_TOP"))
            `uvm_fatal("HOST_MEM_TEST", "top-of-address-space reservation failed")
        addr = high_reserved.alloc(64, 64);
        if (addr == '1 || addr >= 64'hFFFF_FFFF_F000)
            `uvm_fatal("HOST_MEM_TEST", "top reservation was returned by allocator")
        high_reserved.free(addr);

        phase.drop_objection(this);
    endtask
endclass

`endif
