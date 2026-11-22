// VeriInstrument LCDM, per Lecture 9: 8-bit writes on EN falling edges.
// The upper 16 ASCII bytes of each row are encoded on the way to the LCD.
module text_lcd_driver #(
	parameter CLK_FREQ = 24000000,
	parameter POWER_ON_US = 40000, SETUP_US = 1000, ENABLE_US = 1000,
	parameter COMMAND_US = 1000, CLEAR_US = 2000, POLL_US = 20000
	)(input clk, input rst, input [255:0] line1, line2,
	output reg [7:0] db, output reg rs, output rw, output reg en, output reg lcd_rst);
	function [31:0] cycles_us;
		input integer us;
		reg [63:0] product;
		begin
			product = 64'd1 * CLK_FREQ * us + 64'd999999;
			cycles_us = product / 1000000;
			if (cycles_us < 1) cycles_us = 1;
		end
	endfunction
	function integer bits_for;
		input [31:0] limit;
		begin
			bits_for = 0;
			while (limit != 0) begin
				bits_for = bits_for + 1;
				limit = limit >> 1;
			end
			if (bits_for == 0) bits_for = 1;
		end
	endfunction
	function [31:0] max2;
		input [31:0] a, b;
		begin
			max2 =(a > b) ? a : b;
		end
	endfunction
	localparam POWER_C = cycles_us(POWER_ON_US), SETUP_C = cycles_us(SETUP_US),
	ENABLE_C = cycles_us(ENABLE_US), COMMAND_C = cycles_us(COMMAND_US),
	CLEAR_C = cycles_us(CLEAR_US), POLL_C = cycles_us(POLL_US);
	localparam MAX_C = max2(max2(max2(POWER_C, SETUP_C), max2(ENABLE_C, COMMAND_C)),
	max2(CLEAR_C, POLL_C));
	localparam [2:0] S_BOOT = 0, S_POLL = 1, S_RESET = 2, S_LOAD = 3,
		S_SETUP = 4, S_HIGH = 5, S_WAIT = 6;
	reg [2:0] state;
	reg [bits_for(MAX_C - 1) - 1:0] timer;
	reg [5:0] byte_index;
	reg valid;
	reg [127:0] saved1, saved2;
	wire changed = !valid || line1[255:128] != saved1 || line2[255:128] != saved2;
	assign rw = 1'b0;

	function [7:0] lcd_code;
		input [7:0] ascii;
		begin
			if (ascii >= 8'h20 && ascii <= 8'h7e)
				lcd_code = ascii - 8'h20;
			else
				lcd_code = 8'h00;
		end
	endfunction

	always @(posedge clk) begin
		if (rst) begin
			state <= S_BOOT;
			timer <= POWER_C - 1;
			byte_index <= 0;
			valid <= 0;
			saved1 <= 0;
			saved2 <= 0;
			db <= 0;
			rs <= 0;
			en <= 0;
			lcd_rst <= 1;
		end
		else if (timer != 0) begin
			timer <= timer - 1'b1;
		end
		else begin
			case (state)
				S_BOOT, S_POLL: begin
					if (changed) begin
						// Capture a coherent batch; changes during transmission are sent next batch.
						saved1 <= line1[255:128];
						saved2 <= line2[255:128];
						valid <= 1;
						byte_index <= 0;
						lcd_rst <= 1;
						timer <= CLEAR_C - 1;
						state <= S_RESET;
					end
					else begin
						timer <= POLL_C - 1;
						state <= S_POLL;
					end
				end
				S_RESET: begin
					lcd_rst <= 0;
					state <= S_LOAD;
				end
				S_LOAD: begin
					rs <= (byte_index != 0);
					if (byte_index == 0)
						db <= 8'hfc; // Hide cursor after resetting the display.
					else if (byte_index <= 16)
						db <= lcd_code(saved1[127 - 8 * (byte_index - 1) -: 8]);
					else
						db <= lcd_code(saved2[127 - 8 * (byte_index - 17) -: 8]);
					timer <= SETUP_C - 1;
					state <= S_SETUP;
				end
				S_SETUP: begin
					en <= 1;
					timer <= ENABLE_C - 1;
					state <= S_HIGH;
				end
				S_HIGH: begin
					en <= 0;
					timer <= COMMAND_C - 1;
					state <= S_WAIT;
				end
				S_WAIT: begin
					if (byte_index == 32) begin
						timer <= POLL_C - 1;
						state <= S_POLL;
					end
					else begin
						byte_index <= byte_index + 1'b1;
						state <= S_LOAD;
					end
				end
				default: begin
					en <= 0;
					lcd_rst <= 1;
					valid <= 0;
					timer <= POWER_C - 1;
					state <= S_BOOT;
				end
			endcase
		end
	end
endmodule
