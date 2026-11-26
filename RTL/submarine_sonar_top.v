// Top level. inputs[0..13] / outputs[0..53] match VeriInstrument inputN / outputN numbers.
// Defaults assume the 500 Hz main clock supplied by VeriComm.
// Unused (free) inputs: inputs[8], inputs[11], inputs[12], inputs[13].
module submarine_sonar_top #(
	parameter CLK_FREQ = 500,
	parameter MAT_ROW_INV = 0, MAT_COL_INV = 0,
	parameter SEG_INV = 0, SEL_INV = 1,
	parameter SW_INV = 1,                  // 1: switches read 0 when ON (difficulty, current, demo)
	parameter TORP_LOW_ACTIVE = 1,         // torpedo button on inputs[9]: 1 = low active (like LA buttons)
	parameter POR_CYCLES = 8)
	(input clk, input [13:0] inputs, output [53:0] outputs, output [7:0] led_board);

	reg [7:0] por = 0;
	wire rst = (por < POR_CYCLES);
	always @(posedge clk) if (rst) por <= por + 1'b1;

	wire scan_tick, key_tick, anim_tick;
	sonar_ticks #(CLK_FREQ) ticks(clk, rst, scan_tick, key_tick, anim_tick);

	// Normalize every input to "1 = pressed / ON" before debouncing:
	// inputs[4], inputs[5] are low-active buttons; inputs[9] (torpedo button) follows TORP_LOW_ACTIVE;
	// switch polarity (bits 6, 7, 10) follows SW_INV
	localparam [13:0] IN_INV = 14'h0030 |
		((TORP_LOW_ACTIVE != 0) ? 14'h0200 : 14'h0000) |
		((SW_INV != 0) ? 14'h04C0 : 14'h0000);
	wire [13:0] raw = inputs ^ IN_INV;
	wire [13:0] keys, press;
	genvar k;
	generate
		for (k = 0; k < 14; k = k + 1) begin : buttons
			btn_debouncer db(clk, rst, key_tick, raw[k], keys[k], press[k]);
		end
	endgenerate

	wire diff_sw  = keys[6];
	wire drift_sw = keys[7];
	wire demo_sw  = keys[10];
	wire torp_fire = press[9];            // one shot per press; holding does not repeat
	wire [3:0] movement = press[3:0];     // one press = one step

	wire [5:0] x, y, gx, gy;
	wire [3:0] hp, pings;
	wire [2:0] torps;
	wire warn, sonar_busy, hit;
	wire [2:0] game_state;
	wire [6:0] goal_dist;
	wire [63:0] pixels;
	wire [1:0] drift_dir;
	wire drift_seen;

	sonar_game_core core(
		clk, rst, anim_tick, movement, press[4], press[5], torp_fire,
		diff_sw, drift_sw, demo_sw, x, y, gx, gy, hp, pings, torps, game_state, warn,
		sonar_busy, hit, goal_dist, pixels, drift_dir, drift_seen
	);

	matrix_8x8_driver #(MAT_ROW_INV, MAT_COL_INV) mat(clk, rst, scan_tick, pixels, outputs[7:0], outputs[15:8]);
	dual_7seg_driver #(SEG_INV, SEL_INV) sx(clk, rst, scan_tick, x, outputs[33:27], outputs[35:34]);
	dual_7seg_driver #(SEG_INV, SEL_INV) sy(clk, rst, scan_tick, y, outputs[42:36], outputs[44:43]);

	reg blink;
	always @(posedge clk) begin
		if (rst) blink <= 0;
		else if (anim_tick) blink <= ~blink;
	end

	assign led_board = ~(8'hff >> (8 - hp));   // on-board LEDs are low-active; lit count = HP
	assign outputs[45] = (game_state == 2) && (gy < y);   // north
	assign outputs[46] = (game_state == 2) && (gy > y);   // south
	assign outputs[47] = (game_state == 2) && (gx < x);   // west
	assign outputs[48] = (game_state == 2) && (gx > x);   // east
	assign outputs[49] = (game_state == 3) || (game_state == 2 && !warn && !hit);
	assign outputs[50] = (game_state == 2) && warn && blink;
	assign outputs[51] = (game_state == 4) || (hit && blink);
	assign outputs[53] = sonar_busy;

	wire dist_ge100 = (goal_dist >= 7'd100);
	wire [6:0] dist_rem = dist_ge100 ? (goal_dist - 7'd100) : goal_dist;
	reg [3:0] dist_tens, dist_ones;
	reg [6:0] ones7;
	always @* begin
		if (dist_rem >= 7'd90)      begin dist_tens = 4'd9; ones7 = dist_rem - 7'd90; end
		else if (dist_rem >= 7'd80) begin dist_tens = 4'd8; ones7 = dist_rem - 7'd80; end
		else if (dist_rem >= 7'd70) begin dist_tens = 4'd7; ones7 = dist_rem - 7'd70; end
		else if (dist_rem >= 7'd60) begin dist_tens = 4'd6; ones7 = dist_rem - 7'd60; end
		else if (dist_rem >= 7'd50) begin dist_tens = 4'd5; ones7 = dist_rem - 7'd50; end
		else if (dist_rem >= 7'd40) begin dist_tens = 4'd4; ones7 = dist_rem - 7'd40; end
		else if (dist_rem >= 7'd30) begin dist_tens = 4'd3; ones7 = dist_rem - 7'd30; end
		else if (dist_rem >= 7'd20) begin dist_tens = 4'd2; ones7 = dist_rem - 7'd20; end
		else if (dist_rem >= 7'd10) begin dist_tens = 4'd1; ones7 = dist_rem - 7'd10; end
		else                        begin dist_tens = 4'd0; ones7 = dist_rem;          end
		dist_ones = ones7[3:0];
	end

	// Current direction letter for the LCD ('-' until the first shift of this game)
	reg [7:0] cur_char;
	always @* begin
		if (!drift_seen) cur_char = "-";
		else case (drift_dir)
			2'd0 : cur_char = "N";
			2'd1 : cur_char = "S";
			2'd2 : cur_char = "W";
			default : cur_char = "E";
		endcase
	end

	// Two 16-character LCD lines (ASCII, leftmost character in the MSBs)
	reg [127:0] line1, line2;
	always @* begin
		line1 = { "HP:", (8'd48 + { 4'b0, hp }), " SON:", (8'd48 + { 4'b0, pings }), " T:", (8'd48 + { 5'b0, torps }), "  " };
		line2 = { "DIST:", (dist_ge100 ? 8'h31 : 8'h30), (8'd48 + { 4'b0, dist_tens }), (8'd48 + { 4'b0, dist_ones }),
		          (drift_sw ? { " CUR:", cur_char, "  " } : "        ") };
		case (game_state)
			0 : begin
				// Idle screen shows the live difficulty / current switches (handy for checking polarity)
				line1 = { "LV:", (diff_sw ? "HARD" : "NORM"), " CUR:", (drift_sw ? "ON " : "OFF"), " " };
				line2 = "PRESS GO TO DIVE";
			end
			1, 5 : begin
				line1 = "GENERATING MAP  ";
				line2 = "PLEASE WAIT...  ";
			end
			3 : begin
				line1 = "MISSION CLEAR!! ";
				line2 = "PRESS GO RESTART";
			end
			4 : begin
				line1 = "HULL BREACHED!! ";
				line2 = "PRESS GO RESTART";
			end
			default : if (warn) line2 = "WARN: MINE NEAR!";
		endcase
	end

	text_lcd_driver lcd(clk, rst, line1, line2, outputs[23:16], outputs[24], outputs[25], outputs[26], outputs[52]);
endmodule
