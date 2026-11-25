// Uses a 64x64-bit M4K Block RAM (1 full map row per word).
// Goal renders as a '+' cross (any of the 5 points triggers win); Start restarts anytime;
// 7x7 safe zone around goal prevents mines near the '+' cross.
module sonar_game_core(input clk, input rst, input tick_anim,
	input [3:0] move, input sonar, input start, input torpedo,
	input difficult, input drift, input demo, input [1:0] zone,
	output reg [5:0] sub_x, sub_y, goal_x, goal_y,
	output reg [3:0] hp, pings, output reg torpedo_ready,
	output reg [2:0] state, output reg warning,
	output sonar_active, output hit_active, output [6:0] distance,
	output reg [63:0] pixels);

	localparam ST_IDLE = 0, ST_GEN = 1, ST_PLAY = 2, ST_WIN = 3, ST_LOSE = 4;
	localparam J_IDLE = 0, J_READ = 1, J_WAIT = 2, J_APPLY = 3;
	localparam OP_VIEW = 0, OP_MOVE = 1, OP_TORP = 2, OP_DRIFT = 3;

	reg [1:0] job, op;
	reg [15:0] lfsr;
	reg [5:0] gen_row, access_row;
	reg ram_we;
	reg [63:0] ram_din;
	wire [63:0] ram_q;
	wire [5:0] ram_addr = (state == ST_GEN) ? gen_row : access_row;

	sonar_map_ram_64x64 map_ram(clk, ram_we, ram_addr, ram_din, ram_q);

	reg hard;
	reg [3:0] pending_move;
	reg pending_torp, pending_drift;
	reg [1:0] heading;
	reg [5:0] target_x, target_y;
	reg [2:0] view_row;
	reg [63:0] work_frame, view_frame;
	reg work_warning;
	reg [5:0] view_sub_x, view_sub_y;
	reg [3:0] ripple, reveal_ticks;
	reg sonar_div;
	reg [2:0] hit_ticks, anim_frame;
	reg anim_half, blink;
	reg [5:0] drift_ticks;

	assign sonar_active = (ripple != 0 || reveal_ticks != 0);
	assign hit_active = (hit_ticks != 0);
	assign distance = ((goal_x > sub_x) ? goal_x - sub_x : sub_x - goal_x) +
	                  { 1'b0, ((goal_y > sub_y) ? goal_y - sub_y : sub_y - goal_y) };

	wire [5:0] rnd_x = (lfsr[5:0] >= 6'd48) ? (lfsr[5:0] - 6'd48) : lfsr[5:0];
	wire [5:0] rnd_y = (lfsr[11:6] >= 6'd48) ? (lfsr[11:6] - 6'd48) : lfsr[11:6];

	// Helper: check if (target_x, target_y) touches any of the 5 '+' cross goal cells
	wire target_on_goal_plus =
		((target_x == goal_x) && (target_y == goal_y)) ||
		((target_x == goal_x) && ((target_y + 6'd1 == goal_y) || (goal_y + 6'd1 == target_y))) ||
		((target_y == goal_y) && ((target_x + 6'd1 == goal_x) || (goal_x + 6'd1 == target_x)));

	// Generate an entire 64-bit row of mines in 1 clock cycle (with 7x7 safe zone around goal)
	reg [63:0] new_row_mines;
	integer c;
	reg [15:0] col_hash;
	reg col_safe;
	wire [6:0] dy_gen_goal = (gen_row >= goal_y) ? ({1'b0, gen_row} - {1'b0, goal_y}) : ({1'b0, goal_y} - {1'b0, gen_row});
	reg [6:0] dx_gen_goal;
	always @* begin
		for (c = 0; c < 64; c = c + 1) begin
			dx_gen_goal = (c[5:0] >= goal_x) ? ({1'b0, c[5:0]} - {1'b0, goal_x}) : ({1'b0, goal_x} - {1'b0, c[5:0]});
			col_safe = ((c >= 50 && c <= 54) && (gen_row >= 6'd50 && gen_row <= 6'd54)) ||
			           ((dx_gen_goal <= 7'd3) && (dy_gen_goal <= 7'd3));
			col_hash = lfsr ^ ({ 10'b0, c[5:0] } * 16'd25173 + 16'd13849);
			new_row_mines[c] = !col_safe && (hard ? (col_hash[2:0] == 3'd0) : (col_hash[3:0] == 4'd0));
		end
	end

	wire [6:0] dx_drift_goal = (target_x >= goal_x) ? ({1'b0, target_x} - {1'b0, goal_x}) : ({1'b0, goal_x} - {1'b0, target_x});
	wire [6:0] dy_drift_goal = (target_y >= goal_y) ? ({1'b0, target_y} - {1'b0, goal_y}) : ({1'b0, goal_y} - {1'b0, target_y});
	wire drift_safe = ((target_x >= 6'd50 && target_x <= 6'd54) && (target_y >= 6'd50 && target_y <= 6'd54)) ||
	                  ((dx_drift_goal <= 7'd3) && (dy_drift_goal <= 7'd3)) ||
	                  (target_x == sub_x && target_y == sub_y);

	always @* begin
		ram_we = 1'b0;
		ram_din = 64'd0;
		if (state == ST_GEN) begin
			ram_we = 1'b1;
			ram_din = new_row_mines;
		end
		else if (state == ST_PLAY && job == J_APPLY) begin
			if (op == OP_MOVE || op == OP_TORP) begin
				ram_we = 1'b1;
				ram_din = ram_q & ~(64'd1 << target_x);
			end
			else if (op == OP_DRIFT && !drift_safe) begin
				ram_we = 1'b1;
				ram_din = ram_q ^ (64'd1 << target_x);
			end
		end
	end

	// Compute 1 row (8 pixels) of viewport from the fetched 64-bit map row
	integer vx, wx, wy, md;
	reg [7:0] row_pixels;
	reg row_warn;
	reg has_mine, is_goal_plus;
	always @* begin
		row_pixels = 8'd0;
		row_warn = 1'b0;
		wy = view_sub_y + view_row - 3;
		for (vx = 0; vx < 8; vx = vx + 1) begin
			wx = view_sub_x + vx - 3;
			md = ((vx > 3) ? vx - 3 : 3 - vx) + ((view_row > 3) ? view_row - 3 : 3 - view_row);
			if (wx < 0 || wx > 63 || wy < 0 || wy > 63) begin
				row_pixels[vx] = 1'b1;
			end
			else begin
				has_mine = ram_q[wx[5:0]];
				is_goal_plus = ((wx == goal_x && wy == goal_y) ||
				                (wx == goal_x && (wy + 1 == goal_y || wy == goal_y + 1)) ||
				                (wy == goal_y && (wx + 1 == goal_x || wx == goal_x + 1)));
				row_pixels[vx] =
					(has_mine && (demo || reveal_ticks != 0 || (ripple != 0 && md <= ripple))) ||
					(ripple != 0 && md == ripple) ||
					is_goal_plus;
				if (has_mine && md <= 2) row_warn = 1'b1;
			end
		end
	end

	wire [5:0] view_read_row = view_sub_y + { 3'b0, view_row } - 6'd3;

	always @(posedge clk) begin
		if (rst) begin
			state <= ST_IDLE;
			job <= J_IDLE;
			op <= OP_VIEW;
			lfsr <= 16'hACE1;
			sub_x <= 52;
			sub_y <= 52;
			goal_x <= 4;
			goal_y <= 4;
			hp <= 8;
			pings <= 9;
			torpedo_ready <= 1;
			warning <= 0;
			hard <= 0;
			gen_row <= 0;
			access_row <= 0;
			pending_move <= 0;
			pending_torp <= 0;
			pending_drift <= 0;
			heading <= 0;
			target_x <= 0;
			target_y <= 0;
			view_row <= 0;
			work_frame <= 0;
			view_frame <= 0;
			view_sub_x <= 52;
			view_sub_y <= 52;
			work_warning <= 0;
			ripple <= 0;
			reveal_ticks <= 0;
			sonar_div <= 0;
			hit_ticks <= 0;
			anim_frame <= 0;
			anim_half <= 0;
			blink <= 0;
			drift_ticks <= 0;
		end
		else begin
			lfsr <= { lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10] };
			if (tick_anim) begin
				blink <= ~blink;
				anim_half <= ~anim_half;
				sonar_div <= ~sonar_div;
				if (anim_half) anim_frame <= (anim_frame == 5) ? 0 : anim_frame + 1'b1;
				if (hit_ticks != 0) hit_ticks <= hit_ticks - 1'b1;

				if (sonar_div) begin
					if (ripple != 0) begin
						if (ripple == 6) begin
							ripple <= 0;
							reveal_ticks <= 15;
						end
						else ripple <= ripple + 1'b1;
					end
					else if (reveal_ticks != 0) reveal_ticks <= reveal_ticks - 1'b1;
				end

				if (state == ST_PLAY && drift) begin
					if (drift_ticks == 6'd49) begin
						drift_ticks <= 0;
						pending_drift <= 1;
					end
					else drift_ticks <= drift_ticks + 6'd1;
				end
				else drift_ticks <= 0;
			end

			// Pressing Start restarts the game even while currently playing (ST_PLAY)
			if (start && state != ST_GEN) begin
				state <= ST_GEN;
				gen_row <= 0;
				hard <= difficult;
				sub_x <= 52;
				sub_y <= 52;
				hp <= 8;
				pings <= 9;
				torpedo_ready <= 1;
				case (zone)
					0 : begin
						goal_x <= 6'd4 + { 2'b0, lfsr[3:0] };
						goal_y <= 6'd4 + { 2'b0, lfsr[7:4] };
					end
					1 : begin
						goal_x <= 6'd36 + { 2'b0, lfsr[3:0] };
						goal_y <= 6'd4 + { 2'b0, lfsr[7:4] };
					end
					2 : begin
						goal_x <= 6'd4 + { 2'b0, lfsr[3:0] };
						goal_y <= 6'd36 + { 2'b0, lfsr[7:4] };
					end
					3 : begin
						goal_x <= 6'd4 + rnd_x;
						goal_y <= 6'd4 + rnd_y;
					end
				endcase
				ripple <= 0;
				reveal_ticks <= 0;
				sonar_div <= 0;
				hit_ticks <= 0;
				anim_frame <= 0;
				anim_half <= 0;
				pending_move <= 0;
				pending_torp <= 0;
				pending_drift <= 0;
				heading <= 0;
				view_row <= 0;
				work_frame <= 0;
				view_frame <= 0;
				warning <= 0;
				work_warning <= 0;
				job <= J_IDLE;
			end
			else if (state == ST_GEN) begin
				if (gen_row == 6'd63) begin
					state <= ST_PLAY;
					gen_row <= 0;
				end
				else gen_row <= gen_row + 6'd1;
			end
			else if (state == ST_PLAY) begin
				if (hit_ticks == 0) pending_move <= pending_move | move;
				else pending_move <= 0;

				if (torpedo && torpedo_ready) pending_torp <= 1;
				if (sonar && pings != 0 && !sonar_active && !hit_active) begin
					pings <= pings - 1'b1;
					ripple <= 1;
					sonar_div <= 0;
				end

				case (job)
					J_IDLE : begin
						if (pending_move != 0 && !hit_active) begin
							pending_move <= 0;
							op <= OP_MOVE;
							target_x <= sub_x;
							target_y <= sub_y;
							if (pending_move[0]) begin
								heading <= 0;
								if (sub_y != 0) target_y <= sub_y - 1'b1;
							end
							else if (pending_move[1]) begin
								heading <= 1;
								if (sub_y != 63) target_y <= sub_y + 1'b1;
							end
							else if (pending_move[2]) begin
								heading <= 2;
								if (sub_x != 0) target_x <= sub_x - 1'b1;
							end
							else begin
								heading <= 3;
								if (sub_x != 63) target_x <= sub_x + 1'b1;
							end
							job <= J_READ;
						end
						else if (pending_torp && torpedo_ready && !hit_active) begin
							pending_torp <= 0;
							if ((heading == 0 && sub_y != 0) ||
							    (heading == 1 && sub_y != 63) ||
							    (heading == 2 && sub_x != 0) ||
							    (heading == 3 && sub_x != 63)) begin
								torpedo_ready <= 0;
								op <= OP_TORP;
								target_x <= sub_x;
								target_y <= sub_y;
								case (heading)
									0 : target_y <= sub_y - 1'b1;
									1 : target_y <= sub_y + 1'b1;
									2 : target_x <= sub_x - 1'b1;
									3 : target_x <= sub_x + 1'b1;
								endcase
								job <= J_READ;
							end
						end
						else if (pending_drift) begin
							pending_drift <= 0;
							op <= OP_DRIFT;
							target_x <= lfsr[5:0];
							target_y <= lfsr[11:6];
							job <= J_READ;
						end
						else begin
							op <= OP_VIEW;
							if (view_row == 0) begin
								view_sub_x <= sub_x;
								view_sub_y <= sub_y;
							end
							job <= J_READ;
						end
					end

					J_READ : begin
						if (op == OP_VIEW) access_row <= view_read_row;
						else access_row <= target_y;
						job <= J_WAIT;
					end

					J_WAIT : job <= J_APPLY;

					J_APPLY : begin
						job <= J_IDLE;
						if (op == OP_MOVE) begin
							sub_x <= target_x;
							sub_y <= target_y;
							if (ram_q[target_x]) begin
								hp <= hp - 1'b1;
								hit_ticks <= 4;
								if (hp == 1) begin
									state <= ST_LOSE;
									anim_frame <= 0;
									anim_half <= 0;
								end
							end
							// Touching any of the 5 '+' cross points triggers victory
							if (target_on_goal_plus && !(ram_q[target_x] && hp == 1)) begin
								state <= ST_WIN;
								anim_frame <= 0;
								anim_half <= 0;
							end
							view_row <= 0;
							work_frame <= 0;
							work_warning <= 0;
						end
						else if (op == OP_VIEW) begin
							work_frame[view_row * 8 +: 8] <= row_pixels;
							if (row_warn) work_warning <= 1'b1;

							if (view_row == 3'd7) begin
								view_row <= 3'd0;
								view_frame <= { row_pixels, work_frame[55:0] };
								warning <= work_warning || row_warn;
								work_warning <= 1'b0;
							end
							else view_row <= view_row + 3'd1;
						end
					end
				endcase
			end
		end
	end

	always @* begin
		pixels = view_frame;
		pixels[27] = 1'b1;
		if (state == ST_IDLE) pixels = 64'h0000_0018_1800_0000;
		else if (state == ST_GEN) pixels = 64'h0000_183C_3C18_0000;
		else if (state == ST_WIN) case (anim_frame)
			0 : pixels = 64'hFF81_8181_8181_81FF;
			1 : pixels = 64'hFFFF_C3C3_C3C3_FFFF;
			2 : pixels = 64'hFFFF_FFE7_E7FF_FFFF;
			3, 4 : pixels = 64'hFFFF_FFFF_FFFF_FFFF;
			default : pixels = 0;
		endcase
		else if (state == ST_LOSE) case (anim_frame)
			0, 2 : pixels = 64'hFFFF_FFFF_FFFF_FFFF;
			1 : pixels = 64'hC3E7_7E3C_3C7E_E7C3;
			3 : pixels = 64'hFF81_4224_2442_81FF;
			4 : pixels = 64'h55AA_55AA_55AA_55AA;
			default : pixels = 0;
		endcase
		else if (hit_ticks != 0) case (hit_ticks)
			4, 2 : pixels = 64'hFFFF_FFFF_FFFF_FFFF;
			3 : pixels = 64'h8142_2418_1824_4281;
			default : pixels = 64'h0000_183C_3C18_0000;
		endcase
	end
endmodule

// 64x64-bit M4K Synchronous Block RAM (1 full map row per word)
module sonar_map_ram_64x64(input clk, input we, input [5:0] addr, input [63:0] din, output reg [63:0] dout);
	(* ramstyle = "M4K" *) reg [63:0] mem [0:63];
	always @(posedge clk) begin
		if (we)
			mem[addr] <= din;
		dout <= mem[addr];
	end
endmodule