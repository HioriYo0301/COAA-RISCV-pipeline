`ifndef __CPU_DECODE_SV
`define __CPU_DECODE_SV

module cpu_decode import common::*;(
    input  logic [31:0] instr,
    output decode_out_t decode_out
);
    logic [6:0] opcode;

    function automatic logic [63:0] imm_i(input logic [31:0] x);
        imm_i = {{52{x[31]}}, x[31:20]};
    endfunction

    function automatic logic [63:0] imm_s(input logic [31:0] x);
        imm_s = {{52{x[31]}}, x[31:25], x[11:7]};
    endfunction

    function automatic logic [63:0] imm_b(input logic [31:0] x);
        imm_b = {{52{x[31]}}, x[7], x[30:25], x[11:8], 1'b0};
    endfunction

    function automatic logic [63:0] imm_u(input logic [31:0] x);
        imm_u = {{32{x[31]}}, x[31:12], 12'b0};
    endfunction

    function automatic logic [63:0] imm_j(input logic [31:0] x);
        imm_j = {{44{x[31]}}, x[19:12], x[20], x[30:21], 1'b0};
    endfunction

    always_comb begin
        opcode = instr[6:0];

        decode_out = '0;
        decode_out.rd     = instr[11:7];
        decode_out.rs1    = instr[19:15];
        decode_out.rs2    = instr[24:20];
        decode_out.funct3 = instr[14:12];
        decode_out.funct7 = instr[31:25];
        decode_out.alu_op = ALU_ADD;
        decode_out.wb_sel = WB_ALU;

        unique case (opcode)
            7'b0010011, 7'b0000011, 7'b1100111, 7'b0011011: decode_out.imm = imm_i(instr);
            7'b0100011: decode_out.imm = imm_s(instr);
            7'b1100011: decode_out.imm = imm_b(instr);
            7'b0110111, 7'b0010111: decode_out.imm = imm_u(instr);
            7'b1101111: decode_out.imm = imm_j(instr);
            default: decode_out.imm = 64'b0;
        endcase

        unique case (opcode)
            // OP-IMM
            7'b0010011: begin
                decode_out.reg_write = 1'b1;
                decode_out.alu_src   = 1'b1;
                unique case (decode_out.funct3)
                    3'b000: decode_out.alu_op = ALU_ADD;
                    3'b001: decode_out.alu_op = ALU_SLL;
                    3'b010: decode_out.alu_op = ALU_SLT;
                    3'b011: decode_out.alu_op = ALU_SLTU;
                    3'b100: decode_out.alu_op = ALU_XOR;
                    3'b101: decode_out.alu_op = decode_out.funct7[5] ? ALU_SRA : ALU_SRL;
                    3'b110: decode_out.alu_op = ALU_OR;
                    3'b111: decode_out.alu_op = ALU_AND;
                    default: decode_out.alu_op = ALU_ADD;
                endcase
            end

            // OP-IMM-32
            7'b0011011: begin
                decode_out.reg_write = 1'b1;
                decode_out.alu_src   = 1'b1;
                unique case (decode_out.funct3)
                    3'b000: decode_out.alu_op = ALU_ADDW;
                    3'b001: decode_out.alu_op = ALU_SLLW;
                    3'b101: decode_out.alu_op = decode_out.funct7[5] ? ALU_SRAW : ALU_SRLW;
                    default: decode_out.alu_op = ALU_ADDW;
                endcase
            end

            // LOAD
            7'b0000011: begin
                decode_out.reg_write = 1'b1;
                decode_out.alu_src   = 1'b1;
                decode_out.mem_read  = 1'b1;
                decode_out.wb_sel    = WB_MEM;
                decode_out.alu_op    = ALU_ADD;
            end

            // STORE
            7'b0100011: begin
                decode_out.alu_src   = 1'b1;
                decode_out.mem_write = 1'b1;
                decode_out.alu_op    = ALU_ADD;
            end

            // OP
            7'b0110011: begin
                decode_out.reg_write = 1'b1;
                unique case (decode_out.funct3)
                    3'b000: decode_out.alu_op = decode_out.funct7[5] ? ALU_SUB : ALU_ADD;
                    3'b001: decode_out.alu_op = ALU_SLL;
                    3'b010: decode_out.alu_op = ALU_SLT;
                    3'b011: decode_out.alu_op = ALU_SLTU;
                    3'b100: decode_out.alu_op = ALU_XOR;
                    3'b101: decode_out.alu_op = decode_out.funct7[5] ? ALU_SRA : ALU_SRL;
                    3'b110: decode_out.alu_op = ALU_OR;
                    3'b111: decode_out.alu_op = ALU_AND;
                    default: decode_out.alu_op = ALU_ADD;
                endcase
            end

            // OP-32
            7'b0111011: begin
                decode_out.reg_write = 1'b1;
                unique case (decode_out.funct3)
                    3'b000: decode_out.alu_op = decode_out.funct7[5] ? ALU_SUBW : ALU_ADDW;
                    3'b001: decode_out.alu_op = ALU_SLLW;
                    3'b101: decode_out.alu_op = decode_out.funct7[5] ? ALU_SRAW : ALU_SRLW;
                    default: decode_out.alu_op = ALU_ADDW;
                endcase
            end

            // LUI
            7'b0110111: begin
                decode_out.reg_write = 1'b1;
                decode_out.rs1       = 5'b0;
                decode_out.alu_src   = 1'b1;
                decode_out.alu_op    = ALU_ADD;
            end

            // AUIPC
            7'b0010111: begin
                decode_out.reg_write = 1'b1;
                decode_out.use_pc    = 1'b1;
                decode_out.alu_src   = 1'b1;
                decode_out.alu_op    = ALU_ADD;
            end

            // BRANCH
            7'b1100011: begin
                decode_out.is_branch = 1'b1;
            end

            // JAL
            7'b1101111: begin
                decode_out.reg_write = 1'b1;
                decode_out.is_jump   = 1'b1;
                decode_out.wb_sel    = WB_PC4;
            end

            // JALR
            7'b1100111: begin
                decode_out.reg_write = 1'b1;
                decode_out.is_jump   = 1'b1;
                decode_out.is_jalr   = 1'b1;
                decode_out.wb_sel    = WB_PC4;
            end

            default: begin
            end
        endcase
    end
endmodule

`endif
