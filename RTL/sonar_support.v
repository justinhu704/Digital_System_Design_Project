// ??????????????????? (500 Hz ???)
module sonar_ticks #(parameter CLK_FREQ = 500)(input clk, input rst,
	output tick_scan, output tick_key, output tick_anim);
	reg [15:0] cs, ck, ca;
	localparam SC = (CLK_FREQ / 500 > 0) ? CLK_FREQ / 500 : 1; // 500Hz: every clock
	localparam KY = (CLK_FREQ / 25 > 0)  ? CLK_FREQ / 25  : 1; // 500Hz: every 20 clocks (40ms)
	localparam AN = (CLK_FREQ / 10 > 0)  ? CLK_FREQ / 10  : 1; // 500Hz: every 50 clocks (100ms)
	assign tick_scan = (cs == SC - 1);
	assign tick_key = (ck == KY - 1);
	assign tick_anim = (ca == AN - 1);
	always @(posedge clk) begin
		if (rst) begin
			cs <= 0;
			ck <= 0;
			ca <= 0;
		end
		else begin
			cs <= tick_scan ? 16'd0 : cs + 16'd1;
			ck <= tick_key ? 16'd0 : ck + 16'd1;
			ca <= tick_anim ? 16'd0 : ca + 16'd1;
		end
	end
endmodule

// ???????? (??? 2 ? 40ms ???? = 80ms ?????????,?????????)
module btn_debouncer(input clk, input rst, input tick, input raw,
	output reg level, output reg pressed);
	reg s1, s2, h1, h2;
	always @(posedge clk) begin
		s1 <= raw;
		s2 <= s1;
		pressed <= 0;
		if (rst) begin
			s1 <= 0;
			s2 <= 0;
			h1 <= 0;
			h2 <= 0;
			level <= 0;
		end
		else if (tick) begin
			h1 <= s2;
			h2 <= h1;
			if (s2 == h1 && h1 == h2 && s2 != level) begin
				level <= s2;
				pressed <= s2;
			end
		end
	end
endmodule

// 8x8 LED ???? (Active-Row Skipping:???????,?????????)
module matrix_8x8_driver #(parameter ROW_INV = 0, COL_INV = 0)
	(input clk, input rst, input tick, input [63:0] pixels, output [7:0] rows, cols);
	reg [2:0] row;
	reg [63:0] frame;

	reg [2:0] next_row;
	integer i;
	reg found;
	always @* begin
		next_row = row + 3'd1;
		found = 0;
		for (i = 1; i <= 8; i = i + 1) begin
			if (!found && (pixels[((row + i[2:0]) * 8) +: 8] != 8'd0)) begin
				next_row = row + i[2:0];
				found = 1;
			end
		end
	end

	always @(posedge clk) begin
		if (rst) begin
			row <= 0;
			frame <= 0;
		end
		else if (tick) begin
			frame <= pixels;
			row <= next_row;
		end
	end

	wire [7:0] cur_col = frame[row * 8 +: 8];
	wire [7:0] raw_row = (cur_col == 8'd0) ? 8'd0 : (8'b1 << row);
	assign rows = raw_row ^ { 8 { ROW_INV != 0 } };
	assign cols = cur_col ^ { 8 { COL_INV != 0 } };
endmodule

// ?????????? (125 Hz ????)
module dual_7seg_driver #(parameter SEG_INV = 0, SEL_INV = 0)
	(input clk, input rst, input tick, input [5:0] value, output [6:0] seg, output [1:0] sel);
	reg [1:0] div_cnt;
	wire digit = div_cnt[1];
	reg [3:0] tens, ones;
	reg [6:0] code;
	always @(posedge clk) begin
		if (rst) div_cnt <= 0;
		else if (tick) div_cnt <= div_cnt + 2'd1;
	end

	always @* begin
		if (value >= 6'd60)      begin tens = 4'd6; ones = value - 6'd60; end
		else if (value >= 6'd50) begin tens = 4'd5; ones = value - 6'd50; end
		else if (value >= 6'd40) begin tens = 4'd4; ones = value - 6'd40; end
		else if (value >= 6'd30) begin tens = 4'd3; ones = value - 6'd30; end
		else if (value >= 6'd20) begin tens = 4'd2; ones = value - 6'd20; end
		else if (value >= 6'd10) begin tens = 4'd1; ones = value - 6'd10; end
		else                     begin tens = 4'd0; ones = value[3:0];  end

		case (digit ? ones : tens)
			4'd0 : code = 7'b0111111;
			4'd1 : code = 7'b0000110;
			4'd2 : code = 7'b1011011;
			4'd3 : code = 7'b1001111;
			4'd4 : code = 7'b1100110;
			4'd5 : code = 7'b1101101;
			4'd6 : code = 7'b1111101;
			4'd7 : code = 7'b0000111;
			4'd8 : code = 7'b1111111;
			4'd9 : code = 7'b1101111;
			default : code = 7'b0000000;
		endcase
	end

	assign seg = code ^ { 7 { SEG_INV != 0 } };
	assign sel = (digit ? 2'b10 : 2'b01) ^ { 2 { SEL_INV != 0 } };
endmodule