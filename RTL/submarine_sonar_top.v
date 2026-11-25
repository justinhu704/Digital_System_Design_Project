// inputs[0..13] and outputs[0..53] correspond exactly to VeriInstrument numbers.
// Tuned for 500 Hz VeriInstrument clock with clean single-step button debounce
module submarine_sonar_top #(
	parameter CLK_FREQ = 500, MAT_ROW_INV = 0, MAT_COL_INV = 0,
	parameter SEG_INV = 0, SEL_INV = 1, ROT_SWAP = 0, ROT_INV = 0,
	parameter POR_CYCLES = 8,
	parameter LCD_POWER_ON_US = 10, LCD_SETUP_US = 10, LCD_ENABLE_US = 10,
	parameter LCD_COMMAND_US = 10, LCD_CLEAR_US = 10, LCD_POLL_US = 10)
	(input clk, input [13:0] inputs, output [53:0] outputs, output [7:0] led_board);

	reg [7:0] por = 0;
	wire rst = (por < POR_CYCLES);
	always @(posedge clk) if (rst) por <= por + 1'b1;

	wire scan_tick, key_tick, anim_tick;
	sonar_ticks #(CLK_FREQ) ticks(clk, rst, scan_tick, key_tick, anim_tick);

	wire [13:0] raw = inputs ^ 14'h0030;
	wire [13:0] keys, press;
	genvar k;
	generate
		for (k = 0; k < 14; k = k + 1) begin : buttons
			btn_debouncer db(clk, rst, key_tick, raw[k], keys[k], press[k]);
		end
	endgenerate

	// Rotary A/B synchronized at full speed
	reg [1:0] ra, rb;
	reg [1:0] prev_ab;
	reg signed [4:0] rotary_sum;
	reg [1:0] zone;
	wire [1:0] ab = ROT_SWAP ? { rb[1], ra[1] } : { ra[1], rb[1] };
	reg signed [4:0] step;
	always @* begin
		case ({ prev_ab, ab })
			4'b0001, 4'b0111, 4'b1110, 4'b1000 : step = 5'sd1;
			4'b0010, 4'b1011, 4'b1101, 4'b0100 : step = -5'sd1;
			default : step = 5'sd0;
		endcase
	end

	wire [2:0] game_state;
	always @(posedge clk) begin
		ra <= { ra[0], inputs[11] ^ (ROT_INV != 0) };
		rb <= { rb[0], inputs[12] ^ (ROT_INV != 0) };
		if (rst) begin
			ra <= 0;
			rb <= 0;
			prev_ab <= 0;
			zone <= 0;
			rotary_sum <= 0;
		end
		else begin
			prev_ab <= ab;
			if (game_state == 0 || game_state == 3 || game_state == 4) begin
				if (rotary_sum + step >= 5'sd4) begin
					zone <= zone + 1'b1;
					rotary_sum <= 0;
				end
				else if (rotary_sum + step <= -5'sd4) begin
					zone <= zone - 1'b1;
					rotary_sum <= 0;
				end
				else if (step != 0) rotary_sum <= rotary_sum + step;
				else if (prev_ab != ab) rotary_sum <= 0;
			end
			else rotary_sum <= 0;
		end
	end

	wire diff_sw  = ~keys[6];
	wire drift_sw = ~keys[7];
	wire demo_sw  = ~keys[10];

	reg prev_torp_sw;
	always @(posedge clk) begin
		if (rst) prev_torp_sw <= keys[9];
		else prev_torp_sw <= keys[9];
	end
	wire torp_fire = (keys[9] != prev_torp_sw);

	// Pure single-step movement from debounced rising edge (prevents double-stepping)
	wire [3:0] movement = press[3:0];

	wire [5:0] x, y, gx, gy;
	wire [3:0] hp, pings;
	wire ready, warn, sonar_busy, hit;
	wire [6:0] dist;
	wire [63:0] pixels;

	sonar_game_core core(
		clk, rst, anim_tick, movement, press[4], press[5], torp_fire,
		diff_sw, drift_sw, demo_sw, zone, x, y, gx, gy, hp, pings, ready, game_state, warn,
		sonar_busy, hit, dist, pixels
	);

	matrix_8x8_driver #(MAT_ROW_INV, MAT_COL_INV) mat(clk, rst, scan_tick, pixels, outputs[7:0], outputs[15:8]);
	dual_7seg_driver #(SEG_INV, SEL_INV) sx(clk, rst, scan_tick, x, outputs[33:27], outputs[35:34]);
	dual_7seg_driver #(SEG_INV, SEL_INV) sy(clk, rst, scan_tick, y, outputs[42:36], outputs[44:43]);

	reg blink;
	always @(posedge clk) begin
		if (rst) blink <= 0;
		else if (anim_tick) blink <= ~blink;
	end

	assign led_board = ~(8'hff >> (8 - hp));
	assign outputs[45] = (game_state == 2) && (gy < y);
	assign outputs[46] = (game_state == 2) && (gy > y);
	assign outputs[47] = (game_state == 2) && (gx < x);
	assign outputs[48] = (game_state == 2) && (gx > x);
	assign outputs[49] = (game_state == 3) || (game_state == 2 && !warn && !hit);
	assign outputs[50] = (game_state == 2) && warn && blink;
	assign outputs[51] = (game_state == 4) || (hit && blink);
	assign outputs[53] = sonar_busy;

	wire dist_ge100 = (dist >= 7'd100);
	wire [6:0] dist_rem = dist_ge100 ? (dist - 7'd100) : dist;
	reg [3:0] dist_tens, dist_ones;
	always @* begin
		if (dist_rem >= 7'd90)      begin dist_tens = 4'd9; dist_ones = dist_rem - 7'd90; end
		else if (dist_rem >= 7'd80) begin dist_tens = 4'd8; dist_ones = dist_rem - 7'd80; end
		else if (dist_rem >= 7'd70) begin dist_tens = 4'd7; dist_ones = dist_rem - 7'd70; end
		else if (dist_rem >= 7'd60) begin dist_tens = 4'd6; dist_ones = dist_rem - 7'd60; end
		else if (dist_rem >= 7'd50) begin dist_tens = 4'd5; dist_ones = dist_rem - 7'd50; end
		else if (dist_rem >= 7'd40) begin dist_tens = 4'd4; dist_ones = dist_rem - 7'd40; end
		else if (dist_rem >= 7'd30) begin dist_tens = 4'd3; dist_ones = dist_rem - 7'd30; end
		else if (dist_rem >= 7'd20) begin dist_tens = 4'd2; dist_ones = dist_rem - 7'd20; end
		else if (dist_rem >= 7'd10) begin dist_tens = 4'd1; dist_ones = dist_rem - 7'd10; end
		else                        begin dist_tens = 4'd0; dist_ones = dist_rem[3:0];  end
	end

	reg [255:0] line1, line2;
	always @* begin
		line1 = { "HP:", (8'd48 + { 4'b0, hp }), " SON:", (8'd48 + { 4'b0, pings }), " T:", (ready ? 8'h31 : 8'h30), "  ", 128'b0 };
		line2 = { "DIST:", (dist_ge100 ? 8'h31 : 8'h30), (8'd48 + { 4'b0, dist_tens }), (8'd48 + { 4'b0, dist_ones }), "        ", 128'b0 };
		case (game_state)
			0 : begin
				case (zone)
					0 : line1 = { "ZONE:NW PRESS GO", 128'b0 };
					1 : line1 = { "ZONE:N  PRESS GO", 128'b0 };
					2 : line1 = { "ZONE:W  PRESS GO", 128'b0 };
					3 : line1 = { "ZONE:RD PRESS GO", 128'b0 };
				endcase
				line2 = { "ROTATE TO SELECT", 128'b0 };
			end
			1 : begin
				line1 = { "GENERATING MAP  ", 128'b0 };
				line2 = { "PLEASE WAIT...  ", 128'b0 };
			end
			3 : begin
				line1 = { "MISSION CLEAR!! ", 128'b0 };
				line2 = { "PRESS GO RESTART", 128'b0 };
			end
			4 : begin
				line1 = { "HULL BREACHED!! ", 128'b0 };
				line2 = { "PRESS GO RESTART", 128'b0 };
			end
			default : if (warn) line2 = { "WARN: MINE NEAR!", 128'b0 };
		endcase
	end

	text_lcd_driver #(
		.CLK_FREQ(CLK_FREQ), .POWER_ON_US(LCD_POWER_ON_US),
		.SETUP_US(LCD_SETUP_US), .ENABLE_US(LCD_ENABLE_US), .COMMAND_US(LCD_COMMAND_US),
		.CLEAR_US(LCD_CLEAR_US), .POLL_US(LCD_POLL_US)
	) lcd(clk, rst, line1, line2, outputs[23:16], outputs[24], outputs[25], outputs[26], outputs[52]);
endmodule