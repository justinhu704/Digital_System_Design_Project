// VeriInstrument LCDM: Fast 2-clock-per-char writes on EN falling edges.
module text_lcd_driver #(
	parameter CLK_FREQ = 100,
	parameter POWER_ON_US = 10, SETUP_US = 10, ENABLE_US = 10,
	parameter COMMAND_US = 10, CLEAR_US = 10, POLL_US = 10
	)(input clk, input rst, input [255:0] line1, line2,
	output reg [7:0] db, output reg rs, output rw, output reg en, output reg lcd_rst);

	localparam [2:0] S_BOOT = 0, S_POLL = 1, S_RESET = 2, S_HIGH = 3, S_LOW = 4;

	reg [2:0] state;
	reg [5:0] byte_index;
	reg valid;
	reg [127:0] saved1, saved2;
	reg [255:0] shift_buf;

	wire changed = !valid || (line1[255:128] != saved1) || (line2[255:128] != saved2);
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
			byte_index <= 1;
			valid <= 0;
			saved1 <= 0;
			saved2 <= 0;
			shift_buf <= 0;
			db <= 0;
			rs <= 0;
			en <= 0;
			lcd_rst <= 1;
		end
		else begin
			case (state)
				S_BOOT, S_POLL: begin
					if (changed) begin
						saved1 <= line1[255:128];
						saved2 <= line2[255:128];
						shift_buf <= { line1[255:128], line2[255:128] };
						valid <= 1;
						byte_index <= 6'd1;
						lcd_rst <= 1;
						en <= 0;
						state <= S_RESET;
					end
					else begin
						lcd_rst <= 0;
						en <= 0;
						state <= S_POLL;
					end
				end
				S_RESET: begin
					lcd_rst <= 0;
					state <= S_HIGH;
				end
				S_HIGH: begin
					// Present data & raise EN=1 simultaneously
					rs <= 1'b1;
					en <= 1'b1;
					db <= lcd_code(shift_buf[255:248]);
					shift_buf <= { shift_buf[247:0], 8'h00 };
					state <= S_LOW;
				end
				S_LOW: begin
					// Falling edge of EN latches character into LCDM
					en <= 0;
					if (byte_index == 6'd32) begin
						state <= S_POLL;
					end
					else begin
						byte_index <= byte_index + 6'd1;
						state <= S_HIGH;
					end
				end
				default: begin
					en <= 0;
					lcd_rst <= 1;
					valid <= 0;
					state <= S_BOOT;
				end
			endcase
		end
	end
endmodule