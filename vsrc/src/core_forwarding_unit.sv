`ifndef __CORE_FORWARDING_UNIT_SV
`define __CORE_FORWARDING_UNIT_SV

module core_forwarding_unit(
    input  logic [4:0]  rs1_ex,
    input  logic [4:0]  rs2_ex,
    input  logic [63:0] rs1_data_ex,
    input  logic [63:0] rs2_data_ex,
    input  logic        reg_write_mem,
    input  logic [4:0]  rd_mem,
    input  logic [63:0] forward_data_mem,
    input  logic        reg_write_wb,
    input  logic [4:0]  rd_wb,
    input  logic [63:0] wb_data,
    output logic [63:0] op_a_forwarded,
    output logic [63:0] rs2_forwarded
);
    always_comb begin
        op_a_forwarded = rs1_data_ex;
        if (reg_write_mem && rd_mem != 5'b0 && rd_mem == rs1_ex) begin
            op_a_forwarded = forward_data_mem;
        end else if (reg_write_wb && rd_wb != 5'b0 && rd_wb == rs1_ex) begin
            op_a_forwarded = wb_data;
        end
    end

    always_comb begin
        rs2_forwarded = rs2_data_ex;
        if (reg_write_mem && rd_mem != 5'b0 && rd_mem == rs2_ex) begin
            rs2_forwarded = forward_data_mem;
        end else if (reg_write_wb && rd_wb != 5'b0 && rd_wb == rs2_ex) begin
            rs2_forwarded = wb_data;
        end
    end
endmodule

`endif
