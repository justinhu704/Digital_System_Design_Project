// Game core. The 64x64 minefield lives in one 64x64-bit block RAM (one word = one map row).
// Flow: IDLE -> PICK (random start + goal) -> GEN (64 clocks, one row per clock) -> PLAY -> WIN / LOSE.
// The goal is drawn as a '+' cross; touching any of its 5 cells wins.
// No mines within (2*GOAL_SAFE+1)^2 of the goal (5x5 by default) or 5x5 of the start. Start restarts from any state except PICK/GEN.
//
// 'distance' is the number of steps to the nearest cell of the goal cross
// (Manhattan distance to the cross centre minus 1), so distance 1 means one more step wins.
// The difficulty switch sets both mine density and the start-to-goal distance (same measure):
//   normal: density 1/16, distance NORM_MIN_DIST..NORM_MAX_DIST
//   hard  : density 1/8,  distance >= HARD_MIN_DIST
// Start and goal are drawn together, so the direction to the goal is random.
//
// Win screen: every mine in the 8x8 view is shown for WIN_HOLD steps (0.2 s each), then a
// sonar-like ring sweeps from the view corners in to the submarine, hiding the mines outside it.
//
// Current (drift switch): every 5 s the whole minefield is shifted one cell in a random
// direction (drift_dir: 0 N, 1 S, 2 W, 3 E). The submarine and the goal stay put. Cells that
// enter from the map edge get fresh random mines; the goal safe zone stays clear. A mine pushed
// onto the submarine is a hit (HP - 1, mine removed). The shift takes 128 clocks (2 per row).
//
// Torpedoes: NORM_TORPS / HARD_TORPS per game. A torpedo flies straight along the heading
// (last move direction, north at game start) for up to TORP_RANGE cells, one cell every
// TORP_STEP_CLKS clocks, drawn as a moving dot. The first mine it meets is destroyed and a
// BOOM_CLKS explosion is drawn there; it stops early at the map edge. Firing while facing the
// edge is not spent. Only one torpedo flies at a time; presses during a flight are ignored.
module sonar_game_core #(
	parameter NORM_MIN_DIST = 24, NORM_MAX_DIST = 48, HARD_MIN_DIST = 64,
	parameter NORM_TORPS = 6, HARD_TORPS = 3, TORP_RANGE = 4,
	parameter TORP_STEP_CLKS = 30,         // 30 clocks = 60 ms per cell at 500 Hz
	parameter BOOM_CLKS = 100,             // 100 clocks = 200 ms explosion at 500 Hz
	parameter SONAR_REVEAL = 10,           // full-view reveal after the ripple, in 0.2 s steps (10 = 2 s)
	parameter WIN_HOLD = 5,                // win screen: all mines shown for this many 0.2 s steps
	parameter GOAL_SAFE = 2                // mine-free square around the goal: radius 2 = 5x5 (max 3)
	)(input clk, input rst, input tick_anim,
	input [3:0] move, input sonar, input start, input torpedo,
	input difficult, input drift, input demo,
	output reg [5:0] sub_x, sub_y, goal_x, goal_y,
	output reg [3:0] hp, pings, output reg [2:0] torpedoes,
	output reg [2:0] state, output reg warning,
	output sonar_active, output hit_active, output [6:0] distance,
	output reg [63:0] pixels,
	output reg [1:0] drift_dir, output reg drift_seen);

	localparam ST_IDLE = 0, ST_GEN = 1, ST_PLAY = 2, ST_WIN = 3, ST_LOSE = 4, ST_PICK = 5;
	localparam J_IDLE = 0, J_READ = 1, J_WAIT = 2, J_APPLY = 3;
	localparam OP_VIEW = 0, OP_MOVE = 1, OP_TORP = 2;

	// ---------------------------------------------------------------
	// RNG: 64-bit xorshift, advanced every clock (free running, so each
	// game depends on the exact clock at which the player presses Start)
	// ---------------------------------------------------------------
	reg [63:0] rng;
	wire [63:0] xs1 = rng ^ (rng << 13);
	wire [63:0] xs2 = xs1 ^ (xs1 >> 7);
	wire [63:0] rng_next = xs2 ^ (xs2 << 17);

	reg [1:0] job, op;
	reg [5:0] gen_row, access_row;
	reg ram_we;
	reg [63:0] ram_din;
	wire [63:0] ram_q;
	wire [5:0] ram_addr = (state == ST_GEN) ? gen_row : access_row;

	sonar_map_ram_64x64 map_ram(clk, ram_we, ram_addr, ram_din, ram_q);

	reg hard;
	reg [5:0] start_x, start_y;
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
	reg anim_half;
	reg [5:0] drift_ticks;
	reg [2:0] torp_steps;
	reg torp_flying, torp_check;
	reg [1:0] torp_dir;
	reg [5:0] torp_x, torp_y, boom_x, boom_y;
	reg [7:0] torp_timer, boom_timer;
	reg [3:0] win_r;                        // win ring radius (Manhattan, 9 = whole view)
	reg [2:0] win_hold;
	reg drift_busy, drift_phase;
	reg [63:0] drift_carry;
	wire torp_at_edge = (torp_dir == 0 && torp_y == 0) || (torp_dir == 1 && torp_y == 63) ||
	                    (torp_dir == 2 && torp_x == 0) || (torp_dir == 3 && torp_x == 63);

	assign sonar_active = (ripple != 0 || reveal_ticks != 0);
	assign hit_active = (hit_ticks != 0);
	wire [6:0] center_dist = ((goal_x > sub_x) ? goal_x - sub_x : sub_x - goal_x) +
	                         { 1'b0, ((goal_y > sub_y) ? goal_y - sub_y : sub_y - goal_y) };
	assign distance = (center_dist == 7'd0) ? 7'd0 : center_dist - 7'd1;   // to the nearest cross cell

	// ---------------------------------------------------------------
	// PICK: one (start, goal) candidate per clock from independent RNG fields.
	// Both points lie in 3..60 so their safe zones fit inside the map.
	// Rejected candidates are simply retried on the next clock.
	// ('hard' is latched from the switch on the same clock PICK is entered.)
	// ---------------------------------------------------------------
	wire [5:0] cand_sx = rng[5:0];
	wire [5:0] cand_sy = rng[13:8];
	wire [5:0] cand_gx = rng[21:16];
	wire [5:0] cand_gy = rng[29:24];
	wire [6:0] cand_dist = ((cand_gx > cand_sx) ? cand_gx - cand_sx : cand_sx - cand_gx) +
	                       { 1'b0, ((cand_gy > cand_sy) ? cand_gy - cand_sy : cand_sy - cand_gy) };
	wire cand_in = (cand_sx >= 6'd3) && (cand_sx <= 6'd60) && (cand_sy >= 6'd3) && (cand_sy <= 6'd60) &&
	               (cand_gx >= 6'd3) && (cand_gx <= 6'd60) && (cand_gy >= 6'd3) && (cand_gy <= 6'd60);
	wire [6:0] cand_near = cand_dist - 7'd1;   // same measure as 'distance'
	wire cand_dist_ok = (cand_dist != 7'd0) &&
	                    (hard ? (cand_near >= HARD_MIN_DIST) :
	                            (cand_near >= NORM_MIN_DIST && cand_near <= NORM_MAX_DIST));
	wire cand_ok = cand_in && cand_dist_ok;

	// Does (target_x, target_y) touch one of the 5 goal '+' cells?
	wire target_on_goal_plus =
		((target_x == goal_x) && (target_y == goal_y)) ||
		((target_x == goal_x) && ((target_y + 6'd1 == goal_y) || (goal_y + 6'd1 == target_y))) ||
		((target_y == goal_y) && ((target_x + 6'd1 == goal_x) || (goal_x + 6'd1 == target_x)));

	// Safe-zone tests (absolute differences, 7 bits to avoid wrap)
	function in_zone;
		input [5:0] ax, ay, cx, cy;
		input [6:0] r;
		reg [6:0] dx, dy;
		begin
			dx = (ax >= cx) ? ({1'b0, ax} - {1'b0, cx}) : ({1'b0, cx} - {1'b0, ax});
			dy = (ay >= cy) ? ({1'b0, ay} - {1'b0, cy}) : ({1'b0, cy} - {1'b0, ay});
			in_zone = (dx <= r) && (dy <= r);
		end
	endfunction

	// ---------------------------------------------------------------
	// GEN: one full 64-cell row per clock.
	// Column c ANDs 4 RNG bits (normal, p = 1/16) or 3 bits (hard, p = 1/8).
	// Offsets {0,7,19,42} have pairwise-distinct differences mod 64, so any two
	// columns share at most one bit and no regular mine pattern appears.
	// ---------------------------------------------------------------
	reg [63:0] rand_row, new_row_mines, goal_row_mask;
	integer c;
	always @* begin
		for (c = 0; c < 64; c = c + 1) begin
			rand_row[c] = rng[c] && rng[(c + 7) % 64] && rng[(c + 19) % 64] && (hard || rng[(c + 42) % 64]);
			new_row_mines[c] = rand_row[c] &&
				!in_zone(c[5:0], gen_row, start_x, start_y, 7'd2) &&
				!in_zone(c[5:0], gen_row, goal_x, goal_y, GOAL_SAFE);
			goal_row_mask[c] = in_zone(c[5:0], access_row, goal_x, goal_y, GOAL_SAFE);
		end
	end

	// Current: new contents of map row access_row (ram_q holds its old contents).
	// Vertical shifts take the previous row from drift_carry; the edge cell of a
	// horizontal shift gets a fresh random bit. The goal zone is kept clear.
	reg [63:0] drift_shifted, drift_row;
	reg drift_hit;
	always @* begin
		case (drift_dir)
			2'd2 : drift_shifted = { rand_row[0], ram_q[63:1] };   // west: new[x] = old[x+1]
			2'd3 : drift_shifted = { ram_q[62:0], rand_row[0] };   // east: new[x] = old[x-1]
			default : drift_shifted = drift_carry;                 // north / south: previous row
		endcase
		drift_row = drift_shifted & ~goal_row_mask;
		drift_hit = (access_row == sub_y) && drift_row[sub_x];
		if (access_row == sub_y) drift_row[sub_x] = 1'b0;     // a mine pushed onto the submarine explodes
	end
	wire drift_last = (drift_dir == 2'd0) ? (access_row == 6'd0) : (access_row == 6'd63);

	always @* begin
		ram_we = 1'b0;
		ram_din = 64'd0;
		if (state == ST_GEN) begin
			ram_we = 1'b1;
			ram_din = new_row_mines;
		end
		else if (state == ST_PLAY && drift_busy) begin
			if (drift_phase) begin
				ram_we = 1'b1;
				ram_din = drift_row;
			end
		end
		else if (state == ST_PLAY && job == J_APPLY) begin
			if (op == OP_MOVE || op == OP_TORP) begin
				ram_we = 1'b1;
				ram_din = ram_q & ~(64'd1 << target_x);
			end
		end
	end

	// One 8-pixel viewport row from the fetched 64-bit map row
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
			has_mine = 1'b0;
			is_goal_plus = 1'b0;
			if (wx < 0 || wx > 63 || wy < 0 || wy > 63) begin
				row_pixels[vx] = 1'b1;          // outside the map: wall
			end
			else begin
				has_mine = ram_q[wx[5:0]];
				is_goal_plus = ((wx == goal_x && wy == goal_y) ||
				                (wx == goal_x && (wy + 1 == goal_y || wy == goal_y + 1)) ||
				                (wy == goal_y && (wx + 1 == goal_x || wx == goal_x + 1)));
				if (state == ST_WIN)
					// Win: mines inside the shrinking ring stay visible, the ring itself is lit
					row_pixels[vx] = (has_mine && md < win_r) || (md == win_r) || is_goal_plus;
				else
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
			rng <= 64'h9E37_79B9_7F4A_7C15;
			start_x <= 6'd32;
			start_y <= 6'd32;
			sub_x <= 6'd32;
			sub_y <= 6'd32;
			goal_x <= 6'd8;
			goal_y <= 6'd8;
			hp <= 8;
			pings <= 9;
			torpedoes <= NORM_TORPS;
			torp_steps <= 0;
			torp_flying <= 0;
			torp_check <= 0;
			torp_dir <= 0;
			torp_x <= 0;
			torp_y <= 0;
			torp_timer <= 0;
			boom_x <= 0;
			boom_y <= 0;
			boom_timer <= 0;
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
			view_sub_x <= 6'd32;
			view_sub_y <= 6'd32;
			work_warning <= 0;
			ripple <= 0;
			reveal_ticks <= 0;
			sonar_div <= 0;
			hit_ticks <= 0;
			anim_frame <= 0;
			anim_half <= 0;
			drift_ticks <= 0;
			drift_busy <= 0;
			drift_phase <= 0;
			drift_carry <= 0;
			drift_dir <= 0;
			drift_seen <= 0;
			win_r <= 0;
			win_hold <= 0;
		end
		else begin
			rng <= rng_next;
			if (tick_anim) begin
				anim_half <= ~anim_half;
				sonar_div <= ~sonar_div;
				if (anim_half) anim_frame <= (anim_frame == 5) ? 3'd0 : anim_frame + 1'b1;
				if (hit_ticks != 0) hit_ticks <= hit_ticks - 1'b1;

				// Sonar: ripple grows one cell per 2 anim ticks; after 6 the whole view is revealed
				// for SONAR_REVEAL steps
				if (sonar_div) begin
					if (ripple != 0) begin
						if (ripple == 6) begin
							ripple <= 0;
							reveal_ticks <= SONAR_REVEAL;
						end
						else ripple <= ripple + 1'b1;
					end
					else if (reveal_ticks != 0) reveal_ticks <= reveal_ticks - 1'b1;

					// Win screen: hold, then shrink the ring one cell per step
					if (state == ST_WIN) begin
						if (win_hold != 0) win_hold <= win_hold - 1'b1;
						else if (win_r != 0) win_r <= win_r - 1'b1;
					end
				end

				// Current: shift the minefield every 50 anim ticks (5 s at 10 Hz)
				if (state == ST_PLAY && drift) begin
					if (drift_ticks == 6'd49) begin
						drift_ticks <= 0;
						pending_drift <= 1;
					end
					else drift_ticks <= drift_ticks + 6'd1;
				end
				else drift_ticks <= 0;
			end

			if (start && state != ST_GEN && state != ST_PICK) begin
				state <= ST_PICK;
				gen_row <= 0;
				hard <= difficult;
				hp <= 8;
				pings <= 9;
				torpedoes <= difficult ? HARD_TORPS : NORM_TORPS;
				torp_flying <= 0;
				torp_check <= 0;
				torp_timer <= 0;
				boom_timer <= 0;
				ripple <= 0;
				reveal_ticks <= 0;
				sonar_div <= 0;
				hit_ticks <= 0;
				anim_frame <= 0;
				anim_half <= 0;
				pending_move <= 0;
				pending_torp <= 0;
				pending_drift <= 0;
				drift_ticks <= 0;
				drift_busy <= 0;
				drift_phase <= 0;
				drift_seen <= 0;
				heading <= 0;
				view_row <= 0;
				work_frame <= 0;
				view_frame <= 0;
				warning <= 0;
				work_warning <= 0;
				job <= J_IDLE;
			end
			else if (state == ST_PICK) begin
				if (cand_ok) begin
					start_x <= cand_sx;
					start_y <= cand_sy;
					sub_x <= cand_sx;
					sub_y <= cand_sy;
					view_sub_x <= cand_sx;
					view_sub_y <= cand_sy;
					goal_x <= cand_gx;
					goal_y <= cand_gy;
					state <= ST_GEN;
					gen_row <= 0;
				end
			end
			else if (state == ST_GEN) begin
				if (gen_row == 6'd63) begin
					state <= ST_PLAY;
					gen_row <= 0;
				end
				else gen_row <= gen_row + 6'd1;
			end
			else if (state == ST_PLAY || state == ST_WIN) begin
				// ST_WIN only keeps refreshing the viewport (the jobs below fall through to OP_VIEW)
				if (state == ST_PLAY) begin
					if (hit_ticks == 0) pending_move <= pending_move | move;
					else pending_move <= 0;

					if (torpedo && torpedoes != 0 && !torp_flying) pending_torp <= 1;

					// Torpedo flight: after the dwell time in a cell, move on or fizzle out
					if (torp_timer != 0) begin
						torp_timer <= torp_timer - 1'b1;
						if (torp_timer == 1) begin
							if (torp_steps < TORP_RANGE && !torp_at_edge) begin
								torp_steps <= torp_steps + 1'b1;
								case (torp_dir)
									0 : torp_y <= torp_y - 1'b1;
									1 : torp_y <= torp_y + 1'b1;
									2 : torp_x <= torp_x - 1'b1;
									3 : torp_x <= torp_x + 1'b1;
								endcase
								torp_check <= 1;
							end
							else torp_flying <= 0;
						end
					end
					if (boom_timer != 0) boom_timer <= boom_timer - 1'b1;
					if (sonar && pings != 0 && !sonar_active && !hit_active) begin
						pings <= pings - 1'b1;
						ripple <= 1;
						sonar_div <= 0;
					end

					// Current: shift the map one row per 2 clocks (phase 0 reads, phase 1 writes)
					if (drift_busy) begin
						if (!drift_phase) drift_phase <= 1'b1;
						else begin
							drift_phase <= 1'b0;
							drift_carry <= ram_q;
							if (drift_hit) begin
								hp <= hp - 1'b1;
								hit_ticks <= 4;
								if (hp == 1) begin
									state <= ST_LOSE;
									anim_frame <= 0;
									anim_half <= 0;
								end
							end
							if (drift_last) begin
								drift_busy <= 1'b0;
								// Rebuild the viewport from scratch with the shifted map
								view_row <= 0;
								work_frame <= 0;
								work_warning <= 0;
							end
							else if (drift_dir == 2'd0) access_row <= access_row - 6'd1;
							else access_row <= access_row + 6'd1;
						end
					end
				end   // state == ST_PLAY

				if (!drift_busy) case (job)
					J_IDLE : begin
						if (pending_move != 0 && !hit_active) begin
							pending_move <= move;    // keep a press that arrives on this very clock
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
						else if (torp_check) begin
							// Look up the cell the torpedo has just entered
							torp_check <= 0;
							op <= OP_TORP;
							target_x <= torp_x;
							target_y <= torp_y;
							job <= J_READ;
						end
						else if (pending_torp && torpedoes != 0 && !hit_active && !torp_flying) begin
							pending_torp <= 0;
							// Launch into the cell in front of the bow; not spent when facing a wall
							if ((heading == 0 && sub_y != 0) ||
							    (heading == 1 && sub_y != 63) ||
							    (heading == 2 && sub_x != 0) ||
							    (heading == 3 && sub_x != 63)) begin
								torpedoes <= torpedoes - 1'b1;
								torp_flying <= 1;
								torp_check <= 1;
								torp_dir <= heading;
								torp_steps <= 1;
								torp_x <= sub_x;
								torp_y <= sub_y;
								case (heading)
									0 : torp_y <= sub_y - 1'b1;
									1 : torp_y <= sub_y + 1'b1;
									2 : torp_x <= sub_x - 1'b1;
									3 : torp_x <= sub_x + 1'b1;
								endcase
							end
						end
						else if (pending_drift) begin
							// Start a map shift; north walks the rows upward, the others downward
							pending_drift <= 0;
							drift_busy <= 1'b1;
							drift_phase <= 1'b0;
							drift_dir <= rng[33:32];
							drift_seen <= 1'b1;
							drift_carry <= rand_row;    // row entering from the edge (vertical shifts)
							access_row <= (rng[33:32] == 2'd0) ? 6'd63 : 6'd0;
						end
						else begin
							op <= OP_VIEW;
							// Snapshot the position per frame so one frame never mixes two positions
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

					J_WAIT : job <= J_APPLY;   // synchronous RAM: one clock read latency

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
							if (target_on_goal_plus && !(ram_q[target_x] && hp == 1)) begin
								state <= ST_WIN;
								anim_frame <= 0;
								anim_half <= 0;
								// Win screen: show every mine in view, then sweep them away
								win_r <= 4'd9;
								win_hold <= WIN_HOLD;
								ripple <= 0;
								reveal_ticks <= 0;
								pending_move <= 0;
								pending_torp <= 0;
								pending_drift <= 0;
								torp_flying <= 0;
								torp_check <= 0;
								torp_timer <= 0;
								boom_timer <= 0;
							end
							// Drop the half-built frame after a move
							view_row <= 0;
							work_frame <= 0;
							work_warning <= 0;
						end
						else if (op == OP_TORP) begin
							if (ram_q[target_x]) begin
								// Hit: the write path clears the mine this clock; show the explosion
								torp_flying <= 0;
								boom_timer <= BOOM_CLKS;
								boom_x <= target_x;
								boom_y <= target_y;
							end
							else torp_timer <= TORP_STEP_CLKS;   // empty cell: stay visible, then move on
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

	// One lit pixel at world cell (wx, wy) relative to the submarine at view (3,3); none if off view
	function [63:0] dot;
		input [5:0] wx, wy, cx, cy;
		input integer ox, oy;
		integer vx, vy;
		begin
			vx = wx - cx + 3 + ox;
			vy = wy - cy + 3 + oy;
			dot = 64'd0;
			if (vx >= 0 && vx < 8 && vy >= 0 && vy < 8) dot[vy * 8 + vx] = 1'b1;
		end
	endfunction

	always @* begin
		pixels = view_frame;
		pixels[27] = 1'b1;                      // submarine is always at view (3,3)
		if (torp_flying)
			pixels = pixels | dot(torp_x, torp_y, sub_x, sub_y, 0, 0);
		if (boom_timer > BOOM_CLKS / 2)         // explosion: '+' first, then the four diagonals
			pixels = pixels | dot(boom_x, boom_y, sub_x, sub_y, 0, 0) |
			         dot(boom_x, boom_y, sub_x, sub_y, -1, 0) | dot(boom_x, boom_y, sub_x, sub_y, 1, 0) |
			         dot(boom_x, boom_y, sub_x, sub_y, 0, -1) | dot(boom_x, boom_y, sub_x, sub_y, 0, 1);
		else if (boom_timer != 0)
			pixels = pixels |
			         dot(boom_x, boom_y, sub_x, sub_y, -1, -1) | dot(boom_x, boom_y, sub_x, sub_y, 1, -1) |
			         dot(boom_x, boom_y, sub_x, sub_y, -1, 1) | dot(boom_x, boom_y, sub_x, sub_y, 1, 1);
		if (state == ST_IDLE) pixels = 64'h0000_0018_1800_0000;
		else if (state == ST_GEN || state == ST_PICK) pixels = 64'h0000_183C_3C18_0000;
		else if (state == ST_WIN) pixels = view_frame | (64'd1 << 27);   // mines + shrinking ring
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

// 64x64-bit synchronous block RAM (one word = one map row), read-old-data on write
module sonar_map_ram_64x64(input clk, input we, input [5:0] addr, input [63:0] din, output reg [63:0] dout);
	(* ramstyle = "M4K" *) reg [63:0] mem [0:63];
	always @(posedge clk) begin
		if (we)
			mem[addr] <= din;
		dout <= mem[addr];
	end
endmodule
