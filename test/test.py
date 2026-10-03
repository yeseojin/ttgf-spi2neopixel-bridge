# SPDX-FileCopyrightText: © 2026 yeseojin
# SPDX-License-Identifier: Apache-2.0
#
# cocotb tests for tt_um_yeseojin_spi2neopixel_bridge.
# Test numbers follow the spec-to-test table in SESSION_STATE.md.
# All checks are numeric: NeoPixel pulses are measured in clk cycles by a
# monitor sampling uo_out on every rising clk edge.

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge

# ---------------------------------------------------------------------------
# Fixed values
# ---------------------------------------------------------------------------
# SEL -> (clk period ns, T0H, T1H, TBIT, TRESET) in clk cycles
# [calculated, engineer confirmed]
TIMING = {
    0: (25.0, 12, 36, 50, 12000),   # 40 MHz
    1: (31.25, 10, 28, 40, 9600),   # 32 MHz
    2: (50.0, 6, 18, 25, 6000),     # 20 MHz
    3: (62.5, 5, 14, 20, 4800),     # 16 MHz
}
SEL_DEFAULT = 0                     # 40 MHz for all tests except test 2
SCK_HALF_CLK = 2                    # SCK = clk/4, the maximum [engineer]
BURST_GAP_CLK = 1                   # minimum gap between bursts
OP_WRITE = 0x02                     # [engineer]
OP_WRITE_QUAD = 0x32                # [engineer]
OP_LATCH = 0xA5                     # [engineer]
SEED = 1                            # data pattern seed


# ---------------------------------------------------------------------------
# Pin driver
# ---------------------------------------------------------------------------
class Pins:
    """Holds the input pin state and writes it to ui_in / uio_in."""

    def __init__(self, dut):
        self.dut = dut
        self.sck = 0
        self.csn = 1
        self.io = [0, 0, 0, 0]       # IO0..IO3
        self.ch = 0                  # CH[2:0] = channels - 1
        self.sel = SEL_DEFAULT

    def apply(self):
        ui = (self.sck | (self.csn << 1) | (self.io[0] << 2) |
              (self.io[2] << 3) | (self.io[3] << 4) | ((self.ch & 7) << 5))
        uio = (self.io[1] | ((self.sel & 1) << 1) | (((self.sel >> 1) & 1) << 4))
        self.dut.ui_in.value = ui
        self.dut.uio_in.value = uio


def ready(dut):
    return (int(dut.uio_out.value) >> 2) & 1


def error(dut):
    return (int(dut.uio_out.value) >> 3) & 1


class Monitor:
    """Measures every NeoPixel pulse on uo_out[7:0] in clk cycles."""

    def __init__(self, dut):
        self.dut = dut
        self.cycle = 0
        self.level = [0] * 8
        self.rise = [0] * 8
        self.pulses = [[] for _ in range(8)]   # (rise cycle, high cycles)
        self.ready_rise = []                   # cycles where READY went high
        self.last_ready = 0

    def clear(self):
        self.pulses = [[] for _ in range(8)]
        self.ready_rise = []

    async def run(self):
        while True:
            await RisingEdge(self.dut.clk)
            self.cycle += 1
            out = int(self.dut.uo_out.value)
            for k in range(8):
                b = (out >> k) & 1
                if b and not self.level[k]:
                    self.rise[k] = self.cycle
                elif not b and self.level[k]:
                    self.pulses[k].append((self.rise[k], self.cycle - self.rise[k]))
                self.level[k] = b
            r = ready(self.dut)
            if r and not self.last_ready:
                self.ready_rise.append(self.cycle)
            self.last_ready = r

    def bits(self, k, sel):
        _, t0h, t1h, _, _ = TIMING[sel]
        out = []
        for _, h in self.pulses[k]:
            assert h in (t0h, t1h), f"ch{k}: high time {h} clk is neither T0H {t0h} nor T1H {t1h}"
            out.append(1 if h == t1h else 0)
        return out

    def bytes(self, k, sel):
        b = self.bits(k, sel)
        assert len(b) % 8 == 0, f"ch{k}: {len(b)} bits is not a whole number of bytes"
        return [int("".join(str(x) for x in b[i:i + 8]), 2) for i in range(0, len(b), 8)]

    def periods(self, k):
        r = [p[0] for p in self.pulses[k]]
        return [b - a for a, b in zip(r, r[1:])]


# ---------------------------------------------------------------------------
# SPI master (mode 0, MSB first)
# ---------------------------------------------------------------------------
async def half(dut):
    for _ in range(SCK_HALF_CLK):
        await FallingEdge(dut.clk)


async def send_bit(dut, pins, b):
    pins.io[0] = b
    pins.apply()
    await half(dut)
    pins.sck = 1
    pins.apply()
    await half(dut)
    pins.sck = 0
    pins.apply()


async def send_byte(dut, pins, v):
    for i in range(7, -1, -1):
        await send_bit(dut, pins, (v >> i) & 1)


async def send_byte_quad(dut, pins, v):
    for nib in ((v >> 4) & 0xF, v & 0xF):
        pins.io = [(nib >> j) & 1 for j in range(4)]
        pins.apply()
        await half(dut)
        pins.sck = 1
        pins.apply()
        await half(dut)
        pins.sck = 0
        pins.apply()


async def wait_ready(dut, limit=200000):
    for _ in range(limit):
        await FallingEdge(dut.clk)
        if ready(dut):
            return
    raise AssertionError("READY did not go high")


async def burst(dut, pins, cmd, data=(), quad=False, wait=True, bits=None):
    """One CS_n low period. bits: send only this many command bits."""
    if wait:
        await wait_ready(dut)
    await FallingEdge(dut.clk)
    pins.csn = 0
    pins.apply()
    await half(dut)
    if bits is None:
        await send_byte(dut, pins, cmd)
        for v in data:
            if quad:
                await send_byte_quad(dut, pins, v)
            else:
                await send_byte(dut, pins, v)
    else:
        for i in range(7, 7 - bits, -1):
            await send_bit(dut, pins, (cmd >> i) & 1)
    pins.io = [0, 0, 0, 0]
    await half(dut)
    pins.csn = 1
    pins.apply()
    for _ in range(BURST_GAP_CLK):
        await FallingEdge(dut.clk)


async def latch(dut, pins, wait=True):
    await burst(dut, pins, OP_LATCH, wait=wait)


async def send_frame(dut, pins, chans, quad=False):
    """chans[k] = list of bytes for channel k, all the same length."""
    n = len(chans)
    for j in range(len(chans[0])):
        q = quad if isinstance(quad, bool) else quad[j]
        await burst(dut, pins, OP_WRITE_QUAD if q else OP_WRITE,
                    [chans[k][j] for k in range(n)], quad=q)
    await latch(dut, pins)
    await wait_ready(dut)


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
async def setup(dut, sel=SEL_DEFAULT, ch=0):
    period = TIMING[sel][0]
    cocotb.start_soon(Clock(dut.clk, period, unit="ns").start())
    pins = Pins(dut)
    pins.sel = sel
    pins.ch = ch
    dut.ena.value = 1
    pins.apply()
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 5)
    mon = Monitor(dut)
    cocotb.start_soon(mon.run())
    return pins, mon


def pattern(n_ch, n_bytes, seed=SEED):
    rng = random.Random(seed)
    return [[rng.randrange(256) for _ in range(n_bytes)] for _ in range(n_ch)]


def check_frame(mon, chans, sel=SEL_DEFAULT):
    n = len(chans)
    for k in range(8):
        if k < n:
            got = mon.bytes(k, sel)
            assert got == chans[k], f"ch{k}: got {[hex(x) for x in got]}, sent {[hex(x) for x in chans[k]]}"
        else:
            assert mon.pulses[k] == [], f"ch{k} is inactive but has {len(mon.pulses[k])} pulses"


# ---------------------------------------------------------------------------
# 1. Reset state
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_01_reset_state(dut):
    pins, mon = await setup(dut)
    await FallingEdge(dut.clk)
    assert ready(dut) == 1, "READY must be 1 after reset"
    assert error(dut) == 0, "ERROR must be 0 after reset"
    assert int(dut.uo_out.value) == 0, "uo_out must be 0 after reset"
    assert int(dut.uio_oe.value) == 0x0C, f"uio_oe = {int(dut.uio_oe.value):#04x}, expected 0x0c"


# ---------------------------------------------------------------------------
# 2. Timing per SEL
# ---------------------------------------------------------------------------
async def timing_for_sel(dut, sel):
    pins, mon = await setup(dut, sel=sel, ch=1)
    _, t0h, t1h, tbit, _ = TIMING[sel]
    chans = [[0xA5, 0x0F], [0x5A, 0xF0]]
    await send_frame(dut, pins, chans)
    check_frame(mon, chans, sel)
    for k in range(2):
        highs = sorted(set(h for _, h in mon.pulses[k]))
        assert highs == [t0h, t1h], f"SEL {sel} ch{k}: high times {highs}, expected {[t0h, t1h]}"
        per = set(mon.periods(k))
        assert per == {tbit}, f"SEL {sel} ch{k}: periods {per}, expected {{{tbit}}}"
    dut._log.info(f"SEL {sel}: T0H {t0h} T1H {t1h} TBIT {tbit} clk = "
                  f"{t0h * TIMING[sel][0]:.1f} / {t1h * TIMING[sel][0]:.1f} / {tbit * TIMING[sel][0]:.1f} ns")


@cocotb.test()
async def test_02a_timing_40mhz(dut):
    await timing_for_sel(dut, 0)


@cocotb.test()
async def test_02b_timing_32mhz(dut):
    await timing_for_sel(dut, 1)


@cocotb.test()
async def test_02c_timing_20mhz(dut):
    await timing_for_sel(dut, 2)


@cocotb.test()
async def test_02d_timing_16mhz(dut):
    await timing_for_sel(dut, 3)


# ---------------------------------------------------------------------------
# 3. 1-bit write, 1 to 8 channels
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_03_write_1bit_channels(dut):
    pins, mon = await setup(dut)
    for n in range(1, 9):
        pins.ch = n - 1
        pins.apply()
        mon.clear()
        chans = pattern(n, 3, seed=SEED + n)
        await send_frame(dut, pins, chans)
        check_frame(mon, chans)
        assert error(dut) == 0, f"{n} ch: ERROR set"


# ---------------------------------------------------------------------------
# 4. Quad write, and 1-bit / quad mixed in one frame
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_04_write_quad(dut):
    pins, mon = await setup(dut)
    for n, quad in ((8, True), (3, True), (5, [False, True, False, True, True, False])):
        pins.ch = n - 1
        pins.apply()
        mon.clear()
        n_bytes = 3 if isinstance(quad, bool) else len(quad)
        chans = pattern(n, n_bytes, seed=SEED + 10 + n)
        await send_frame(dut, pins, chans, quad=quad)
        check_frame(mon, chans)
        assert error(dut) == 0, f"{n} ch quad={quad}: ERROR set"


# ---------------------------------------------------------------------------
# 5. Consecutive bursts without a gap
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_05_seamless(dut):
    pins, mon = await setup(dut, ch=7)
    tbit = TIMING[SEL_DEFAULT][3]
    chans = pattern(8, 6, seed=SEED + 20)
    await send_frame(dut, pins, chans)
    check_frame(mon, chans)
    for k in range(8):
        per = set(mon.periods(k))
        assert per == {tbit}, f"ch{k}: periods {per}, expected {{{tbit}}} (gap between bursts)"


# ---------------------------------------------------------------------------
# 6. LATCH, TRESET and READY
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_06_latch_ready(dut):
    pins, mon = await setup(dut, ch=0)
    _, _, _, tbit, treset = TIMING[SEL_DEFAULT]
    chans = [[0x81, 0x7E]]
    for j in range(2):
        await burst(dut, pins, OP_WRITE, [chans[0][j]])
    mon.ready_rise = []
    await latch(dut, pins)
    await FallingEdge(dut.clk)
    assert ready(dut) == 0, "READY must be low right after LATCH"
    await wait_ready(dut)
    await ClockCycles(dut.clk, 2)          # let the monitor record the READY edge
    check_frame(mon, chans)
    last_rise = mon.pulses[0][-1][0]
    r = mon.ready_rise[-1]
    low = r - last_rise
    assert low >= tbit + treset, f"READY came back {low} clk after the last bit start, expected >= {tbit + treset}"
    assert int(dut.uo_out.value) == 0, "line must be low after TRESET"
    dut._log.info(f"READY back {low} clk after last bit start (TBIT {tbit} + TRESET {treset})")


# ---------------------------------------------------------------------------
# 7. Short burst
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_07_short_burst(dut):
    pins, mon = await setup(dut, ch=1)
    await burst(dut, pins, OP_WRITE, [0x11, 0x21])
    await burst(dut, pins, OP_WRITE, [0xEE])                 # short: 1 of 2
    await ClockCycles(dut.clk, 10)
    assert error(dut) == 1, "short burst must set ERROR"
    await burst(dut, pins, OP_WRITE, [0x12, 0x22])
    await latch(dut, pins)
    await wait_ready(dut)
    check_frame(mon, [[0x11, 0x12], [0x21, 0x22]])


# ---------------------------------------------------------------------------
# 8. Long burst
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_08_long_burst(dut):
    pins, mon = await setup(dut, ch=1)
    await burst(dut, pins, OP_WRITE, [0x11, 0x21])
    await burst(dut, pins, OP_WRITE, [0x12, 0x22, 0xEE])     # long: 3 of 2
    await ClockCycles(dut.clk, 10)
    assert error(dut) == 1, "long burst must set ERROR"
    await latch(dut, pins)
    await wait_ready(dut)
    check_frame(mon, [[0x11, 0x12], [0x21, 0x22]])


# ---------------------------------------------------------------------------
# 9. Unknown and incomplete command
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_09_unknown_command(dut):
    pins, mon = await setup(dut, ch=0)
    await burst(dut, pins, 0x11, [0xEE])                     # unknown, in IDLE
    await ClockCycles(dut.clk, 10)
    assert error(dut) == 1, "unknown command must set ERROR"
    assert ready(dut) == 1, "unknown command must not start a frame"
    assert mon.pulses[0] == [], "unknown command must not produce output"
    await burst(dut, pins, OP_WRITE, [0x33])                 # frame starts, ERROR cleared
    await burst(dut, pins, 0x11, [0xEE])                     # unknown, in frame
    await burst(dut, pins, OP_WRITE, bits=4)                 # incomplete command
    await ClockCycles(dut.clk, 10)
    assert error(dut) == 1, "unknown / incomplete command in a frame must set ERROR"
    await burst(dut, pins, OP_WRITE, [0x44])
    await latch(dut, pins)
    await wait_ready(dut)
    check_frame(mon, [[0x33, 0x44]])


# ---------------------------------------------------------------------------
# 10. WRITE that ignores READY
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_10_rejected_write(dut):
    pins, mon = await setup(dut, ch=0)
    await burst(dut, pins, OP_WRITE, [0x11])                 # taken at once
    await burst(dut, pins, OP_WRITE, [0x22])                 # waits in hold_buf
    await burst(dut, pins, OP_WRITE, [0xEE], wait=False)     # hold_buf full
    await ClockCycles(dut.clk, 10)
    assert error(dut) == 1, "WRITE into a full hold_buf must set ERROR"
    await latch(dut, pins)
    await burst(dut, pins, OP_WRITE, [0xDD], wait=False)     # during DRAIN / TRESET
    await wait_ready(dut)
    check_frame(mon, [[0x11, 0x22]])


# ---------------------------------------------------------------------------
# 11. ERROR stays after the frame and clears at the next frame start
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_11_error_persist(dut):
    pins, mon = await setup(dut, ch=0)
    await burst(dut, pins, OP_WRITE, [0x11])
    await burst(dut, pins, 0x11)                             # unknown -> ERROR
    await latch(dut, pins)
    await wait_ready(dut)
    assert error(dut) == 1, "ERROR must stay set after the frame ends"
    await ClockCycles(dut.clk, 1000)
    assert error(dut) == 1, "ERROR must stay set while idle"
    await burst(dut, pins, OP_WRITE, [0x22])                 # next frame starts
    await ClockCycles(dut.clk, 10)
    assert error(dut) == 0, "ERROR must clear at the next frame start"
    await latch(dut, pins)
    await wait_ready(dut)
    check_frame(mon, [[0x11, 0x22]])


# ---------------------------------------------------------------------------
# 12. Underrun
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_12_underrun(dut):
    pins, mon = await setup(dut, ch=0)
    _, _, _, tbit, treset = TIMING[SEL_DEFAULT]
    await burst(dut, pins, OP_WRITE, [0x11])
    await ClockCycles(dut.clk, 3 * 8 * tbit)                 # 3 byte times, no data
    assert error(dut) == 1, "underrun must set ERROR"
    await burst(dut, pins, OP_WRITE, [0x22])                 # resumes within TRESET
    await ClockCycles(dut.clk, treset + 20 * tbit)           # no LATCH, timeout
    await FallingEdge(dut.clk)
    assert ready(dut) == 1, "after the underrun timeout READY must be high"
    assert mon.bytes(0, SEL_DEFAULT) == [0x11, 0x22]
    # back in IDLE: a new frame with 2 channels must be accepted and clear ERROR
    pins.ch = 1
    pins.apply()
    mon.clear()
    await burst(dut, pins, OP_WRITE, [0x33, 0x43])
    await ClockCycles(dut.clk, 10)
    assert error(dut) == 0, "new frame after the timeout must clear ERROR"
    await latch(dut, pins)
    await wait_ready(dut)
    check_frame(mon, [[0x33], [0x43]])


# ---------------------------------------------------------------------------
# 13. CH pins are held for the whole frame
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_13_ch_latched(dut):
    pins, mon = await setup(dut, ch=1)
    await burst(dut, pins, OP_WRITE, [0x11, 0x21])
    pins.ch = 7                                              # change mid frame
    pins.apply()
    await burst(dut, pins, OP_WRITE, [0x12, 0x22])
    await burst(dut, pins, OP_WRITE, [0x13, 0x23])
    await latch(dut, pins)
    await wait_ready(dut)
    assert error(dut) == 0, "2-byte bursts must still be valid after a CH change"
    check_frame(mon, [[0x11, 0x12, 0x13], [0x21, 0x22, 0x23]])
