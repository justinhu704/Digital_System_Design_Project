`timescale 1us/1ns
// Full-game simulation of submarine_sonar_top at the real 500 Hz clock.
// Stimulus goes only through inputs[] with realistic press times (no internal forcing of inputs).
// Every output component is decoded back from the pins and compared with an independent model:
//   8x8 matrix (scanned rows -> frame), two 7-segment displays (-> X/Y), LCD (pin-level model -> text),
//   compass / status LEDs, on-board HP LEDs.
// Internal signals are read only as the reference (map contents, goal) and to wait for idle moments.
// An autopilot (BFS over the real map) drives the submarine to the goal.
// A text log of the whole session is written to game_log.txt.
module tb_game;
	localparam real HALF_US = 1000.0;           // 500 Hz
	localparam integer MS = 1000;
	localparam integer HOLD = 160 * MS, GAP = 180 * MS;
	reg clk = 0;
	always #(HALF_US) clk = ~clk;

	// Idle input levels: buttons 0..3 high active (0), LA buttons 4/5 and torpedo button 9 low active (1),
	// switches 6/7/10 read 1 when OFF (SW_INV = 1). Unused 8, 11, 12, 13 held at 0.
	reg [13:0] inputs = 14'h06F0;
	wire [53:0] outputs;
	wire [7:0] hp_led;
	submarine_sonar_top dut(clk, inputs, outputs, hp_led);

	integer errors = 0, log, i, j, k, n, steps, games_won = 0;
	integer sx, sy;

	task check;
		input condition;
		input [511:0] message;
		begin
			if (condition !== 1'b1) begin
				$display("FAIL at %0t ms: %0s", $time / 1000, message);
				$fdisplay(log, "FAIL at %0t ms: %0s", $time / 1000, message);
				errors = errors + 1;
			end
		end
	endtask
	task note;
		input [1023:0] message;
		begin
			$display("[%7.1f s] %0s", $realtime / 1.0e6, message);
			$fdisplay(log, "[%7.1f s] %0s", $realtime / 1.0e6, message);
		end
	endtask
	task wait_ms;
		input integer t;
		begin
			#(t * MS);
		end
	endtask

	// ------------------------------------------------------------------
	// Input helpers
	// ------------------------------------------------------------------
	task press;            // bit 0..3 high active, 4/5/9 low active
		input integer b;
		input integer hold_ms;
		begin
			inputs[b] = (b == 4 || b == 5 || b == 9) ? 1'b0 : 1'b1;
			wait_ms(hold_ms);
			inputs[b] = (b == 4 || b == 5 || b == 9) ? 1'b1 : 1'b0;
			wait_ms(GAP / MS);
		end
	endtask
	task switch;           // logical ON/OFF; pin is inverted (SW_INV = 1)
		input integer b;
		input on;
		begin
			inputs[b] = ~on;
			wait_ms(250);
		end
	endtask

	// ------------------------------------------------------------------
	// Pin decoders
	// ------------------------------------------------------------------
	// 8x8 matrix: collect the rows the scanner shows during a window
	reg [7:0] macc [0:7];
	integer mhits [0:7];
	reg mgrab = 0;
	integer mclocks;
	always @(negedge clk) if (!dut.rst) begin
		check(outputs[7:0] == 0 || (outputs[7:0] & (outputs[7:0] - 1)) == 0, "matrix drives at most one row");
		if (mgrab) begin
			mclocks = mclocks + 1;
			for (k = 0; k < 8; k = k + 1)
				if (outputs[k]) begin
					macc[k] = macc[k] | outputs[15:8];
					mhits[k] = mhits[k] + 1;
				end
		end
	end
	task grab_matrix;
		output [63:0] f;
		integer q;
		begin
			for (q = 0; q < 8; q = q + 1) begin
				macc[q] = 0;
				mhits[q] = 0;
			end
			mclocks = 0;
			@(negedge clk);
			mgrab = 1;
			repeat (24) @(negedge clk);
			mgrab = 0;
			for (q = 0; q < 8; q = q + 1) f[q * 8 +: 8] = macc[q];
		end
	endtask

	// 7-segment: SEL_INV = 1, so a select pin at 0 is the active digit
	function integer seg_digit;
		input [6:0] s;
		case (s)
			7'b0111111 : seg_digit = 0;
			7'b0000110 : seg_digit = 1;
			7'b1011011 : seg_digit = 2;
			7'b1001111 : seg_digit = 3;
			7'b1100110 : seg_digit = 4;
			7'b1101101 : seg_digit = 5;
			7'b1111101 : seg_digit = 6;
			7'b0000111 : seg_digit = 7;
			7'b1111111 : seg_digit = 8;
			7'b1101111 : seg_digit = 9;
			default : seg_digit = -1;
		endcase
	endfunction
	integer x_tens = -1, x_ones = -1, y_tens = -1, y_ones = -1;
	always @(negedge clk) if (!dut.rst) begin
		check(outputs[35:34] == 2'b10 || outputs[35:34] == 2'b01, "X digit select one-hot (low active)");
		check(outputs[44:43] == 2'b10 || outputs[44:43] == 2'b01, "Y digit select one-hot (low active)");
		check(seg_digit(outputs[33:27]) >= 0 && seg_digit(outputs[42:36]) >= 0, "valid 7-segment codes");
		if (outputs[34] == 0) x_tens = seg_digit(outputs[33:27]); else x_ones = seg_digit(outputs[33:27]);
		if (outputs[43] == 0) y_tens = seg_digit(outputs[42:36]); else y_ones = seg_digit(outputs[42:36]);
	end
	function integer disp_x;
		input dummy;
		disp_x = x_tens * 10 + x_ones;
	endfunction
	function integer disp_y;
		input dummy;
		disp_y = y_tens * 10 + y_ones;
	endfunction

	// LCD model: RST high clears + homes, EN falling edge with RS = 1 writes code + 0x20
	reg [7:0] lcd [0:31];
	integer lcd_addr = 0, lcd_batches = 0;
	always @(posedge outputs[52]) begin
		for (k = 0; k < 32; k = k + 1) lcd[k] = " ";
		lcd_addr = 0;
	end
	always @(negedge outputs[26]) if (!dut.rst) begin
		check(outputs[25] === 0 && outputs[52] === 0, "LCD write with RW and RST low");
		if (outputs[24]) begin
			if (lcd_addr < 32) lcd[lcd_addr] = outputs[23:16] + 8'h20;
			lcd_addr = lcd_addr + 1;
			if (lcd_addr == 32) lcd_batches = lcd_batches + 1;
		end
	end
	task lcd_settle;      // wait until the driver has nothing left to send
		begin
			@(negedge clk);
			while (!(dut.lcd.state == 1 && !dut.lcd.changed)) @(negedge clk);
		end
	endtask
	function [127:0] lcd_line;
		input integer row;
		integer q;
		begin
			for (q = 0; q < 16; q = q + 1) lcd_line[127 - 8 * q -: 8] = lcd[row * 16 + q];
		end
	endfunction
	task check_lcd;
		input [127:0] a, b;
		begin
			lcd_settle;
			if (lcd_line(0) !== a || lcd_line(1) !== b) begin
				$display("   LCD shows [%s] [%s], expected [%s] [%s]", lcd_line(0), lcd_line(1), a, b);
				$fdisplay(log, "   LCD shows [%s] [%s], expected [%s] [%s]", lcd_line(0), lcd_line(1), a, b);
			end
			check(lcd_line(0) === a, "LCD line 1");
			check(lcd_line(1) === b, "LCD line 2");
		end
	endtask
	function [7:0] dch;
		input integer v;
		dch = 8'h30 + v;
	endfunction
	function [127:0] play_line1;
		input integer hp, pings, ready;
		play_line1 = { "HP:", dch(hp), " SON:", dch(pings), " T:", dch(ready), "  " };
	endfunction
	// DIST counts to the nearest cell of the goal cross; with the current switch ON the
	// last shift direction follows (N/S/W/E, '-' before the first shift)
	function [127:0] play_line2;
		input integer d;
		input cur_on;
		input [7:0] cur;
		play_line2 = { "DIST:", dch(d / 100), dch((d / 10) % 10), dch(d % 10),
		               cur_on ? { " CUR:", cur, "  " } : "        " };
	endfunction
	function [7:0] cur_letter;
		input dummy;
		cur_letter = !dut.core.drift_seen ? "-" : dut.core.drift_dir == 0 ? "N" :
		             dut.core.drift_dir == 1 ? "S" : dut.core.drift_dir == 2 ? "W" : "E";
	endfunction

	function integer hp_leds_lit;
		input dummy;
		integer q;
		begin
			hp_leds_lit = 0;
			for (q = 0; q < 8; q = q + 1) if (hp_led[q] == 0) hp_leds_lit = hp_leds_lit + 1;
		end
	endfunction

	// ------------------------------------------------------------------
	// Reference model (independent of the RTL viewport logic)
	// ------------------------------------------------------------------
	function mine;
		input integer mx, my;
		mine = (mx < 0 || mx > 63 || my < 0 || my > 63) ? 1'b0 : dut.core.map_ram.mem[my][mx];
	endfunction
	function on_goal;
		input integer mx, my;
		integer gx, gy;
		begin
			gx = dut.core.goal_x;
			gy = dut.core.goal_y;
			on_goal = (mx == gx && my == gy) || (mx == gx && (my == gy - 1 || my == gy + 1)) ||
			          (my == gy && (mx == gx - 1 || mx == gx + 1));
		end
	endfunction
	function [63:0] render;
		input integer px, py;
		input show_mines;
		integer vx, vy, wx, wy;
		begin
			render = 0;
			for (vy = 0; vy < 8; vy = vy + 1)
				for (vx = 0; vx < 8; vx = vx + 1) begin
					wx = px + vx - 3;
					wy = py + vy - 3;
					if (wx < 0 || wx > 63 || wy < 0 || wy > 63) render[vy * 8 + vx] = 1;
					else if (on_goal(wx, wy) || (show_mines && mine(wx, wy))) render[vy * 8 + vx] = 1;
				end
			render[27] = 1;
		end
	endfunction
	function expect_warn;
		input integer px, py;
		integer dx, dy;
		begin
			expect_warn = 0;
			for (dy = -2; dy <= 2; dy = dy + 1)
				for (dx = -2; dx <= 2; dx = dx + 1)
					if ((dx < 0 ? -dx : dx) + (dy < 0 ? -dy : dy) <= 2 && mine(px + dx, py + dy))
						expect_warn = 1;
		end
	endfunction
	function integer absd;
		input integer a, b;
		absd = (a > b) ? a - b : b - a;
	endfunction

	task show_frame;
		input [63:0] f;
		integer q, w;
		reg [8*8-1:0] s;
		begin
			for (q = 0; q < 8; q = q + 1) begin
				for (w = 0; w < 8; w = w + 1) s[63 - 8 * w -: 8] = f[q * 8 + w] ? "#" : ".";
				$fdisplay(log, "      %s", s);
			end
		end
	endtask

	// Full check of every display at the current position
	reg [63:0] frame;
	integer px, py, gx, gy, warn_seen, green_seen;
	task check_displays;
		input show_mines;
		begin
			px = dut.core.sub_x;
			py = dut.core.sub_y;
			gx = dut.core.goal_x;
			gy = dut.core.goal_y;
			check(disp_x(0) == px && disp_y(0) == py, "7-segment shows submarine X/Y");
			grab_matrix(frame);
			if (frame !== render(px, py, show_mines)) begin
				$fdisplay(log, "   matrix mismatch at (%0d,%0d): got / expected", px, py);
				show_frame(frame);
				$fdisplay(log, "   ---");
				show_frame(render(px, py, show_mines));
			end
			check(frame === render(px, py, show_mines), "matrix frame matches map");
			check(outputs[45] == (gy < py) && outputs[46] == (gy > py) &&
			      outputs[47] == (gx < px) && outputs[48] == (gx > px), "compass LEDs");
			check(hp_leds_lit(0) == dut.core.hp, "on-board HP LEDs");
			check(outputs[53] == dut.core.sonar_active, "sonar LED");
			warn_seen = 0;
			green_seen = 0;
			for (k = 0; k < 120; k = k + 1) begin
				@(negedge clk);
				if (outputs[50]) warn_seen = 1;
				if (outputs[49]) green_seen = 1;
			end
			check(warn_seen == expect_warn(px, py), "yellow warning LED");
			check(green_seen == (!expect_warn(px, py) && !dut.core.hit_active), "green safe LED");
			check_lcd(play_line1(dut.core.hp, dut.core.pings, dut.core.torpedoes),
				expect_warn(px, py) ? "WARN: MINE NEAR!" :
				play_line2(absd(px, gx) + absd(py, gy) - 1, dut.drift_sw, cur_letter(0)));
		end
	endtask

	// ------------------------------------------------------------------
	// Autopilot: BFS from the goal cross over mine-free cells
	// ------------------------------------------------------------------
	integer bd [0:4095];
	integer bq [0:4095];
	task bfs;
		integer head, tail, c, cx, cy, nx, ny, dir;
		begin
			for (c = 0; c < 4096; c = c + 1) bd[c] = -1;
			head = 0;
			tail = 0;
			for (c = 0; c < 4096; c = c + 1)
				if (on_goal(c % 64, c / 64)) begin
					bd[c] = 0;
					bq[tail] = c;
					tail = tail + 1;
				end
			while (head < tail) begin
				c = bq[head];
				head = head + 1;
				cx = c % 64;
				cy = c / 64;
				for (dir = 0; dir < 4; dir = dir + 1) begin
					nx = cx + (dir == 2 ? -1 : dir == 3 ? 1 : 0);
					ny = cy + (dir == 0 ? -1 : dir == 1 ? 1 : 0);
					if (nx >= 0 && nx < 64 && ny >= 0 && ny < 64 && bd[ny * 64 + nx] < 0 && !mine(nx, ny)) begin
						bd[ny * 64 + nx] = bd[c] + 1;
						bq[tail] = ny * 64 + nx;
						tail = tail + 1;
					end
				end
			end
		end
	endtask
	function integer next_dir;     // 0 up, 1 down, 2 left, 3 right, -1 none
		input integer cx, cy;
		integer dir, nx, ny, best;
		begin
			next_dir = -1;
			best = bd[cy * 64 + cx];
			for (dir = 0; dir < 4; dir = dir + 1) begin
				nx = cx + (dir == 2 ? -1 : dir == 3 ? 1 : 0);
				ny = cy + (dir == 0 ? -1 : dir == 1 ? 1 : 0);
				if (nx >= 0 && nx < 64 && ny >= 0 && ny < 64 && bd[ny * 64 + nx] >= 0 &&
				    bd[ny * 64 + nx] < best && next_dir < 0)
					next_dir = dir;
			end
		end
	endfunction

	reg [4095:0] path;
	task dump_map;
		integer q, w;
		reg [64*8-1:0] s;
		begin
			$fdisplay(log, "   map (S start, G goal cross, * mine, o path):");
			for (q = 0; q < 64; q = q + 1) begin
				for (w = 0; w < 64; w = w + 1)
					s[511 - 8 * w -: 8] = (w == sx && q == sy) ? "S" : on_goal(w, q) ? "G" :
					                      mine(w, q) ? "*" : path[q * 64 + w] ? "o" : ".";
				$fdisplay(log, "   %s", s);
			end
		end
	endtask

	task autopilot;
		input integer check_every;
		integer dir, ox, oy, hp_before;
		begin
			steps = 0;
			path = 0;
			while (dut.core.state == 2 && steps < 400) begin
				bfs;
				px = dut.core.sub_x;
				py = dut.core.sub_y;
				dir = next_dir(px, py);
				if (dir < 0) begin
					check(0, "autopilot found no path");
					steps = 999;
				end
				else begin
					ox = px + (dir == 2 ? -1 : dir == 3 ? 1 : 0);
					oy = py + (dir == 0 ? -1 : dir == 1 ? 1 : 0);
					hp_before = dut.core.hp;
					press(dir, HOLD / MS);
					steps = steps + 1;
					path[oy * 64 + ox] = 1;
					check(dut.core.sub_x == ox && dut.core.sub_y == oy, "button press moves exactly one cell");
					check(dut.core.hp == hp_before || dut.core.state != 2, "autopilot avoids mines");
					if (dut.core.state == 2 && (steps % check_every) == 0) check_displays(dut.demo_sw);
				end
			end
		end
	endtask

	// ------------------------------------------------------------------
	// Scenario
	// ------------------------------------------------------------------
	integer drift_bad, hits, hp_before, dd, ox, oy, exp_m, t_shift, t_first, shift_i;   // shift_i: k is shared with the pin decoders
	reg [63:0] snap [0:63];
	initial begin
		log = $fopen("game_log.txt", "w");
		note("power on (500 Hz clock, all switches OFF)");
		wait_ms(600);

		// ---- Idle screen ----
		check_lcd("LV:NORM CUR:OFF ", "PRESS GO TO DIVE");
		grab_matrix(frame);
		check(frame == 64'h0000001818000000, "idle matrix pattern");
		check(hp_leds_lit(0) == 8, "8 HP LEDs at power up");
		check(outputs[53:45] == 0 || outputs[53:45] == 9'b0, "status LEDs dark in idle");
		check(lcd_batches == 1, "single LCD draw at power up");
		note("idle screen OK: LCD [LV:NORM CUR:OFF ][PRESS GO TO DIVE], matrix centre dot, 8 HP LEDs");

		// ---- Switch polarity is visible on the idle screen ----
		switch(6, 1);
		check_lcd("LV:HARD CUR:OFF ", "PRESS GO TO DIVE");
		switch(7, 1);
		check_lcd("LV:HARD CUR:ON  ", "PRESS GO TO DIVE");
		switch(6, 0);
		switch(7, 0);
		check_lcd("LV:NORM CUR:OFF ", "PRESS GO TO DIVE");
		note("difficulty / current switches update the idle LCD");

		// ================= GAME 1: normal =================
		press(5, HOLD / MS);
		wait_ms(200);
		check(dut.core.state == 2, "GO starts a game");
		sx = dut.core.sub_x;
		sy = dut.core.sub_y;
		gx = dut.core.goal_x;
		gy = dut.core.goal_y;
		n = absd(sx, gx) + absd(sy, gy) - 1;      // to the nearest cell of the goal cross
		$fdisplay(log, "");
		note("GAME 1 (normal) started");
		$fdisplay(log, "   start (%0d,%0d)  goal (%0d,%0d)  distance %0d", sx, sy, gx, gy, n);
		$display("   start (%0d,%0d)  goal (%0d,%0d)  distance %0d", sx, sy, gx, gy, n);
		check(n >= 24 && n <= 48, "normal distance range");
		check_displays(0);
		grab_matrix(frame);
		$fdisplay(log, "   matrix at start:");
		show_frame(frame);

		// ---- Debounce: short tap ignored, long hold = one step ----
		press(1, 40);
		check(dut.core.sub_y == sy, "40 ms tap is filtered out");
		press(0, 1000);
		check(dut.core.sub_y == sy - 1, "1 s hold moves exactly one cell");
		press(1, 130);
		check(dut.core.sub_y == sy, "130 ms press registers");
		note("buttons: 40 ms tap ignored, 130 ms press accepted, 1 s hold = single step");

		// ---- Sonar ----
		press(4, HOLD / MS);
		check(dut.core.pings == 8 && outputs[53], "sonar fired, sonar LED on");
		wait(dut.core.ripple == 0 && dut.core.reveal_ticks != 0);
		wait_ms(150);
		check_displays(1);
		$fdisplay(log, "   matrix during sonar reveal (mines visible):");
		show_frame(frame);
		wait(!dut.core.sonar_active);
		wait_ms(150);
		check_displays(0);
		note("sonar: ripple, full reveal, LED and SON count OK");

		// ---- Warning + torpedo (planted mine north of the submarine) ----
		press(0, HOLD / MS);                      // face north at (sx, sy-1)
		dut.core.map_ram.mem[sy - 2][sx] = 1;
		wait_ms(150);
		check_displays(0);
		check(warn_seen == 1, "warning for mine one cell ahead");
		press(9, HOLD / MS);                      // torpedo button
		check(dut.core.map_ram.mem[sy - 2][sx] == 0 && dut.core.torpedoes == 5, "torpedo clears mine ahead, 5 left");
		wait_ms(300);                             // let the explosion animation finish
		check_displays(0);
		note("warning LED/LCD and torpedo button OK");

		// ---- Hit ----
		dut.core.map_ram.mem[sy - 2][sx] = 1;
		inputs[0] = 1;
		wait(dut.core.hit_active);
		grab_matrix(frame);
		check(frame == 64'hffffffffffffffff, "hit flash on matrix");
		k = 0;
		for (i = 0; i < 200; i = i + 1) begin
			@(negedge clk);
			if (outputs[51]) k = k + 1;
		end
		check(k > 0, "red LED blinks on hit");
		inputs[0] = 0;
		wait_ms(400);
		check(dut.core.hp == 7, "HP 7 after hit");
		check_displays(0);
		note("mine hit: HP 7, matrix flash, red LED, HP LEDs = 7");

		// ---- Drive to the goal ----
		autopilot(1);
		check(dut.core.state == 3, "game 1 reaches goal");
		if (dut.core.state == 3) games_won = games_won + 1;
		// Win screen: all mines in view first, then the ring sweeps them away
		px = dut.core.sub_x;
		py = dut.core.sub_y;
		grab_matrix(frame);
		check(frame === render(px, py, 1), "win screen shows every mine in view");
		$fdisplay(log, "   matrix right after the win (all mines in view):");
		show_frame(frame);
		dump_map;
		$fdisplay(log, "   autopilot steps: %0d", steps);
		check_lcd("MISSION CLEAR!! ", "PRESS GO RESTART");
		check(outputs[49] && !outputs[51], "green LED on after win");
		check(outputs[48:45] == 0, "compass off after win");
		wait_ms(3000);
		grab_matrix(frame);
		check(frame === render(px, py, 0), "win ring has swept all mines away");
		$fdisplay(log, "   matrix after the win sweep:");
		show_frame(frame);
		note("GAME 1 cleared: LCD MISSION CLEAR, green LED, win screen shows mines then sweeps them away");

		// ================= GAME 2: hard (current tested separately below) =================
		switch(6, 1);
		press(5, HOLD / MS);
		wait_ms(200);
		check(dut.core.state == 2 && dut.core.hard, "hard game started");
		sx = dut.core.sub_x;
		sy = dut.core.sub_y;
		gx = dut.core.goal_x;
		gy = dut.core.goal_y;
		n = absd(sx, gx) + absd(sy, gy) - 1;      // to the nearest cell of the goal cross
		$fdisplay(log, "");
		note("GAME 2 (hard) started");
		$fdisplay(log, "   start (%0d,%0d)  goal (%0d,%0d)  distance %0d", sx, sy, gx, gy, n);
		$display("   start (%0d,%0d)  goal (%0d,%0d)  distance %0d", sx, sy, gx, gy, n);
		check(n >= 64, "hard distance range");
		// Hard game: 3 torpedoes; holding the button fires exactly once
		check(dut.core.torpedoes == 3, "hard game has 3 torpedoes");
		dut.core.map_ram.mem[sy - 1][sx] = 1;
		dut.core.map_ram.mem[sy - 2][sx] = 1;
		press(9, 1500);
		check(dut.core.torpedoes == 2 && dut.core.map_ram.mem[sy - 1][sx] == 0, "torpedo fires north at game start");
		check(dut.core.map_ram.mem[sy - 2][sx] == 1, "held torpedo button fires only once");
		press(9, HOLD / MS);
		check(dut.core.torpedoes == 1 && dut.core.map_ram.mem[sy - 2][sx] == 0, "second torpedo flies on to the next mine");
		wait_ms(300);
		press(9, HOLD / MS);
		wait_ms(300);
		press(9, HOLD / MS);
		wait_ms(300);
		check(dut.core.torpedoes == 0, "no more than 3 torpedoes in hard mode");
		wait_ms(150);                             // let the viewport redraw after editing the map
		check_displays(0);

		// ---- Demo switch ----
		switch(10, 1);
		wait_ms(150);
		check_displays(1);
		$fdisplay(log, "   matrix with Demo ON:");
		show_frame(frame);
		switch(10, 0);
		wait_ms(150);
		check_displays(0);
		note("torpedo: 3 in hard mode, held button fires once, flies to next mine; Demo switch shows mines");

		// ---- Current: switch ON, wait for two map shifts without moving ----
		switch(7, 1);
		wait_ms(150);
		check_displays(0);                        // LCD line 2 shows CUR:- before the first shift
		for (shift_i = 0; shift_i < 2; shift_i = shift_i + 1) begin
			px = dut.core.sub_x;
			py = dut.core.sub_y;
			hp_before = dut.core.hp;
			for (j = 0; j < 64; j = j + 1) snap[j] = dut.core.map_ram.mem[j];
			wait(dut.core.drift_busy);
			t_shift = $time / MS;
			if (shift_i == 1) begin
				$fdisplay(log, "   second shift %0d ms after the first", t_shift - t_first);
				check(t_shift - t_first >= 4950 && t_shift - t_first <= 5050, "current shifts the map every 5 s");
			end
			t_first = t_shift;
			wait(!dut.core.drift_busy);
			dd = dut.core.drift_dir;
			drift_bad = 0;
			hits = 0;
			for (j = 0; j < 64; j = j + 1)
				for (i = 0; i < 64; i = i + 1) begin
					ox = i + (dd == 2 ? 1 : dd == 3 ? -1 : 0);
					oy = j + (dd == 0 ? 1 : dd == 1 ? -1 : 0);
					if (ox >= 0 && ox < 64 && oy >= 0 && oy < 64) begin
						exp_m = snap[oy][ox];
						if (absd(i, gx) <= 2 && absd(j, gy) <= 2) exp_m = 0;
						if (i == px && j == py) begin
							hits = exp_m;
							exp_m = 0;
						end
						if (dut.core.map_ram.mem[j][i] !== exp_m) drift_bad = drift_bad + 1;
					end
				end
			$fdisplay(log, "   current shift %0d: direction %s, %0d mine(s) pushed onto the submarine",
				shift_i + 1, cur_letter(0), hits);
			check(drift_bad == 0, "current shifts every mine one cell");
			check(dut.core.sub_x == px && dut.core.sub_y == py, "submarine stays put in the current");
			check(dut.core.hp == hp_before - hits, "mine pushed onto the submarine costs one HP");
			wait_ms(600);                         // let a hit animation finish
			check_displays(0);                    // LCD line 2 shows the direction, matrix the shifted map
		end
		switch(7, 0);
		note("current: map shifts one cell every 5 s, LCD shows the direction");

		autopilot(5);
		check(dut.core.state == 3, "game 2 reaches goal");
		if (dut.core.state == 3) games_won = games_won + 1;
		dump_map;
		$fdisplay(log, "   autopilot steps: %0d", steps);
		note("GAME 2 finished");
		switch(6, 0);
		switch(7, 0);

		// ================= GAME 3: lose on purpose =================
		press(5, HOLD / MS);
		wait_ms(200);
		$fdisplay(log, "");
		note("GAME 3 (normal): walking into planted mines until the hull breaks");
		sx = dut.core.sub_x;
		sy = dut.core.sub_y;
		for (i = 0; i < 8; i = i + 1) begin
			j = (i % 2 == 0) ? 0 : 1;           // alternate up / down
			if (j == 0) dut.core.map_ram.mem[sy - 1][sx] = 1;
			else dut.core.map_ram.mem[sy][sx] = 1;
			press(j, HOLD / MS);
			wait_ms(400);
			check(dut.core.hp == 7 - i, "each mine costs one HP");
			check(hp_leds_lit(0) == 7 - i, "HP LEDs follow HP");
		end
		check(dut.core.state == 4, "eighth hit loses");
		check_lcd("HULL BREACHED!! ", "PRESS GO RESTART");
		k = 0;
		for (i = 0; i < 100; i = i + 1) begin
			@(negedge clk);
			if (!outputs[51]) k = k + 1;
		end
		check(k == 0, "red LED steady after defeat");
		check(hp_led == 8'hff, "all HP LEDs off");
		note("defeat: LCD HULL BREACHED, red LED steady, HP LEDs off");

		// ================= GAME 4: restart mid-game =================
		press(5, HOLD / MS);
		wait_ms(200);
		press(0, HOLD / MS);
		press(5, HOLD / MS);
		wait_ms(200);
		check(dut.core.state == 2 && dut.core.hp == 8 && dut.core.pings == 9 && dut.core.torpedoes == 6,
			"GO during play restarts with full resources");
		check_displays(0);
		note("restart during play OK");

		// ---- Matrix refresh statistics ----
		grab_matrix(frame);
		n = 0;
		for (i = 0; i < 8; i = i + 1) if (mhits[i] > 0) n = n + 1;
		$fdisplay(log, "   matrix: %0d lit rows -> each row refreshed at %0d Hz (500 Hz / %0d)", n, 500 / n, n);
		note("matrix refresh measured");

		$fdisplay(log, "");
		if (errors == 0) note("PASS: full game simulation");
		else begin
			$display("FAIL: %0d checks", errors);
			$fdisplay(log, "FAIL: %0d checks", errors);
		end
		$display("games won by autopilot: %0d of 2", games_won);
		$fclose(log);
		$finish;
	end
	initial begin
		#(600 * 1000 * MS);
		errors = errors + 1;
		$display("FAIL: game timeout");
		$finish;
	end
endmodule
