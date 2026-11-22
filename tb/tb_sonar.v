`timescale 1ns/1ps
module tb_sonar;
	reg clk = 0;
	always # 5 clk = ~ clk;
	reg rst = 1, tick = 0, sonar = 0, start = 0, torp = 0, hard = 0, drift = 0, demo = 0;
	reg [3:0] move = 0;
	reg [1:0] zone = 0;
	wire [5:0] x, y, gx, gy;
	wire [3:0] hp, pings;
	wire ready, warn, busy, hit;
	wire [2:0] state;
	wire [6:0] distance;
	wire [63:0] pixels;
	integer errors = 0, i, j, count;
	sonar_game_core dut(clk, rst, tick, move, sonar, start, torp, hard, drift, demo, zone,
	x, y, gx, gy, hp, pings, ready, state, warn, busy, hit, distance, pixels);
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
			cycles(4096);
			check(state == 2, "generation exactly 4096 writes");
			cycles(400);
		end
	endtask
	task go;
		input [3:0] d;
		begin
			move = d;
			cycles(1);
			move = 0;
			cycles(400);
		end
	endtask
	initial begin
		cycles(3);
		rst = 0;
		cycles(2);
		check(state == 0 && hp == 8 && pings == 9, "reset values");
		newgame;
		check(x == 52 && y == 52, "start position");
		check(gx >= 4 && gx <= 19 && gy >= 4 && gy <= 19, "NW goal bounds");
		count = 0;
		for (i = 0; i < 4096; i = i + 1) begin
			check(dut.map_ram.mem [i] === 0 || dut.map_ram.mem [i] === 1, "all map bits initialized");
			if (dut.map_ram.mem [i]) count = count + 1;
		end
		check(count > 100 && count < 400, "normal mine density");
		for (i = 50; i <= 54; i = i + 1) for (j = 50; j <= 54; j = j + 1)
		check(dut.map_ram.mem [j * 64 + i] == 0, "start safe zone");
		for (i = gx - 2; i <= gx + 2; i = i + 1) for (j = gy - 2; j <= gy + 2; j = j + 1)
		check(dut.map_ram.mem [j * 64 + i] == 0, "goal safe zone");
		go(1);
		check(x == 52 && y == 51, "north single step");
		dut.map_ram.mem [50 * 64 + 52] = 1;
		cycles(400);
		check(warn, "distance-one mine warning");
		go(1);
		check(hp == 7 && hit, "mine hit decrements once");
		check(dut.map_ram.mem [50 * 64 + 52] == 0, "hit clears mine");
		check(pixels == 64'hffffffffffffffff, "hit starts all bright");
		anim;
		anim;
		check(pixels == 64'h8142241818244281, "hit third tick cross");
		anim;
		check(pixels == 64'hffffffffffffffff, "hit second flash");
		anim;
		check(pixels == 64'h0000183c3c180000, "hit final aftershock");
		anim;
		check(! hit, "hit animation expires");
		// Sonar resource and retrigger protection.
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
		check(dut.ripple == 0 && dut.reveal_ticks == 12, "ripple enters reveal");
		repeat (12) anim;
		check(! busy, "reveal expires");
		// Facing north after movement, torpedo clears forward cell.
		dut.map_ram.mem [49 * 64 + 52] = 1;
		torp = 1;
		cycles(1);
		torp = 0;
		cycles(100);
		check(! ready && dut.map_ram.mem [49 * 64 + 52] == 0, "one-use torpedo");
		dut.map_ram.mem [49 * 64 + 52] = 1;
		torp = 1;
		cycles(1);
		torp = 0;
		cycles(100);
		check(dut.map_ram.mem [49 * 64 + 52] == 1, "spent torpedo cannot fire twice");
		// Defeat and direct restart.
		dut.hp = 1;
		go(1);
		check(state == 4 && hp == 0, "last mine hit loses");
		check(pixels == 64'hffffffffffffffff, "lose first frame");
		hard = 1;
		zone = 1;
		newgame;
		check(hp == 8 && pings == 9 && ready, "restart resources");
		check(gx >= 36 && gx <= 51 && gy <= 19, "north zone");
		count = 0;
		for (i = 0; i < 4096; i = i + 1) if (dut.map_ram.mem [i]) count = count + 1;
		check(count > 300 && count < 750, "hard density");
		// Boundary protection, no unsigned coordinate wrap.
		dut.sub_x = 0;
		dut.sub_y = 0;
		dut.map_ram.mem [0] = 0;
		go(4);
		check(x == 0 && y == 0, "west edge clamps");
		go(1);
		check(y == 0, "north edge clamps");
		check(pixels [0] && pixels [7] && pixels [56], "out-of-world wall");
		dut.goal_x = 63;
		dut.goal_y = 63;
		cycles(2);
		check(distance == 126, "full-width Manhattan distance");
		// Current never introduces mine at submarine or either safe zone.
		dut.target_x = 0;
		dut.target_y = 0;
		dut.access_addr = 0;
		dut.op = 3;
		dut.job = 3;
		cycles(2);
		check(dut.map_ram.mem [0] == 0, "current protects current submarine cell");
		// Reach an adjacent safe goal.
		dut.sub_x = 20;
		dut.sub_y = 20;
		dut.goal_x = 21;
		dut.goal_y = 20;
		dut.map_ram.mem [20 * 64 + 21] = 0;
		go(8);
		check(state == 3, "goal equality wins");
		check(pixels == 64'hff818181818181ff, "win starts outside ring");
		repeat (6) anim;
		check(pixels == 64'hffffffffffffffff, "win fills center");
		zone = 2;
		newgame;
		check(gx <= 19 && gy >= 36 && gy <= 51, "west zone");
		dut.state = 3;
		zone = 3;
		newgame;
		check(gx >= 4 && gx <= 51 && gy >= 4 && gy <= 51, "random zone safe margins");
		if (errors == 0) $display("PASS: sonar core regression");
		else $display("FAIL: %0d checks", errors);
		$finish;
	end
	initial begin
		# 2000000;
		errors = errors + 1;
		$display("FAIL: timeout");
		$finish;
	end
endmodule
