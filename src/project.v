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
 * with command 01h, the LED type per channel with command 31h (see
 * burst_ctrl). Errors are read with command 05h.
 *
 * Flip-flops: 243 register bits in the RTL (sum of the per-module DFF
 * counts). Synthesis re-encodes the spi_rx cmd and phase state machines
 * to one-hot, which gives 247 flip-flops.
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
  // Timing constants, clk cycles. Bit period 1.25 us (800 kHz) for both LED
  // types, TRESET 300 us. [calculated, engineer confirmed]
  //                     WS2812B      SK6812
  //   SEL  clk      TBIT  T0H  T1H   T0H  T1H   TRESET
  //   00   40 MHz    50    18   32    12   24    12000   (reset value)
  //   01   32 MHz    40    14   26    10   19     9600
  //   10   20 MHz    25     9   16     6   12     6000
  //   11   reserved, same as 20 MHz
  // WS2812B: 450 / 800 ns high. SK6812 (also WS2812B-V5): 300 / 600 ns.
  // ---------------------------------------------------------------------
  localparam [5:0]  TBIT_40 = 6'd50, TBIT_32 = 6'd40, TBIT_20 = 6'd25;
  localparam [5:0]  WS_T0H_40 = 6'd18, WS_T1H_40 = 6'd32;
  localparam [5:0]  WS_T0H_32 = 6'd14, WS_T1H_32 = 6'd26;
  localparam [5:0]  WS_T0H_20 = 6'd9,  WS_T1H_20 = 6'd16;
  localparam [5:0]  SK_T0H_40 = 6'd12, SK_T1H_40 = 6'd24;
  localparam [5:0]  SK_T0H_32 = 6'd10, SK_T1H_32 = 6'd19;
  localparam [5:0]  SK_T0H_20 = 6'd6,  SK_T1H_20 = 6'd12;
  localparam [13:0] TRST_40 = 14'd12000;
  localparam [13:0] TRST_32 = 14'd9600;
  localparam [13:0] TRST_20 = 14'd6000;

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
  wire [7:0] ch_type;
  wire [1:0] sel = cfg_sel;

  // Timing selection: low-time thresholds (TBIT - TH) per LED type
  reg [5:0]  t0l_ws, t1l_ws, t0l_sk, t1l_sk, tbit_m1;
  reg [13:0] treset;
  always @(*) begin
    case (sel)
      2'b00: begin
        tbit_m1 = TBIT_40 - 6'd1;
        t0l_ws = TBIT_40 - WS_T0H_40;  t1l_ws = TBIT_40 - WS_T1H_40;
        t0l_sk = TBIT_40 - SK_T0H_40;  t1l_sk = TBIT_40 - SK_T1H_40;
        treset = TRST_40;
      end
      2'b01: begin
        tbit_m1 = TBIT_32 - 6'd1;
        t0l_ws = TBIT_32 - WS_T0H_32;  t1l_ws = TBIT_32 - WS_T1H_32;
        t0l_sk = TBIT_32 - SK_T0H_32;  t1l_sk = TBIT_32 - SK_T1H_32;
        treset = TRST_32;
      end
      default: begin  // 10, 11
        tbit_m1 = TBIT_20 - 6'd1;
        t0l_ws = TBIT_20 - WS_T0H_20;  t1l_ws = TBIT_20 - WS_T1H_20;
        t0l_sk = TBIT_20 - SK_T0H_20;  t1l_sk = TBIT_20 - SK_T1H_20;
        treset = TRST_20;
      end
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
      .cfg_byte(byte_data),
      .frame_idle(frame_idle), .accept(accept), .hold_full(hold_full),
      .wr_en(wr_en), .wr_idx(wr_idx),
      .burst_ok(burst_ok), .latch_req(latch_req),
      .err_short(err_short), .err_long(err_long),
      .err_cmd(err_cmd), .err_rej(err_rej),
      .ch_n(ch_n), .cfg_sel(cfg_sel), .cfg_snoop(cfg_snoop), .ch_type(ch_type)
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
      .ch_n(ch_n), .ch_type(ch_type), .tbit_m1(tbit_m1),
      .t0l_ws(t0l_ws), .t1l_ws(t1l_ws), .t0l_sk(t0l_sk), .t1l_sk(t1l_sk),
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
