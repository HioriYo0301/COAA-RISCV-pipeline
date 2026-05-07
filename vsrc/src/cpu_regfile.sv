`ifndef __CPU_REGFILE_SV
`define __CPU_REGFILE_SV

module cpu_regfile(
    input  logic              clk,
    input  logic              reset,
    input  logic              wen,
    input  logic [4:0]        waddr,
    input  logic [63:0]       wdata,
    input  logic [4:0]        raddr1,
    input  logic [4:0]        raddr2,
    output logic [63:0]       rdata1,
    output logic [63:0]       rdata2,
    output logic [31:0][63:0] regs_dbg
);
    always_ff @(posedge clk) begin
        if (reset) begin
            for (int i = 0; i < 32; i++) begin
                regs_dbg[i] <= 64'b0;
            end
        end else if (wen && waddr != 5'b0) begin
            regs_dbg[waddr] <= wdata;
        end
    end

    always_comb begin
        rdata1 = (raddr1 == 5'b0) ? 64'b0 : regs_dbg[raddr1];
        rdata2 = (raddr2 == 5'b0) ? 64'b0 : regs_dbg[raddr2];
    end
endmodule

`endif
