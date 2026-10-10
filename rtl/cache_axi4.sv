// cache_axi4: 4-way set-associative write-back cache, AXI4 master
module cache_axi4 #(
    parameter int ADDR_W    = 32,
    parameter int SET_IDX_W = 6,          // 64 sets
    parameter int OFFSET_W  = 4,          // 16-byte lines (4 words)
    parameter int WAYS      = 4
)(
    input  logic clk,
    input  logic rst_n,

    // CPU / core interface
    input  logic              req_valid,
    input  logic              req_rw,          // 1 = write, 0 = read
    input  logic [ADDR_W-1:0] req_addr,
    input  logic [31:0]       req_wdata,
    output logic              req_ready,       // request accepted
    output logic              req_hit,         // hit/miss result
    output logic              req_done,        // transaction completion pulse
    output logic [31:0]       req_rdata,

    // AXI4 master : read address/data
    output logic [3:0]        arid,
    output logic [ADDR_W-1:0] araddr,
    output logic [7:0]        arlen,
    output logic [2:0]        arsize,
    output logic [1:0]        arburst,
    output logic              arvalid,
    input  logic              arready,
    input  logic [ADDR_W-1:0] rdata,
    input  logic              rlast,
    input  logic              rvalid,
    output logic              rready,

    // AXI4 master : write address/data/response
    output logic [3:0]        awid,
    output logic [ADDR_W-1:0] awaddr,
    output logic [7:0]        awlen,
    output logic [2:0]        awsize,
    output logic [1:0]        awburst,
    output logic              awvalid,
    input  logic              awready,
    output logic [31:0]       wdata,
    output logic [3:0]        wstrb,
    output logic              wlast,
    output logic              wvalid,
    input  logic              wready,
    input  logic              bvalid,
    output logic              bready
);

    // derived parameters
    localparam int LINE_WORDS = 1 << (OFFSET_W - 2);   // words per 16-byte line
    localparam int SETS       = 1 << SET_IDX_W;
    localparam int TAG_W      = ADDR_W - SET_IDX_W - OFFSET_W;

    // address decode
    logic [TAG_W-1:0]     tag_in;
    logic [SET_IDX_W-1:0] idx_in;
    logic [OFFSET_W-1:0]  off_in;
    assign tag_in = req_addr[ADDR_W-1 -: TAG_W];
    assign idx_in = req_addr[SET_IDX_W+OFFSET_W-1 -: SET_IDX_W];
    assign off_in = req_addr[OFFSET_W-1 -: OFFSET_W];
    logic [OFFSET_W-3:0]  offw;                 // word index within the line
    assign offw = off_in[OFFSET_W-1:2];

    // tag / data / lru arrays
    logic              valid_m [SETS-1:0][WAYS-1:0];
    logic              dirty_m [SETS-1:0][WAYS-1:0];
    logic [TAG_W-1:0]  tag_m   [SETS-1:0][WAYS-1:0];
    logic [31:0]       data_m  [SETS-1:0][WAYS-1:0][LINE_WORDS-1:0];
    logic [WAYS-2:0]   lru_m   [SETS-1:0];   // 3 bits per set (4 ways)

    // request capture
    logic [ADDR_W-1:0]  req_addr_q;
    logic [31:0]        req_wdata_q;
    logic               req_rw_q;
    logic [TAG_W-1:0]   line_tag_q;
    logic [SET_IDX_W-1:0] line_idx_q;
    logic [2:0]         off_q;
    logic [2:0]         victim_q;
    logic               victim_dirty_q;
    logic [TAG_W-1:0]   victim_tag_q;
    logic               ev_aw_done;    // AW handshake completed this eviction
    logic               req_pending;   // a request has been accepted, result not yet returned
    logic               req_hit_q;     // registered hit/miss result
    logic [31:0]        req_rdata_q;   // registered read data

    // line buffer + burst counters
    logic [31:0]        line_buf [LINE_WORDS-1:0];
    logic [3:0]         wr_cnt;    // write-burst word counter
    logic [3:0]         rd_cnt;    // read-burst word counter

    // FSM
    typedef enum logic [2:0] {
        S_IDLE   = 3'd0,
        S_EVICT  = 3'd1,
        S_REFILL = 3'd2,
        S_COMMIT = 3'd3,
        S_DONE   = 3'd4
    } state_t;
    state_t state, nstate;

    // combinational decode of the request
    logic [WAYS-1:0] way_hit;
    logic            any_hit;
    logic [2:0]      hit_way;

    always_comb begin
        way_hit = '0; any_hit = 1'b0; hit_way = 3'd0;
        for (int i = 0; i < WAYS; i = i + 1) begin
            if (valid_m[idx_in][i] && (tag_m[idx_in][i] == tag_in)) begin
                way_hit[i] = 1'b1; any_hit = 1'b1; hit_way = i;
            end
        end
    end

    // decode of the LATCHED request (used for side-effects)
    logic [TAG_W-1:0]     tag_q;
    logic [SET_IDX_W-1:0] idx_q;
    logic [2:0]           off_qw;
    logic                 any_hit_q;
    logic [2:0]           hit_way_q;
    assign tag_q   = req_addr_q[ADDR_W-1 -: TAG_W];
    assign idx_q   = req_addr_q[SET_IDX_W+OFFSET_W-1 -: SET_IDX_W];
    assign off_qw  = req_addr_q[OFFSET_W-1:2];

    always_comb begin
        any_hit_q = 1'b0; hit_way_q = 3'd0;
        for (int i = 0; i < WAYS; i = i + 1) begin
            if (valid_m[idx_q][i] && (tag_m[idx_q][i] == tag_q)) begin
                any_hit_q = 1'b1; hit_way_q = i;
            end
        end
    end

    // victim: first invalid way, else tree PLRU
    // lru[1] root (0: ways 0/1, 1: ways 2/3), lru[0] picks 0/1, lru[2] picks 2/3
    logic [2:0]      victim;
    logic [WAYS-2:0] lru_bits;
    assign lru_bits = lru_m[idx_in];
    always_comb begin
        if (!lru_bits[1])
            victim = lru_bits[0] ? 3'd1 : 3'd0;
        else
            victim = lru_bits[2] ? 3'd3 : 3'd2;
        for (int i = WAYS-1; i >= 0; i = i - 1)
            if (!valid_m[idx_in][i]) victim = i;    // lowest invalid way wins
    end

    // LRU update: point the tree AWAY from the used way
    function automatic [2:0] lru_new(input logic [2:0] bits, input logic [2:0] way);
        begin
            lru_new = bits;
            case (way)
                3'd0: begin lru_new[1] = 1'b1; lru_new[0] = 1'b1; end
                3'd1: begin lru_new[1] = 1'b1; lru_new[0] = 1'b0; end
                3'd2: begin lru_new[1] = 1'b0; lru_new[2] = 1'b1; end
                3'd3: begin lru_new[1] = 1'b0; lru_new[2] = 1'b0; end
            endcase
        end
    endfunction

    // STATE MACHINE (outputs + next state)
    logic lru_update;
    logic [SET_IDX_W-1:0] lru_idx;
    logic [2:0]  lru_wd;

    always_comb begin
        // defaults
        nstate    = S_IDLE;
        req_ready = 1'b0;
        lru_update = 1'b0; lru_idx = idx_in; lru_wd = hit_way;

        arid = 4'd0; araddr = '0; arlen = 8'd0; arsize = 3'b010; arburst = 2'b01;
        arvalid = 1'b0; rready = 1'b0;
        awid = 4'd0; awaddr = '0; awlen = 8'd0; awsize = 3'b010; awburst = 2'b01;
        awvalid = 1'b0; wdata = 32'd0; wstrb = 4'h0; wlast = 1'b0; wvalid = 1'b0;
        bready = 1'b0;

        case (state)
            // IDLE : accept the request
            S_IDLE: begin
                if (req_valid && !req_pending) begin
                    // accept: latch the request, evaluate it next cycle
                    req_ready = 1'b1;
                    nstate    = S_IDLE;
                end
                else if (req_pending) begin
                    // evaluate the LATCHED request (stable, race-free)
                    if (any_hit_q) begin
                        lru_update = 1'b1;
                        lru_idx    = idx_q;
                        lru_wd     = hit_way_q;
                        nstate = S_DONE;      // hit: complete, report done next
                    end
                    else begin
                        nstate = S_EVICT;    // miss : evict victim (maybe WB)
                    end
                end
            end

            // EVICT : write-back dirty victim
            S_EVICT: begin
                if (!victim_dirty_q) begin
                    nstate = S_REFILL;      // clean victim : straight to refill
                end else begin
                    // writeback target = victim's line address
                    awaddr  = {victim_tag_q, line_idx_q, {OFFSET_W{1'b0}}};
                    awlen   = LINE_WORDS-1;
                    awsize  = 3'b010;
                    awburst = 2'b01;
                    awvalid = !ev_aw_done;       // AW first, W one cycle later
                    wdata   = data_m[line_idx_q][victim_q][wr_cnt];
                    wstrb   = 4'hF;
                    wlast   = (wr_cnt == LINE_WORDS-1);
                    wvalid  = ev_aw_done;
                    bready  = 1'b1;
                    // after the burst completes and the B response returns
                    if (wvalid && wready && wlast && bvalid && bready)
                        nstate = S_REFILL;
                    else
                        nstate = S_EVICT;
                end
            end

            // REFILL : AXI read burst
            S_REFILL: begin
                araddr  = ~{OFFSET_W{1'b1}} & req_addr_q;
                arlen   = LINE_WORDS-1;
                arsize  = 3'b010;
                arburst = 2'b01;
                arvalid = 1'b1;
                rready  = 1'b1;
                if (rvalid && rready && rlast)
                    nstate = S_COMMIT;
                else
                    nstate = S_REFILL;
            end

            // COMMIT : install the line
            S_COMMIT: begin
                lru_update = 1'b1;           // newly installed line is MRU
                lru_idx    = line_idx_q;
                lru_wd     = victim_q;
                nstate     = S_DONE;
            end

            // DONE : report completion, then accept next
            S_DONE: begin
                nstate = S_IDLE;
            end
            default: nstate = S_IDLE;
        endcase
    end

    // SEQUENTIAL SIDE EFFECTS

    // FSM register
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= S_IDLE;
        else
            state <= nstate;
    end

    // request capture + hit side-effects (one atomic accept edge)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            req_addr_q  <= '0;
            req_wdata_q <= 32'd0;
            req_rw_q    <= 1'b0;
            line_tag_q  <= '0;
            line_idx_q  <= '0;
            off_q       <= 3'd0;
            victim_q    <= 3'd0;
            victim_dirty_q <= 1'b0;
            victim_tag_q <= '0;
        end
        else if (req_valid && (state == S_IDLE) && !req_pending) begin
            // latch the accepted request (valid for both hits and misses)
            req_addr_q    <= req_addr;
            req_wdata_q   <= req_wdata;
            req_rw_q      <= req_rw;
            line_tag_q    <= tag_in;
            line_idx_q    <= idx_in;
            off_q         <= offw;
            victim_q      <= victim;
            victim_dirty_q<= dirty_m[idx_in][victim];
            victim_tag_q  <= tag_m[idx_in][victim];
        end
    end

    // request slot + registered results; separate DONE cycle so a request
    // that is still held high isn't accepted twice
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            req_pending  <= 1'b0;
            req_hit_q    <= 1'b0;
            req_rdata_q  <= 32'd0;
        end
        else begin
            if (req_valid && (state == S_IDLE) && !req_pending) begin
                // accept a new request
                req_pending <= 1'b1;
            end
            else if (req_pending && (state == S_IDLE) && any_hit_q) begin
                // hit: latch the result (read data) now; result reported in S_DONE
                req_hit_q <= 1'b1;
                if (!req_rw_q)
                    req_rdata_q <= data_m[idx_q][hit_way_q][off_qw];
            end
            else if (state == S_COMMIT) begin
                // miss: latch the refilled line result
                req_hit_q <= 1'b0;
                if (!req_rw_q)
                    req_rdata_q <= line_buf[off_q];
            end
            else if (state == S_DONE) begin
                // release the request slot
                req_pending <= 1'b0;
            end
        end
    end

    assign req_hit  = req_hit_q;
    assign req_done = (state == S_DONE);
    assign req_rdata = req_rdata_q;

    // tag/data array writes: write-hit merge, line install, victim dirty-clear.
    // One always_ff drives every array so each has a single driver.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int s = 0; s < SETS; s++)
                for (int w = 0; w < WAYS; w++) begin
                    valid_m[s][w] <= 1'b0;
                    dirty_m[s][w] <= 1'b0;
                    tag_m[s][w]   <= '0;
                    for (int b = 0; b < LINE_WORDS; b++)
                        data_m[s][w][b] <= 32'd0;
                end
        end
        else if (req_pending && (state == S_IDLE)) begin
            // write hit: merge the store from the LATCHED request (race-free)
            if (any_hit_q && req_rw_q) begin
                data_m[idx_q][hit_way_q][off_qw] <= req_wdata_q;
                dirty_m[idx_q][hit_way_q]          <= 1'b1;
            end
        end
        else if (state == S_COMMIT) begin
            // install refilled line (write-allocate)
            valid_m[line_idx_q][victim_q]      <= 1'b1;
            dirty_m[line_idx_q][victim_q]      <= req_rw_q;   // pending store stays dirty
            tag_m[line_idx_q][victim_q]        <= line_tag_q;
            for (int b = 0; b < LINE_WORDS; b++)
                data_m[line_idx_q][victim_q][b] <= line_buf[b];
            // apply the pending store within the new line (write miss only)
            if (req_rw_q)
                data_m[line_idx_q][victim_q][off_q] <= req_wdata_q;
        end
        else if (state == S_REFILL && rvalid && rready && rlast) begin
            // clear the victim dirty flag once it has been written back
            if (victim_dirty_q)
                dirty_m[line_idx_q][victim_q] <= 1'b0;
        end
    end

    // line buffer capture during refill
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_cnt <= 4'd0;
            for (int i = 0; i < LINE_WORDS; i++) line_buf[i] <= 32'd0;
        end
        else if (state == S_REFILL) begin
            if (rvalid && rready) begin
                line_buf[rd_cnt] <= rdata;
                rd_cnt <= rd_cnt + 1;
            end
        end
        else begin
            rd_cnt <= 4'd0;
        end
    end

    // write-burst counter
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_cnt <= 4'd0;
        end
        else if (state == S_EVICT && victim_dirty_q) begin
            if (wvalid && wready) wr_cnt <= wr_cnt + 1;
        end
        else begin
            wr_cnt <= 4'd0;
        end
    end

    // AW handshake tracking: W data must be delayed one cycle after AWVALID
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ev_aw_done <= 1'b0;
        end
        else if (state == S_EVICT && victim_dirty_q) begin
            if (awvalid && awready) ev_aw_done <= 1'b1;
        end
        else begin
            ev_aw_done <= 1'b0;
        end
    end

    // LRU update
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int s = 0; s < SETS; s++) lru_m[s] <= 3'b000;
        end
        else if (lru_update) begin
            lru_m[lru_idx] <= lru_new(lru_m[lru_idx], lru_wd);
        end
    end

endmodule