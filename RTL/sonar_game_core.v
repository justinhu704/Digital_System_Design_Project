// A single synchronous RAM port serves all jobs. Read latency is explicit.
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
	reg [11:0] gen_addr, access_addr;
	reg ram_we, ram_din;
	wire ram_q;
	wire [11:0] ram_addr;
	reg hard;
	reg [3:0] pending_move;
	reg pending_torp, pending_drift;
	reg [1:0] heading;
	reg [5:0] target_x, target_y;
	reg [5:0] view_index;
	reg [63:0] work_frame, view_frame;
	reg work_warning;
	reg [5:0] view_sub_x, view_sub_y;
	reg [3:0] ripple, reveal_ticks;
	reg [2:0] hit_ticks, anim_frame;
	reg anim_half, blink;
	reg [4:0] drift_ticks;
	integer wx, wy, lx, ly, md, dx, dy;
	reg safe_gen, safe_drift;
	assign ram_addr =(state == ST_GEN) ? gen_addr : access_addr;
	sonar_map_ram map_ram(clk, ram_we, ram_addr, ram_din, ram_q);
	assign sonar_active =(ripple != 0 || reveal_ticks != 0);
	assign hit_active =(hit_ticks != 0);
	assign distance =((goal_x > sub_x) ? goal_x - sub_x : sub_x - goal_x) +
	{ 1'b0,((goal_y > sub_y) ? goal_y - sub_y : sub_y - goal_y) };
	always @* begin
		dx = gen_addr [5:0];
		dy = gen_addr [11:6];
		safe_gen =((dx >= 50 && dx <= 54) &&(dy >= 50 && dy <= 54)) ||
		((dx >= goal_x - 2 && dx <= goal_x + 2) &&(dy >= goal_y - 2 && dy <= goal_y + 2));
		dx = target_x;
		dy = target_y;
		safe_drift =((dx >= 50 && dx <= 54) &&(dy >= 50 && dy <= 54)) ||
		((dx >= goal_x - 2 && dx <= goal_x + 2) &&(dy >= goal_y - 2 && dy <= goal_y + 2)) ||
		(target_x == sub_x && target_y == sub_y);
		ram_we = 0;
		ram_din = 0;
		if (state == ST_GEN) begin
			ram_we = 1;
			ram_din = ! safe_gen &&(hard ?(lfsr [2:0] == 0) :(lfsr [3:0] == 0));
		end
		else if (state == ST_PLAY && job == J_APPLY) begin
			if (op == OP_MOVE || op == OP_TORP) begin
				ram_we = 1;
				ram_din = 0;
			end
			else if (op == OP_DRIFT && ! safe_drift) begin
				ram_we = 1;
				ram_din = ~ ram_q;
			end
		end
	end
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
			gen_addr <= 0;
			access_addr <= 0;
			pending_move <= 0;
			pending_torp <= 0;
			pending_drift <= 0;
			heading <= 0;
			target_x <= 0;
			target_y <= 0;
			view_index <= 0;
			work_frame <= 0;
			view_frame <= 0;
			view_sub_x <= 52;
			view_sub_y <= 52;
			work_warning <= 0;
			ripple <= 0;
			reveal_ticks <= 0;
			hit_ticks <= 0;
			anim_frame <= 0;
			anim_half <= 0;
			blink <= 0;
			drift_ticks <= 0;
		end
		else begin
			lfsr <= { lfsr [14:0], lfsr [15] ^ lfsr [13] ^ lfsr [12] ^ lfsr [10] };
			if (tick_anim) begin
				blink <= ~ blink;
				anim_half <= ~ anim_half;
				if (anim_half) anim_frame <=(anim_frame == 5) ? 0 : anim_frame + 1'b1;
				if (hit_ticks != 0) hit_ticks <= hit_ticks - 1'b1;
				if (ripple != 0) begin
					if (ripple == 12) begin
						ripple <= 0;
						reveal_ticks <= 12;
					end
					else ripple <= ripple + 1'b1;
				end
				else if (reveal_ticks != 0) reveal_ticks <= reveal_ticks - 1'b1;
				if (state == ST_PLAY && drift) begin
					if (drift_ticks == 29) begin
						drift_ticks <= 0;
						pending_drift <= 1;
					end
					else drift_ticks <= drift_ticks + 1'b1;
				end
				else drift_ticks <= 0;
			end
			// Restart directly starts a fresh game from IDLE or either result state.
			if (start && state != ST_GEN && state != ST_PLAY) begin
				state <= ST_GEN;
				gen_addr <= 0;
				hard <= difficult;
				sub_x <= 52;
				sub_y <= 52;
				hp <= 8;
				pings <= 9;
				torpedo_ready <= 1;
				case (zone)
					0 : begin
						goal_x <= 4 + { 2'b0, lfsr [3:0] };
						goal_y <= 4 + { 2'b0, lfsr [7:4] };
					end
					1 : begin
						goal_x <= 36 + { 2'b0, lfsr [3:0] };
						goal_y <= 4 + { 2'b0, lfsr [7:4] };
					end
					2 : begin
						goal_x <= 4 + { 2'b0, lfsr [3:0] };
						goal_y <= 36 + { 2'b0, lfsr [7:4] };
					end
					3 : begin
						goal_x <= 4 +(lfsr [5:0] % 48);
						goal_y <= 4 +(lfsr [11:6] % 48);
					end
				endcase
				ripple <= 0;
				reveal_ticks <= 0;
				hit_ticks <= 0;
				anim_frame <= 0;
				anim_half <= 0;
				pending_move <= 0;
				pending_torp <= 0;
				pending_drift <= 0;
				heading <= 0;
				view_index <= 0;
				work_frame <= 0;
				view_frame <= 0;
				warning <= 0;
				work_warning <= 0;
				job <= J_IDLE;
			end
			else if (state == ST_GEN) begin
				if (gen_addr == 4095) begin
					state <= ST_PLAY;
					gen_addr <= 0;
				end
				else gen_addr <= gen_addr + 1'b1;
			end
			else if (state == ST_PLAY) begin
				if (hit_ticks == 0) pending_move <= pending_move | move;
				else pending_move <= 0;
				if (torpedo && torpedo_ready) pending_torp <= 1;
				if (sonar && pings != 0 && ! sonar_active && ! hit_active) begin
					pings <= pings - 1'b1;
					ripple <= 1;
				end
				case (job)
					J_IDLE : begin
						if (pending_move != 0 && ! hit_active) begin
							pending_move <= 0;
							op <= OP_MOVE;
							target_x <= sub_x;
							target_y <= sub_y;
							if (pending_move [0]) begin
								heading <= 0;
								if (sub_y != 0) target_y <= sub_y - 1'b1;
							end
							else if (pending_move [1]) begin
								heading <= 1;
								if (sub_y != 63) target_y <= sub_y + 1'b1;
							end
							else if (pending_move [2]) begin
								heading <= 2;
								if (sub_x != 0) target_x <= sub_x - 1'b1;
							end
							else begin
								heading <= 3;
								if (sub_x != 63) target_x <= sub_x + 1'b1;
							end
							job <= J_READ;
						end
						else if (pending_torp && torpedo_ready && ! hit_active) begin
							pending_torp <= 0;
							torpedo_ready <= 0;
							op <= OP_TORP;
							target_x <= sub_x;
							target_y <= sub_y;
							case (heading)
								0 : if (sub_y != 0) target_y <= sub_y - 1'b1;
								1 : if (sub_y != 63) target_y <= sub_y + 1'b1;
								2 : if (sub_x != 0) target_x <= sub_x - 1'b1;
								3 : if (sub_x != 63) target_x <= sub_x + 1'b1;
							endcase
							job <= J_READ;
						end
						else if (pending_drift) begin
							pending_drift <= 0;
							op <= OP_DRIFT;
							target_x <= lfsr [5:0];
							target_y <= lfsr [11:6];
							job <= J_READ;
						end
						else begin
							op <= OP_VIEW;
							// Snapshot coordinates for an entire frame to prevent mixed camera rows.
							if (view_index == 0) begin
								view_sub_x <= sub_x;
								view_sub_y <= sub_y;
							end
							job <= J_READ;
						end
					end
					J_READ : begin
						if (op == OP_VIEW) begin
							wx = view_sub_x;
							wy = view_sub_y;
							wx = wx + view_index [2:0] - 3;
							wy = wy + view_index [5:3] - 3;
							access_addr <= { wy [5:0], wx [5:0] };
						end
						else access_addr <= { target_y, target_x };
						job <= J_WAIT;
					end
					J_WAIT : job <= J_APPLY;
					J_APPLY : begin
						job <= J_IDLE;
						if (op == OP_MOVE) begin
							sub_x <= target_x;
							sub_y <= target_y;
							if (ram_q) begin
								hp <= hp - 1'b1;
								hit_ticks <= 5;
								if (hp == 1) begin
									state <= ST_LOSE;
									anim_frame <= 0;
									anim_half <= 0;
								end
							end
							if (target_x == goal_x && target_y == goal_y && !(ram_q && hp == 1)) begin
								state <= ST_WIN;
								anim_frame <= 0;
								anim_half <= 0;
							end
							// Discard partial camera frame after moving.
							view_index <= 0;
							work_frame <= 0;
							work_warning <= 0;
						end
						else if (op == OP_VIEW) begin
							lx = view_index [2:0];
							ly = view_index [5:3];
							wx = view_sub_x;
							wy = view_sub_y;
							wx = wx + lx - 3;
							wy = wy + ly - 3;
							md =((lx > 3) ? lx - 3 : 3 - lx) +((ly > 3) ? ly - 3 : 3 - ly);
							if (wx < 0 || wx > 63 || wy < 0 || wy > 63) work_frame [view_index] <= 1;
							else begin
								work_frame [view_index] <=
								(ram_q &&(demo ||(blink &&(reveal_ticks != 0 ||(ripple != 0 && md < ripple))))) ||
								(ripple != 0 && md == ripple) ||(wx == goal_x && wy == goal_y);
								if (ram_q && md <= 2) work_warning <= 1;
							end
							// Commit one cycle later, at next dispatch, to include bit 63.
							if (view_index == 63) begin
								view_index <= 0;
							end
							else view_index <= view_index + 1'b1;
						end
					end
				endcase
				if (job == J_IDLE && view_index == 0) begin
					view_frame <= work_frame;
					warning <= work_warning;
					work_warning <= 0;
				end
			end
		end
	end
	always @* begin
		pixels = view_frame;
		pixels [27] = blink;
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
			5, 4, 2 : pixels = 64'hFFFF_FFFF_FFFF_FFFF;
			3 : pixels = 64'h8142_2418_1824_4281;
			default : pixels = 64'h0000_183C_3C18_0000;
		endcase
	end
endmodule
