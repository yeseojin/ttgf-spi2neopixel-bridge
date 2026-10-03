/*
 * Copyright (c) 2026 yeseojin
 * SPDX-License-Identifier: Apache-2.0
 *
 * tt_um_yeseojin_spi2neopixel_bridge
 * SPI / QSPI (mode 0) to 8-channel NeoPixel bridge, with status read and
 * an optional PSRAM snoop mode.
 *
 * Pin map
 *   ui_in[0]   SCK  (MCU bus)          uo_out[7:0]  NeoPixel ch0..ch7
 *   ui_in[1]   CS_n (MCU bus)          uio[0]  io   IO1 in / MISO out (05h)
 *   ui_in[2]   IO0 / MOSI              uio[1]  in   Pmod SD0 (snoop)
 *   ui_in[3]   IO2                     uio[2]  in   Pmod SD1 (snoop)
 *   ui_in[4]   IO3                     uio[3]  in   Pmod SCK (snoop)
 *   ui_in[5]   DWIN (snoop window)     uio[4]  in   Pmod SD2 (snoop)
 *   ui_in[7:6] unused                  uio[5]  in   Pmod SD3 (snoop)
 *                                      uio[6]  in   Pmod PSRAM CS (unused)
 *                                      uio[7]  out  READY
 *
 * CH, SEL and snoop enable are held in a configuration register written
 * with command 01h (see burst_ctrl). Errors are read with command 05h.
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
  // Derived for px_tx: low-time thresholds and TBIT - 1
  localparam [5:0]  T0L_40 = TBIT_40 - T0H_40, T1L_40 = TBIT_40 - T1H_40, TBM1_40 = TBIT_40 - 6'd1;
  localparam [5:0]  T0L_32 = TBIT_32 - T0H_32, T1L_32 = TBIT_32 - T1H_32, TBM1_32 = TBIT_32 - 6'd1;
  localparam [5:0]  T0L_20 = TBIT_20 - T0H_20, T1L_20 = TBIT_20 - T1H_20, TBM1_20 = TBIT_20 - 6'd1;
  localparam [5:0]  T0L_16 = TBIT_16 - T0H_16, T1L_16 = TBIT_16 - T1H_16, TBM1_16 = TBIT_16 - 6'd1;

  // Pin decode
  wire       sck_mcu  = ui_in[0];
  wire       csn_mcu  = ui_in[1];
  wire [3:0] io_mcu   = {ui_in[4], ui_in[3], uio_in[0], ui_in[2]};  // IO3..IO0
  wire       dwin     = ui_in[5];
  wire       sck_pmod = uio_in[3];
  wire [3:0] io_pmod  = {uio_in[5], uio_in[4], uio_in[2], uio_in[1]}; // SD3..SD0

  // Configuration register (in burst_ctrl)
  wire [2:0] ch_n;
  wire [1:0] cfg_sel;
  wire       cfg_snoop;
  wire [1:0] sel = cfg_sel;

  // Timing selection
  reg [5:0]  t0l, t1l, tbit_m1;
  reg [13:0] treset;
  always @(*) begin
    case (sel)
      2'b00:   begin t0l = T0L_40; t1l = T1L_40; tbit_m1 = TBM1_40; treset = TRST_40; end
      2'b01:   begin t0l = T0L_32; t1l = T1L_32; tbit_m1 = TBM1_32; treset = TRST_32; end
      2'b10:   begin t0l = T0L_20; t1l = T1L_20; tbit_m1 = TBM1_20; treset = TRST_20; end
      default: begin t0l = T0L_16; t1l = T1L_16; tbit_m1 = TBM1_16; treset = TRST_16; end
    endcase
  end

  // Interconnect
  wire        sck_rise, cs_fall, cs_rise, csn_s, snoop_s;
  wire [3:0]  io_s;
  wire        cmd_valid, byte_valid;
  wire [2:0]  cmd;
  wire [7:0]  byte_data;
  wire        miso, miso_oe;
  wire        wr_en;
  wire [2:0]  wr_idx;
  wire        burst_ok, latch_req;
  wire        err_short, err_long, err_cmd, err_rej;
  wire [63:0] hold_data;
  wire        hold_full, take, tx_idle;
  wire        frame_idle, accept, tx_en;
  wire        ready;
  wire [4:0]  flags;
  wire [1:0]  state;
  wire [7:0]  dout;

  // Status byte for 05h: ready, error flags, FSM state. Bit 7 is the
  // READY condition without the "no burst in progress" term, because the
  // status read itself is a burst (CS_n low) and would always read 0.
  wire        ready_core = accept & ~hold_full;
  wire [7:0]  status = {ready_core, flags, state};

  sync_in u_sync (
      .clk(clk), .rst_n(rst_n),
      .snoop_en(cfg_snoop), .dwin(dwin),
      .sck_mcu(sck_mcu), .csn_mcu(csn_mcu), .io_mcu(io_mcu),
      .sck_pmod(sck_pmod), .io_pmod(io_pmod),
      .sck_rise(sck_rise), .cs_fall(cs_fall), .cs_rise(cs_rise),
      .csn_s(csn_s), .snoop_s(snoop_s), .io_s(io_s)
  );

  spi_rx u_rx (
      .clk(clk), .rst_n(rst_n),
      .sck_rise(sck_rise), .cs_fall(cs_fall), .csn_s(csn_s),
      .snoop_s(snoop_s), .io_s(io_s), .status(status),
      .cmd_valid(cmd_valid), .cmd(cmd),
      .byte_valid(byte_valid), .byte_data(byte_data),
      .miso(miso), .miso_oe(miso_oe)
  );

  burst_ctrl u_burst (
      .clk(clk), .rst_n(rst_n),
      .cs_fall(cs_fall), .cs_rise(cs_rise),
      .cmd_valid(cmd_valid), .cmd(cmd), .byte_valid(byte_valid),
      .cfg_byte(byte_data[5:0]),
      .frame_idle(frame_idle), .accept(accept), .hold_full(hold_full),
      .wr_en(wr_en), .wr_idx(wr_idx),
      .burst_ok(burst_ok), .latch_req(latch_req),
      .err_short(err_short), .err_long(err_long),
      .err_cmd(err_cmd), .err_rej(err_rej),
      .ch_n(ch_n), .cfg_sel(cfg_sel), .cfg_snoop(cfg_snoop)
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
      .ch_n(ch_n), .t0l(t0l), .t1l(t1l), .tbit_m1(tbit_m1),
      .take(take), .tx_idle(tx_idle), .dout(dout)
  );

  frame_ctrl u_frame (
      .clk(clk), .rst_n(rst_n),
      .csn_s(csn_s), .cs_rise(cs_rise),
      .burst_ok(burst_ok),
      .err_short(err_short), .err_long(err_long),
      .err_cmd(err_cmd), .err_rej(err_rej),
      .latch_req(latch_req),
      .hold_full(hold_full), .tx_idle(tx_idle), .treset(treset),
      .frame_idle(frame_idle), .accept(accept), .tx_en(tx_en),
      .ready(ready), .flags(flags), .state(state)
  );

  // Outputs
  assign uo_out  = dout;
  assign uio_out = {ready, 6'b000000, miso};
  assign uio_oe  = {1'b1, 6'b000000, miso_oe};  // uio[7] READY, uio[0] MISO

  // Unused inputs
  wire _unused = &{ena, ui_in[7:6], uio_in[7:6], 1'b0};

endmodule

`default_nettype wire
