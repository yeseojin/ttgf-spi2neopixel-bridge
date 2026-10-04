/*
 * burst_ctrl.v
 * Burst handling between spi_rx and hold_buf, and the configuration
 * register.
 *
 * WRITE / WRITE_QUAD burst = command (or snoop window) + exactly N data
 * bytes, N = ch_n + 1. Data byte k of a burst is written to hold_buf slot
 * k (byte interleave: ch0, ch1, ... ch(N-1)).
 *
 * CONFIG burst = 01h + exactly 1 byte, accepted only while the frame is
 * idle. Byte fields: [2:0] CH, [4:3] SEL, [5] snoop enable, [7:6] unused.
 *
 * TYPE burst = 31h + exactly 1 byte, same rules as CONFIG. Bit k selects
 * the LED type of channel k: 0 = WS2812B, 1 = SK6812.
 *
 * Burst outcome, evaluated at CS_n rising edge
 *   WRITE accepted, N bytes          -> burst_ok
 *   WRITE accepted, more than N      -> burst_ok + err_long (extra dropped)
 *   WRITE accepted, fewer than N     -> err_short (nothing committed)
 *   WRITE not accepted               -> err_rej (hold_buf full, or frame
 *                                       in DRAIN/TRESET)
 *   CONFIG / TYPE in IDLE, 1 byte    -> register updated
 *   CONFIG / TYPE in IDLE, 0 / >1    -> err_short / err_long, not updated
 *   CONFIG / TYPE outside IDLE       -> err_rej, not updated
 *   LATCH                            -> latch_req
 *   STATUS                           -> nothing (handled by spi_rx)
 *   unknown or incomplete command    -> err_cmd
 *
 * A rejected WRITE never touches hold_buf, so data waiting for px_tx is
 * never overwritten. Slots written by a short burst are harmless because
 * hold_buf is only marked full by burst_ok.
 *
 * Reset values: CH = 0 (1 channel), SEL = 0 (40 MHz), snoop off,
 * all channels WS2812B [engineer].
 *
 * DFF count: idx 3 + flags 6 + config 6 + type 8 + temp 8 + pulses 6 = 37
 */

`default_nettype none

module burst_ctrl (
    input  wire       clk,
    input  wire       rst_n,
    // from sync_in
    input  wire       cs_fall,
    input  wire       cs_rise,
    // from spi_rx
    input  wire       cmd_valid,
    input  wire [2:0] cmd,
    input  wire       byte_valid,
    input  wire [7:0] cfg_byte,     // byte_data, for CONFIG / TYPE
    // from frame_ctrl / hold_buf
    input  wire       frame_idle,   // FSM in IDLE
    input  wire       accept,       // FSM in IDLE or STREAM
    input  wire       hold_full,
    // to hold_buf
    output wire       wr_en,
    output wire [2:0] wr_idx,
    // to frame_ctrl / hold_buf
    output reg        burst_ok,     // one clk pulse, also commits hold_buf
    output reg        latch_req,    // one clk pulse
    output reg        err_short,    // one clk pulse each
    output reg        err_long,
    output reg        err_cmd,
    output reg        err_rej,
    // configuration register
    output reg  [2:0] ch_n,         // active channels - 1
    output reg  [1:0] cfg_sel,      // clock frequency select
    output reg        cfg_snoop,    // snoop mode enable
    output reg  [7:0] ch_type       // LED type per channel, 1 = SK6812
);

  // Decoded command values (must match spi_rx). CMD_UNKNOWN = 3'd0 and
  // CMD_STATUS = 3'd5 need no action here.
  localparam [2:0] CMD_WRITE      = 3'd1;
  localparam [2:0] CMD_WRITE_QUAD = 3'd2;
  localparam [2:0] CMD_LATCH      = 3'd3;
  localparam [2:0] CMD_CONFIG     = 3'd4;
  localparam [2:0] CMD_STATUS     = 3'd5;
  localparam [2:0] CMD_TYPE       = 3'd6;

  // Reset values of the configuration register [engineer]
  localparam [2:0] CH_RESET  = 3'd0;    // 1 channel
  localparam [1:0] SEL_RESET = 2'd0;    // 40 MHz

  reg [2:0] idx;        // next slot to write
  reg       cmd_seen;   // a full command byte (or snoop start) in this burst
  reg       active;     // accepted WRITE burst in progress
  reg       cfg_active; // accepted CONFIG or TYPE burst in progress
  reg       cfg_kind;   // 0 = CONFIG, 1 = TYPE
  reg       got_all;    // all expected bytes received
  reg       too_long;   // more bytes than expected
  reg [7:0] cfg_tmp;    // received CONFIG / TYPE byte

  wire       is_write = (cmd == CMD_WRITE) || (cmd == CMD_WRITE_QUAD);
  wire [2:0] last_idx = cfg_active ? 3'd0 : ch_n;   // index of last byte

  assign wr_en  = byte_valid & active & ~got_all;
  assign wr_idx = idx;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      idx        <= 3'd0;
      cmd_seen   <= 1'b0;
      active     <= 1'b0;
      cfg_active <= 1'b0;
      cfg_kind   <= 1'b0;
      got_all    <= 1'b0;
      too_long   <= 1'b0;
      cfg_tmp    <= 8'd0;
      ch_type    <= 8'd0;
      ch_n       <= CH_RESET;
      cfg_sel    <= SEL_RESET;
      cfg_snoop  <= 1'b0;
      burst_ok   <= 1'b0;
      latch_req  <= 1'b0;
      err_short  <= 1'b0;
      err_long   <= 1'b0;
      err_cmd    <= 1'b0;
      err_rej    <= 1'b0;
    end else begin
      burst_ok  <= 1'b0;
      latch_req <= 1'b0;
      err_short <= 1'b0;
      err_long  <= 1'b0;
      err_cmd   <= 1'b0;
      err_rej   <= 1'b0;

      if (cs_fall) begin
        idx        <= 3'd0;
        cmd_seen   <= 1'b0;
        active     <= 1'b0;
        cfg_active <= 1'b0;
        got_all    <= 1'b0;
        too_long   <= 1'b0;
      end else if (cs_rise) begin
        if (!cmd_seen) begin
          err_cmd <= 1'b1;                          // incomplete command
        end else if (active) begin
          if (got_all) begin
            burst_ok <= 1'b1;
            err_long <= too_long;
          end else begin
            err_short <= 1'b1;
          end
        end else if (cfg_active) begin
          if (!got_all) begin
            err_short <= 1'b1;
          end else if (too_long) begin
            err_long <= 1'b1;
          end else if (cfg_kind) begin
            ch_type   <= cfg_tmp;
          end else begin
            ch_n      <= cfg_tmp[2:0];
            cfg_sel   <= cfg_tmp[4:3];
            cfg_snoop <= cfg_tmp[5];
          end
        end
        active     <= 1'b0;
        cfg_active <= 1'b0;
      end else begin
        if (cmd_valid) begin
          cmd_seen <= 1'b1;
          if (is_write) begin
            if (accept && !hold_full)
              active <= 1'b1;
            else
              err_rej <= 1'b1;                      // rejected WRITE
          end else if (cmd == CMD_CONFIG || cmd == CMD_TYPE) begin
            cfg_kind <= (cmd == CMD_TYPE);
            if (frame_idle)
              cfg_active <= 1'b1;
            else
              err_rej <= 1'b1;                      // CONFIG / TYPE outside IDLE
          end else if (cmd == CMD_LATCH) begin
            latch_req <= 1'b1;
          end else if (cmd != CMD_STATUS) begin
            err_cmd <= 1'b1;                        // unknown command
          end
        end

        if (byte_valid && (active || cfg_active)) begin
          if (cfg_active && !got_all)
            cfg_tmp <= cfg_byte;
          if (got_all) begin
            too_long <= 1'b1;
          end else if (idx == last_idx) begin
            got_all <= 1'b1;
          end else begin
            idx <= idx + 3'd1;
          end
        end
      end
    end
  end

endmodule

`default_nettype wire
