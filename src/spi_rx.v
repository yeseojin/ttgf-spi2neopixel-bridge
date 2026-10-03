/*
 * spi_rx.v
 * SPI mode 0 slave receiver (sample on SCK rising edge, MSB first).
 *
 * Frame inside one CS_n low period (one burst):
 *   command byte, always 1-bit on IO0
 *     02h WRITE       -> data bytes 1-bit on IO0
 *     32h WRITE_QUAD  -> data bytes 4-bit, high nibble first,
 *                        IO3 = bit 7 / bit 3, IO0 = bit 4 / bit 0
 *     A5h LATCH       -> no data, further bits ignored
 *     other           -> UNKNOWN, further bits ignored
 *
 * Outputs are registered one clk after the last SCK rising edge of a byte.
 * byte_data is the shift register itself; it stays valid until the next
 * SCK rising edge, which is at least 4 clk away because SCK <= clk/4.
 *
 * DFF count: shift 8 + count 3 + phase 2 + cmd 2 + pulses 2 = 17
 */

`default_nettype none

module spi_rx (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       sck_rise,
    input  wire       cs_fall,
    input  wire       csn_s,
    input  wire [3:0] io_s,
    output reg        cmd_valid,   // one clk pulse after the command byte
    output reg  [1:0] cmd,         // decoded command, held until next cs_fall
    output reg        byte_valid,  // one clk pulse after each data byte
    output wire [7:0] byte_data
);

  // Command codes on the bus [engineer]
  localparam [7:0] OP_WRITE      = 8'h02;
  localparam [7:0] OP_WRITE_QUAD = 8'h32;
  localparam [7:0] OP_LATCH      = 8'hA5;

  // Decoded command values
  localparam [1:0] CMD_UNKNOWN    = 2'd0;
  localparam [1:0] CMD_WRITE      = 2'd1;
  localparam [1:0] CMD_WRITE_QUAD = 2'd2;
  localparam [1:0] CMD_LATCH      = 2'd3;

  // Receive phase
  localparam [1:0] PH_CMD    = 2'd0;
  localparam [1:0] PH_DATA1  = 2'd1;
  localparam [1:0] PH_DATA4  = 2'd2;
  localparam [1:0] PH_IGNORE = 2'd3;

  reg [7:0] shift;
  reg [2:0] cnt;
  reg [1:0] phase;

  // Next shift value for the current SCK edge
  wire [7:0] shift_1bit = {shift[6:0], io_s[0]};
  wire [7:0] shift_4bit = {shift[3:0], io_s[3:0]};

  // Last edge of a byte
  wire last_1bit = (cnt == 3'd7);
  wire last_4bit = (cnt == 3'd1);

  assign byte_data = shift;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      shift      <= 8'h00;
      cnt        <= 3'd0;
      phase      <= PH_CMD;
      cmd        <= CMD_UNKNOWN;
      cmd_valid  <= 1'b0;
      byte_valid <= 1'b0;
    end else begin
      cmd_valid  <= 1'b0;
      byte_valid <= 1'b0;

      if (cs_fall) begin
        cnt   <= 3'd0;
        phase <= PH_CMD;
        cmd   <= CMD_UNKNOWN;
      end else if (sck_rise && !csn_s) begin
        case (phase)
          PH_CMD: begin
            shift <= shift_1bit;
            cnt   <= cnt + 3'd1;
            if (last_1bit) begin
              cmd_valid <= 1'b1;
              cnt       <= 3'd0;
              case (shift_1bit)
                OP_WRITE:      begin cmd <= CMD_WRITE;      phase <= PH_DATA1;  end
                OP_WRITE_QUAD: begin cmd <= CMD_WRITE_QUAD; phase <= PH_DATA4;  end
                OP_LATCH:      begin cmd <= CMD_LATCH;      phase <= PH_IGNORE; end
                default:       begin cmd <= CMD_UNKNOWN;    phase <= PH_IGNORE; end
              endcase
            end
          end
          PH_DATA1: begin
            shift <= shift_1bit;
            cnt   <= cnt + 3'd1;
            if (last_1bit) begin
              byte_valid <= 1'b1;
              cnt        <= 3'd0;
            end
          end
          PH_DATA4: begin
            shift <= shift_4bit;
            cnt   <= cnt + 3'd1;
            if (last_4bit) begin
              byte_valid <= 1'b1;
              cnt        <= 3'd0;
            end
          end
          default: ; // PH_IGNORE
        endcase
      end
    end
  end

endmodule

`default_nettype wire
