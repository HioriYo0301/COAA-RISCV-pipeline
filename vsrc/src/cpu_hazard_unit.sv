`ifndef __CPU_HAZARD_UNIT_SV
`define __CPU_HAZARD_UNIT_SV

module cpu_hazard_unit(
    input  logic       mem_read_ex,
    input  logic [4:0] rd_ex,
    input  logic [4:0] rs1_id,
    input  logic [4:0] rs2_id,
    output logic       load_use_hazard
);
    assign load_use_hazard = mem_read_ex && (rd_ex != 5'b0) &&
                             ((rd_ex == rs1_id) || (rd_ex == rs2_id));
endmodule

`endif
