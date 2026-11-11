// =============================================================================
// Testbench for RV32M extension (MUL/MULH/MULHSU/MULHU/DIV/DIVU/REM/REMU)
//
// Loads finaltest_mul.txt via $readmemh.
//
// Test groups (each adds +1 to x1 on pass):
//   T01: MUL    x6 = x2*x3 = 5*3 = 15
//   T02: MULH   x6 = high(signed(-1)*signed(3)) = -1
//   T03: MULHU  x6 = high(unsigned(0xFFFFFFFF)*unsigned(3)) = 2
//   T04: MULHSU x6 = high(signed(-1)*unsigned(3)) = -1
//   T05: DIV    x6 = 15/3 = 5
//   T06: DIVU   x6 = 15/3 = 5
//   T07: REM    x6 = 17%3 = 2
//   T08: REMU   x6 = 17%3 = 2
//
// Pass criterion: mem[200] = 8
// Halt: JAL x0,0 at addr 172 (imem[43])
// =============================================================================

`timescale 1ns/1ps

module final_project_pipeline_tb_m;

    reg         clk, rst;
    wire [31:0] imem_addr, imem_rdata;
    wire        dmem_wen;
    wire [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    wire [3:0]  dmem_wstrb;

    // Instruction memory (256 words)
    reg [31:0] imem [0:255];
    assign imem_rdata = imem[imem_addr[9:2]];

    // Data memory (256 words, byte-enable write)
    reg [31:0] dmem [0:255];
    always @(posedge clk) begin
        if (dmem_wen) begin
            if (dmem_wstrb[0]) dmem[dmem_addr[9:2]][7:0]   <= dmem_wdata[7:0];
            if (dmem_wstrb[1]) dmem[dmem_addr[9:2]][15:8]  <= dmem_wdata[15:8];
            if (dmem_wstrb[2]) dmem[dmem_addr[9:2]][23:16] <= dmem_wdata[23:16];
            if (dmem_wstrb[3]) dmem[dmem_addr[9:2]][31:24] <= dmem_wdata[31:24];
        end
    end
    assign dmem_rdata = dmem[dmem_addr[9:2]];

    // DUT
    riscv_pipeline dut (
        .clk(clk), .rst(rst),
        .imem_addr(imem_addr), .imem_rdata(imem_rdata),
        .dmem_wen(dmem_wen),   .dmem_addr(dmem_addr),
        .dmem_wdata(dmem_wdata),.dmem_wstrb(dmem_wstrb),
        .dmem_rdata(dmem_rdata)
    );

    initial clk = 1'b0;
    always  #5 clk = ~clk;

    integer k;
    initial begin
        for (k = 0; k < 256; k = k + 1) begin
            imem[k] = 32'd0;
            dmem[k] = 32'd0;
        end
        $readmemh("finaltest_mul.txt", imem, 0, 43);
    end

    initial begin
        rst = 1'b1;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
    end

    integer cycle_count;
    reg     done;
    initial begin cycle_count = 0; done = 1'b0; end

    always @(posedge clk) begin
        if (!rst) begin
            cycle_count <= cycle_count + 1;
            // Halt: JAL x0,0 at addr 172
            if (!done && (imem_addr == 32'd172) && (imem_rdata == 32'h0000006F))
                done <= 1'b1;
            if (cycle_count > 10000) begin
                $display("TIMEOUT after %0d cycles", cycle_count);
                $finish;
            end
        end
    end

    always @(posedge done) begin
        repeat (15) @(posedge clk);
        report_results;
        $finish;
    end

    task report_results;
        integer score;
        begin
            score = dmem[50]; // mem[200] / 4 = 50
            $display("============================================================");
            $display(" RV32M Extension - Simulation Results");
            $display("============================================================");
            $display(" Cycles elapsed   : %0d", cycle_count);
            $display(" Score in mem[200]: %0d / 8", score);
            $display("------------------------------------------------------------");
            if (score == 8)
                $display(" STATUS : ALL RV32M TESTS PASSED [score=8/8]");
            else
                $display(" STATUS : FAILED [score=%0d, expected 8]", score);
            $display("------------------------------------------------------------");
            $display(" Register snapshot:");
            $display("   x1 (ra) = %0d  (pass counter, expected 8)", dut.rf[1]);
            $display("   x2 (sp) = %0d  (expected 5)",               dut.rf[2]);
            $display("   x3 (gp) = %0d  (expected 3)",               dut.rf[3]);
            $display("   x6 (t1) = %0d",                             dut.rf[6]);
            $display("============================================================");
        end
    endtask

    initial begin
        $dumpfile("riscv_pipeline_m.vcd");
        $dumpvars(0, final_project_pipeline_tb_m);
    end

endmodule