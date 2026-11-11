// =============================================================================
// RV32I + RV32M 5-Stage Pipelined Processor
// Stages: IF -> ID -> EX -> MEM -> WB
//
// Features:
//   - Full forwarding (EX->EX and MEM->EX paths)
//   - Load-use hazard detection with one-cycle stall
//   - Branch/jump resolved in EX stage, predict-not-taken (flush 2 stages)
//   - All RV32I base instructions except FENCE/PAUSE/ECALL/EBREAK
//   - RV32M extension: MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM, REMU
// =============================================================================

`timescale 1ns/1ps

// =============================================================================
// Top-level pipelined processor
// =============================================================================
module riscv_pipeline (
    input  wire        clk,
    input  wire        rst,
    // Instruction memory (single-cycle read)
    output wire [31:0] imem_addr,
    input  wire [31:0] imem_rdata,
    // Data memory (single-cycle read/write)
    output wire        dmem_wen,
    output wire [31:0] dmem_addr,
    output wire [31:0] dmem_wdata,
    output wire [3:0]  dmem_wstrb,
    input  wire [31:0] dmem_rdata
);

    // =========================================================================
    // Register file (x0 always 0; x1-x31 general-purpose)
    // =========================================================================
    reg [31:0] rf [0:31];

    // =========================================================================
    // Pipeline registers (named by stage boundary they cross)
    // =========================================================================

    // --- IF/ID ---
    reg [31:0] if_id_pc;
    reg [31:0] if_id_instr;

    // --- ID/EX ---
    reg [31:0] id_ex_pc;
    reg [31:0] id_ex_op_a;       // rs1 data (or PC for AUIPC/JAL)
    reg [31:0] id_ex_op_b_reg;   // rs2 data (kept for forwarding target and stores)
    reg [31:0] id_ex_imm;
    reg [4:0]  id_ex_rs1;
    reg [4:0]  id_ex_rs2;
    reg [4:0]  id_ex_rd;
    reg [2:0]  id_ex_funct3;
    // Control signals
    reg [4:0]  id_ex_alu_op;  // 5-bit: supports RV32M ops 10-17
    reg        id_ex_alu_src;    // 1=use imm as B, 0=use rs2
    reg        id_ex_reg_write;
    reg        id_ex_mem_read;
    reg        id_ex_mem_write;
    reg        id_ex_mem_to_reg; // 1=load, write mem data to rd
    reg        id_ex_branch;
    reg        id_ex_jal;
    reg        id_ex_jalr;
    reg        id_ex_link;       // 1=write PC+4 to rd (JAL/JALR)

    // --- EX/MEM ---
    reg [31:0] ex_mem_alu_result;
    reg [31:0] ex_mem_rs2_fwd;   // forwarded rs2 (for stores)
    reg [31:0] ex_mem_pc4;       // PC+4 for link
    reg [4:0]  ex_mem_rd;
    reg [2:0]  ex_mem_funct3;
    reg        ex_mem_reg_write;
    reg        ex_mem_mem_read;
    reg        ex_mem_mem_write;
    reg        ex_mem_mem_to_reg;
    reg        ex_mem_link;

    // --- MEM/WB ---
    reg [31:0] mem_wb_alu_result;
    reg [31:0] mem_wb_mem_data;
    reg [31:0] mem_wb_pc4;
    reg [4:0]  mem_wb_rd;
    reg        mem_wb_reg_write;
    reg        mem_wb_mem_to_reg;
    reg        mem_wb_link;

    // =========================================================================
    // IF stage: Program Counter
    // =========================================================================
    reg [31:0] pc;
    assign imem_addr = pc;

    // =========================================================================
    // ID stage: Decode
    // =========================================================================
    wire [6:0] id_opcode = if_id_instr[6:0];
    wire [4:0] id_rs1    = if_id_instr[19:15];
    wire [4:0] id_rs2    = if_id_instr[24:20];
    wire [4:0] id_rd     = if_id_instr[11:7];
    wire [2:0] id_funct3 = if_id_instr[14:12];
    wire [6:0] id_funct7 = if_id_instr[31:25];

    // Register file read (x0 always 0)
    // Forward from WB when WB writes the same register read in ID this cycle
    wire [31:0] id_rf_rs1 = (id_rs1 == 5'd0) ? 32'd0 :
                (mem_wb_reg_write && mem_wb_rd == id_rs1) ? wb_data : rf[id_rs1];
    wire [31:0] id_rf_rs2 = (id_rs2 == 5'd0) ? 32'd0 :
                (mem_wb_reg_write && mem_wb_rd == id_rs2) ? wb_data : rf[id_rs2];

    // Immediate generator
    wire [31:0] id_imm;
    imm_gen u_imm (.instr(if_id_instr), .imm(id_imm));

    // Control unit
    wire [4:0]  id_alu_op;
    wire        id_alu_src, id_reg_write, id_mem_read, id_mem_write;
    wire        id_mem_to_reg, id_branch, id_jal, id_jalr, id_link;

    control_unit u_ctrl (
        .opcode     (id_opcode),
        .funct3     (id_funct3),
        .funct7     (id_funct7),
        .alu_op     (id_alu_op),
        .alu_src    (id_alu_src),
        .reg_write  (id_reg_write),
        .mem_read   (id_mem_read),
        .mem_write  (id_mem_write),
        .mem_to_reg (id_mem_to_reg),
        .branch     (id_branch),
        .jal        (id_jal),
        .jalr       (id_jalr),
        .link       (id_link)
    );

    // For LUI:  op_a = 0,      op_b = imm
    // For AUIPC: op_a = PC,    op_b = imm
    // For JAL:   op_a = PC,    op_b = imm  (target = PC+imm; result = PC+4 via link)
    // For JALR:  op_a = rs1,   op_b = imm  (target = rs1+imm & ~1)
    // For others: op_a = rs1, op_b = rs2 or imm
    wire [31:0] id_op_a =
        (id_opcode == 7'b0110111) ? 32'd0      :  // LUI: 0 + imm
        (id_opcode == 7'b0010111) ? if_id_pc   :  // AUIPC: PC + imm
        (id_opcode == 7'b1101111) ? if_id_pc   :  // JAL: PC + imm (branch target)
                                    id_rf_rs1;     // normal: rs1

    // =========================================================================
    // Hazard detection: load-use stall
    // =========================================================================
    wire stall = id_ex_mem_read &&
                 (id_ex_rd != 5'd0) &&
                 ((id_ex_rd == id_rs1) || (id_ex_rd == id_rs2));

    // =========================================================================
    // EX stage: Forwarding + ALU
    // =========================================================================

    // WB data (combinational, used for MEM->EX forward)
    wire [31:0] wb_data =
        mem_wb_link       ? mem_wb_pc4        :
        mem_wb_mem_to_reg ? mem_wb_mem_data   :
                            mem_wb_alu_result;

    // EX/MEM forward for EX->EX path
    wire [31:0] ex_mem_wr_data =
        ex_mem_link       ? ex_mem_pc4        :
        ex_mem_mem_to_reg ? 32'd0             :  // load not yet ready (stall prevents this)
                            ex_mem_alu_result;

    // Forwarding select for operand A (rs1)
    wire [1:0] fwd_a =
        (ex_mem_reg_write && (ex_mem_rd != 5'd0) && (ex_mem_rd == id_ex_rs1)) ? 2'b10 :
        (mem_wb_reg_write && (mem_wb_rd != 5'd0) && (mem_wb_rd == id_ex_rs1)) ? 2'b01 :
                                                                                  2'b00;

    // Forwarding select for operand B (rs2)
    wire [1:0] fwd_b =
        (ex_mem_reg_write && (ex_mem_rd != 5'd0) && (ex_mem_rd == id_ex_rs2)) ? 2'b10 :
        (mem_wb_reg_write && (mem_wb_rd != 5'd0) && (mem_wb_rd == id_ex_rs2)) ? 2'b01 :
                                                                                  2'b00;

    wire [31:0] ex_a =
        (fwd_a == 2'b10) ? ex_mem_wr_data :
        (fwd_a == 2'b01) ? wb_data         :
                            id_ex_op_a;

    wire [31:0] ex_b_reg =
        (fwd_b == 2'b10) ? ex_mem_wr_data :
        (fwd_b == 2'b01) ? wb_data         :
                            id_ex_op_b_reg;

    wire [31:0] ex_b = id_ex_alu_src ? id_ex_imm : ex_b_reg;

    // ALU
    wire [31:0] ex_alu_result;
    alu u_alu (.a(ex_a), .b(ex_b), .alu_op(id_ex_alu_op), .result(ex_alu_result));

    // PC+4 (link value for JAL/JALR)
    wire [31:0] ex_pc4 = id_ex_pc + 32'd4;

    // Branch/jump target and taken signal
    wire [31:0] ex_branch_target = id_ex_pc + id_ex_imm;      // branch / JAL
    wire [31:0] ex_jalr_target   = (ex_a + id_ex_imm) & ~32'h1; // JALR
    wire        ex_branch_taken;

    branch_unit u_bu (
        .funct3 (id_ex_funct3),
        .a      (ex_a),
        .b      (ex_b_reg),   // always rs2 for branch compare (not imm)
        .taken  (ex_branch_taken)
    );

    wire        ex_take_jump   = (id_ex_branch & ex_branch_taken) | id_ex_jal | id_ex_jalr;
    wire [31:0] ex_jump_target =
        id_ex_jalr ? ex_jalr_target  :
                     ex_branch_target;

    // =========================================================================
    // MEM stage: Data memory interface
    // =========================================================================
    assign dmem_wen  = ex_mem_mem_write;
    assign dmem_addr = ex_mem_alu_result;

    // Write data and strobe for byte/halfword/word stores
    reg [31:0] dmem_wdata_r;
    reg [3:0]  dmem_wstrb_r;
    always @(*) begin
        case (ex_mem_funct3)
            3'b000: begin // SB
                dmem_wdata_r = {4{ex_mem_rs2_fwd[7:0]}};
                dmem_wstrb_r = 4'b0001 << ex_mem_alu_result[1:0];
            end
            3'b001: begin // SH
                dmem_wdata_r = {2{ex_mem_rs2_fwd[15:0]}};
                dmem_wstrb_r = ex_mem_alu_result[1] ? 4'b1100 : 4'b0011;
            end
            default: begin // SW
                dmem_wdata_r = ex_mem_rs2_fwd;
                dmem_wstrb_r = 4'b1111;
            end
        endcase
    end
    assign dmem_wdata = dmem_wdata_r;
    assign dmem_wstrb = dmem_wstrb_r;

    // Load data extension
    wire [31:0] mem_load_data;
    load_extend u_lext (
        .raw_data (dmem_rdata),
        .addr     (ex_mem_alu_result[1:0]),
        .funct3   (ex_mem_funct3),
        .result   (mem_load_data)
    );

    // =========================================================================
    // WB stage: Register file write
    // =========================================================================
    integer rf_i;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            for (rf_i = 0; rf_i < 32; rf_i = rf_i + 1)
                rf[rf_i] <= 32'd0;
        end else if (mem_wb_reg_write && (mem_wb_rd != 5'd0))
            rf[mem_wb_rd] <= wb_data;
    end

    // =========================================================================
    // Pipeline register updates (clocked)
    // =========================================================================

    // Flush signals
    wire flush_id_ex = ex_take_jump | stall;   // flush ID/EX (insert bubble)
    wire flush_if_id = ex_take_jump;            // flush IF/ID (insert bubble)
    wire hold       = stall;                    // hold IF and IF/ID

    // -- PC --
    always @(posedge clk or posedge rst) begin
        if (rst)
            pc <= 32'd0;
        else if (!hold)
            pc <= ex_take_jump ? ex_jump_target : pc + 32'd4;
    end

    // -- IF/ID --
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            if_id_pc    <= 32'd0;
            if_id_instr <= 32'd0;
        end else if (!hold) begin
            if (flush_if_id) begin
                if_id_pc    <= 32'd0;
                if_id_instr <= 32'd0; // NOP = addi x0,x0,0
            end else begin
                if_id_pc    <= pc;
                if_id_instr <= imem_rdata;
            end
        end
        // on hold: if_id keeps its value
    end

    // -- ID/EX --
    always @(posedge clk or posedge rst) begin
        if (rst || flush_id_ex) begin
            id_ex_pc        <= 32'd0;
            id_ex_op_a      <= 32'd0;
            id_ex_op_b_reg  <= 32'd0;
            id_ex_imm       <= 32'd0;
            id_ex_rs1       <= 5'd0;
            id_ex_rs2       <= 5'd0;
            id_ex_rd        <= 5'd0;
            id_ex_funct3    <= 3'd0;
            id_ex_alu_op    <= 5'd0;
            id_ex_alu_src   <= 1'd0;
            id_ex_reg_write <= 1'd0;
            id_ex_mem_read  <= 1'd0;
            id_ex_mem_write <= 1'd0;
            id_ex_mem_to_reg<= 1'd0;
            id_ex_branch    <= 1'd0;
            id_ex_jal       <= 1'd0;
            id_ex_jalr      <= 1'd0;
            id_ex_link      <= 1'd0;
        end else begin
            id_ex_pc        <= if_id_pc;
            id_ex_op_a      <= id_op_a;
            id_ex_op_b_reg  <= id_rf_rs2;
            id_ex_imm       <= id_imm;
            id_ex_rs1       <= id_rs1;
            id_ex_rs2       <= id_rs2;
            id_ex_rd        <= id_rd;
            id_ex_funct3    <= id_funct3;
            id_ex_alu_op    <= id_alu_op;
            id_ex_alu_src   <= id_alu_src;
            id_ex_reg_write <= id_reg_write;
            id_ex_mem_read  <= id_mem_read;
            id_ex_mem_write <= id_mem_write;
            id_ex_mem_to_reg<= id_mem_to_reg;
            id_ex_branch    <= id_branch;
            id_ex_jal       <= id_jal;
            id_ex_jalr      <= id_jalr;
            id_ex_link      <= id_link;
        end
    end

    // -- EX/MEM --
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ex_mem_alu_result <= 32'd0;
            ex_mem_rs2_fwd    <= 32'd0;
            ex_mem_pc4        <= 32'd0;
            ex_mem_rd         <= 5'd0;
            ex_mem_funct3     <= 3'd0;
            ex_mem_reg_write  <= 1'd0;
            ex_mem_mem_read   <= 1'd0;
            ex_mem_mem_write  <= 1'd0;
            ex_mem_mem_to_reg <= 1'd0;
            ex_mem_link       <= 1'd0;
        end else begin
            ex_mem_alu_result <= ex_alu_result;
            ex_mem_rs2_fwd    <= ex_b_reg;    // forwarded rs2 (for stores)
            ex_mem_pc4        <= ex_pc4;
            ex_mem_rd         <= id_ex_rd;
            ex_mem_funct3     <= id_ex_funct3;
            ex_mem_reg_write  <= id_ex_reg_write;
            ex_mem_mem_read   <= id_ex_mem_read;
            ex_mem_mem_write  <= id_ex_mem_write;
            ex_mem_mem_to_reg <= id_ex_mem_to_reg;
            ex_mem_link       <= id_ex_link;
        end
    end

    // -- MEM/WB --
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            mem_wb_alu_result <= 32'd0;
            mem_wb_mem_data   <= 32'd0;
            mem_wb_pc4        <= 32'd0;
            mem_wb_rd         <= 5'd0;
            mem_wb_reg_write  <= 1'd0;
            mem_wb_mem_to_reg <= 1'd0;
            mem_wb_link       <= 1'd0;
        end else begin
            mem_wb_alu_result <= ex_mem_alu_result;
            mem_wb_mem_data   <= mem_load_data;
            mem_wb_pc4        <= ex_mem_pc4;
            mem_wb_rd         <= ex_mem_rd;
            mem_wb_reg_write  <= ex_mem_reg_write;
            mem_wb_mem_to_reg <= ex_mem_mem_to_reg;
            mem_wb_link       <= ex_mem_link;
        end
    end

endmodule

// =============================================================================
// Immediate Generator
// Produces sign-extended 32-bit immediate from instruction encoding.
// =============================================================================
module imm_gen (
    input  wire [31:0] instr,
    output reg  [31:0] imm
);
    wire [6:0] op = instr[6:0];
    always @(*) begin
        case (op)
            7'b0010011, // I-ALU
            7'b0000011, // LOAD
            7'b1100111: // JALR
                imm = {{20{instr[31]}}, instr[31:20]};
            7'b0100011: // S-type
                imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};
            7'b1100011: // B-type
                imm = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
            7'b0110111, // LUI
            7'b0010111: // AUIPC
                imm = {instr[31:12], 12'b0};
            7'b1101111: // J-type
                imm = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};
            default:
                imm = 32'd0;
        endcase
    end
endmodule

// =============================================================================
// Control Unit
// Produces control signals from opcode/funct3/funct7.
//
// ALU op encoding:
//   0000=ADD  0001=SUB  0010=SLL  0011=SLT
//   0100=SLTU 0101=XOR  0110=SRL  0111=SRA
//   1000=OR   1001=AND
// =============================================================================
module control_unit (
    input  wire [6:0] opcode,
    input  wire [2:0] funct3,
    input  wire [6:0] funct7,
    output reg  [4:0] alu_op,
    output reg        alu_src,     // 1=imm, 0=rs2
    output reg        reg_write,
    output reg        mem_read,
    output reg        mem_write,
    output reg        mem_to_reg,  // 1=load result goes to rd
    output reg        branch,
    output reg        jal,
    output reg        jalr,
    output reg        link         // 1=write PC+4 to rd
);
    localparam ALU_ADD  = 5'd0;
    localparam ALU_SUB  = 5'd1;
    localparam ALU_SLL  = 5'd2;
    localparam ALU_SLT  = 5'd3;
    localparam ALU_SLTU = 5'd4;
    localparam ALU_XOR  = 5'd5;
    localparam ALU_SRL  = 5'd6;
    localparam ALU_SRA  = 5'd7;
    localparam ALU_OR    = 5'd8;
    localparam ALU_AND   = 5'd9;
    // RV32M
    localparam ALU_MUL   = 5'd10;
    localparam ALU_MULH  = 5'd11;
    localparam ALU_MULHSU= 5'd12;
    localparam ALU_MULHU = 5'd13;
    localparam ALU_DIV   = 5'd14;
    localparam ALU_DIVU  = 5'd15;
    localparam ALU_REM   = 5'd16;
    localparam ALU_REMU  = 5'd17;

    always @(*) begin
        // Safe defaults (NOP)
        alu_op    = ALU_ADD;
        alu_src   = 1'b0;
        reg_write = 1'b0;
        mem_read  = 1'b0;
        mem_write = 1'b0;
        mem_to_reg= 1'b0;
        branch    = 1'b0;
        jal       = 1'b0;
        jalr      = 1'b0;
        link      = 1'b0;

        case (opcode)
            // R-type: RV32I base (funct7=0x00/0x20) and RV32M (funct7=0x01)
            7'b0110011: begin
                reg_write = 1'b1;
                if (funct7 == 7'b0000001) begin
                    // RV32M multiply/divide
                    case (funct3)
                        3'b000: alu_op = ALU_MUL;
                        3'b001: alu_op = ALU_MULH;
                        3'b010: alu_op = ALU_MULHSU;
                        3'b011: alu_op = ALU_MULHU;
                        3'b100: alu_op = ALU_DIV;
                        3'b101: alu_op = ALU_DIVU;
                        3'b110: alu_op = ALU_REM;
                        3'b111: alu_op = ALU_REMU;
                        default: alu_op = ALU_ADD;
                    endcase
                end else begin
                    // RV32I base R-type
                    case (funct3)
                        3'b000: alu_op = funct7[5] ? ALU_SUB : ALU_ADD;
                        3'b001: alu_op = ALU_SLL;
                        3'b010: alu_op = ALU_SLT;
                        3'b011: alu_op = ALU_SLTU;
                        3'b100: alu_op = ALU_XOR;
                        3'b101: alu_op = funct7[5] ? ALU_SRA : ALU_SRL;
                        3'b110: alu_op = ALU_OR;
                        3'b111: alu_op = ALU_AND;
                        default: alu_op = ALU_ADD;
                    endcase
                end
            end
            // I-type ALU (ADDI, SLTI, SLTIU, XORI, ORI, ANDI, SLLI, SRLI, SRAI)
            7'b0010011: begin
                reg_write = 1'b1;
                alu_src   = 1'b1;
                case (funct3)
                    3'b000: alu_op = ALU_ADD;
                    3'b001: alu_op = ALU_SLL;
                    3'b010: alu_op = ALU_SLT;
                    3'b011: alu_op = ALU_SLTU;
                    3'b100: alu_op = ALU_XOR;
                    3'b101: alu_op = funct7[5] ? ALU_SRA : ALU_SRL;
                    3'b110: alu_op = ALU_OR;
                    3'b111: alu_op = ALU_AND;
                    default: alu_op = ALU_ADD;
                endcase
            end
            // LOAD (LB, LH, LW, LBU, LHU)
            7'b0000011: begin
                reg_write  = 1'b1;
                mem_read   = 1'b1;
                mem_to_reg = 1'b1;
                alu_src    = 1'b1;
                alu_op     = ALU_ADD; // addr = rs1 + imm
            end
            // STORE (SB, SH, SW)
            7'b0100011: begin
                mem_write = 1'b1;
                alu_src   = 1'b1;
                alu_op    = ALU_ADD; // addr = rs1 + imm
            end
            // BRANCH (BEQ, BNE, BLT, BGE, BLTU, BGEU)
            7'b1100011: begin
                branch = 1'b1;
                // ALU not used for condition (branch_unit handles it)
            end
            // JAL
            7'b1101111: begin
                reg_write = 1'b1;
                jal       = 1'b1;
                link      = 1'b1;
                // op_a=PC, op_b=imm -> target=PC+imm (computed in EX)
                alu_src   = 1'b1;
                alu_op    = ALU_ADD;
            end
            // JALR
            7'b1100111: begin
                reg_write = 1'b1;
                jalr      = 1'b1;
                link      = 1'b1;
                alu_src   = 1'b1;
                alu_op    = ALU_ADD; // rs1 + imm (then clear bit 0)
            end
            // LUI
            7'b0110111: begin
                reg_write = 1'b1;
                alu_src   = 1'b1;
                alu_op    = ALU_ADD; // 0 + imm (op_a forced to 0 in ID stage)
            end
            // AUIPC
            7'b0010111: begin
                reg_write = 1'b1;
                alu_src   = 1'b1;
                alu_op    = ALU_ADD; // PC + imm (op_a forced to PC in ID stage)
            end
            default: begin end
        endcase
    end
endmodule

// =============================================================================
// ALU
// =============================================================================
module alu (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [4:0]  alu_op,
    output reg  [31:0] result
);
    wire [4:0] shamt = b[4:0];

    // RV32M: 64-bit products via Verilog functions (Icarus-safe)
    reg [63:0] m64;   // temp used inside always block for multiply results

    function [63:0] fn_mul_ss;
        input [31:0] x, y;
        reg signed [63:0] t;
        begin t = $signed(x) * $signed(y); fn_mul_ss = t; end
    endfunction
    function [63:0] fn_mul_su;
        input [31:0] x, y;
        reg signed [63:0] t;
        begin t = $signed(x) * $signed({1'b0,y}); fn_mul_su = t; end
    endfunction
    function [63:0] fn_mul_uu;
        input [31:0] x, y;
        reg [63:0] t;
        begin t = {32'd0,x} * {32'd0,y}; fn_mul_uu = t; end
    endfunction

    always @(*) begin
        case (alu_op)
            // RV32I base
            5'd0:  result = a + b;
            5'd1:  result = a - b;
            5'd2:  result = a << shamt;
            5'd3:  result = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;
            5'd4:  result = (a < b)                   ? 32'd1 : 32'd0;
            5'd5:  result = a ^ b;
            5'd6:  result = a >> shamt;
            5'd7:  result = $signed(a) >>> shamt;
            5'd8:  result = a | b;
            5'd9:  result = a & b;
            // RV32M multiply: store 64-bit result in m64, then select half
            5'd10: begin m64=fn_mul_ss(a,b); result=m64[31:0];  end // MUL
            5'd11: begin m64=fn_mul_ss(a,b); result=m64[63:32]; end // MULH
            5'd12: begin m64=fn_mul_su(a,b); result=m64[63:32]; end // MULHSU
            5'd13: begin m64=fn_mul_uu(a,b); result=m64[63:32]; end // MULHU
            // RV32M divide/remainder (div-by-zero per spec)
            5'd14: result = (b==32'd0) ? 32'hFFFFFFFF : $signed(a)/$signed(b); // DIV
            5'd15: result = (b==32'd0) ? 32'hFFFFFFFF : a/b;                   // DIVU
            5'd16: result = (b==32'd0) ? a : $signed(a)%$signed(b);            // REM
            5'd17: result = (b==32'd0) ? a : a%b;                              // REMU
            default: result = 32'd0;
        endcase
    end
endmodule

// =============================================================================
// Branch condition evaluator
// Compares rs1 and rs2 according to funct3 to determine if branch is taken.
// =============================================================================
module branch_unit (
    input  wire [2:0]  funct3,
    input  wire [31:0] a,
    input  wire [31:0] b,
    output reg         taken
);
    always @(*) begin
        case (funct3)
            3'b000: taken = (a == b);
            3'b001: taken = (a != b);
            3'b100: taken = ($signed(a) < $signed(b));
            3'b101: taken = ($signed(a) >= $signed(b));
            3'b110: taken = (a < b);
            3'b111: taken = (a >= b);
            default: taken = 1'b0;
        endcase
    end
endmodule

// =============================================================================
// Load data sign/zero extender
// =============================================================================
module load_extend (
    input  wire [31:0] raw_data,
    input  wire [1:0]  addr,
    input  wire [2:0]  funct3,
    output reg  [31:0] result
);
    // Extract byte/halfword from the correct position in the word
    wire [7:0]  byte_sel = raw_data >> ({addr,       3'b000});
    wire [15:0] half_sel = raw_data >> ({addr[1],    4'b0000});

    always @(*) begin
        case (funct3)
            3'b000: result = {{24{byte_sel[7]}},  byte_sel};  // LB
            3'b001: result = {{16{half_sel[15]}}, half_sel};  // LH
            3'b010: result = raw_data;                        // LW
            3'b100: result = {24'd0, byte_sel};               // LBU
            3'b101: result = {16'd0, half_sel};               // LHU
            default: result = raw_data;
        endcase
    end
endmodule