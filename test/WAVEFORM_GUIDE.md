# Waveform guide

How to run the cocotb tests in the dev container and what to expect in the waveforms. All expected values come
from the specification; the time stamps were measured from RTL simulation runs of each test on its own
(Icarus 12.0, cocotb 2.1.0). Gate level simulation gives the same test results and total simulation time.
There are 22 tests.

## 1. Running

All commands run in the **dev container terminal** (prompt `(venv) vscode ➜ /workspaces/spi2neopixel_bridge`).

| What | Command (in `test/`) |
|---|---|
| All 22 tests | `make` |
| One test | `make COCOTB_TEST_FILTER=test_02a_timing_40mhz` |
| One test, gate level | `make -B GATES=yes COCOTB_TEST_FILTER=test_02a_timing_40mhz` (needs `gate_level_netlist.v`, see README) |

- The waveform is written to `test/tb.fst`. Every run overwrites it, so run **one test at a time** when looking at
  waveforms. Time 0 is the start of that test.
- Open `tb.fst` in VS Code (Surfer extension, installed in the dev container) or in GTKWave.
- Use `rm -rf sim_build` if a run seems to use old sources.

## 2. Signals to add

| Signal | Meaning |
|---|---|
| `tb.clk`, `tb.rst_n` | clock, reset |
| `tb.ui_in[0]` | SCK (MCU bus) |
| `tb.ui_in[1]` | CS_N (MCU bus) |
| `tb.ui_in[2]`, `tb.uio_in[0]`, `tb.ui_in[3]`, `tb.ui_in[4]` | IO0, IO1, IO2, IO3 |
| `tb.ui_in[5]` | DWIN (snoop) |
| `tb.uio_in[3]` | Pmod SCK (snoop) |
| `tb.uio_in[1]`, `[2]`, `[4]`, `[5]` | Pmod SD0..SD3 (snoop) |
| `tb.uio_out[7]` | READY |
| `tb.uio_out[0]`, `tb.uio_oe[0]` | MISO and its output enable |
| `tb.uo_out[7:0]` | NeoPixel channels 0..7 |

Internal signals (RTL only, the gate level netlist renames them):

| Signal | Meaning |
|---|---|
| `tb.user_project.u_frame.state` | 0 IDLE, 1 STREAM, 2 DRAIN, 3 TRESET |
| `tb.user_project.u_frame.flags` | {short, long, cmd, rej, underrun} |
| `tb.user_project.u_burst.ch_n`, `cfg_sel`, `cfg_snoop` | configuration register |
| `tb.user_project.u_burst.ch_type` | LED type per channel (TYPE register), 1 = SK6812 |
| `tb.user_project.u_hold.hold_full` | buffer full |
| `tb.user_project.u_tx.cc`, `bit_end` | bit timer (counts down), last clock of a bit |

## 3. Values that hold in every test

| Item | 40 MHz | 32 MHz | 20 MHz |
|---|---|---|---|
| clk period | 25 ns | 31.25 ns | 50 ns |
| WS2812B T0H (0 bit high) | 450 ns (18 clk) | 437.5 ns (14 clk) | 450 ns (9 clk) |
| WS2812B T1H (1 bit high) | 800 ns (32 clk) | 812.5 ns (26 clk) | 800 ns (16 clk) |
| SK6812 T0H (0 bit high) | 300 ns (12 clk) | 312.5 ns (10 clk) | 300 ns (6 clk) |
| SK6812 T1H (1 bit high) | 600 ns (24 clk) | 593.75 ns (19 clk) | 600 ns (12 clk) |
| Bit period (both types) | 1250 ns (50 clk) | 1250 ns (40 clk) | 1250 ns (25 clk) |
| TRESET after LATCH | 300 us | 300 us | 300 us |

- All channels are WS2812B type unless a test sends TYPE (31h); only tests 17 and 18 do.
- WS2812B and SK6812 channels rise at the same time; only the falling edge differs.

- Bits are sent MSB first. A byte is 8 bits = 10 us.
- Channels above the configured count stay low.
- READY is low while CS_N is low and while the buffer is full; after LATCH it stays low until the line has been low
  for 300 us.
- SCK in the tests is clk/4 for writes and clk/8 for status reads.
- Every test except 01 and 14 starts with a CONFIG burst (01h), so the first CS_N low is at about 390 ns.

## 4. Per test

Times are from the start of the test, measured in RTL simulation [calculated].
"Bursts" counts every CS_N low period, including CONFIG and STATUS reads.

### test_01_reset_state

- Sent: nothing after reset, then one STATUS read (05h).
- Expect: READY = 1, `uo_out` = 0, `uio_oe` = 80h. During the status read `uio_oe[0]` = 1 and MISO shifts out
  **80h** (ready, IDLE, no errors).
- Times: status read CS_N low at 387.5 ns; test ends at 3.9 us.

### test_02a / 02b / 02c — timing per SEL (40 / 32 / 20 MHz)

- Sent: CONFIG 2 channels, two WRITE bursts, LATCH. ch0 = A5 0F, ch1 = 5A F0.
- Expect: high times and bit period from section 3. A5 = 1010 0101 → long, short, long, short, short, long, short,
  long.
- Times (40 MHz): first output 4.85 us, last output change 24.4 us, READY back 324.9 us.
  32 MHz: 6.06 / 25.63 / 326.1 us. 20 MHz: 9.70 / 29.25 / 329.8 us.

### test_02d_timing_sel_reserved

- Sent: same as 02c with SEL = 11 at 20 MHz.
- Expect: exactly the 20 MHz waveform of 02c (450 / 800 / 1250 ns). Times identical to 02c.

### test_03_write_1bit_channels

- Sent: for 1 to 8 channels, CONFIG then 3 WRITE bursts and LATCH; STATUS read after each frame.
- Data (ch0 / ch1 / ...):

| N | Data |
|---|---|
| 1 | 1C 2E 2B |
| 2 | 79 42 BD / F2 21 06 |
| 3 | 78 9B 34 / CA F5 4F / 2E 22 0A |
| 4 | 82 B7 0E / EE 7F 1A / 50 39 BE / F0 7E C2 |
| 5 | 29 F8 85 / 12 00 4A / F0 BF A3 / 0B 8B FA / 65 D3 30 |
| 6 | A5 4D CA / 18 25 30 / BB 1D 6D / 13 2C DE / D6 23 7B / 2E D9 1E |
| 7 | 74 BD C0 / 40 62 16 / 2B 46 7E / 6B CD 0F / EB F9 E8 / C7 FD 62 / CE 2D F8 |
| 8 | ED BF 88 / 46 5F 03 / AD ED 29 / AB 14 C2 / 56 E7 D8 / 50 56 79 / 1A 38 43 / 20 C4 34 |

- Expect: in frame N only channels 0..N-1 toggle; 24 bits per channel; each status read returns no error bits.
- Times: 49 bursts, first output 5.9 us, last output change 2418.8 us, test ends 2722.8 us. Frames are about
  300 us apart because of TRESET.

### test_04_write_quad

- Sent: WRITE_QUAD (32h) bursts; IO0..IO3 all toggle during data. Frames: 8 channels quad, 3 channels quad,
  5 channels mixed (1-bit, quad, 1-bit, quad, quad, 1-bit).
- Data: 8 ch: 16 3D 66 / C9 B1 94 / 4B 85 37 / 85 D2 A7 / 89 37 A6 / 9F 0B 67 / 24 67 3A / E9 C6 25.
  3 ch: 36 7E 8A / 82 95 25 / E6 9B EE.
  5 ch: B9 F0 F6 91 D5 74 / E4 02 D1 84 79 71 / 05 97 9A AB 48 9E / 0B 70 81 0A 4E 0E / ED E9 97 72 9E B9.
- Expect: each data byte takes 2 SCK edges in quad bursts, 8 edges in 1-bit bursts. Outputs as in test 03.
- Times: 22 bursts, first output 6.7 us, last output change 743.8 us.

### test_05_seamless

- Sent: 8 channels, 6 WRITE bursts back to back (1 clk gap after READY), LATCH.
- Data: 54 D6 D6 90 F5 6E / F3 5D 78 01 07 BD / DB 23 4A 76 77 15 / DF D0 E2 11 A8 FE /
  3B BC 0B 4F 2D 3F / 0A E8 52 AF CD F8 / 4D 5F 13 F0 78 26 / 65 6A 24 3E F3 C6.
- Expect: **no gap** between bytes: rising edges every 1250 ns for 48 bits on all 8 channels (60 us).
- Times: first output 9.65 us, last output change 69.2 us, READY back 369.7 us.

### test_06_latch_ready

- Sent: 1 channel, WRITE 81, WRITE 7E, LATCH.
- Expect: READY low right after LATCH, `state` 1 → 2 (DRAIN) → 3 (TRESET) → 0. READY rises at least
  TBIT + TRESET = 301.25 us after the start of the last bit.
- Times: first output 4.05 us, last output change 23.25 us, READY back 324.1 us.

### test_07_short_burst

- Sent: 2 channels. WRITE 11 21, WRITE EE (only 1 of 2 bytes), STATUS, WRITE 12 22, LATCH.
- Expect: EE never appears. ch0 = 11 12, ch1 = 21 22. Status: short flag (bit 6) set. The second byte follows
  the first without a gap, because the short burst and the status read finish within one byte time (10 us).
- Times: first output 4.85 us, READY back 324.9 us.

### test_08_long_burst

- Sent: 2 channels. WRITE 11 21, WRITE 12 22 EE (3 of 2 bytes), STATUS, LATCH.
- Expect: EE dropped. ch0 = 11 12, ch1 = 21 22. Status: long flag (bit 5) set.
- Times: first output 4.85 us, READY back 324.9 us.

### test_09_unknown_command

- Sent: 1 channel. Command 11h with a data byte (idle), STATUS, WRITE 33, command 11h, 4-bit incomplete command,
  STATUS, WRITE 44, LATCH.
- Expect: no output and READY stays high after the first 11h. Output 33 44. Status: cmd flag (bit 4) set both times.
- Times: 9 bursts, first output 9.58 us, READY back 329.6 us.

### test_10_rejected_write

- Sent: 1 channel. WRITE 11, WRITE 22, WRITE EE without waiting for READY (buffer full), STATUS, LATCH,
  WRITE DD during DRAIN / TRESET.
- Expect: output 11 22 only. Status: reject flag (bit 3) set.
- Times: first output 4.05 us, READY back 324.1 us.

### test_11_error_persist

- Sent: WRITE 11, command 11h, LATCH; two STATUS reads while idle; WRITE 22 (new frame), STATUS, LATCH.
- Expect: error flag still set after the first frame and while idle; **cleared** in the status read after the new
  frame starts. Output 11 (first frame) and 22 (second frame, starts about 350 us).
- Times: first output 4.05 us, last output change 357.2 us, READY back 658.0 us.

### test_12_underrun

- Sent: WRITE 11, then nothing for 3 byte times (30 us), STATUS, WRITE 22, no LATCH. After the timeout: CONFIG
  2 channels, WRITE 33 43, STATUS, LATCH.
- Expect: line low between 11 and 22 (underrun), underrun flag (bit 2) set. After 22 the line stays low and the
  design returns to IDLE after 300 us without LATCH. New frame: ch0 = 33, ch1 = 43, error flags cleared.
- Times: first output 4.05 us, last output change 378.3 us, READY back 678.8 us.

### test_13_config_in_frame

- Sent: 2 channels. WRITE 11 21, CONFIG 8 channels (during the frame), STATUS, WRITE 12 22, WRITE 13 23, LATCH,
  STATUS.
- Expect: CONFIG rejected (bit 3), `ch_n` stays 1. Output ch0 = 11 12 13, ch1 = 21 22 23, channels 2..7 low.
- Times: first output 4.85 us, READY back 338.4 us.

### test_14_config_register

- Sent: no CONFIG after reset (reset value 1 channel, 40 MHz): WRITE A5, LATCH. CONFIG with no data byte, STATUS,
  CONFIG with 2 bytes, STATUS, WRITE 3C, LATCH. CONFIG 2 channels, WRITE 5A C3, LATCH.
- Expect: A5 with 40 MHz timing. Short (bit 6) and long (bit 5) flags; configuration unchanged, so 3C is on
  channel 0 only. Last frame: ch0 = 5A, ch1 = C3.
- Times: first output 2.23 us, last output change 648.9 us, READY back 949.3 us.

### test_15_status_flags

- Sent: 2 channels. STATUS (idle), WRITE 11 21, STATUS, short burst, STATUS, long burst, STATUS, command 11h,
  STATUS, LATCH, STATUS, STATUS after READY, WRITE 31 41, wait 3 byte times, STATUS.
- Expect status values in order: 80h (idle), state 01 (STREAM) no errors, short bit, long bit, cmd bit,
  state 10 or 11 with READY bit 0, then IDLE with READY bit 1 and the three flags still set, finally only the
  underrun bit (04h plus state).
- Times: 15 bursts, first output 8.3 us, test ends 370.2 us.

### test_16_snoop

- Sent: CONFIG 3 channels with SNOOP = 1. Four snoop bursts: Pmod SCK and SD toggle first with DWIN low (4 nibbles
  of "command / address" noise), then DWIN high for 3 bytes (6 Pmod SCK edges), DWIN low. STATUS and LATCH on the
  MCU bus. Then a normal MCU bus frame with 2 bytes.
- Data, snoop frame: ch0 = 06 F0 39 C9, ch1 = 48 16 47 39, ch2 = 76 47 4B 10.
  MCU bus frame: ch0 = 27 6D, ch1 = 4A 9B, ch2 = 79 FE.
- Expect: activity on the Pmod bus while DWIN is low has no effect. CS_N (MCU bus) stays high while DWIN is high.
  No error bits.
- Times: first output 3.5 us, last output change 366.6 us, READY back 667.1 us.

### test_17_channel_type

- Sent: CONFIG 6 channels, TYPE 20h (channel 5 = SK6812, others WS2812B), four WRITE bursts of 6 bytes, LATCH.
  Then TYPE with no data byte, TYPE with 2 bytes, a WRITE burst, TYPE during the frame, LATCH.
- Data: ch0 = FF 00 00 00 (WS2812B green + 1 pad byte), ch5 = 00 FF 00 00 (SK6812RGBW red), ch1..4 = 00.
- Expect: ch0 high times 450 / 800 ns, ch5 300 / 600 ns, both with 1250 ns period and **identical rising edges**.
  Short (bit 6), long (bit 5) and reject (bit 3) flags for the wrong TYPE bursts; channel types unchanged
  afterwards.
- Times: 15 bursts, first output 9.9 us, last output change 376.0 us, READY back 676.4 us.

### test_18a / 18b — LED type per channel at 32 / 20 MHz

- Sent: CONFIG 2 channels, TYPE 02h (channel 1 = SK6812), WRITE A5 A5, LATCH.
- Expect: ch0 (WS2812B) 437.5 / 812.5 ns at 32 MHz, 450 / 800 ns at 20 MHz. ch1 (SK6812) 312.5 / 593.75 ns at
  32 MHz, 300 / 600 ns at 20 MHz. Same data on both channels, so the rising edges line up and only the falling
  edges differ.
- Times: 32 MHz first output 8.34 us, last output change 17.9 us, READY back 318.4 us.
  20 MHz: 13.35 / 22.9 / 323.4 us.
