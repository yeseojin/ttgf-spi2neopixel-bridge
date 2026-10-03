/*
 * sync_in.v
 * 2-FF synchronizers for the asynchronous SPI/QSPI slave inputs and
 * edge detection on SCK and CS_n.
 *
 * Assumptions
 *  - SCK <= clk/4, so every SCK high/low phase lasts at least 2 clk cycles
 *    and the data lines are stable while the synchronized SCK rising edge
 *    is detected.
 *  - SCK rising edges are reported regardless of CS_n; the consumer
 *    (spi_rx) must ignore them while CS_n is high. This also makes the
 *    reset value of the SCK synchronizer harmless for SPI mode 3
 *    (SCK idle high).
 *
 * DFF count: 6 inputs x 2 stages + 2 edge-detect stages = 14
 */

`default_nettype none

module sync_in (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       sck_in,     // ui_in[0]
    input  wire       csn_in,     // ui_in[1]
    input  wire [3:0] io_in,      // {IO3, IO2, IO1, IO0}
    output wire       sck_rise,   // one clk pulse per SCK rising edge
    output wire       cs_fall,    // one clk pulse when CS_n goes low
    output wire       cs_rise,    // one clk pulse when CS_n goes high
    output wire       csn_s,      // synchronized CS_n level
    output wire [3:0] io_s        // synchronized IO, aligned with sck_rise
);

  reg [1:0] sck_sync;
  reg [1:0] csn_sync;
  reg [3:0] io_sync0;
  reg [3:0] io_sync1;
  reg       sck_d;
  reg       csn_d;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sck_sync <= 2'b00;
      csn_sync <= 2'b11;   // CS_n inactive after reset
      io_sync0 <= 4'h0;
      io_sync1 <= 4'h0;
      sck_d    <= 1'b0;
      csn_d    <= 1'b1;
    end else begin
      sck_sync <= {sck_sync[0], sck_in};
      csn_sync <= {csn_sync[0], csn_in};
      io_sync0 <= io_in;
      io_sync1 <= io_sync0;
      sck_d    <= sck_sync[1];
      csn_d    <= csn_sync[1];
    end
  end

  assign sck_rise = sck_sync[1] & ~sck_d;
  assign cs_fall  = ~csn_sync[1] &  csn_d;
  assign cs_rise  =  csn_sync[1] & ~csn_d;
  assign csn_s    = csn_sync[1];
  assign io_s     = io_sync1;

endmodule

`default_nettype wire
