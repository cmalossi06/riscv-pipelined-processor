// =============================================================================
// Testbench for RV32I 5-Stage Pipelined Processor
//
// Loads instruction memory from finaltest_pipeline.txt via $readmemh.
// Tests (T01-T19) cover all RV32I base instructions.
// Expected final score stored in mem[100] = 25.
// =============================================================================

`timescale 1ns/1ps

module final_project_tb;

    // -------------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------------
    reg         clk;
    reg         rst;
    wire [31:0] imem_addr;
    wire [31:0] imem_rdata;
    wire        dmem_wen;
    wire [31:0] dmem_addr;
    wire [31:0] dmem_wdata;
    wire [3:0]  dmem_wstrb;
    wire [31:0] dmem_rdata;

    // -------------------------------------------------------------------------
    // Instruction memory (1 KB = 256 words)
    // Loaded from finaltest_pipeline.txt using $readmemh
    // -------------------------------------------------------------------------
    reg [31:0] imem [0:255];
    assign imem_rdata = imem[imem_addr[9:2]];

    // -------------------------------------------------------------------------
    // Data memory (1 KB = 256 words, byte-enable write)
    // -------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    // DUT
    // -------------------------------------------------------------------------
    riscv_pipeline dut (
        .clk        (clk),
        .rst        (rst),
        .imem_addr  (imem_addr),
        .imem_rdata (imem_rdata),
        .dmem_wen   (dmem_wen),
        .dmem_addr  (dmem_addr),
        .dmem_wdata (dmem_wdata),
        .dmem_wstrb (dmem_wstrb),
        .dmem_rdata (dmem_rdata)
    );

    // -------------------------------------------------------------------------
    // Clock: 10 ns period
    // -------------------------------------------------------------------------
    initial clk = 1'b0;
    always  #5 clk = ~clk;

    // -------------------------------------------------------------------------
    // Memory initialisation
    // -------------------------------------------------------------------------
    integer k;
    initial begin
        // Zero out both memories first
        for (k = 0; k < 256; k = k + 1) begin
            imem[k] = 32'd0;
            dmem[k] = 32'd0;
        end
        // Load the test program from the hex file (one 32-bit word per line)
    $readmemh("finaltest_pipeline.txt", imem, 0, 99);
    end

    // -------------------------------------------------------------------------
    // Reset sequence
    // -------------------------------------------------------------------------
    initial begin
        rst = 1'b1;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
    end

    // -------------------------------------------------------------------------
    // Simulation control
    // Detects the infinite-loop halt (JAL x0,0 at addr 396 = imem[99])
    // and waits long enough for the preceding SW to commit to data memory.
    // -------------------------------------------------------------------------
    integer cycle_count;
    reg     done;

    initial begin
        cycle_count = 0;
        done        = 1'b0;
    end

    always @(posedge clk) begin
        if (!rst) begin
            cycle_count <= cycle_count + 1;

            // Detect halt: PC fetching imem[99] (addr=396, JAL x0,0 = 0x0000006F)
            if (!done && (imem_addr == 32'd396) && (imem_rdata == 32'h0000006F))
                done <= 1'b1;

            if (cycle_count > 10000) begin
                $display("TIMEOUT: simulation exceeded 10000 cycles");
                $finish;
            end
        end
    end

    // Wait extra cycles after halt detected so in-flight SW reaches MEM stage
    always @(posedge done) begin
        repeat (15) @(posedge clk);
        report_results;
        $finish;
    end

    // -------------------------------------------------------------------------
    // Result reporting
    // -------------------------------------------------------------------------
    task report_results;
        integer score;
        begin
            score = dmem[25]; // mem[100] = dmem word index 25 (100/4 = 25)

            $display("============================================================");
            $display(" RV32I Pipeline Processor - Simulation Results");
            $display("============================================================");
            $display(" Cycles elapsed   : %0d", cycle_count);
            $display(" Score in mem[100]: %0d", score);
            $display("------------------------------------------------------------");

            if (score == 25) begin
                $display(" STATUS : ALL TESTS PASSED [score=25/25]");
                $display("          T01-T18 each +1, T19 +1 then +6 bonus");
            end else begin
                $display(" STATUS : FAILED [score=%0d, expected 25]", score);
                $display("          Last passing test counter: %0d", score);
            end

            $display("------------------------------------------------------------");
            $display(" Register file snapshot:");
            $display("   x1  (ra) = %0d",  dut.rf[1]);
            $display("   x2  (sp) = %0d",  dut.rf[2]);
            $display("   x3  (gp) = %0d",  dut.rf[3]);
            $display("   x4  (tp) = %0d",  dut.rf[4]);
            $display("   x5  (t0) = %0d",  dut.rf[5]);
            $display("   x6  (t1) = %0d",  dut.rf[6]);
            $display("   x7  (t2) = %0d",  dut.rf[7]);
            $display("============================================================");
        end
    endtask

    // -------------------------------------------------------------------------
    // Waveform dump
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("riscv_pipeline.vcd");
        $dumpvars(0, final_project_tb);
        $dumpvars(1, dut.rf[1]);
        $dumpvars(1, dut.rf[2]);
        $dumpvars(1, dut.rf[6]);
    end

endmodule