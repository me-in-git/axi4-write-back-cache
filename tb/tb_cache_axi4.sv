// tb_cache_axi4: cache testbench against the AXI4 RAM model
module tb_cache_axi4;

    logic clk = 0, rst_n = 0;

    logic        req_valid, req_rw, req_ready, req_hit, req_done;
    logic [31:0] req_addr, req_wdata, req_rdata;

    logic [3:0]  arid; logic [31:0] araddr; logic [7:0] arlen;
    logic [2:0]  arsize; logic [1:0] arburst; logic arvalid, arready;
    logic [31:0] rdata; logic rlast, rvalid, rready;

    logic [3:0]  awid; logic [31:0] awaddr; logic [7:0] awlen;
    logic [2:0]  awsize; logic [1:0] awburst; logic awvalid, awready;
    logic [31:0] wdata; logic [3:0] wstrb; logic wlast, wvalid, wready;
    logic [1:0]  bresp; logic bvalid, bready;

    cache_axi4 #(.ADDR_W(32), .SET_IDX_W(6), .OFFSET_W(4), .WAYS(4)) dut (
        .clk(clk), .rst_n(rst_n),
        .req_valid(req_valid), .req_rw(req_rw), .req_addr(req_addr),
        .req_wdata(req_wdata), .req_ready(req_ready), .req_hit(req_hit),
        .req_done(req_done), .req_rdata(req_rdata),
        .arid(arid), .araddr(araddr), .arlen(arlen), .arsize(arsize),
        .arburst(arburst), .arvalid(arvalid), .arready(arready),
        .rdata(rdata), .rlast(rlast), .rvalid(rvalid), .rready(rready),
        .awid(awid), .awaddr(awaddr), .awlen(awlen), .awsize(awsize),
        .awburst(awburst), .awvalid(awvalid), .awready(awready),
        .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid),
        .wready(wready), .bvalid(bvalid), .bready(bready));

    axi_ram_slave #(.DEPTH_WORDS(4096)) mem (
        .clk(clk), .rst_n(rst_n),
        .arid(arid), .araddr(araddr), .arlen(arlen), .arsize(arsize),
        .arburst(arburst), .arvalid(arvalid), .arready(arready),
        .rdata(rdata), .rlast(rlast), .rvalid(rvalid), .rready(rready),
        .awid(awid), .awaddr(awaddr), .awlen(awlen), .awsize(awsize),
        .awburst(awburst), .awvalid(awvalid), .awready(awready),
        .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid),
        .wready(wready), .bresp(bresp), .bvalid(bvalid), .bready(bready));

    always #5 clk = ~clk;

    // count completed write-back bursts (AW handshakes)
    integer wb_count = 0;
    always @(posedge clk)
        if (awvalid && awready) wb_count = wb_count + 1;

    // protocol check: no new ARVALID between an AR handshake and its RLAST
    logic   ar_open = 0;
    integer ar_errors = 0;
    always @(posedge clk) begin
        if (ar_open && arvalid) ar_errors = ar_errors + 1;
        if (arvalid && arready) ar_open = 1;
        if (rvalid && rready && rlast) ar_open = 0;
    end

    initial #2000000 begin
        $display("=== TIMEOUT ===");
        $finish;
    end

    integer errors = 0;

    // random phase: 3 sets x 6 tags x 4 words; 6 tags > 4 ways, so lines get evicted
    localparam int RN_OPS = 2000;
    logic [31:0] model [72];                    // expected value per word slot
    int          rn_bad = 0, rn_reads = 0, rn_writes = 0, rn_hits = 0;

    // k in 0..71 -> tag 1..6, set 5..7 (not touched by the directed part), word 0..3
    function automatic logic [31:0] rn_addr(input int k);
        rn_addr = ((k / 12 + 1) << 10) | ((k / 4 % 3 + 5) << 4) | ((k % 4) << 2);
    endfunction

    task check(input logic ok, input string what);
        if (ok) $display("PASS: %s", what);
        else begin $display("FAIL: %s", what); errors++; end
    endtask

    task cpu_xfer(input logic rw, input logic [31:0] a, input logic [31:0] wd,
                  output logic hit, output logic [31:0] rd);
        begin
            // drive on negedge so it's stable at the next posedge
            @(negedge clk);
            req_valid = 1'b1; req_rw = rw; req_addr = a; req_wdata = wd;
            #1;
            do @(posedge clk); while (!(req_done === 1'b1));
            #1 hit = req_hit; rd = req_rdata;
            req_valid = 1'b0;
            @(negedge clk);
        end
    endtask

    initial begin
        mem.mem[32'h1000>>2] = 32'h1111_1111;
        mem.mem[32'h1004>>2] = 32'h2222_2222;
        mem.mem[32'h1008>>2] = 32'h3333_3333;
        mem.mem[32'h100C>>2] = 32'h4444_4444;
        mem.mem[32'h2000>>2] = 32'hAAAA_AAAA;
        mem.mem[32'h3000>>2] = 32'hCCCC_CCCC;
        mem.mem[32'h1400>>2] = 32'hDDDD_DDDD;
        mem.mem[32'h1800>>2] = 32'hEEEE_EEEE;

        req_valid = 0; req_rw = 0; req_addr = 0; req_wdata = 0;
        #40 rst_n = 1;
        #20;

        // 1-3: miss, hit, write hit (dirty, memory untouched)
        cpu_xfer(0, 32'h0000_1000, 0, hit_out, rd_out);
        check(rd_out === 32'h1111_1111 && hit_out === 1'b0, "read miss refill @0x1000");
        cpu_xfer(0, 32'h0000_1004, 0, hit_out, rd_out);
        check(rd_out === 32'h2222_2222 && hit_out === 1'b1, "read hit @0x1004");
        cpu_xfer(1, 32'h0000_1004, 32'hDEAD_BEEF, hit_out, rd_out);
        check(hit_out === 1'b1, "write hit @0x1004");
        check(mem.mem[32'h1004>>2] === 32'h2222_2222, "memory untouched until eviction");

        // 4: fill ways 1..3 of set 0 - no eviction allowed yet
        cpu_xfer(1, 32'h0000_2000, 32'hBBBB_BBBB, hit_out, rd_out);
        check(hit_out === 1'b0, "write miss @0x2000 allocates");
        cpu_xfer(0, 32'h0000_3000, 0, hit_out, rd_out);
        check(rd_out === 32'hCCCC_CCCC && hit_out === 1'b0, "read miss @0x3000");
        cpu_xfer(0, 32'h0000_1400, 0, hit_out, rd_out);
        check(rd_out === 32'hDDDD_DDDD && hit_out === 1'b0, "read miss @0x1400");
        check(wb_count == 0, "4 lines in a 4-way set: no write-back");
        check(mem.mem[32'h2000>>2] === 32'hAAAA_AAAA, "write-allocated line not written through");

        // 5: all four lines still resident; touching 1..3 makes 0x1000 LRU
        cpu_xfer(0, 32'h0000_2000, 0, hit_out, rd_out);
        check(rd_out === 32'hBBBB_BBBB && hit_out === 1'b1, "store applied to new line @0x2000");
        cpu_xfer(0, 32'h0000_3000, 0, hit_out, rd_out);
        check(hit_out === 1'b1, "hit @0x3000");
        cpu_xfer(0, 32'h0000_1400, 0, hit_out, rd_out);
        check(hit_out === 1'b1, "hit @0x1400");
        cpu_xfer(0, 32'h0000_1008, 0, hit_out, rd_out);   // 0x1000 line, way 0
        check(rd_out === 32'h3333_3333 && hit_out === 1'b1, "hit @0x1008 (all 4 ways resident)");
        cpu_xfer(0, 32'h0000_2000, 0, hit_out, rd_out);
        cpu_xfer(0, 32'h0000_3000, 0, hit_out, rd_out);
        cpu_xfer(0, 32'h0000_1400, 0, hit_out, rd_out);

        // 6: fifth line evicts the pseudo-LRU (dirty) line 0x1000
        cpu_xfer(0, 32'h0000_1800, 0, hit_out, rd_out);
        check(rd_out === 32'hEEEE_EEEE && hit_out === 1'b0, "read miss @0x1800");
        check(wb_count == 1, "exactly one write-back burst");
        check(mem.mem[32'h1004>>2] === 32'hDEAD_BEEF, "dirty line written back @0x1004");
        check(mem.mem[32'h1000>>2] === 32'h1111_1111, "clean words of the victim line preserved");
        cpu_xfer(0, 32'h0000_2000, 0, hit_out, rd_out);
        check(hit_out === 1'b1, "0x2000 survived the eviction");
        cpu_xfer(0, 32'h0000_3000, 0, hit_out, rd_out);
        check(hit_out === 1'b1, "0x3000 survived the eviction");
        cpu_xfer(0, 32'h0000_1400, 0, hit_out, rd_out);
        check(hit_out === 1'b1, "0x1400 survived the eviction");

        // 7: evicted data comes back from memory
        cpu_xfer(0, 32'h0000_1004, 0, hit_out, rd_out);
        check(rd_out === 32'hDEAD_BEEF && hit_out === 1'b0, "re-read evicted line @0x1004 from memory");

        // random reads/writes against a software copy of memory
        begin
            int k, op, wb0;
            logic [31:0] ad, wd;
            for (k = 0; k < 72; k++) begin
                ad = rn_addr(k);
                mem.mem[ad >> 2] = $urandom;
                model[k] = mem.mem[ad >> 2];
            end
            wb0 = wb_count;
            for (int n = 0; n < RN_OPS; n++) begin
                k  = $urandom_range(0, 71);
                ad = rn_addr(k);
                op = $urandom_range(0, 1);
                if (op) begin
                    wd = $urandom;
                    cpu_xfer(1, ad, wd, hit_out, rd_out);
                    model[k] = wd;
                    rn_writes++;
                end else begin
                    cpu_xfer(0, ad, 0, hit_out, rd_out);
                    if (rd_out !== model[k]) begin
                        if (rn_bad < 5) $display("FAIL: random read @%h got %h exp %h", ad, rd_out, model[k]);
                        rn_bad++;
                    end
                    rn_reads++;
                end
                if (hit_out) rn_hits++;
            end
            // read every word back once more
            for (k = 0; k < 72; k++) begin
                ad = rn_addr(k);
                cpu_xfer(0, ad, 0, hit_out, rd_out);
                if (rd_out !== model[k]) begin
                    if (rn_bad < 5) $display("FAIL: final read @%h got %h exp %h", ad, rd_out, model[k]);
                    rn_bad++;
                end
            end
            $display("random phase: %0d reads, %0d writes, %0d hits, %0d write-backs",
                     rn_reads, rn_writes, rn_hits, wb_count - wb0);
            check(rn_bad == 0, "random phase: every read matched the memory model");
        end
        check(ar_errors == 0, "arvalid low while a read burst is outstanding");
        $display("=== CACHE_TEST: %0d error(s) ===", errors);
        $finish;
    end

    logic hit_out;
    logic [31:0] rd_out;

endmodule
