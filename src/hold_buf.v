/*
 * hold_buf.v
 * One-burst wait buffer: one byte per channel plus a full flag.
 *
 * burst_ctrl writes slot wr_idx while a WRITE burst is received and
 * marks the buffer full with commit (= burst_ok). px_tx copies all slots
 * into its shift registers at a byte boundary and clears the flag with
 * take. commit and take cannot occur together: burst_ctrl only accepts a
 * WRITE while the buffer is empty, and px_tx only takes a full buffer.
 *
 * Data registers have no reset (smaller cells); their content is only
 * used while hold_full is set, which is reset to 0.
 *
 * DFF count: 8 x 8 data + 1 flag = 65
 */

`default_nettype none

module hold_buf (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        wr_en,
    input  wire [2:0]  wr_idx,
    input  wire [7:0]  wr_data,
    input  wire        commit,
    input  wire        take,
    output wire [63:0] hold_data,  // slot k at [8k+7 : 8k]
    output reg         hold_full
);

  reg [7:0] slot [0:7];

  always @(posedge clk) begin
    if (wr_en)
      slot[wr_idx] <= wr_data;
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      hold_full <= 1'b0;
    else if (take)
      hold_full <= 1'b0;
    else if (commit)
      hold_full <= 1'b1;
  end

  assign hold_data = {slot[7], slot[6], slot[5], slot[4],
                      slot[3], slot[2], slot[1], slot[0]};

endmodule

`default_nettype wire
