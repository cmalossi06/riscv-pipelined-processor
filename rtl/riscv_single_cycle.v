// ============================================================
// top
// ============================================================
module top (
    clk, reset, WriteData, DataAdr, MemWrite
);
    input wire clk;
    input wire reset;
    output wire [31:0] WriteData;
    output wire [31:0] DataAdr;
    output wire MemWrite;

    wire [31:0] PC;
    wire [31:0] Instr;
    wire [31:0] ReadData;

    riscvsingle rvsingle(
        .clk(clk), .reset(reset), .PC(PC), .Instr(Instr),
        .MemWrite(MemWrite), .ALUResult(DataAdr),
        .WriteData(WriteData), .ReadData(ReadData)
    );
    imem imem(.a(PC), .rd(Instr));
    dmem dmem(.clk(clk), .we(MemWrite), .a(DataAdr),
              .wd(WriteData), .funct3(Instr[14:12]), .rd(ReadData));
endmodule

// ============================================================
// riscvsingle
// ============================================================
module riscvsingle (
    clk, reset, PC, Instr, MemWrite, ALUResult, WriteData, ReadData
);
    input wire clk, reset;
    output wire [31:0] PC;
    input  wire [31:0] Instr;
    output wire MemWrite;
    output wire [31:0] ALUResult;
    output wire [31:0] WriteData;
    input  wire [31:0] ReadData;

    wire        ALUSrc, RegWrite, Jump, JalrSrc;
    wire        Zero, Less, LessU;
    wire [1:0]  ResultSrc;
    wire [2:0]  ImmSrc;
    wire [2:0]  ALUControl;
    wire        PCSrc;

    controller c(
        .op(Instr[6:0]), .funct3(Instr[14:12]), .funct7b5(Instr[30]),
        .Zero(Zero), .Less(Less), .LessU(LessU),
        .ResultSrc(ResultSrc), .MemWrite(MemWrite), .PCSrc(PCSrc),
        .ALUSrc(ALUSrc), .RegWrite(RegWrite), .Jump(Jump),
        .JalrSrc(JalrSrc), .ImmSrc(ImmSrc), .ALUControl(ALUControl)
    );
    datapath dp(
        .clk(clk), .reset(reset), .ResultSrc(ResultSrc),
        .PCSrc(PCSrc), .ALUSrc(ALUSrc), .RegWrite(RegWrite),
        .ImmSrc(ImmSrc), .ALUControl(ALUControl),
        .Jump(Jump), .JalrSrc(JalrSrc), .Funct7b5(Instr[30]),
        .Zero(Zero), .Less(Less), .LessU(LessU),
        .PC(PC), .Instr(Instr), .ALUResult(ALUResult),
        .WriteData(WriteData), .ReadData(ReadData)
    );
endmodule

// ============================================================
// controller
// ============================================================
module controller (
    input wire [6:0] op,
    input wire [2:0] funct3,
    input wire       funct7b5,
    input wire       Zero, Less, LessU,
    output wire [1:0] ResultSrc,
    output wire       MemWrite, PCSrc, ALUSrc, RegWrite, Jump, JalrSrc,
    output wire [2:0] ImmSrc,
    output wire [2:0] ALUControl
);
    wire        Branch;
    wire [1:0]  ALUOp;
    wire        BranchTaken;

    maindec md(
        .op(op), .funct3(funct3),
        .ResultSrc(ResultSrc), .MemWrite(MemWrite), .Branch(Branch),
        .ALUSrc(ALUSrc), .RegWrite(RegWrite), .Jump(Jump),
        .JalrSrc(JalrSrc), .ImmSrc(ImmSrc), .ALUOp(ALUOp)
    );
    aludec ad(
        .opb5(op[5]), .funct3(funct3), .funct7b5(funct7b5),
        .ALUOp(ALUOp), .ALUControl(ALUControl)
    );

    // Tutte le condizioni di branch
    assign BranchTaken = Branch & (
        (funct3 == 3'b000 &  Zero)   |   // BEQ
        (funct3 == 3'b001 & ~Zero)   |   // BNE
        (funct3 == 3'b100 &  Less)   |   // BLT
        (funct3 == 3'b101 & ~Less)   |   // BGE
        (funct3 == 3'b110 &  LessU)  |   // BLTU
        (funct3 == 3'b111 & ~LessU)      // BGEU
    );

     assign #5 PCSrc = BranchTaken | Jump | JalrSrc;
endmodule

// ============================================================
// maindec
// controls = {RegWrite, ImmSrc[2:0], ALUSrc, MemWrite,
//             ResultSrc[1:0], Branch, ALUOp[1:0], Jump}  -> 12 bit
// ImmSrc: 000=I  001=S  010=B  011=J  100=U
// ALUOp:  00=ADD  01=SUB  10=funct3
// ============================================================
module maindec (
    input wire [6:0] op,
    input wire [2:0] funct3,
    output wire [1:0] ResultSrc,
    output wire       MemWrite, Branch, ALUSrc, RegWrite, Jump, JalrSrc,
    output wire [2:0] ImmSrc,
    output wire [1:0] ALUOp
);
    reg [12:0] controls;
    // bit layout: {RegWrite, ImmSrc[2:0], ALUSrc, MemWrite,
    //              ResultSrc[1:0], Branch, ALUOp[1:0], Jump, JalrSrc}
    assign {RegWrite, ImmSrc, ALUSrc, MemWrite,
            ResultSrc, Branch, ALUOp, Jump, JalrSrc} = controls;

    always @(*) begin
        case (op)
            7'b0000011: controls = 13'b1_000_1_0_01_0_00_0_0; // LOAD
            7'b0100011: controls = 13'b0_001_1_1_00_0_00_0_0; // STORE (SW/SH/SB)
            7'b0110011: controls = 13'b1_000_0_0_00_0_10_0_0; // R-type
            7'b1100011: controls = 13'b0_010_0_0_00_1_01_0_0; // BRANCH (tutti)
            7'b0010011: controls = 13'b1_000_1_0_00_0_10_0_0; // I-type ALU
            7'b1101111: controls = 13'b1_011_0_0_10_0_00_1_0; // JAL
            7'b1100111: controls = 13'b1_000_1_0_10_0_00_0_1; // JALR
            7'b0110111: controls = 13'b1_100_1_0_00_0_10_0_0; // LUI
            7'b0010111: controls = 13'b1_100_0_0_11_0_00_0_0; // AUIPC
            default:    controls = 13'bx_xxx_x_x_xx_x_xx_x_x;
        endcase
    end
endmodule

// ============================================================
// aludec
// ============================================================
module aludec (
    input wire       opb5,
    input wire [2:0] funct3,
    input wire       funct7b5,
    input wire [1:0] ALUOp,
    output reg [2:0] ALUControl
);
    wire RtypeSub;
    wire RtypeSra;
    assign RtypeSub = funct7b5 & opb5;   // SUB
    assign RtypeSra = funct7b5;           // SRA / SRAI

    always @(*) begin
        case (ALUOp)
            2'b00: ALUControl = 3'b000;   // ADD (load/store/AUIPC)
            2'b01: ALUControl = 3'b001;   // SUB (branch compare)
            default:
                case (funct3)
                    3'b000: ALUControl = RtypeSub ? 3'b001 : 3'b000; // ADD/SUB/ADDI
                    3'b001: ALUControl = 3'b110;   // SLL/SLLI
                    3'b010: ALUControl = 3'b101;   // SLT/SLTI
                    3'b011: ALUControl = 3'b101;   // SLTU/SLTIU (ALU usa LessU via funct7b5)
                    3'b100: ALUControl = 3'b100;   // XOR/XORI
                    3'b101: ALUControl = 3'b111;   // SRL/SRA/SRLI/SRAI (ALU distingue via funct7b5)
                    3'b110: ALUControl = 3'b011;   // OR/ORI
                    3'b111: ALUControl = 3'b010;   // AND/ANDI
                    default: ALUControl = 3'bxxx;
                endcase
        endcase
    end
endmodule

// ============================================================
// datapath
// ============================================================
module datapath (
    input wire        clk, reset,
    input wire [1:0]  ResultSrc,
    input wire        PCSrc, ALUSrc, RegWrite,
    input wire [2:0]  ImmSrc,
    input wire [2:0]  ALUControl,
    input wire        Jump, JalrSrc, Funct7b5,
    output wire       Zero, Less, LessU,
    output wire [31:0] PC,
    input wire [31:0]  Instr,
    output wire [31:0] ALUResult,
    output wire [31:0] WriteData,
    input wire [31:0]  ReadData
);
    wire [31:0] PCNext, PCPlus4, PCTarget, PCPlusImm, JalrTarget;
    wire [31:0] ImmExt, SrcA, SrcB, Result;

    flopr #(.WIDTH(32)) pcreg(.clk(clk), .reset(reset), .d(PCNext), .q(PC));
    adder pcadd4(.a(PC), .b(32'd4), .y(PCPlus4));
    adder pcaddbranch(.a(PC), .b(ImmExt), .y(PCTarget));

    assign PCPlusImm  = PC + ImmExt;          // per AUIPC (ResultSrc=11)
    assign JalrTarget = SrcA + ImmExt;        // per JALR

    // PCNext: se JALR usa JalrTarget, altrimenti PCTarget (branch/JAL) o PCPlus4
    mux2 #(.WIDTH(32)) pcmux(
        .d0(PCPlus4),
        .d1(JalrSrc ? JalrTarget : PCTarget),
        .s(PCSrc),
        .y(PCNext)
    );

    regfile rf(
        .clk(clk), .we3(RegWrite),
        .a1(Instr[19:15]), .a2(Instr[24:20]), .a3(Instr[11:7]),
        .wd3(Result), .rd1(SrcA), .rd2(WriteData)
    );
    extend ext(.instr(Instr[31:7]), .immsrc(ImmSrc), .immext(ImmExt));

    mux2 #(.WIDTH(32)) srcbmux(
        .d0(WriteData), .d1(ImmExt), .s(ALUSrc), .y(SrcB)
    );

    alu alu(
        .a(SrcA), .b(SrcB), .alucontrol(ALUControl), .funct7b5(Funct7b5),
        .result(ALUResult), .zero(Zero), .less(Less), .lessu(LessU)
    );

    // ResultSrc: 00=ALU  01=Mem  10=PC+4  11=PC+Imm(AUIPC)
    mux4 #(.WIDTH(32)) resultmux(
        .d0(ALUResult), .d1(ReadData), .d2(PCPlus4), .d3(PCPlusImm),
        .s(ResultSrc), .y(Result)
    );
endmodule

// ============================================================
// alu — aggiunto funct7b5, less, lessu; SRA vs SRL; SLTU vs SLT
// ============================================================
module alu (
    input wire [31:0]  a, b,
    input wire [2:0]   alucontrol,
    input wire         funct7b5,
    output reg [31:0]  result,
    output wire        zero,
    output wire        less,
    output wire        lessu
);
    wire [31:0] condinvb;
    wire [31:0] sum;
    wire v, isAddSub;

    assign condinvb = alucontrol[0] ? ~b : b;
    assign sum      = a + condinvb + alucontrol[0];
    assign isAddSub = (~alucontrol[2] & ~alucontrol[1]) |
                      (~alucontrol[1] &  alucontrol[0]);

    assign v    = (~((alucontrol[0] ^ a[31]) ^ b[31]) &
                    (a[31] ^ sum[31])) & isAddSub;
    assign less  = sum[31] ^ v;          // SLT  (signed)
    assign lessu = ($unsigned(a) < $unsigned(b)) ? 1'b1 : 1'b0; // SLTU (unsigned) //MODIFICA
    assign zero  = (result == 32'b0);

    always @(*) begin
        case (alucontrol)
            3'b000: result = sum;                                     // ADD
            3'b001: result = sum;                                     // SUB
            3'b010: result = a & b;                                   // AND
            3'b011: result = a | b;                                   // OR
            3'b100: result = a ^ b;                                   // XOR
            3'b101: result = funct7b5 ? (lessu ? 32'd1 : 32'd0)      // SLTU
                                      : (less  ? 32'd1 : 32'd0);     // SLT
            3'b110: result = a << b[4:0];                             // SLL/SLLI
            3'b111: result = funct7b5 ? ($signed(a) >>> b[4:0])      // SRA/SRAI
                                      : (a >> b[4:0]);                // SRL/SRLI
            default: result = 32'bx;
        endcase
    end
endmodule

// ============================================================
// extend — ImmSrc 3 bit: 000=I 001=S 010=B 011=J 100=U
// ============================================================
module extend (
    input wire [31:7] instr,
    input wire [2:0]  immsrc,
    output reg [31:0] immext
);
    always @(*) begin
        case (immsrc)
            3'b000: immext = {{20{instr[31]}}, instr[31:20]};                           // I
            3'b001: immext = {{20{instr[31]}}, instr[31:25], instr[11:7]};              // S
            3'b010: immext = {{20{instr[31]}}, instr[7], instr[30:25], instr[11:8], 1'b0}; // B
            3'b011: immext = {{12{instr[31]}}, instr[19:12], instr[20], instr[30:21], 1'b0}; // J
            3'b100: immext = {instr[31:12], 12'b0};                                    // U
            default: immext = 32'bx;
        endcase
    end
endmodule

// ============================================================
// regfile
// ============================================================
module regfile (
    input wire        clk, we3,
    input wire [4:0]  a1, a2, a3,
    input wire [31:0] wd3,
    output wire [31:0] rd1, rd2
);
    reg [31:0] rf [31:0];
    always @(posedge clk)
        if (we3) rf[a3] <= wd3;
    assign rd1 = (a1 != 0) ? rf[a1] : 32'b0;
    assign rd2 = (a2 != 0) ? rf[a2] : 32'b0;
endmodule

// ============================================================
// imem
// ============================================================
module imem (
    input wire [31:0]  a,
    output wire [31:0] rd
);
    reg [31:0] RAM [127:0];
    initial $readmemh("finaltest_base.txt", RAM, 0, 99);
    assign rd = RAM[a[31:2]];
endmodule

// ============================================================
// dmem — byte addressable per SB/LBU
// ============================================================
module dmem (
    input wire        clk, we,
    input wire [31:0] a, wd,
    input wire [2:0]  funct3,
    output wire [31:0] rd
);
    reg [7:0] RAM [255:0];

    // lettura: LW=word, LBU=byte zero-extended
    wire [31:0] word;
    assign word = {RAM[a+3], RAM[a+2], RAM[a+1], RAM[a]};
   assign rd = (funct3 == 3'b000) ? {{24{RAM[a][7]}}, RAM[a]}           // LB
      : (funct3 == 3'b001) ? {{16{RAM[a+1][7]}}, RAM[a+1], RAM[a]}  // LH
      : (funct3 == 3'b010) ? word                                    // LW
      : (funct3 == 3'b100) ? {24'b0, RAM[a]}                        // LBU
      : (funct3 == 3'b101) ? {{16{1'b0}}, RAM[a+1], RAM[a]}         // LHU
      : 32'b0;
    // scrittura: SW=word, SB=byte, SH=halfword
    always @(posedge clk) begin
        if (we) begin
            case (funct3)
                3'b000: RAM[a] <= wd[7:0];                   // SB
                3'b001: begin                                  // SH
                    RAM[a]   <= wd[7:0];
                    RAM[a+1] <= wd[15:8];
                end
                default: begin                                 // SW
                    RAM[a]   <= wd[7:0];
                    RAM[a+1] <= wd[15:8];
                    RAM[a+2] <= wd[23:16];
                    RAM[a+3] <= wd[31:24];
                end
            endcase
        end
    end
endmodule

// ============================================================
// utility modules
// ============================================================
module adder (input [31:0] a, b, output wire [31:0] y);
    assign y = a + b;
endmodule

module flopr #(parameter WIDTH = 8) (
    input wire             clk, reset,
    input wire [WIDTH-1:0] d,
    output reg [WIDTH-1:0] q
);
    always @(posedge clk or posedge reset)
        if (reset) q <= 0;
        else       q <= d;
endmodule

module mux2 #(parameter WIDTH = 8) (
    input wire [WIDTH-1:0] d0, d1,
    input wire s,
    output wire [WIDTH-1:0] y
);
    assign y = s ? d1 : d0;
endmodule

module mux3 #(parameter WIDTH = 8) (
    input wire [WIDTH-1:0] d0, d1, d2,
    input wire [1:0] s,
    output wire [WIDTH-1:0] y
);
    assign y = s[1] ? d2 : (s[0] ? d1 : d0);
endmodule

module mux4 #(parameter WIDTH = 8) (
    input wire [WIDTH-1:0] d0, d1, d2, d3,
    input wire [1:0] s,
    output reg [WIDTH-1:0] y
);
    always @(*) begin
        case (s)
            2'b00: y = d0;
            2'b01: y = d1;
            2'b10: y = d2;
            2'b11: y = d3;
            default: y = d0;
        endcase
    end
endmodule