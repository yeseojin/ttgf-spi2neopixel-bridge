/*
 * spi_rx.v
 * SPI mode 0 slave (sample on SCK rising edge, MSB first).
 *
 * Bursts on the MCU bus start with a command byte, always 1-bit on IO0:
 *   01h CONFIG      -> 1 data byte, 1-bit
 *   02h WRITE       -> data bytes, 1-bit
 *   32h WRITE_QUAD  -> data bytes, 4-bit, high nibble first,
 *                      IO3 = bit 7 / bit 3, IO0 = bit 4 / bit 0
 *   05h STATUS      -> the status byte is shifted out on MISO, MSB first
 *   A5h LATCH       -> no data, further bits ignored
 *   other           -> UNKNOWN, further bits ignored
 *
 * Snoop bursts (Pmod bus selected, snoop_s = 1) have no command byte: the
 * receiver acts as if WRITE_QUAD had been received. The decision is taken
 * one clock after cs_fall so that CS_n and the bus select are both
 * through their synchronizers.
 *
 * Status read: the status byte is loaded when the 05h command byte is
 * complete and shifted after every following SCK rising edge, i.e. MISO
 * changes a few clocks after the edge the MCU sampled on. This needs
 * SCK <= clk/8 during a status read.
 *
 * Outputs are registered one clk after the last SCK rising edge of a byte.
 * byte_data is the shift register itself; it stays valid until the next
 * SCK rising edge, which is at least 4 clk away because SCK <= clk/4.
 *
 * DFF count: shift 8 + count 3 + phase 3 + cmd 3 + pulses 2 + cs_fall_d 1
 *            = 20
 */

`default_nettype none

module spi_rx (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       sck_rise,
    input  wire       cs_fall,
    input  wire       csn_s,
    input  wire       snoop_s,
    input  wire [3:0] io_s,
    input  wire [7:0] status,      // status byte for 05h
    output reg        cmd_valid,   // one clk pulse after the command byte
    output reg  [2:0] cmd,         // decoded command, held until next cs_fall
    output reg        byte_valid,  // one clk pulse after each data byte
    output wire [7:0] byte_data,
    output wire       miso,
    output wire       miso_oe
);

  // Command codes on the bus [engineer]
  localparam [7:0] OP_CONFIG     = 8'h01;
  localparam [7:0] OP_WRITE      = 8'h02;
  localparam [7:0] OP_STATUS     = 8'h05;
  localparam [7:0] OP_WRITE_QUAD = 8'h32;
  localparam [7:0] OP_LATCH      = 8'hA5;

  // Decoded command values (shared with burst_ctrl)
  localparam [2:0] CMD_UNKNOWN    = 3'd0;
  localparam [2:0] CMD_WRITE      = 3'd1;
  localparam [2:0] CMD_WRITE_QUAD = 3'd2;
  localparam [2:0] CMD_LATCH      = 3'd3;
  localparam [2:0] CMD_CONFIG     = 3'd4;
  localparam [2:0] CMD_STATUS     = 3'd5;

  // Receive phase
  localparam [2:0] PH_CMD    = 3'd0;
  localparam [2:0] PH_DATA1  = 3'd1;
  localparam [2:0] PH_DATA4  = 3'd2;
  localparam [2:0] PH_IGNORE = 3'd3;
  localparam [2:0] PH_READ   = 3'd4;

  reg [7:0] shift;
  reg [2:0] cnt;
  reg [2:0] phase;
  reg       cs_fall_d;

  // Next shift value for the current SCK edge
  wire [7:0] shift_1bit = {shift[6:0], io_s[0]};
  wire [7:0] shift_4bit = {shift[3:0], io_s[3:0]};

  // Last edge of a byte
  wire last_1bit = (cnt == 3'd7);
  wire last_4bit = (cnt == 3'd1);

  assign byte_data = shift;
  assign miso      = shift[7];
  assign miso_oe   = (phase == PH_READ) && !csn_s;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      shift      <= 8'h00;
      cnt        <= 3'd0;
      phase      <= PH_CMD;
      cmd        <= CMD_UNKNOWN;
      cmd_valid  <= 1'b0;
      byte_valid <= 1'b0;
      cs_fall_d  <= 1'b0;
    end else begin
      cmd_valid  <= 1'b0;
      byte_valid <= 1'b0;
      cs_fall_d  <= cs_fall;

      if (cs_fall) begin
        cnt   <= 3'd0;
        phase <= PH_CMD;
        cmd   <= CMD_UNKNOWN;
      end else if (cs_fall_d && snoop_s && !csn_s) begin
        // snoop burst: implicit WRITE_QUAD, no command byte
        cmd       <= CMD_WRITE_QUAD;
        phase     <= PH_DATA4;
        cmd_valid <= 1'b1;
      end else if (sck_rise && !csn_s) begin
        case (phase)
          PH_CMD: begin
            shift <= shift_1bit;
            cnt   <= cnt + 3'd1;
            if (last_1bit) begin
              cmd_valid <= 1'b1;
              cnt       <= 3'd0;
              case (shift_1bit)
                OP_CONFIG:     begin cmd <= CMD_CONFIG;     phase <= PH_DATA1;  end
                OP_WRITE:      begin cmd <= CMD_WRITE;      phase <= PH_DATA1;  end
                OP_WRITE_QUAD: begin cmd <= CMD_WRITE_QUAD; phase <= PH_DATA4;  end
                OP_LATCH:      begin cmd <= CMD_LATCH;      phase <= PH_IGNORE; end
                OP_STATUS:     begin cmd <= CMD_STATUS;     phase <= PH_READ;
                                     shift <= status;                             end
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
          PH_READ: begin
            shift <= {shift[6:0], 1'b0};          // next status bit on MISO
          end
          default: ; // PH_IGNORE
        endcase
      end
    end
  end

endmodule

`default_nettype wire
