module testbench;
	reg clk;
	reg reset;
	wire [31:0] WriteData;
	wire [31:0] DataAdr;
	wire MemWrite;
	
	top dut(
		.clk(clk),
		.reset(reset),
		.WriteData(WriteData),
		.DataAdr(DataAdr),
		.MemWrite(MemWrite)
	);
	initial begin
		reset <= 1;
		#22
		reset <= 0;
		repeat (300) @(posedge clk);
		$finish;
	end
	initial begin
		$dumpfile("riscvsingle1.vcd");
		$dumpvars(0,testbench);
	end
	always begin
		clk = 1;
		#5
		clk = 0;
		#5;
	end

	always @(negedge clk)
    if (MemWrite) begin
        $display("MEMWRITE at addr=%0d data=%0d", DataAdr, WriteData);
        if ((DataAdr == 100) & (WriteData == 25)) begin
            $display("Simulation succeeded - All tests passed!");
            #20
			#20
			#20
			#20
			#20
            $finish;
        end
        else if (DataAdr != 96 && DataAdr != 100) begin
            $display("Simulation failed at addr=%0d", DataAdr);
            #20
			#20
			#20
			#20

            $finish;
        end
    end

endmodule