`timescale 1ns/1ps
module tb_top;
	parameter TEST_CLK_FREQ = 1000000;
	localparam real HALF_PERIOD_NS = 500000000.0 / TEST_CLK_FREQ;
	reg clk = 0;
	always #(HALF_PERIOD_NS) clk = ~ clk;
	reg [13:0] inputs = 14'h0030;
	wire [53:0] outputs;
	wire [7:0] hp_led;
	integer errors = 0, lcd_chars = 0, reset_count = 0, lcd_addr = 0;
	reg [127:0] expected1 = "ZONE:NW PRESS GO", expected2 = "ROTATE TO SELECT";
	submarine_sonar_top #(.CLK_FREQ(TEST_CLK_FREQ),.POR_CYCLES(8)) dut(clk, inputs, outputs, hp_led);
	task check;
		input condition;
		input [511:0] message;
		begin
			if (condition !== 1'b1) begin
				$display("FAIL: %0s", message);
				errors = errors + 1;
			end
		end
	endtask
	always @(negedge outputs[52]) if (!dut.rst) begin
		reset_count = reset_count + 1;
		lcd_addr = 0;
	end
	always @(negedge outputs[26]) if (!dut.rst) begin
		check(outputs[25] === 0 && outputs[52] === 0, "LCD write with RW and RST low");
		if (!outputs[24])
			check(outputs[23:16] === 8'hfc, "LCD hide-cursor command");
		else begin
			if (dut.game_state == 0) begin
				if (lcd_addr < 16)
					check(outputs[23:16] + 8'h20 === expected1[127 - 8 * lcd_addr -: 8], "LCD first line");
				else if (lcd_addr < 32)
					check(outputs[23:16] + 8'h20 === expected2[127 - 8 * (lcd_addr - 16) -: 8], "LCD second line");
				else
					check(1'b0, "LCD cursor out of range");
				lcd_chars = lcd_chars + 1;
			end
			lcd_addr = lcd_addr + 1;
		end
	end
	initial begin
		# 200000000;
		check(reset_count == 1 && lcd_chars == 32, "LCD initialization and both complete lines");
		check(hp_led == 0, "HP low-active full bar");
		check(dut.game_state == 0, "top idle");
		inputs [5] = 0;
		# 40000000;
		inputs [5] = 1;
		# 20000000;
		check(dut.game_state == 2, "debounced low-active start");
		check(dut.x == 52 && dut.y == 52, "start coordinates");
		inputs [0] = 1;
		# 40000000;
		inputs [0] = 0;
		# 40000000;
		check(dut.y == 51, "one-step move");
		inputs [4] = 0;
		# 40000000;
		inputs [4] = 1;
		# 20000000;
		check(dut.pings == 8, "sonar decrement");
		check(dut.ready && outputs [53], "status indicators");
		check((outputs [7:0] &(outputs [7:0] - 1'b1)) == 0 && outputs [7:0] != 0, "one-hot matrix");
		check(outputs [35:34] == 1 || outputs [35:34] == 2, "one-hot digit select");
		if (errors == 0) $display("PASS: top-level integration at %0d Hz", TEST_CLK_FREQ);
		$finish;
	end
	initial begin
		# 700000000;
		errors = errors + 1;
		$display("FAIL: top timeout");
		$finish;
	end
endmodule
