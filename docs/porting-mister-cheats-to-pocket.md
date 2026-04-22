# Porting MiSTer-style Game Genie cheats to a Pocket openFPGA core

Notes collected while grafting the MiSTer NES `CODES` module onto the
Analogue Pocket NES core. Written for a future agent doing the same thing
for another Pocket core (GB, Genesis, SNES, PCE, etc.). The specifics are
NES-flavored but the bulk of the advice carries over; the items marked
**important** cost me hours of real-hardware debug that static inspection
wouldn't have caught.

## Scope

End result we shipped:
- User drops a `.gg` / `.cht` text file onto the SD card.
- Picks it from the core's Core Settings menu.
- Toggles a checkbox to activate.
- Cheats apply on the fly, no ROM modification.

File format is the text-Game-Genie list used by both MiSTer (`*.gg`) and
RetroArch cheat packs, so existing corpora work unchanged.

## Architecture

Three pieces:

1. **Code-storage + address/data comparator**, taken verbatim from the
   upstream MiSTer core (`rtl/cheatcodes.sv` in NES at the 1.0.1 layout;
   in cores that have split static RTL into a subdir it lives at
   `rtl/upstream/cheatcodes.sv`). It has a small RAM of N codes and an
   `always_comb` that produces `genie_ovr` / `genie_data` the cycle the
   CPU address matches a stored cheat.
2. **Parser** (new, `rtl/cheat_loader.sv`). An FSM that streams ASCII
   bytes off the openFPGA ioctl bus, recognizes 6- or 8-letter Game Genie
   codes, decodes them with the FCEUX `FCEUI_DecodeGG` algorithm, and
   emits 129-bit messages into the storage module (128 bits of code +
   1 bit strobe).
3. **Glue** in `rtl/nes_top.sv` + `target/pocket/core_top.v` that wires
   a new openFPGA data slot, a user-facing on/off toggle, and pipes
   `genie_ovr` into the CPU's data bus mux.

In most MiSTer cores, (1) is already present and unused. You just light it up.

## Wiring the CPU data path

The Game Genie is a single 2:1 mux on the CPU's incoming data byte:

```verilog
assign from_data_bus = genie_ovr ? genie_data : external_data_bus;
```

`external_data_bus` is whatever the core normally feeds the CPU (cart ROM,
PPU, APU registers, etc.). When a cheat matches, the CPU sees the patched
byte instead.

Comparator inputs:
- `addr_in` — the CPU's current memory address. On NES this is 16 bits.
- `data_in` — the *original* byte being read (for 8-letter compare codes
  that only fire when the underlying byte equals the expected value).

When the CPU reads from ROM, `data_in` has to be the ROM byte, not the
genie-patched byte — otherwise 8-letter codes never self-confirm. The NES
core handles this because `data_in` is wired to the SDRAM/mapper read
result, not to `from_data_bus`.

## openFPGA wiring

### data.json

New data slot for the cheat file:

```json
{
  "name": "Cheats",
  "id": 12,
  "required": false,
  "parameters": "0x3",
  "extensions": ["gg", "cht"],
  "size_maximum": "0x2000",
  "address": "0x10000000"
}
```

`0x2000` (8 KiB) is plenty. `address` is the same bridge RAM region the
cart uses — the slot id is what distinguishes the stream downstream.

### core_top.v

Gate the ioctl byte stream on the cheat slot id:

```verilog
wire cheat_download = is_downloading && dataslot_requestwrite_id == 12;
```

Register a `cheats_enabled` flag at a free APF address, synch it across
clock domains with the existing `synch_3` helper, then pipe both
`cheat_download` and `cheats_enabled_s` into the core top.

### nes_top.sv

Instantiate the parser:

```verilog
cheat_loader cheat_loader_i (
    .clk          (clk_ppu_21_47),
    .reset        (gg_reset),
    .stream_active(cheat_download),
    .stream_wr    (ioctl_wr && cheat_download),
    .stream_data  (ioctl_dout),
    .gg_code      (gg_code),
    .cheat_count  (gg_cheat_count)
);
```

`gg_reset` should pulse on the *rising edge* of either the ROM download
or the cheat download, so the code table is cleared right before a fresh
file streams in:

```verilog
reg prev_rom_download, prev_cheat_download;
always @(posedge clk_ppu_21_47) begin
    prev_rom_download   <= ioctl_download;
    prev_cheat_download <= cheat_download;
end
wire gg_reset = (~prev_rom_download   && ioctl_download)
             || (~prev_cheat_download && cheat_download);
```

Feed `cheats_enabled_s` into the core's existing `gg` / `gg_enable`
input (invert if your core uses the MiSTer `gg` convention, where 1 =
disable).

## The FCEUX decode, briefly

Game Genie alphabet: `APZLGITYEOXUKSVN`, each letter = 4 bits (A=0…N=15).
For a 6-letter code `t0..t5` or 8-letter code `t0..t7`:

```
addr = {1, t3[2:0], t4[3], t5[2:0], t1[3], t2[2:0], t3[3], t4[2:0]}
data = {t0[3], t1[2:0], (is_eight ? t7[3] : t5[3]), t0[2:0]}
compare (8-letter only) = {t6[3], t7[2:0], t5[3], t6[2:0]}
```

Bit 15 of `addr` is always 1 (Game Genie only patches $8000–$FFFF on NES).
The 129-bit message layout is `{strobe, 31'd0, compare_flag, 16'd0, addr,
24'd0, compare, 24'd0, data}` — padding positions match the CODES module's
`[96]/[79:64]/[39:32]/[7:0]` slicing.

There's a reference implementation at `tools/gg_decode.py` in this repo;
reuse it to regenerate test vectors for the sim.

## Pocket menu gotchas **important**

1. **Pocket firmware silently drops interact.json variable entries past
   some index**. A `"check"` entry with valid schema placed at the end of
   the variables array won't render. Solution: put the cheat toggle near
   the top of the variables array (right after Reset core works fine).
2. **`"writeonly": false` on `check` or `slider_u32` entries breaks the
   whole menu**, at least on current firmware. The firmware seems to
   reject the file. Keep everything `"writeonly": true`.
3. **Variable ids ≥ 100 are dropped** (probably related to #1 — they
   push past the index cutoff when combined with other entries). Use
   ids < 100.
4. **Name collisions** between a `data.json` slot and an `interact.json`
   entry cause at least one of them to be hidden. If the cheat data slot
   is named "Cheats", the interact toggle needs a different name
   (e.g., "Apply Cheat Codes").

There's no built-in way for an interact.json entry to display live core
state — the menu reads persisted values on boot and doesn't re-query the
core. If you want live diagnostics (loaded-code count, hit counter), the
only options are: (a) expose a bridge read register for a PC-side APF
debug tool, or (b) alter the video output.

## ALM budget **important for Pocket**

The Pocket's Cyclone V 5CEBA4 has 18,480 ALMs. Each stored code in the
MiSTer CODES module costs ~34 flops + a full-width address comparator.
The upstream default `MAX_CODES = 32` won't fit on a tight core.

For NES we capped at 4:

```verilog
CODES #(
    .ADDR_WIDTH(16),
    .DATA_WIDTH(8),
    .MAX_CODES(4)
) codes ( ... );
```

4 covers the common case (one cheat or a couple compatible codes for one
game). If your core has more ALM headroom, scale up — the parser happily
handles many more and just saturates.

The parser itself is cheap (~60 flops for the FSM + accumulator).

## STA: the clearing_ram → reset_nes path **important**

On NES, the core-wide reset signal ORs in several sources, one of which
(`clearing_ram`) is in a slower domain (clk_85_9) and fans out
combinationally through the entire reset tree. Once the CODES address
comparator sits inside that tree (on `from_data_bus`'s fanin), the path
`clearing_ram → mapper → data_in → CODES compare → from_data_bus → CPU
BAL` becomes a clk_85_9 → clk_ppu cross-clock launch with ~11.6 ns of
budget, which the comparator can't close.

Close it in SDC, not RTL:

```tcl
set_false_path -from [get_registers {core_top:ic|nes_top:nes|clearing_ram}]
```

`clearing_ram` is a boot-time flag that transitions once and stays
stable for millions of cycles; it's safe to false-path.

I initially tried a 2-flop RTL synchronizer into clk_ppu_21_47 for
`reset_nes`. It closed timing but had a confounding interaction elsewhere
that took a long time to track down. SDC false_path is the right fix.

## The clearing_ram ↔ cheat-load bug **important**

On NES, `clearing_ram` is set on the falling edge of `is_downloading`
(any data slot) with an ad-hoc exclusion for palette. That triggers a
~60 ms save-RAM wipe and holds the NES in reset for the duration.

Loading a cheat file would fire this, resetting the game every time the
user picked a `.gg`. The right fix is to tie the trigger specifically to
cartridge slot completion:

```verilog
if (prev_ioctl_download && ~ioctl_download && ~did_load_save) begin
    clearing_ram <= 1;
end
```

(where `ioctl_download` is `is_downloading && dataslot_requestwrite_id == 0`).

If your core has similar "post-load RAM clear" logic, audit what slots
it triggers on and make sure a cheat-file load doesn't trip it.

## Upstream savestate regression **important, core-specific**

The cheat branch started from master of `agg23/openFPGA-NES`. Savestate
**load** silently fails on master — the save produces a file (screenshot
in Memories) but loading leaves the running game state untouched. This
is **not** caused by the cheat branch; a plain master build without any
cheat code reproduces it.

The regression is somewhere in the ~50 upstream sync commits between the
`5bb74dc` (1.0.1) tag and current master — likely the "Rearrange CHR and
CPU RAM for larger ROMs" changes or one of its reverts. Savestate-load
works on 1.0.1.

We shipped by rebasing onto 1.0.1 + bringing in the static-RTL
separation refactor. If your Pocket core's master is in a similar state,
check savestate-load behavior before and after the rebase base commit.
If a user reports "cheats broke savestates", test a plain non-cheat
build of the same base first — the break is usually pre-existing.

## Dataslot streaming minutiae

`data_loader.sv` (shared helper in most Pocket cores) delivers bytes as
1-cycle `ioctl_wr` pulses with a ~4-cycle gap (`WRITE_MEM_CLOCK_DELAY`).
Your parser needs to tolerate this cadence, not assume back-to-back
bytes. `cheat_loader.sv` handles this naturally; if you write your own,
match this pattern.

`bridge_endian_little = 0` in `core_top.v` means the data_loader
byte-swaps incoming words so the shift-out order is "file order" (byte 0
first). Don't change this.

On end-of-file, `cheat_download` goes low. The parser uses that falling
edge as an EOF-flush to commit a partial code that wasn't newline-
terminated. If you skip the flush you'll silently drop the last code on
files without a trailing newline.

## Simulation

Two iverilog testbenches were sufficient:

- `sim/tb_cheat_loader.sv` drives the parser directly with synthetic
  inputs: 6/8 letter decodes, CRLF/LF, comments, invalid-length skip,
  EOF flush, enable/disable, MAX_CODES overflow.
- `sim/tb_cheat_file.sv` streams the real sample `.gg` through the
  parser + CODES pair with data_loader-like pulse timing, then probes
  CODES outputs for each loaded code.

Reference vectors come from `tools/gg_decode.py` (Python port of FCEUX).

## What I'd do differently on the next core

- Start from the last known-good tagged release, not HEAD. The upstream
  syncs often introduce regressions that aren't caught until someone
  tests a specific flow (savestates, mappers, etc.). If the core has
  version tags, use them.
- Close clearing_ram timing with SDC `set_false_path` from day one
  instead of trying an RTL sync. Spent a while on that detour.
- Sketch the interact.json layout first and verify the Pocket actually
  renders it before wiring any of the RTL. The menu constraints
  (position, id range, name collisions, writeonly) ate a surprising
  amount of time.
- Add the in-game visible test (e.g. NES SMB `AATOZA` → "MARIO x00" on
  game start) to the README. It's the fastest way for the user to
  confirm the whole pipeline end-to-end without a PC-side debug tool.

## Files touched, for quick reference

RTL:
- `rtl/cheat_loader.sv` — new, parser + decoder
- `rtl/nes_top.sv` — instantiation + gg_reset + clearing_ram trigger fix
- `rtl/cheatcodes.sv` — tiny SV-compat tweaks (outputs → logic).
  In cores that have split static RTL into a subdir, this is at
  `rtl/upstream/cheatcodes.sv`.
- `rtl/nes.v` — `MAX_CODES(4)` on the CODES instantiation.
  In split-layout cores, `rtl/upstream/nes.v`.

Target/platform:
- `target/pocket/core_top.v` — cheats_enabled reg + cheat_download wire
- `projects/nes_pocket.sdc` — `set_false_path -from clearing_ram`

Package:
- `pkg/pocket/Cores/<author.CORE>/data.json` — slot 12 Cheats
- `pkg/pocket/Cores/<author.CORE>/interact.json` — Apply Cheat Codes
- `pkg/pocket/Assets/<platform>/common/cheats/` — README + example .gg

Sim/tools:
- `sim/tb_cheat_loader.sv`, `sim/tb_cheat_file.sv`, `sim/Makefile`
- `tools/gg_decode.py` — FCEUX reference

Build (for NES Pocket): 18,247 / 18,480 ALMs, slow 85C/0C setup slack
~+5 ns, hold ~+0.4 ns on the PPU clock after the SDC false_path.
