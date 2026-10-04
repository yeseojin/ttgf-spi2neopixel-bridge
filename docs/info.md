<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

The design is an SPI / QSPI slave that turns bytes written by a microcontroller into WS2812B / SK6812 (NeoPixel)
waveforms on up to 8 channels in parallel. The LED type can be set per channel. The MCU only performs ordinary SPI
transfers; the bit timing of the LEDs is generated in hardware, so the MCU does not have to disable interrupts or use
timing-critical code.

### Data path

1. **sync_in** synchronizes SCK, CS_N and IO0..IO3 to the system clock (SPI mode 0, SCK <= clk/4).
2. **spi_rx** receives a command byte (always 1-bit on IO0) followed by data bytes, either 1-bit (IO0) or 4-bit
   (IO0..IO3, high nibble first, IO3 = bit 7 / bit 3).
3. **burst_ctrl** places byte *k* of a burst into channel *k* (byte interleave) and checks that a burst carries
   exactly N bytes, N = number of active channels.
4. **hold_buf** stores one byte per channel while the previous byte is being sent.
5. **px_tx** shifts the 8 channels out at the same time, MSB first, with one shared bit timer. Each channel uses
   the high times of its LED type. Consecutive bursts are sent without a gap.
6. **frame_ctrl** runs the frame state machine (IDLE, STREAM, DRAIN, TRESET), drives READY and keeps the error
   flags.

### Commands

The command byte is always sent 1-bit on IO0, MSB first. One burst is one CS_N low period.

| Code | Name       | Data                                                       |
|------|------------|------------------------------------------------------------|
| 01h  | CONFIG     | 1 byte, 1-bit, accepted only while idle                    |
| 31h  | TYPE       | 1 byte, 1-bit, accepted only while idle                    |
| 02h  | WRITE      | N bytes, 1-bit                                             |
| 32h  | WRITE_QUAD | N bytes, 4-bit, high nibble first                          |
| 05h  | STATUS     | 1 byte returned on MISO (uio[0]), SCK <= clk/8             |
| A5h  | LATCH      | none; ends the frame                                       |

### CONFIG byte

| Bits  | Field | Values                                                   | Reset         |
|-------|-------|----------------------------------------------------------|---------------|
| [2:0] | CH    | number of channels - 1 (0..7)                            | 0 (1 channel) |
| [4:3] | SEL   | 00 = 40 MHz, 01 = 32 MHz, 10 = 20 MHz, 11 = same as 20 MHz | 00 (40 MHz)  |
| [5]   | SNOOP | 1 = PSRAM snoop mode enabled                             | 0             |
| [7:6] | -     | write 0                                                  |               |

SEL tells the design which clock frequency is applied to `clk`, so that the LED timing is correct.

### TYPE byte

| Bit | Channel   | 0       | 1      | Reset |
|-----|-----------|---------|--------|-------|
| k   | channel k | WS2812B | SK6812 | 0     |

The reset value 00h sets all channels to WS2812B. CONFIG and TYPE keep their values until the next reset, so they
only have to be sent once after power-up or reset.

### STATUS byte

| Bit   | Meaning                                              |
|-------|------------------------------------------------------|
| 7     | ready: idle or streaming, and the buffer is empty    |
| 6     | short burst (fewer than N bytes, discarded)          |
| 5     | long burst (extra bytes dropped)                     |
| 4     | unknown or incomplete command                        |
| 3     | rejected WRITE, CONFIG or TYPE                       |
| 2     | underrun (next burst arrived too late)               |
| [1:0] | state: 00 IDLE, 01 STREAM, 10 DRAIN, 11 TRESET       |

Error bits stay set after the frame has ended and are cleared when the next frame starts.

### LED timing

The bit period is 1.25 us (800 kHz) for both LED types, so all channels share one bit timer and start every bit at
the same time. Only the high time depends on the LED type of the channel. After LATCH the outputs stay low for
300 us (reset / latch time).

| SEL | clk    | WS2812B T0H / T1H | SK6812 T0H / T1H     | Bit period |
|-----|--------|-------------------|----------------------|------------|
| 00  | 40 MHz | 450 / 800 ns      | 300 / 600 ns         | 1250 ns    |
| 01  | 32 MHz | 437.5 / 812.5 ns  | 312.5 / 593.75 ns    | 1250 ns    |
| 10  | 20 MHz | 450 / 800 ns      | 300 / 600 ns         | 1250 ns    |

WS2812B-V5 parts (T0H 220 ~ 380 ns) must be set to SK6812 type.

### Flow control and frame

- A WRITE burst is the command byte plus exactly N bytes: channel 0, channel 1, ... channel N-1. One burst gives
  each channel one byte (8 LED bits). RGB LEDs need 3 bursts per LED, RGBW LEDs (SK6812RGBW) need 4.
- READY (uio[7]) is low while a burst is in progress and while the buffer is full. After raising CS_N, wait until
  READY is high before sending the next burst.
- A WRITE sent while the buffer is full, or while the frame is ending (between LATCH and READY high), is rejected
  and does not overwrite data.
- If no new burst arrives in time, the line stays low (underrun). If this lasts 300 us the frame is treated as
  latched and the design returns to IDLE.
- LATCH (A5h) ends the frame: remaining data is sent, then the outputs stay low for 300 us. READY goes high again
  when the design is back in IDLE.

### PSRAM snoop mode

With SNOOP = 1 the design can take its data from a QSPI PSRAM read instead of the MCU bus. While DWIN (ui[5]) is
high, the receiver listens to the Pmod bus (SCK on uio[3], SD0..SD3 on uio[1], uio[2], uio[4], uio[5]). One DWIN
high period is one burst of exactly N bytes, with no command byte. Command, address and dummy cycles of the PSRAM
read are sent with DWIN low and are ignored. LATCH, CONFIG, TYPE and STATUS are still sent on the MCU bus.

## How to test

The design is tested with the Tiny Tapeout demoboard (RP2350B). The RP2350B provides the project clock and drives
the MCU bus on `ui_in` / `uio_in`.

1. Set the project clock to 40 MHz, 32 MHz or 20 MHz and reset the design.
2. Send CONFIG (01h) with the number of channels and the matching SEL value, and TYPE (31h) if any channel drives
   SK6812 LEDs. Without CONFIG and TYPE the design uses 1 channel at 40 MHz, WS2812B type.
3. For every LED position, send one WRITE (02h) or WRITE_QUAD (32h) burst per color byte, each with N bytes (one
   byte per channel), waiting for READY high between bursts. Send the color bytes in G, R, B order (G, R, B, W
   for RGBW).
4. Send LATCH (A5h) and wait for READY high.
5. Optionally read STATUS (05h) at SCK <= clk/8 to check that no error bit is set.

Example for 2 channels, one LED each, at 40 MHz:

```text
CS_N low, 01h 01h, CS_N high          CONFIG: CH = 1 (2 channels), SEL = 00
CS_N low, 02h G0 G1, CS_N high        green byte for channel 0 and channel 1
CS_N low, 02h R0 R1, CS_N high        red
CS_N low, 02h B0 B1, CS_N high        blue
CS_N low, A5h, CS_N high              LATCH
```

The NeoPixel outputs on `uo_out[7:0]` can be checked with an oscilloscope or logic analyzer. At 40 MHz a WS2812B
channel shows 450 ns high for a 0 bit and 800 ns for a 1 bit, an SK6812 channel 300 ns and 600 ns, both with a
bit period of 1.25 us.

Usage conditions:

- SCK <= clk/4 for writes, SCK <= clk/8 for STATUS reads.
- Keep the MCU bus CS_N high while DWIN is high (snoop mode).
- I/O voltage is 3.3 V.

Notes for the TT ETR demoboard:

- The MCU bus is on `ui_in` (driven by RP2350B GPIO17..24) instead of the recommended SPI pins on `uio`, because
  `uio` is kept free for the QSPI Pmod pinout used by the snoop mode.
- Set all input DIP switches to OFF; they are connected to `ui_in` and would interfere with the MCU bus.
- `uo_out[0..7]` also drive the 7-segment display through jumpers JP1..JP8 and 510 ohm resistors. The display
  does not affect the function, but it loads the NeoPixel outputs; the schematic notes that these jumpers allow the
  display to be disconnected.

## External hardware

- WS2812B or SK6812 / SK6812RGBW (NeoPixel) LED strips on `uo_out[0]` .. `uo_out[7]`, one strip per channel.
  WS2812B-V5 strips are driven with the SK6812 type.
- For snoop mode only: Tiny Tapeout QSPI Pmod on the bidirectional Pmod header, with jumper rows F (Flash CS) and
  B (PSRAM B CS) on J2 cut, so that only PSRAM A is used and uio[0] / uio[7] are free. Start a new PSRAM read for
  every burst so that the PSRAM CE# low time stays within its specification. Do not plug an unmodified QSPI Pmod.
