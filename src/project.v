/*
 * Copyright (c) 2026 yeseojin
 * SPDX-License-Identifier: Apache-2.0
 *
 * tt_um_yeseojin_spi2neopixel_bridge
 * SPI / QSPI (mode 0, write only) to 8-channel NeoPixel bridge.
 *
 * Pin map
 *   ui_in[0]   SCK            uo_out[7:0]  NeoPixel ch0..ch7
 *   ui_in[1]   CS_n           uio[0]  in   IO1 (QSPI data)
 *   ui_in[2]   IO0 / MOSI     uio[1]  in   SEL[0]
 *   ui_in[3]   IO2            uio[2]  out  READY
 *   ui_in[4]   IO3            uio[3]  out  ERROR
 *   ui_in[7:5] CH[2:0]        uio[4]  in   SEL[1]
 *                             uio[7:5]     unused (input)
 *
 * SEL selects the clk frequency the design is told it runs at. It is a
 * static pin (not synchronized) and must only change while rst_n is low.
 */

`default_nettype none

module tt_um_yeseojin_spi2neopixel_bridge (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

  // ---------------------------------------------------------------------
  // Timing constants, clk cycles. Bit period 1.25 us (800 kHz), WS2812 /
  // WS2812B common window, TRESET 300 us. [calculated, engineer confirmed]
  //   SEL  clk      T0H  T1H  TBIT  TRESET
  //   00   40 MHz   12   36   50    12000
  //   01   32 MHz   10   28   40     9600
  //   10   20 MHz    6   18   25     6000
  //   11   16 MHz    5   14   20     4800
  // ---------------------------------------------------------------------
  localparam [5:0]  T0H_40  = 6'd12,  T1H_40  = 6'd36,  TBIT_40  = 6'd50;
  localparam [5:0]  T0H_32  = 6'd10,  T1H_32  = 6'd28,  TBIT_32  = 6'd40;
  localparam [5:0]  T0H_20  = 6'd6,   T1H_20  = 6'd18,  TBIT_20  = 6'd25;
  localparam [5:0]  T0H_16  = 6'd5,   T1H_16  = 6'd14,  TBIT_16  = 6'd20;
  localparam [13:0] TRST_40 = 14'd12000;
  localparam [13:0] TRST_32 = 14'd9600;
  localparam [13:0] TRST_20 = 14'd6000;
  localparam [13:0] TRST_16 = 14'd4800;

  // Pin decode
  wire       sck_in  = ui_in[0];
  wire       csn_in  = ui_in[1];
  wire [3:0] io_in   = {ui_in[4], ui_in[3], uio_in[0], ui_in[2]};  // IO3..IO0
  wire [2:0] ch_pins = ui_in[7:5];
  wire [1:0] sel     = {uio_in[4], uio_in[1]};

  // Timing selection
  reg [5:0]  t0h, t1h, tbit;
  reg [13:0] treset;
  always @(*) begin
    case (sel)
      2'b00:   begin t0h = T0H_40; t1h = T1H_40; tbit = TBIT_40; treset = TRST_40; end
      2'b01:   begin t0h = T0H_32; t1h = T1H_32; tbit = TBIT_32; treset = TRST_32; end
      2'b10:   begin t0h = T0H_20; t1h = T1H_20; tbit = TBIT_20; treset = TRST_20; end
      default: begin t0h = T0H_16; t1h = T1H_16; tbit = TBIT_16; treset = TRST_16; end
    endcase
  end

  // Interconnect
  wire        sck_rise, cs_fall, cs_rise, csn_s;
  wire [3:0]  io_s;
  wire        cmd_valid, byte_valid;
  wire [1:0]  cmd;
  wire [7:0]  byte_data;
  wire        wr_en;
  wire [2:0]  wr_idx;
  wire        burst_ok, burst_err, latch_req;
  wire [2:0]  ch_n;
  wire [63:0] hold_data;
  wire        hold_full, take, tx_idle;
  wire        frame_idle, accept, tx_en;
  wire        ready, error;
  wire [7:0]  dout;

  sync_in u_sync (
      .clk(clk), .rst_n(rst_n),
      .sck_in(sck_in), .csn_in(csn_in), .io_in(io_in),
      .sck_rise(sck_rise), .cs_fall(cs_fall), .cs_rise(cs_rise),
      .csn_s(csn_s), .io_s(io_s)
  );

  spi_rx u_rx (
      .clk(clk), .rst_n(rst_n),
      .sck_rise(sck_rise), .cs_fall(cs_fall), .csn_s(csn_s), .io_s(io_s),
      .cmd_valid(cmd_valid), .cmd(cmd),
      .byte_valid(byte_valid), .byte_data(byte_data)
  );

  burst_ctrl u_burst (
      .clk(clk), .rst_n(rst_n),
      .cs_fall(cs_fall), .cs_rise(cs_rise),
      .cmd_valid(cmd_valid), .cmd(cmd), .byte_valid(byte_valid),
      .ch_pins(ch_pins),
      .frame_idle(frame_idle), .accept(accept), .hold_full(hold_full),
      .wr_en(wr_en), .wr_idx(wr_idx),
      .burst_ok(burst_ok), .burst_err(burst_err), .latch_req(latch_req),
      .ch_n(ch_n)
  );

  hold_buf u_hold (
      .clk(clk), .rst_n(rst_n),
      .wr_en(wr_en), .wr_idx(wr_idx), .wr_data(byte_data),
      .commit(burst_ok), .take(take),
      .hold_data(hold_data), .hold_full(hold_full)
  );

  px_tx u_tx (
      .clk(clk), .rst_n(rst_n),
      .tx_en(tx_en), .hold_data(hold_data), .hold_full(hold_full),
      .ch_n(ch_n), .t0h(t0h), .t1h(t1h), .tbit(tbit),
      .take(take), .tx_idle(tx_idle), .dout(dout)
  );

  frame_ctrl u_frame (
      .clk(clk), .rst_n(rst_n),
      .csn_s(csn_s), .cs_rise(cs_rise),
      .burst_ok(burst_ok), .burst_err(burst_err), .latch_req(latch_req),
      .hold_full(hold_full), .tx_idle(tx_idle), .treset(treset),
      .frame_idle(frame_idle), .accept(accept), .tx_en(tx_en),
      .ready(ready), .error(error)
  );

  // Outputs
  assign uo_out  = dout;
  assign uio_out = {4'b0000, error, ready, 2'b00};
  assign uio_oe  = 8'b0000_1100;   // uio[3:2] outputs, others inputs

  // Unused inputs
  wire _unused = &{ena, uio_in[7:5], uio_in[3:2], 1'b0};

endmodule

`default_nettype wire
