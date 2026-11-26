// Driver for the VeriInstrument Text LCD Display (2x16, high active, Lecture 9).
// Each character takes 2 clocks: S_HIGH drives data and raises EN, S_LOW drops EN (falling edge writes).
// The screen is redrawn only when the text changes: RST is pulsed high for one clock
// (clear + home), then 32 characters are sent (the LCD wraps to line 2 after 16).
// Intended for a slow clock such as 500 Hz; EN would be far too short for a real LCD at MHz clocks.
// If the text changes mid-batch, the newest text is sent right after the batch finishes.
module text_lcd_driver(input clk, input rst, input [127:0] line1, line2,
	output reg [7:0] db, output reg rs, output rw, output reg en, output reg lcd_rst);

	localparam [2:0] S_BOOT = 0, S_POLL = 1, S_RESET = 2, S_HIGH = 3, S_LOW = 4;

	reg [2:0] state;
	reg [5:0] byte_index;
	reg valid;
	reg [127:0] saved1, saved2;
	reg [255:0] shift_buf;

	wire changed = !valid || (line1 != saved1) || (line2 != saved2);
	assign rw = 1'b0;

	// Course character table: code = ASCII - 0x20 (space -> 0x00, '0' -> 0x10, 'A' -> 0x21)
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
						// Snapshot a whole batch; changes during transmission go to the next batch
						saved1 <= line1;
						saved2 <= line2;
						shift_buf <= { line1, line2 };
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
					rs <= 1'b1;
					en <= 1'b1;
					db <= lcd_code(shift_buf[255:248]);
					shift_buf <= { shift_buf[247:0], 8'h00 };
					state <= S_LOW;
				end
				S_LOW: begin
					en <= 0;
					if (byte_index == 6'd32)
						state <= S_POLL;
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
