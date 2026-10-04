![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg) ![](../../workflows/fpga/badge.svg)

# SPI to NeoPixel Bridge

An SPI / QSPI slave for Tiny Tapeout (GF180MCU) that converts bytes written by a microcontroller into WS2812B / SK6812
(NeoPixel) waveforms on up to 8 channels in parallel. The LED bit timing is generated in hardware, so the MCU only
performs ordinary SPI transfers and does not need interrupt-free, timing-critical code.

- [Datasheet / project documentation](docs/info.md)

## Features

- SPI mode 0 slave, 1-bit (02h) and quad (32h) writes
- 1 to 8 NeoPixel channels, byte interleaved, sent in parallel without gaps between bursts
- LED type per channel: WS2812B (450 / 800 ns high) or SK6812 / SK6812RGBW / WS2812B-V5 (300 / 600 ns high),
  common bit period 1.25 us (800 kHz)
- RGB and RGBW LEDs (3 or 4 bytes per LED, chosen by the MCU)
- System clock 40, 32 or 20 MHz, selected by a configuration command (reset value 40 MHz)
- READY output for flow control, LATCH command with 300 us reset time
- Status read (05h) with error flags: short / long burst, unknown command, rejected write, underrun
- Optional PSRAM snoop mode: LED data is taken directly from a QSPI PSRAM read on the Pmod bus

## Pinout

| Pin       | Function                                      |
|-----------|-----------------------------------------------|
| ui[0]     | SCK                                           |
| ui[1]     | CS_N                                          |
| ui[2]     | IO0 / MOSI                                    |
| ui[3]     | IO2                                           |
| ui[4]     | IO3                                           |
| ui[5]     | DWIN (snoop data window)                      |
| uio[0]    | IO1 (quad write) / MISO (status read)         |
| uio[1..5] | Pmod SD0, SD1, SCK (uio[3]), SD2, SD3 (snoop) |
| uio[7]    | READY                                         |
| uo[0..7]  | NeoPixel channel 0..7                         |

I/O voltage is 3.3 V.

## Commands

| Code | Name       | Data                                   |
|------|------------|----------------------------------------|
| 01h  | CONFIG     | 1 byte: CH (channels - 1), SEL, SNOOP  |
| 31h  | TYPE       | 1 byte: bit k = 1 for SK6812 on ch k   |
| 02h  | WRITE      | N bytes, 1-bit                         |
| 32h  | WRITE_QUAD | N bytes, 4-bit, high nibble first      |
| 05h  | STATUS     | 1 byte on MISO, SCK <= clk/8           |
| A5h  | LATCH      | ends the frame                         |

See [docs/info.md](docs/info.md) for the full register, status and timing description.

## Repository layout

| Path                     | Content                                         |
|--------------------------|-------------------------------------------------|
| `src/`                   | Verilog RTL (top level in `project.v`)          |
| `test/`                  | cocotb testbench (22 tests)                     |
| `docs/info.md`           | Datasheet text                                  |
| `docs/block_diagram.drawio` | RTL block diagram (draw.io)                  |
| `docs/timing_basic.json` | WaveDrom timing diagram, basic mode             |
| `docs/timing_snoop.json` | WaveDrom timing diagram, PSRAM snoop mode       |
| `.devcontainer/`         | Development container (LibreLane 3.0.14, GF180MCU PDK) |

## Running the tests

Open the repository in the dev container (VS Code: *Dev Containers: Reopen in Container*), then:

```sh
cd test
make
```

Gate level simulation after hardening:

```sh
./tt/tt_tool.py --harden --gf
cd test
TOP_MODULE=$(cd .. && ./tt/tt_tool.py --print-top-module --gf)
cp ../runs/wokwi/final/pnl/$TOP_MODULE.pnl.v gate_level_netlist.v
make -B GATES=yes
```

## What is Tiny Tapeout?

Tiny Tapeout is an educational project that makes it easier and cheaper than ever to get your digital and analog
designs manufactured on a real chip. To learn more and get started, visit https://tinytapeout.com.

- [FAQ](https://tinytapeout.com/faq/)
- [Local hardening guide](https://www.tinytapeout.com/guides/local-hardening/)
- [Join the community](https://tinytapeout.com/discord)
