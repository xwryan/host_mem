// host_mem_owned_view 定向测试：只认领自己的分配、跨分配/越界拒绝、两个视图共享 backing 互不认领、free 账本。
`include "uvm_macros.svh"

program host_mem_owned_view_tb;
    import uvm_pkg::*;
    import host_mem_pkg::*;

    class expected_msg_catcher extends uvm_report_catcher;
        int caught;

        function new(string name = "expected_msg_catcher");
            super.new(name);
        endfunction

        function action_e catch();
            if (get_id() == "HOST_MEM" && get_severity() == UVM_ERROR) begin
                caught++;
                return CAUGHT;
            end
            return THROW;
        endfunction
    endclass

    host_mem_manager      mem;
    host_mem_owned_view   a, b;
    expected_msg_catcher  catcher;
    bit [63:0]            a0, a1, b0;
    string                why;
    byte                  wdata[], rdata[];

    task automatic check(bit cond, string what);
        if (!cond)
            $fatal(1, {"FAILED: ", what});
    endtask

    initial begin
        mem = new("mem");
        mem.init_region(64'h1_0000_0000, 64'h1_00FF_FFFF);
        a = new("view_a");
        b = new("view_b");
        check(a.bind_backing(mem, why) && b.bind_backing(mem, why), "bind backing");

        a0 = a.alloc(256, 64);
        a1 = a.alloc(4096, 4096);
        b0 = b.alloc(128, 64);
        check(a0 != '1 && a1 != '1 && b0 != '1, "allocations succeed");
        check(a.owned_count() == 2 && b.owned_count() == 1, "ledger counts");

        check(a.claims_dma_address(a0) && a.claims_dma_address(a0 + 255), "A claims its first allocation");
        check(!a.claims_dma_address(a0 + 256) || a0 + 256 == a1, "A does not claim past its allocation");
        check(!a.claims_dma_address(b0) && b.claims_dma_address(b0), "views do not claim each other");
        check(a.validate_dma_access(a1, 4096, 1, why), "whole second allocation is valid");
        check(!a.validate_dma_access(a1 + 4000, 200, 0, why), "range past the allocation is rejected");
        check(!a.validate_dma_access(a0, 0, 0, why), "empty range is rejected");

        wdata = new[4];
        foreach (wdata[i]) wdata[i] = 8'hA0 + i;
        a.write_mem(a0, wdata);
        b.read_mem(a0, 4, rdata);
        check(rdata == wdata, "views share the backing data");

        catcher = new();
        uvm_report_cb::add(null, catcher);
        b.free(a0);
        check(catcher.caught == 1 && a.claims_dma_address(a0), "foreign free is rejected");
        uvm_report_cb::delete(null, catcher);

        a.free(a0);
        check(!a.claims_dma_address(a0) && a.owned_count() == 1, "free drops the claim");
        a.free_all();
        b.free_all();
        check(a.owned_count() == 0 && b.owned_count() == 0, "free_all empties the ledgers");
        mem.leak_check();
        $display("HOST_MEM_OWNED_VIEW_TB PASSED");
        $finish;
    end
endprogram
