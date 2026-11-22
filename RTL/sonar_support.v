// 產生固定頻率的掃描、按鈕、動畫時脈訊號
module sonar_ticks #(parameter CLK_FREQ = 24000000)(input clk, input rst,
	output tick_scan, output tick_key, output tick_anim);
	reg [31:0] cs, ck, ca;
	localparam SC =(CLK_FREQ / 2000 > 0) ? CLK_FREQ / 2000 : 1;
	localparam KY =(CLK_FREQ / 100 > 0) ? CLK_FREQ / 100 : 1;
	localparam AN =(CLK_FREQ / 10 > 0) ? CLK_FREQ / 10 : 1;
	assign tick_scan = cs == SC - 1;
	assign tick_key = ck == KY - 1;
	assign tick_anim = ca == AN - 1;
	always @(posedge clk) if (rst) begin
		cs <= 0;
		ck <= 0;
		ca <= 0;
	end
	else begin
		cs <= tick_scan ? 0 : cs + 1;
		ck <= tick_key ? 0 : ck + 1;
		ca <= tick_anim ? 0 : ca + 1;
	end
endmodule

// 按鈕防彈跳
module btn_debouncer(input clk, input rst, input tick, input raw,
	output reg level, output reg pressed);
	reg s1, s2, hist;
	always @(posedge clk) begin
		s1 <= raw;
		s2 <= s1;
		pressed <= 0;
		if (rst) begin
			s1 <= 0;
			s2 <= 0;
			hist <= 0;
			level <= 0;
		end
		else if (tick) begin
			hist <= s2;
			if (s2 == hist && s2 != level) begin
				level <= s2;
				pressed <= s2;
			end
		end
	end
endmodule

// 4Kx1 RAM for sonar map
module sonar_map_ram(input clk, input we, input [11:0] addr, input din, output reg dout);
	(* ramstyle = "M4K" *) reg mem [0:4095];
	always @(posedge clk) begin
		if (we) begin
			mem [addr] <= din;
			dout <= din;
		end
		else dout <= mem [addr];
	end
endmodule

// 8x8 LED 矩陣驅動
module matrix_8x8_driver #(parameter ROW_INV = 0, COL_INV = 0)
	(input clk, input rst, input tick, input [63:0] pixels, output [7:0] rows, cols);
	reg [2:0] row;
	reg [63:0] frame;
	always @(posedge clk) if (rst) begin
		row <= 7;
		frame <= 0;
	end
	else if (tick) begin
		row <= row + 1'b1;
		if (row == 7) frame <= pixels;
	end
	assign rows =(8'b1 << row) ^ { 8 { ROW_INV != 0 } };
	assign cols =(frame >>(row * 8)) ^ { 8 { COL_INV != 0 } };
endmodule

// 雙位數七段顯示器驅動
module dual_7seg_driver #(parameter SEG_INV = 0, SEL_INV = 0)
	(input clk, input rst, input tick, input [5:0] value, output [6:0] seg, output [1:0] sel);
	reg digit;
	reg [3:0] n;
	reg [6:0] code;
	always @(posedge clk) if (rst) digit <= 0;
	else if (tick) digit <= ~ digit;
	// seg[0..6] = a,b,c,d,e,f,g. sel[0]=tens, sel[1]=units.
	always @* begin
		n = digit ? value % 10 : value / 10;
		case (n)
			0 : code = 7'b0111111;
			1 : code = 7'b0000110;
			2 : code = 7'b1011011;
			3 : code = 7'b1001111;
			4 : code = 7'b1100110;
			5 : code = 7'b1101101;
			6 : code = 7'b1111101;
			7 : code = 7'b0000111;
			8 : code = 7'b1111111;
			9 : code = 7'b1101111;
			default : code = 0;
		endcase
	end
	assign seg = code ^ { 7 { SEG_INV != 0 } };
	assign sel =(digit ? 2'b10 : 2'b01) ^ { 2 { SEL_INV != 0 } };
endmodule
