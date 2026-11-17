`ifndef HOST_MEM_BIGREGION_TB_SV
`define HOST_MEM_BIGREGION_TB_SV

`include "uvm_macros.svh"
`include "host_mem_macros.svh"

// Regression: 4 GB buddy region (granule 16) alloc/write/read/free. Guards against the former
// 32-bit overflow in addr_to_level() and buddy split (wrong addresses, FATAL, data corruption).

program host_mem_bigregion_tb;

    import uvm_pkg::*;
    import host_mem_pkg::*;

    host_mem_manager mem;
    host_mem_manager reserved_mem;
    bit [63:0] addr1, addr2, addr3;
    bit [63:0] reserved_base[$];
    bit [63:0] reserved_size[$];
    bit [63:0] allocated[$];
    byte wdata[], rdata[];
    int unsigned mismatch;
    bit cmp_result;

    initial begin

        $display("\n=== Big-Region Buddy Test: 4GB region ===");
        $display("  init_region(0, 0xFFFF_FFFF, MODE_BUDDY, 16)");

        mem = new("big_buddy");
        // 4 GB region: base=0, end=0xFFFF_FFFF (inclusive), granule=16
        mem.init_region(64'h0, 64'hFFFF_FFFF, MODE_BUDDY, 16);

        $display("  init done, allocating...");

        `host_mem_alloc(mem, addr1, 256, 64);
        if (addr1 == '1) begin
            $display("FAIL: alloc(256,64) returned ~0");
            $fatal(1, "alloc failed on 4GB region");
        end
        $display("  alloc1=0x%016h (expect addr < 4GB)", addr1);
        assert(addr1 < 64'h1_0000_0000)
            else $fatal(1, $sformatf("alloc1 addr=0x%016h out of 4GB region!", addr1));
        assert((addr1 % 64) == 0)
            else $fatal(1, $sformatf("alloc1 alignment fail: addr=0x%016h", addr1));

        `host_mem_alloc(mem, addr2, 128, 128);
        if (addr2 == '1) begin
            $display("FAIL: alloc(128,128) returned ~0");
            $fatal(1, "alloc2 failed on 4GB region");
        end
        $display("  alloc2=0x%016h", addr2);
        assert(addr2 < 64'h1_0000_0000)
            else $fatal(1, $sformatf("alloc2 addr=0x%016h out of 4GB region!", addr2));
        assert((addr2 % 128) == 0)
            else $fatal(1, $sformatf("alloc2 alignment fail: addr=0x%016h", addr2));

        `host_mem_alloc(mem, addr3, 512, 64);
        if (addr3 == '1) begin
            $display("FAIL: alloc(512,64) returned ~0");
            $fatal(1, "alloc3 failed on 4GB region");
        end
        $display("  alloc3=0x%016h", addr3);
        assert(addr3 < 64'h1_0000_0000)
            else $fatal(1, $sformatf("alloc3 addr=0x%016h out of 4GB region!", addr3));

        assert(addr1 + 256 <= addr2 || addr2 + 128 <= addr1)
            else $fatal(1, "OVERLAP: addr1 and addr2");
        assert(addr1 + 256 <= addr3 || addr3 + 512 <= addr1)
            else $fatal(1, "OVERLAP: addr1 and addr3");
        assert(addr2 + 128 <= addr3 || addr3 + 512 <= addr2)
            else $fatal(1, "OVERLAP: addr2 and addr3");

        wdata = new[256];
        foreach (wdata[i]) wdata[i] = byte'(i ^ 8'hA5);
        `host_mem_write(mem, addr1, wdata);
        `host_mem_read(mem, addr1, 256, rdata);
        foreach (rdata[i])
            assert(rdata[i] == wdata[i])
                else $fatal(1, $sformatf("data mismatch at byte %0d: exp=0x%02h got=0x%02h",
                    i, wdata[i], rdata[i]));
        $display("  write/read roundtrip addr1 (256B) OK");

        wdata = new[128];
        foreach (wdata[i]) wdata[i] = byte'(i ^ 8'h5A);
        `host_mem_write(mem, addr2, wdata);
        `host_mem_read(mem, addr2, 128, rdata);
        foreach (rdata[i])
            assert(rdata[i] == wdata[i])
                else $fatal(1, $sformatf("addr2 data mismatch at %0d", i));
        $display("  write/read roundtrip addr2 (128B) OK");

        `host_mem_free(mem, addr1);
        `host_mem_free(mem, addr2);
        `host_mem_free(mem, addr3);
        $display("  free all OK");

        `host_mem_leak_check(mem);
        $display("  leak_check passed");

        // Alloc a medium block to verify merging works
        `host_mem_alloc(mem, addr1, 65536, 4096);
        assert(addr1 != '1)
            else $fatal(1, "alloc(65536,4096) after free failed - merge broken?");
        $display("  post-free re-alloc 64KB OK at 0x%016h", addr1);
        `host_mem_free(mem, addr1);
        `host_mem_leak_check(mem);

        // Near-64-bit aperture with hundreds of scattered non-RAM holes (BAR/MSI-X style): rebuilding
        // the free structures must stay linear in the reservation count, and random allocations must
        // never touch a hole.
        $display("\n=== Reserved-hole Test: [4GB, 2^64-256TB) with 512 holes ===");
        reserved_mem = new("reserved_buddy");
        reserved_mem.set_alloc_policy(HOST_MEM_RANDOM);
        reserved_mem.init_region(64'h0000_0001_0000_0000, 64'hfffe_ffff_ffff_ffff, MODE_BUDDY, 16);
        while (reserved_base.size() < 512) begin
            bit [63:0] base;
            bit [63:0] size;
            bit        clash;

            size = 64'h1000 << ($urandom() % 15);
            base = ({$urandom(), $urandom()} % (64'hfffe_ffff_ffff_0000 - 64'h0000_0001_0000_0000 - size)) +
                   64'h0000_0001_0000_0000;
            base = base & ~(size - 1);
            clash = (base < 64'h0000_0001_0000_0000);
            foreach (reserved_base[i])
                if (base < reserved_base[i] + reserved_size[i] && reserved_base[i] < base + size)
                    clash = 1;
            if (clash)
                continue;
            if (!reserved_mem.reserve_range(base, size, $sformatf("hole%0d", reserved_base.size())))
                $fatal(1, $sformatf("reserve_range(0x%016h, 0x%0h) failed", base, size));
            reserved_base.push_back(base);
            reserved_size.push_back(size);
        end
        foreach (reserved_base[i])
            assert(reserved_mem.range_reserved(reserved_base[i]) &&
                   reserved_mem.range_reserved(reserved_base[i] + reserved_size[i] - 1))
                else $fatal(1, $sformatf("hole %0d not reported as reserved", i));
        assert(!reserved_mem.range_reserved(64'h0000_0001_0000_0000 - 1))
            else $fatal(1, "address below the aperture reported as reserved");
        for (int n = 0; n < 2000; n++) begin
            int unsigned size;

            size = 64 << ($urandom() % 7);
            `host_mem_alloc(reserved_mem, addr1, size, 64);
            assert(addr1 != '1) else $fatal(1, "alloc failed in reserved-hole region");
            foreach (reserved_base[i])
                assert(addr1 + size <= reserved_base[i] || reserved_base[i] + reserved_size[i] <= addr1)
                    else $fatal(1, $sformatf("alloc 0x%016h+%0d overlaps hole %0d", addr1, size, i));
            allocated.push_back(addr1);
        end
        foreach (allocated[i])
            `host_mem_free(reserved_mem, allocated[i]);
        `host_mem_leak_check(reserved_mem);
        $display("  512 holes reserved, 2000 random allocations avoided them, leak_check passed");

        $display("\n========================================");
        $display("BIG-REGION TEST PASSED");
        $display("========================================\n");
        $finish;
    end

endprogram

`endif
