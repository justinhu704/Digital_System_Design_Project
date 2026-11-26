`timescale 1ns/1ps
// Game-core unit test: drives sonar_game_core directly; uses hierarchical access to place mines.
module tb_sonar;
	reg clk = 0;
	always #5 clk = ~clk;
	reg rst = 1, tick = 0, sonar = 0, start = 0, torp = 0, hard = 0, drift = 0, demo = 0;
	reg [3:0] move = 0;
	wire [5:0] x, y, gx, gy;
	wire [3:0] hp, pings;
	wire [2:0] torps;
	wire warn, busy, hit;
	wire [2:0] state;
	wire [6:0] distance;
	wire [63:0] pixels;
	integer errors = 0, i, j, count, g, d, distinct, rows_not4, period16;
	integer min_d, max_d, sx, sy, quads, total_mines, min_m, max_m;
	integer t4, t5, t6, t7, tplus, tdiag, tend;
	reg [3:0] quad_seen;
	reg [63:0] r;
	reg [4095:0] goal_seen;
	sonar_game_core dut(clk, rst, tick, move, sonar, start, torp, hard, drift, demo,
		x, y, gx, gy, hp, pings, torps, state, warn, busy, hit, distance, pixels);

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
	task cycles;
		input integer n;
		begin
			repeat (n) @(negedge clk);
		end
	endtask
	task anim;
		begin
			tick = 1;
			cycles(1);
			tick = 0;
			cycles(1);
		end
	endtask
	task newgame;
		begin
			start = 1;
			cycles(1);
			start = 0;
			i = 0;
			while (state != 2 && i < 5000) begin
				cycles(1);
				i = i + 1;
			end
			check(state == 2, "PICK + GEN reaches PLAY");
			sx = x;
			sy = y;
			cycles(200);
		end
	endtask
	task go;
		input [3:0] dir;
		begin
			move = dir;
			cycles(1);
			move = 0;
			cycles(200);
		end
	endtask
	function integer absd;
		input integer a, b;
		absd = (a > b) ? a - b : b - a;
	endfunction
	task fire;             // fire and wait for the flight and explosion to finish
		begin
			torp = 1;
			cycles(1);
			torp = 0;
			cycles(400);
		end
	endtask
	task place;            // put the submarine at (px, py) facing dir (0 N, 1 S, 2 W, 3 E)
		input integer px, py, dir;
		begin
			dut.sub_x = px;
			dut.sub_y = py;
			dut.heading = dir;
			dut.map_ram.mem[py][px] = 0;
			cycles(2);
		end
	endtask
	task count_mines;
		begin
			count = 0;
			for (j = 0; j < 64; j = j + 1)
				for (i = 0; i < 64; i = i + 1)
					if (dut.map_ram.mem[j][i]) count = count + 1;
		end
	endtask

	initial begin
		cycles(3);
		rst = 0;
		cycles(2);
		check(state == 0 && hp == 8 && pings == 9 && torps == 6, "reset values");
		check(pixels == 64'h0000001818000000, "idle pattern");

		// ---------- normal game: distance, map quality, safe zones ----------
		newgame;
		d = absd(gx, sx) + absd(gy, sy);
		check(d >= 24 && d <= 48, "normal start-goal distance 24..48");
		check(sx >= 3 && sx <= 60 && sy >= 3 && sy <= 60, "start inside 3..60");
		check(gx >= 3 && gx <= 60 && gy >= 3 && gy <= 60, "goal inside 3..60");
		for (j = 0; j < 64; j = j + 1)
			check(^dut.map_ram.mem[j] !== 1'bx, "all map rows initialized");
		count_mines;
		$display("INFO: normal map mines = %0d / 4096", count);
		check(count > 160 && count < 360, "normal mine density about 1/16");
		for (i = sx - 2; i <= sx + 2; i = i + 1) for (j = sy - 2; j <= sy + 2; j = j + 1)
			check(dut.map_ram.mem[j][i] == 0, "start 5x5 safe zone");
		for (i = gx - 3; i <= gx + 3; i = i + 1) for (j = gy - 3; j <= gy + 3; j = j + 1)
			check(dut.map_ram.mem[j][i] == 0, "goal 7x7 safe zone");
		// Old hash defect: exactly 4 mines per row repeating every 16 columns.
		rows_not4 = 0;
		period16 = 0;
		for (j = 0; j < 64; j = j + 1) begin
			r = dut.map_ram.mem[j];
			count = 0;
			for (i = 0; i < 64; i = i + 1) if (r[i]) count = count + 1;
			if (count != 4) rows_not4 = rows_not4 + 1;
			if (r != 0 && r == { r[47:0], r[63:48] }) period16 = period16 + 1;
		end
		check(rows_not4 > 30, "mine count per row varies");
		check(period16 < 3, "rows are not 16-column periodic");

		// ---------- move, warning, mine hit ----------
		go(1);
		check(x == sx && y == sy - 1, "north single step");
		dut.map_ram.mem[sy - 2][sx] = 1;
		cycles(200);
		check(warn, "distance-one mine warning");
		go(1);
		check(hp == 7 && hit, "mine hit decrements once");
		check(dut.map_ram.mem[sy - 2][sx] == 0, "hit clears mine");
		check(pixels == 64'hffffffffffffffff, "hit frame 1 all bright");
		go(2);
		check(y == sy - 2, "move ignored while stunned");
		anim;
		check(pixels == 64'h8142241818244281, "hit frame 3 cross");
		anim;
		check(pixels == 64'hffffffffffffffff, "hit frame 2 flash");
		anim;
		check(pixels == 64'h0000183c3c180000, "hit final aftershock");
		anim;
		check(!hit, "hit animation expires");

		// ---------- sonar ----------
		sonar = 1;
		cycles(1);
		sonar = 0;
		cycles(2);
		check(pings == 8 && busy && dut.ripple == 1, "sonar starts");
		sonar = 1;
		cycles(1);
		sonar = 0;
		cycles(1);
		check(pings == 8, "busy sonar not charged");
		repeat (12) anim;
		check(dut.ripple == 0 && dut.reveal_ticks == 15, "ripple enters reveal");
		dut.map_ram.mem[sy - 1][sx + 1] = 1;      // view (4,4) = pixel 36
		cycles(200);
		check(pixels[36] == 1, "reveal shows mine");
		repeat (30) anim;
		check(!busy, "reveal expires");
		cycles(200);
		check(pixels[36] == 0, "mine hidden after reveal");
		demo = 1;
		cycles(200);
		check(pixels[36] == 1, "demo shows mine");
		demo = 0;
		dut.map_ram.mem[sy - 1][sx + 1] = 0;
		for (i = 0; i < 8; i = i + 1) begin
			sonar = 1;
			cycles(1);
			sonar = 0;
			repeat (44) anim;
		end
		check(pings == 0, "all nine pings used");
		sonar = 1;
		cycles(1);
		sonar = 0;
		cycles(2);
		check(!busy && pings == 0, "no sonar without pings");

		// ---------- torpedo (facing north at sx, sy-2) ----------
		check(torps == 6, "normal game has 6 torpedoes");
		dut.map_ram.mem[sy - 3][sx] = 1;
		fire;
		check(torps == 5 && dut.map_ram.mem[sy - 3][sx] == 0, "torpedo clears adjacent mine, 5 left");
		dut.map_ram.mem[sy - 3][sx] = 1;
		dut.torpedoes = 0;
		fire;
		check(torps == 0 && dut.map_ram.mem[sy - 3][sx] == 1, "no torpedo fires when none are left");

		// ---------- defeat, then restart in hard mode ----------
		dut.hp = 1;
		go(1);
		check(state == 4 && hp == 0, "last mine hit loses");
		check(pixels == 64'hffffffffffffffff, "lose first frame");
		hard = 1;
		newgame;
		check(hp == 8 && pings == 9 && torps == 3, "hard restart resources, 3 torpedoes");
		d = absd(gx, sx) + absd(gy, sy);
		check(d >= 64, "hard start-goal distance >= 64");
		count_mines;
		$display("INFO: hard map mines = %0d / 4096", count);
		check(count > 380 && count < 660, "hard mine density about 1/8");
		for (i = sx - 2; i <= sx + 2; i = i + 1) for (j = sy - 2; j <= sy + 2; j = j + 1)
			check(dut.map_ram.mem[j][i] == 0, "hard start safe zone");

		// ---------- borders ----------
		dut.sub_x = 0;
		dut.sub_y = 0;
		dut.map_ram.mem[0][0] = 0;
		go(4);
		check(x == 0 && y == 0, "west edge clamps");
		go(1);
		check(y == 0, "north edge clamps");
		check(pixels[0] && pixels[7] && pixels[56], "out-of-world wall");
		fire;
		check(torps == 3, "torpedo facing wall is not spent");
		dut.goal_x = 63;
		dut.goal_y = 63;
		cycles(2);
		check(distance == 126, "full-width Manhattan distance");

		// ---------- current never mines the submarine cell ----------
		dut.target_x = 0;
		dut.target_y = 0;
		dut.access_row = 0;
		dut.op = 3;
		dut.job = 3;
		cycles(2);
		check(dut.map_ram.mem[0][0] == 0, "current protects submarine cell");

		// ---------- straight-flying torpedo ----------
		dut.torpedoes = 6;
		place(30, 30, 0);                          // north: first mine 3 cells ahead
		for (i = 26; i <= 29; i = i + 1) dut.map_ram.mem[i][30] = 0;
		dut.map_ram.mem[27][30] = 1;
		dut.map_ram.mem[26][30] = 1;
		fire;
		check(dut.map_ram.mem[27][30] == 0 && dut.map_ram.mem[26][30] == 1 && torps == 5,
			"torpedo flies to the first mine and stops there");
		place(30, 30, 3);                          // east: range is 4 cells, watch the animation
		for (i = 31; i <= 35; i = i + 1) dut.map_ram.mem[30][i] = 0;
		dut.map_ram.mem[30][34] = 1;
		cycles(100);
		check(pixels[31:28] == 0, "view east of submarine dark before launch");
		t4 = -1; t5 = -1; t6 = -1; t7 = -1; tplus = -1; tdiag = -1; tend = -1;
		torp = 1;
		cycles(1);
		torp = 0;
		for (i = 0; i < 400; i = i + 1) begin
			if (t4 < 0 && pixels[28]) t4 = i;
			if (t5 < 0 && pixels[29]) t5 = i;
			if (t6 < 0 && pixels[30]) t6 = i;
			if (t7 < 0 && pixels[31]) t7 = i;
			if (tplus < 0 && pixels[23] && pixels[39] && pixels[30]) tplus = i;    // '+' around view (7,3)
			if (tdiag < 0 && pixels[22] && pixels[38] && !pixels[31]) tdiag = i;   // diagonals at (6,2),(6,4)
			if (tdiag >= 0 && tend < 0 && pixels[31:28] == 0 && !pixels[22] && !pixels[38]) tend = i;
			cycles(1);
		end
		$display("INFO: torpedo dot at view x=4,5,6,7 from clock %0d,%0d,%0d,%0d; explosion '+' %0d, diagonals %0d, clear %0d",
			t4, t5, t6, t7, tplus, tdiag, tend);
		check(t4 >= 0 && t4 < 5, "torpedo appears in front of the bow right after launch");
		check(t5 - t4 >= 30 && t5 - t4 <= 40 && t6 - t5 >= 30 && t6 - t5 <= 40 && t7 - t6 >= 30 && t7 - t6 <= 40,
			"torpedo advances one cell about every 60 ms");
		check(tplus >= t7 && tplus - t7 < 10, "explosion '+' when the torpedo hits");
		check(tdiag - tplus >= 45 && tdiag - tplus <= 55, "explosion turns into diagonals after 100 ms");
		check(tend - tplus >= 95 && tend - tplus <= 105, "explosion lasts 200 ms, then the cell is clear");
		check(dut.map_ram.mem[30][34] == 0 && torps == 4, "torpedo reaches 4 cells");
		dut.map_ram.mem[30][35] = 1;
		fire;
		check(dut.map_ram.mem[30][35] == 1 && torps == 3, "nothing beyond 4 cells; a miss is still spent");
		place(30, 61, 1);                          // south: stops at the map edge
		dut.map_ram.mem[62][30] = 0;
		dut.map_ram.mem[63][30] = 1;
		fire;
		check(dut.map_ram.mem[63][30] == 0 && torps == 2, "torpedo reaches the last row");
		fire;
		check(torps == 1 && !dut.torp_flying, "torpedo through empty cells to the edge finishes");
		place(10, 30, 2);                          // west: only the first of two mines
		for (i = 6; i <= 9; i = i + 1) dut.map_ram.mem[30][i] = 0;
		dut.map_ram.mem[30][8] = 1;
		dut.map_ram.mem[30][7] = 1;
		fire;
		check(dut.map_ram.mem[30][8] == 0 && dut.map_ram.mem[30][7] == 1 && torps == 0,
			"west torpedo destroys only the first mine");
		go(4);
		check(x == 9 && y == 30 && hp == 8, "path cleared by torpedo is safe");

		// ---------- win via a '+' arm ----------
		dut.sub_x = 20;
		dut.sub_y = 20;
		dut.goal_x = 22;
		dut.goal_y = 20;
		dut.map_ram.mem[20][21] = 0;
		go(8);
		check(state == 3, "touching goal plus arm wins");
		check(pixels == 64'hff818181818181ff, "win first frame");
		repeat (6) anim;
		check(pixels == 64'hffffffffffffffff, "win fills center");

		// ---------- randomness: 40 games per difficulty ----------
		for (g = 0; g < 2; g = g + 1) begin
			hard = g;
			goal_seen = 0;
			distinct = 0;
			quad_seen = 0;
			min_d = 999;
			max_d = 0;
			total_mines = 0;
			min_m = 9999;
			max_m = 0;
			for (j = 0; j < 40; j = j + 1) begin
				cycles(1 + (j * 37) % 23);   // players press Start at different times
				newgame;
				d = absd(gx, sx) + absd(gy, sy);
				if (d < min_d) min_d = d;
				if (d > max_d) max_d = d;
				check(gx >= 3 && gx <= 60 && gy >= 3 && gy <= 60, "random goal bounds");
				check(sx >= 3 && sx <= 60 && sy >= 3 && sy <= 60, "random start bounds");
				if (g == 0) check(d >= 24 && d <= 48, "normal distance");
				else check(d >= 64, "hard distance");
				if (!goal_seen[gy * 64 + gx]) distinct = distinct + 1;
				goal_seen[gy * 64 + gx] = 1;
				quad_seen[{ (gx > sx), (gy > sy) }] = 1;
				d = j;
				count_mines;
				j = d;
				total_mines = total_mines + count;
				if (count < min_m) min_m = count;
				if (count > max_m) max_m = count;
			end
			$display("INFO: %0s: mines per map avg %0d (min %0d, max %0d), expected about %0d",
				g ? "hard" : "normal", total_mines / 40, min_m, max_m, g ? 504 : 252);
			check(total_mines / 40 > (g ? 470 : 230) && total_mines / 40 < (g ? 540 : 275), "average density matches 1/16 or 1/8");
			quads = quad_seen[0] + quad_seen[1] + quad_seen[2] + quad_seen[3];
			$display("INFO: %0s: %0d distinct goals of 40, distance %0d..%0d, directions NW/SW/NE/SE seen = %b",
				g ? "hard" : "normal", distinct, min_d, max_d, quad_seen);
			check(distinct >= 30, "goals vary between games");
			check(quads == 4, "goal appears in every direction from start");
		end

		if (errors == 0) $display("PASS: sonar core regression");
		else $display("FAIL: %0d checks", errors);
		$finish;
	end
	initial begin
		#40000000;
		errors = errors + 1;
		$display("FAIL: timeout");
		$finish;
	end
endmodule
