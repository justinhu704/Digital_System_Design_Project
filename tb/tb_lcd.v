`timescale 1ns/1fs
// Independent write-side LCD checker: no internal DUT state is inspected.
module tb_lcd;
	parameter TEST_CLK_FREQ = 24000000;
	localparam real HALF_PERIOD_NS = 500000000.0 / TEST_CLK_FREQ;
	reg clk = 0;
	always #(HALF_PERIOD_NS) clk = ~ clk;
	reg rst = 1;
	reg [255:0] line1 = { "HP:8 SON:9      ", 128'b0 };
	reg [255:0] line2 = { "DIST:080        ", 128'b0 };
	wire [7:0] db;
	wire rs, rw, en, lcd_rst;
	integer errors = 0, reset_count = 0, command_count = 0, data_count = 0, addr = 0, i, before_count;
	reg [7:0] ddram [0:31];
	reg [7:0] held_db;
	reg held_rs;
	realtime released = 0, rise_time = 0, last_fall = 0, changed_time = 0, busy_until = 0, reset_rise = 0;
	text_lcd_driver #(.CLK_FREQ(TEST_CLK_FREQ)) dut(clk, rst, line1, line2, db, rs, rw, en, lcd_rst);
	task check;
		input condition;
		input [511:0] message;
		begin
			if (condition !== 1'b1) begin
				$display("FAIL at %0t: %0s", $time, message);
				errors = errors + 1;
			end
		end
	endtask
	task check_rows;
		input [127:0] a, b;
		begin
			for (i = 0; i < 16; i = i + 1) begin
				check(ddram [i] === a [127 - 8 * i -: 8], "row 1 DDRAM contents");
				check(ddram [16 + i] === b [127 - 8 * i -: 8], "row 2 DDRAM contents");
			end
		end
	endtask
	always @(db or rs) begin
		if (! rst) begin
			check(en !== 1'b1, "data and RS stable while E high");
			if (last_fall > 0) check($realtime - last_fall >= 999, "data hold >= 1 us");
		end
		changed_time = $realtime;
	end
	always @(posedge en) if (! rst) begin
		check(rw === 0 && lcd_rst === 0, "write with RW and LCD reset low");
		check($realtime - changed_time >= 999999, "configured setup >= 1 ms");
		check($realtime >= busy_until - 1, "no command while LCD busy");
		check($realtime - released >= 40000000, "power-on wait >= 40 ms");
		held_db = db;
		held_rs = rs;
		rise_time = $realtime;
	end
	always @(negedge en) if (! rst && rise_time > 0) begin
		check($realtime - rise_time >= 999999, "configured E width >= 1 ms");
		check(db === held_db && rs === held_rs, "data held through falling edge");
		last_fall = $realtime;
		busy_until = $realtime + 1000000;
		if (!rs) begin
			check(db == 8'hfc && addr == 0, "hide cursor only after homing");
			command_count = command_count + 1;
		end
		else begin
			check(reset_count > 0 && addr < 32, "write follows reset and stays within two rows");
			check(db <= 8'h5e, "Lecture 9 character code");
			if (addr < 32)
				ddram[addr] = db + 8'h20;
			addr = addr + 1;
			data_count = data_count + 1;
		end
	end
	always @(posedge lcd_rst) reset_rise = $realtime;
	always @(negedge lcd_rst) if (!rst) begin
		check(en === 0, "EN inactive during reset release");
		check($realtime - reset_rise >= 1999999, "reset pulse >= 2 ms");
		addr = 0;
		reset_count = reset_count + 1;
		for (i = 0; i < 32; i = i + 1)
			ddram[i] = 8'h20;
	end
	initial begin
		for (i = 0; i < 32; i = i + 1) ddram [i] = 8'hxx;
		repeat (10) @(negedge clk);
		rst = 0;
		released = $realtime;
		# 200000000;
		check(reset_count == 1 && command_count == 1 && data_count == 32, "complete startup and first batch");
		check_rows(line1 [255:128], line2 [255:128]);
		before_count = data_count;
		# 50000000;
		check(data_count == before_count, "unchanged rows cause no writes");
		line1 = { "HP:7 SON:9      ", 128'b0 };
		# 140000000;
		check(data_count == before_count + 32, "one updated batch redraws both rows");
		check_rows(line1 [255:128], line2 [255:128]);
		// Changes during a batch must not corrupt its snapshot or disappear.
		line1 = { "HP:6 SON:8      ", 128'b0 };
		line2 = { "WARN: MINE NEAR!", 128'b0 };
		# 30000000;
		line1 = { "HP:5 SON:7      ", 128'b0 };
		# 230000000;
		check_rows(line1 [255:128], line2 [255:128]);
		before_count = data_count;
		# 50000000;
		check(data_count == before_count, "stable display stays idle after updates");
		check(reset_count == 4 && command_count == 4, "one reset and hide command per batch");
		if (errors == 0) $display("PASS: LCD Lecture 9 timing and frame updates at %0d Hz", TEST_CLK_FREQ);
		$finish;
	end
	initial begin
		# 850000000;
		errors = errors + 1;
		$display("FAIL: LCD timeout");
		$finish;
	end
endmodule
