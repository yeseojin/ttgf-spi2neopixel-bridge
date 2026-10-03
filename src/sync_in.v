/*
 * sync_in.v
 * Input selection, 2-FF synchronizers and edge detection for the SPI /
 * QSPI receiver.
 *
 * Two input buses share one receiver:
 *  - MCU bus  : SCK, CS_n, IO0..IO3 (normal operation and all commands)
 *  - Pmod bus : PSRAM SCK and SD0..SD3, used while snoop mode is enabled
 *               and DWIN is high. CS_n is then taken as active (low).
 * The selection is done before the synchronizers. The MCU must keep the
 * MCU bus CS_n high while DWIN is high, and both SCK lines low when DWIN
 * changes (SPI mode 0 idle level).
 *
 * Assumptions
 *  - SCK <= clk/4 on both buses, so every SCK phase lasts >= 2 clk cycles.
 *  - SCK rising edges are reported regardless of CS_n; the consumer
 *    (spi_rx) ignores them while CS_n is high.
 *
 * DFF count: 7 inputs x 2 stages + 2 edge-detect stages = 16
 */

`default_nettype none

module sync_in (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       snoop_en,   // config register bit 5
    input  wire       dwin,       // ui_in[5], snoop data window
    input  wire       sck_mcu,    // ui_in[0]
    input  wire       csn_mcu,    // ui_in[1]
    input  wire [3:0] io_mcu,     // {IO3, IO2, IO1, IO0}
    input  wire       sck_pmod,   // uio[3]
    input  wire [3:0] io_pmod,    // {SD3, SD2, SD1, SD0}
    output wire       sck_rise,   // one clk pulse per SCK rising edge
    output wire       cs_fall,    // one clk pulse when CS_n goes low
    output wire       cs_rise,    // one clk pulse when CS_n goes high
    output wire       csn_s,      // synchronized CS_n level
    output wire       snoop_s,    // synchronized "Pmod bus selected"
    output wire [3:0] io_s        // synchronized IO, aligned with sck_rise
);

  // Bus selection (asynchronous, before the synchronizers)
  wire       sel    = snoop_en & dwin;
  wire       sck_in = sel ? sck_pmod : sck_mcu;
  wire       csn_in = csn_mcu & ~sel;
  wire [3:0] io_in  = sel ? io_pmod : io_mcu;

  reg [1:0] sck_sync;
  reg [1:0] csn_sync;
  reg [1:0] sel_sync;
  reg [3:0] io_sync0;
  reg [3:0] io_sync1;
  reg       sck_d;
  reg       csn_d;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sck_sync <= 2'b00;
      csn_sync <= 2'b11;   // CS_n inactive after reset
      sel_sync <= 2'b00;
      io_sync0 <= 4'h0;
      io_sync1 <= 4'h0;
      sck_d    <= 1'b0;
      csn_d    <= 1'b1;
    end else begin
      sck_sync <= {sck_sync[0], sck_in};
      csn_sync <= {csn_sync[0], csn_in};
      sel_sync <= {sel_sync[0], sel};
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
  assign snoop_s  = sel_sync[1];
  assign io_s     = io_sync1;

endmodule

`default_nettype wire
