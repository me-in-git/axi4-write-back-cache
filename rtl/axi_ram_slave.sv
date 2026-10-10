// axi_ram_slave: AXI4 slave memory model (simulation only)
module axi_ram_slave #(
    parameter int DEPTH_WORDS = 4096
)(
    input  logic clk,
    input  logic rst_n,

    // read address channel
    input  logic [3:0]        arid,
    input  logic [31:0]       araddr,
    input  logic [7:0]        arlen,
    input  logic [2:0]        arsize,
    input  logic [1:0]        arburst,
    input  logic              arvalid,
    output logic              arready,

    // read data channel
    output logic [31:0]       rdata,
    output logic              rlast,
    output logic              rvalid,
    input  logic              rready,

    // write address channel
    input  logic [3:0]        awid,
    input  logic [31:0]       awaddr,
    input  logic [7:0]        awlen,
    input  logic [2:0]        awsize,
    input  logic [1:0]        awburst,
    input  logic              awvalid,
    output logic              awready,

    // write data channel
    input  logic [31:0]       wdata,
    input  logic [3:0]        wstrb,
    input  logic              wlast,
    input  logic              wvalid,
    output logic              wready,

    // write response channel
    output logic [1:0]        bresp,
    output logic              bvalid,
    input  logic              bready
);

    logic [31:0] mem [DEPTH_WORDS-1:0];

    // read burst
    logic [31:0] r_addr_q;
    logic [7:0]  r_len_q;
    logic [7:0]  r_cnt;
    logic        r_active;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_addr_q <= '0; r_len_q <= 8'd0; r_cnt <= 8'd0; r_active <= 1'b0;
        end
        else if (!r_active && arvalid && arready) begin
            r_addr_q <= araddr;
            r_len_q  <= arlen;
            r_cnt    <= 8'd0;
            r_active <= 1'b1;
        end
        else if (r_active && rvalid && rready) begin
            if (r_cnt == r_len_q) begin
                r_active <= 1'b0;
            end else begin
                r_cnt <= r_cnt + 8'd1;
            end
        end
    end

    assign arready = !r_active;
    assign rvalid  = r_active;
    assign rlast   = r_active && (r_cnt == r_len_q);
    assign rdata   = mem[r_addr_q[31:2] + r_cnt];

    // write burst
    logic [31:0] w_addr_q;
    logic [7:0]  w_len_q;
    logic [7:0]  w_cnt;
    logic        w_active;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_addr_q <= '0; w_len_q <= 8'd0; w_cnt <= 8'd0; w_active <= 1'b0;
        end
        else if (!w_active && awvalid && awready) begin
            w_addr_q <= awaddr;
            w_len_q  <= awlen;
            w_cnt    <= 8'd0;
            w_active <= 1'b1;
        end
        else if (w_active && wvalid && wready) begin
            if (w_cnt == w_len_q) begin
                w_active <= 1'b0;
            end else begin
                w_cnt <= w_cnt + 8'd1;
            end
        end
    end

    // write data into memory (full-word writes; cache drives wstrb=0xF)
    always_ff @(posedge clk) begin
        if (w_active && wvalid && wready)
            mem[w_addr_q[31:2] + w_cnt] <= wdata;
    end

    assign awready = !w_active;
    assign wready  = 1'b1;
    assign bresp   = 2'b00;
    assign bvalid  = w_active && (w_cnt == w_len_q);

endmodule