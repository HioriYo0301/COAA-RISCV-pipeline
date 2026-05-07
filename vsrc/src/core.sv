`ifndef __CORE_SV
`define __CORE_SV

`ifdef VERILATOR
`include "include/common.sv"
`include "src/cpu_decode.sv"
`include "src/cpu_alu.sv"
`include "src/cpu_regfile.sv"
`include "src/cpu_hazard_unit.sv"
`include "src/cpu_forwarding_unit.sv"
`endif

module core import common::*;(
    input  logic       clk,
    input  logic       reset,
    output ibus_req_t  ireq,
    input  ibus_resp_t iresp,
    output dbus_req_t  dreq,
    input  dbus_resp_t dresp,
    input  logic       trint,
    input  logic       swint,
    input  logic       exint
);
    localparam logic [31:0] TRAP_INST = 32'h0005006b;

    function automatic msize_t mem_size_from_funct3(input logic [2:0] funct3);
        unique case (funct3)
            3'b000, 3'b100: mem_size_from_funct3 = MSIZE1;
            3'b001, 3'b101: mem_size_from_funct3 = MSIZE2;
            3'b010, 3'b110: mem_size_from_funct3 = MSIZE4;
            default:        mem_size_from_funct3 = MSIZE8;
        endcase
    endfunction

    function automatic strobe_t store_strobe_from_funct3(
        input logic [2:0] funct3,
        input logic [2:0] addr_low
    );
        unique case (funct3)
            3'b000:  store_strobe_from_funct3 = 8'b0000_0001 << addr_low;
            3'b001:  store_strobe_from_funct3 = 8'b0000_0011 << addr_low;
            3'b010:  store_strobe_from_funct3 = 8'b0000_1111 << addr_low;
            default: store_strobe_from_funct3 = 8'b1111_1111;
        endcase
    endfunction

    function automatic logic [63:0] align_store_data(
        input logic [63:0] store_data,
        input logic [2:0]  addr_low
    );
        align_store_data = store_data << {addr_low, 3'b0};
    endfunction

    function automatic logic [63:0] extend_load_data(
        input logic [63:0] raw_data,
        input logic [2:0]  addr_low,
        input logic [2:0]  funct3
    );
        logic [63:0] shifted_data;
        begin
            shifted_data = raw_data >> {addr_low, 3'b0};
            unique case (funct3)
                3'b000:  extend_load_data = {{56{shifted_data[7]}}, shifted_data[7:0]};
                3'b001:  extend_load_data = {{48{shifted_data[15]}}, shifted_data[15:0]};
                3'b010:  extend_load_data = {{32{shifted_data[31]}}, shifted_data[31:0]};
                3'b011:  extend_load_data = shifted_data;
                3'b100:  extend_load_data = {56'b0, shifted_data[7:0]};
                3'b101:  extend_load_data = {48'b0, shifted_data[15:0]};
                3'b110:  extend_load_data = {32'b0, shifted_data[31:0]};
                default: extend_load_data = shifted_data;
            endcase
        end
    endfunction

    // ------------------------------------------------------------
    // Architectural state and commit bookkeeping
    // ------------------------------------------------------------
    logic [63:0] wb_data;
    logic        reg_write_wb;
    logic        reg_write_wb_fire;
    logic        wb_fired;
    logic [4:0]  rd_wb;
    logic [31:0][63:0] rf_dbg;
    logic [63:0] cycle_cnt;
    logic [63:0] instr_cnt;
    logic        trap_valid_wb;
    logic        is_trap_wb;
    logic [7:0]  trap_code_wb;

    // ------------------------------------------------------------
    // Program counter and global control
    // ------------------------------------------------------------
    logic [63:0] pc;
    logic [63:0] next_pc;
    logic        stall;
    logic        fetch_wait;
    logic        mem_wait;
    logic        mem_access_mem;
    logic        redirect_valid_ex;
    logic        redirect_fire_ex;
    logic [63:0] redirect_target_ex;

    assign next_pc = redirect_fire_ex ? redirect_target_ex : (pc + 64'd4);

    always_ff @(posedge clk) begin
        if (reset) begin
            pc <= PCINIT;
        end else if (redirect_fire_ex || !stall) begin
            pc <= next_pc;
        end
    end

    // ------------------------------------------------------------
    // IF stage
    // ------------------------------------------------------------
    logic [63:0] pc_id;
    logic [31:0] instr_id;
    logic        inst_valid_id;

    assign ireq.valid = ~load_use_hazard && !mem_access_mem;
    assign ireq.addr  = pc;

    always_ff @(posedge clk) begin
        if (reset || redirect_fire_ex) begin
            pc_id        <= 64'b0;
            instr_id     <= 32'b0;
            inst_valid_id <= 1'b0;
        end else if (!stall) begin
            pc_id        <= pc;
            instr_id     <= iresp.data;
            inst_valid_id <= iresp.data_ok;
        end
    end

    // ------------------------------------------------------------
    // Decode / register file
    // ------------------------------------------------------------
    decode_out_t decode_id;
    logic [4:0]  rd_id;
    logic [4:0]  rs1_id;
    logic [4:0]  rs2_id;
    logic [2:0]  funct3_id;
    logic [6:0]  funct7_id;
    logic [63:0] imm_id;
    alu_op_t     alu_op_id;
    logic        alu_src_id;
    logic        use_pc_id;
    logic        is_branch_id;
    logic        is_jump_id;
    logic        is_jalr_id;
    logic        mem_read_id;
    logic        mem_write_id;
    logic        reg_write_id;
    wb_sel_t     wb_sel_id;
    logic [63:0] rs1_data_id_r;
    logic [63:0] rs2_data_id_r;

    cpu_decode u_decode (
        .instr     (instr_id),
        .decode_out(decode_id)
    );

    assign rd_id        = decode_id.rd;
    assign rs1_id       = decode_id.rs1;
    assign rs2_id       = decode_id.rs2;
    assign funct3_id    = decode_id.funct3;
    assign funct7_id    = decode_id.funct7;
    assign imm_id       = decode_id.imm;
    assign alu_op_id    = decode_id.alu_op;
    assign alu_src_id   = decode_id.alu_src;
    assign use_pc_id    = decode_id.use_pc;
    assign is_branch_id = decode_id.is_branch;
    assign is_jump_id   = decode_id.is_jump;
    assign is_jalr_id   = decode_id.is_jalr;
    assign mem_read_id  = decode_id.mem_read;
    assign mem_write_id = decode_id.mem_write;
    assign reg_write_id = decode_id.reg_write;
    assign wb_sel_id    = decode_id.wb_sel;

    cpu_regfile u_regfile (
        .clk      (clk),
        .reset    (reset),
        .wen      (reg_write_wb_fire),
        .waddr    (rd_wb),
        .wdata    (wb_data),
        .raddr1   (rs1_id),
        .raddr2   (rs2_id),
        .rdata1   (rs1_data_id_r),
        .rdata2   (rs2_data_id_r),
        .regs_dbg (rf_dbg)
    );

    // ------------------------------------------------------------
    // ID/EX pipeline register
    // ------------------------------------------------------------
    logic [63:0] pc_ex;
    logic [63:0] rs1_data_ex;
    logic [63:0] rs2_data_ex;
    logic [63:0] imm_ex;
    logic [31:0] instr_ex;
    logic [4:0]  rd_ex;
    logic [4:0]  rs1_ex;
    logic [4:0]  rs2_ex;
    logic [2:0]  funct3_ex;
    logic [6:0]  funct7_ex;
    alu_op_t     alu_op_ex;
    logic        alu_src_ex;
    logic        use_pc_ex;
    logic        is_branch_ex;
    logic        is_jump_ex;
    logic        is_jalr_ex;
    logic        inst_valid_ex;
    logic        mem_read_ex;
    logic        mem_write_ex;
    logic        reg_write_ex;
    wb_sel_t     wb_sel_ex;

    always_ff @(posedge clk) begin
        if (reset || redirect_fire_ex) begin
            pc_ex         <= 64'b0;
            rs1_data_ex   <= 64'b0;
            rs2_data_ex   <= 64'b0;
            imm_ex        <= 64'b0;
            instr_ex      <= 32'b0;
            rd_ex         <= 5'b0;
            rs1_ex        <= 5'b0;
            rs2_ex        <= 5'b0;
            funct3_ex     <= 3'b0;
            funct7_ex     <= 7'b0;
            alu_op_ex     <= ALU_ADD;
            alu_src_ex    <= 1'b0;
            use_pc_ex     <= 1'b0;
            is_branch_ex  <= 1'b0;
            is_jump_ex    <= 1'b0;
            is_jalr_ex    <= 1'b0;
            inst_valid_ex <= 1'b0;
            mem_read_ex   <= 1'b0;
            mem_write_ex  <= 1'b0;
            reg_write_ex  <= 1'b0;
            wb_sel_ex     <= WB_ALU;
        end else if ((load_use_hazard && !mem_wait && !fetch_wait) || (mem_access_mem && !mem_wait && !fetch_wait)) begin
            pc_ex         <= 64'b0;
            rs1_data_ex   <= 64'b0;
            rs2_data_ex   <= 64'b0;
            imm_ex        <= 64'b0;
            instr_ex      <= 32'b0;
            rd_ex         <= 5'b0;
            rs1_ex        <= 5'b0;
            rs2_ex        <= 5'b0;
            funct3_ex     <= 3'b0;
            funct7_ex     <= 7'b0;
            alu_op_ex     <= ALU_ADD;
            alu_src_ex    <= 1'b0;
            use_pc_ex     <= 1'b0;
            is_branch_ex  <= 1'b0;
            is_jump_ex    <= 1'b0;
            is_jalr_ex    <= 1'b0;
            inst_valid_ex <= 1'b0;
            mem_read_ex   <= 1'b0;
            mem_write_ex  <= 1'b0;
            reg_write_ex  <= 1'b0;
            wb_sel_ex     <= WB_ALU;
        end else if (!stall) begin
            pc_ex         <= pc_id;
            rs1_data_ex   <= rs1_data_id_r;
            rs2_data_ex   <= rs2_data_id_r;
            imm_ex        <= imm_id;
            instr_ex      <= instr_id;
            rd_ex         <= rd_id;
            rs1_ex        <= rs1_id;
            rs2_ex        <= rs2_id;
            funct3_ex     <= funct3_id;
            funct7_ex     <= funct7_id;
            alu_op_ex     <= alu_op_id;
            alu_src_ex    <= alu_src_id;
            use_pc_ex     <= use_pc_id;
            is_branch_ex  <= is_branch_id;
            is_jump_ex    <= is_jump_id;
            is_jalr_ex    <= is_jalr_id;
            inst_valid_ex <= inst_valid_id;
            mem_read_ex   <= mem_read_id;
            mem_write_ex  <= mem_write_id;
            reg_write_ex  <= reg_write_id;
            wb_sel_ex     <= wb_sel_id;
        end
    end

    // ------------------------------------------------------------
    // Hazard / forwarding / ALU
    // ------------------------------------------------------------
    logic load_use_hazard;
    logic [63:0] rs1_forwarded_ex;
    logic [63:0] rs2_forwarded_ex;
    logic [63:0] forward_data_mem;
    logic [63:0] alu_in_a_ex;
    logic [63:0] alu_in_b_ex;
    logic [63:0] alu_result_ex;
    logic        branch_taken_ex;

    cpu_hazard_unit u_hazard (
        .mem_read_ex     (mem_read_ex),
        .rd_ex           (rd_ex),
        .rs1_id          (rs1_id),
        .rs2_id          (rs2_id),
        .load_use_hazard (load_use_hazard)
    );

    cpu_forwarding_unit u_forward (
        .rs1_ex           (rs1_ex),
        .rs2_ex           (rs2_ex),
        .rs1_data_ex      (rs1_data_ex),
        .rs2_data_ex      (rs2_data_ex),
        .reg_write_mem    (reg_write_mem),
        .rd_mem           (rd_mem),
        .forward_data_mem  (forward_data_mem),
        .reg_write_wb     (reg_write_wb),
        .rd_wb            (rd_wb),
        .wb_data          (wb_data),
        .op_a_forwarded   (rs1_forwarded_ex),
        .rs2_forwarded    (rs2_forwarded_ex)
    );

    assign alu_in_a_ex = use_pc_ex ? pc_ex : rs1_forwarded_ex;
    assign alu_in_b_ex = alu_src_ex ? imm_ex : rs2_forwarded_ex;

    cpu_alu u_alu (
        .alu_op (alu_op_ex),
        .op_a   (alu_in_a_ex),
        .op_b   (alu_in_b_ex),
        .result (alu_result_ex)
    );

    always_comb begin
        branch_taken_ex = 1'b0;
        unique case (funct3_ex)
            3'b000: branch_taken_ex = (rs1_forwarded_ex == rs2_forwarded_ex);
            3'b001: branch_taken_ex = (rs1_forwarded_ex != rs2_forwarded_ex);
            3'b100: branch_taken_ex = ($signed(rs1_forwarded_ex) <  $signed(rs2_forwarded_ex));
            3'b101: branch_taken_ex = ($signed(rs1_forwarded_ex) >= $signed(rs2_forwarded_ex));
            3'b110: branch_taken_ex = (rs1_forwarded_ex < rs2_forwarded_ex);
            3'b111: branch_taken_ex = (rs1_forwarded_ex >= rs2_forwarded_ex);
            default: branch_taken_ex = 1'b0;
        endcase
    end

    assign redirect_valid_ex = inst_valid_ex && (is_jump_ex || (is_branch_ex && branch_taken_ex));
    assign redirect_target_ex = is_jalr_ex ? ((rs1_forwarded_ex + imm_ex) & ~64'd1) : (pc_ex + imm_ex);
    assign redirect_fire_ex = redirect_valid_ex && !fetch_wait && !mem_wait;

    // ------------------------------------------------------------
    // EX/MEM pipeline register and memory interface
    // ------------------------------------------------------------
    logic [63:0] pc_mem;
    logic [63:0] alu_result_mem;
    logic [63:0] rs2_data_mem;
    logic [31:0] instr_mem;
    logic [4:0]  rd_mem;
    logic [2:0]  funct3_mem;
    logic        inst_valid_mem;
    logic        mem_read_mem;
    logic        mem_write_mem;
    logic        reg_write_mem;
    wb_sel_t     wb_sel_mem;

    always_ff @(posedge clk) begin
        if (reset) begin
            pc_mem         <= 64'b0;
            alu_result_mem  <= 64'b0;
            rs2_data_mem    <= 64'b0;
            instr_mem       <= 32'b0;
            rd_mem          <= 5'b0;
            funct3_mem      <= 3'b0;
            inst_valid_mem  <= 1'b0;
            mem_read_mem    <= 1'b0;
            mem_write_mem   <= 1'b0;
            reg_write_mem   <= 1'b0;
            wb_sel_mem      <= WB_ALU;
        end else if (!fetch_wait && !mem_wait) begin
            pc_mem         <= pc_ex;
            alu_result_mem <= alu_result_ex;
            rs2_data_mem   <= rs2_forwarded_ex;
            instr_mem      <= instr_ex;
            rd_mem         <= rd_ex;
            funct3_mem     <= funct3_ex;
            inst_valid_mem  <= inst_valid_ex;
            mem_read_mem   <= mem_read_ex;
            mem_write_mem  <= mem_write_ex;
            reg_write_mem  <= reg_write_ex;
            wb_sel_mem     <= wb_sel_ex;
        end
    end

    assign forward_data_mem = (wb_sel_mem == WB_PC4) ? (pc_mem + 64'd4) : alu_result_mem;

    logic [63:0] load_data_mem;
    logic [63:0] store_data_aligned_mem;
    strobe_t     store_strobe_mem;
    msize_t      mem_size_mem;

    assign mem_access_mem = inst_valid_mem && (mem_read_mem || mem_write_mem);
    assign mem_wait       = mem_access_mem && !dresp.data_ok;
    assign mem_size_mem   = mem_size_from_funct3(funct3_mem);
    assign store_strobe_mem = store_strobe_from_funct3(funct3_mem, alu_result_mem[2:0]);
    assign store_data_aligned_mem = align_store_data(rs2_data_mem, alu_result_mem[2:0]);
    assign load_data_mem = extend_load_data(dresp.data, alu_result_mem[2:0], funct3_mem);

    assign dreq.valid  = mem_access_mem;
    assign dreq.addr   = alu_result_mem;
    assign dreq.size   = mem_size_mem;
    assign dreq.strobe = mem_write_mem ? store_strobe_mem : 8'b0;
    assign dreq.data   = store_data_aligned_mem;

    // ------------------------------------------------------------
    // MEM/WB pipeline register and writeback
    // ------------------------------------------------------------
    logic [63:0] pc_wb;
    logic [63:0] alu_result_wb;
    logic [63:0] mem_data_wb;
    logic [31:0] instr_wb;
    logic [2:0]  funct3_wb;
    logic        inst_valid_wb;
    logic        mem_read_wb;
    logic        mem_write_wb;
    logic        commit_valid_wb;
    logic        difftest_skip_wb;
    wb_sel_t     wb_sel_wb;

    always_ff @(posedge clk) begin
        if (reset) begin
            pc_wb         <= 64'b0;
            alu_result_wb <= 64'b0;
            mem_data_wb   <= 64'b0;
            instr_wb      <= 32'b0;
            funct3_wb     <= 3'b0;
            inst_valid_wb  <= 1'b0;
            mem_read_wb   <= 1'b0;
            mem_write_wb  <= 1'b0;
            reg_write_wb  <= 1'b0;
            rd_wb         <= 5'b0;
            wb_sel_wb     <= WB_ALU;
        end else if (!fetch_wait && !mem_wait) begin
            pc_wb         <= pc_mem;
            alu_result_wb <= alu_result_mem;
            mem_data_wb   <= load_data_mem;
            instr_wb      <= instr_mem;
            funct3_wb     <= funct3_mem;
            inst_valid_wb  <= inst_valid_mem;
            mem_read_wb   <= mem_read_mem;
            mem_write_wb  <= mem_write_mem;
            reg_write_wb  <= reg_write_mem;
            rd_wb         <= rd_mem;
            wb_sel_wb     <= wb_sel_mem;
        end
    end

    always_comb begin
        unique case (wb_sel_wb)
            WB_MEM: wb_data = mem_data_wb;
            WB_PC4: wb_data = pc_wb + 64'd4;
            default: wb_data = alu_result_wb;
        endcase
    end

    assign is_trap_wb = inst_valid_wb && (instr_wb == TRAP_INST);
    assign commit_valid_wb = inst_valid_wb && !wb_fired;
    assign reg_write_wb_fire = reg_write_wb && commit_valid_wb && (rd_wb != 5'b0);
    assign trap_valid_wb = is_trap_wb && commit_valid_wb;
    assign trap_code_wb = rf_dbg[10][7:0];
    assign difftest_skip_wb = (mem_read_wb || mem_write_wb) && (alu_result_wb[31] == 1'b0);

    always_ff @(posedge clk) begin
        if (reset) begin
            wb_fired <= 1'b0;
        end else if (!fetch_wait && !mem_wait) begin
            wb_fired <= 1'b0;
        end else if (commit_valid_wb) begin
            wb_fired <= 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            cycle_cnt <= 64'b0;
            instr_cnt <= 64'b0;
        end else begin
            cycle_cnt <= cycle_cnt + 64'd1;
            if (commit_valid_wb && !is_trap_wb) begin
                instr_cnt <= instr_cnt + 64'd1;
            end
        end
    end

    // ------------------------------------------------------------
    // Stall and fetch control
    // ------------------------------------------------------------
    assign fetch_wait = ireq.valid && !iresp.data_ok;
    assign stall = load_use_hazard || fetch_wait || mem_access_mem;

    // ------------------------------------------------------------
    // Difftest view
    // ------------------------------------------------------------
    logic [63:0] gpr_dt [32];
    always_comb begin
        for (int i = 0; i < 32; i++) begin
            if (i == 0) begin
                gpr_dt[i] = 64'b0;
            end else if (reg_write_wb_fire && rd_wb == i[4:0]) begin
                gpr_dt[i] = wb_data;
            end else begin
                gpr_dt[i] = rf_dbg[i];
            end
        end
    end

`ifdef VERILATOR
    DifftestInstrCommit u_difftest_commit (
        .clock    (clk),
        .coreid   (8'b0),
        .index    (8'b0),
        .valid    (commit_valid_wb),
        .pc       (pc_wb),
        .instr    (instr_wb),
        .skip     (difftest_skip_wb),
        .isRVC    (1'b0),
        .scFailed (1'b0),
        .wen      (reg_write_wb_fire),
        .wdest    ({3'b0, rd_wb}),
        .wdata    (wb_data)
    );

    DifftestArchIntRegState u_difftest_gpr (
        .clock  (clk),
        .coreid (8'b0),
        .gpr_0  (gpr_dt[0]),
        .gpr_1  (gpr_dt[1]),
        .gpr_2  (gpr_dt[2]),
        .gpr_3  (gpr_dt[3]),
        .gpr_4  (gpr_dt[4]),
        .gpr_5  (gpr_dt[5]),
        .gpr_6  (gpr_dt[6]),
        .gpr_7  (gpr_dt[7]),
        .gpr_8  (gpr_dt[8]),
        .gpr_9  (gpr_dt[9]),
        .gpr_10 (gpr_dt[10]),
        .gpr_11 (gpr_dt[11]),
        .gpr_12 (gpr_dt[12]),
        .gpr_13 (gpr_dt[13]),
        .gpr_14 (gpr_dt[14]),
        .gpr_15 (gpr_dt[15]),
        .gpr_16 (gpr_dt[16]),
        .gpr_17 (gpr_dt[17]),
        .gpr_18 (gpr_dt[18]),
        .gpr_19 (gpr_dt[19]),
        .gpr_20 (gpr_dt[20]),
        .gpr_21 (gpr_dt[21]),
        .gpr_22 (gpr_dt[22]),
        .gpr_23 (gpr_dt[23]),
        .gpr_24 (gpr_dt[24]),
        .gpr_25 (gpr_dt[25]),
        .gpr_26 (gpr_dt[26]),
        .gpr_27 (gpr_dt[27]),
        .gpr_28 (gpr_dt[28]),
        .gpr_29 (gpr_dt[29]),
        .gpr_30 (gpr_dt[30]),
        .gpr_31 (gpr_dt[31])
    );

    DifftestTrapEvent u_difftest_trap (
        .clock    (clk),
        .coreid   (0),
        .valid    (trap_valid_wb),
        .code     (trap_code_wb[2:0]),
        .pc       (pc_wb),
        .cycleCnt (cycle_cnt),
        .instrCnt (instr_cnt)
    );

	DifftestCSRState DifftestCSRState(
		.clock              (clk),
		.coreid             (0),
		.priviledgeMode     (3),
		.mstatus            (0),
		.sstatus            (0 /* mstatus & SSTATUS_MASK */),
		.mepc               (0),
		.sepc               (0),
		.mtval              (0),
		.stval              (0),
		.mtvec              (0),
		.stvec              (0),
		.mcause             (0),
		.scause             (0),
		.satp               (0),
		.mip                (0),
		.mie                (0),
		.mscratch           (0),
		.sscratch           (0),
		.mideleg            (0),
		.medeleg            (0)
	);
`endif
endmodule
`endif
