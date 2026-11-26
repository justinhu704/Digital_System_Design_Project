`timescale 1us/1ns
// Write-side LCD checker at the real 500 Hz clock. Only the LCD pins are observed:
// a model of the VeriInstrument LCD (clear on RST, write on EN falling edge) rebuilds the screen.
module tb_lcd;
	parameter TEST_CLK_FREQ = 500;
	localparam real HALF_PERIOD_US = 500000.0 / TEST_CLK_FREQ;
	reg clk = 0;
	always #(HALF_PERIOD_US) clk = ~clk;
	reg rst = 1;
	reg [127:0] line1 = "HP:8 SON:9 T:1  ";
	reg [127:0] line2 = "DIST:040        ";
	wire [7:0] db;
	wire rs, rw, en, lcd_rst;
	integer errors = 0, reset_count = 0, data_count = 0, addr = 0, i, before_count, batch_start;
	reg [7:0] ddram [0:31];
	text_lcd_driver dut(clk, rst, line1, line2, db, rs, rw, en, lcd_rst);

	task check;
		input condition;
		input [511:0] message;
		begin
			if (condition !== 1'b1) begin
				$display("FAIL at %0t us: %0s", $time, message);
				errors = errors + 1;
			end
		end
	endtask
	task check_rows;
		input [127:0] a, b;
		begin
			for (i = 0; i < 16; i = i + 1) begin
				check(ddram[i] === a[127 - 8 * i -: 8], "row 1 DDRAM contents");
				check(ddram[16 + i] === b[127 - 8 * i -: 8], "row 2 DDRAM contents");
			end
		end
	endtask
	// Data may change together with the EN rising edge, but must then stay stable until EN falls
	reg [8:0] held;
	always @(posedge en) if (!rst) begin
		check(rw === 0 && lcd_rst === 0, "write with RW and RST low");
		#1 held = { rs, db };
	end
	always @(negedge en) if (!rst) begin
		check({ rs, db } === held, "data and RS stable while EN high");
		check(rs === 1, "only character writes");
		check(addr < 32, "at most 32 characters per batch");
		check(db <= 8'h5e, "Lecture 9 character code range");
		if (addr == 0) batch_start = $time;
		if (addr < 32) ddram[addr] = db + 8'h20;
		addr = addr + 1;
		data_count = data_count + 1;
		if (addr == 32) $display("INFO: batch of 32 chars took %0d ms", ($time - batch_start) / 1000);
	end
	always @(negedge lcd_rst) if (!rst) begin
		check(en === 0, "EN low while releasing RST");
		addr = 0;
		reset_count = reset_count + 1;
		for (i = 0; i < 32; i = i + 1) ddram[i] = 8'h20;
	end

	initial begin
		for (i = 0; i < 32; i = i + 1) ddram[i] = 8'hxx;
		repeat (10) @(negedge clk);
		rst = 0;
		#300000;
		check(reset_count == 1 && data_count == 32, "power-up draws one full screen");
		check_rows(line1, line2);
		before_count = data_count;
		#500000;
		check(data_count == before_count, "unchanged text causes no writes");
		line1 = "HP:7 SON:9 T:1  ";
		#300000;
		check(data_count == before_count + 32 && reset_count == 2, "one change redraws once");
		check_rows(line1, line2);
		// Changes during a batch must not corrupt it, and the newest text must win
		line1 = "HP:6 SON:8 T:1  ";
		line2 = "WARN: MINE NEAR!";
		#30000;
		line1 = "HP:5 SON:7 T:0  ";
		#600000;
		check_rows(line1, line2);
		before_count = data_count;
		#500000;
		check(data_count == before_count, "stable after updates");
		check(reset_count == 4, "exactly two more batches for the mid-batch change");
		if (errors == 0) $display("PASS: LCD protocol and screen updates at %0d Hz", TEST_CLK_FREQ);
		else $display("FAIL: %0d checks", errors);
		$finish;
	end
	initial begin
		#5000000;
		errors = errors + 1;
		$display("FAIL: LCD timeout");
		$finish;
	end
endmodule
