#!/usr/bin/env python3
"""NES Game Genie decoder.

A direct port of FCEUX's FCEUI_DecodeGG() in src/cheat.cpp.  Used to generate
expected values for the hardware testbench at sim/tb_cheat_loader.sv.

Usage (library):
    from gg_decode import decode
    addr, value, compare = decode("SXIOPO")

Usage (CLI):
    $ python3 tools/gg_decode.py SXIOPO GXXZPOVG
    SXIOPO     6  addr=0x91d9 value=0xad compare=-
    GXXZPOVG   8  addr=0xa1a1 value=0x24 compare=0xce
"""
import sys

_ALPHABET = "APZLGITYEOXUKSVN"
_NIBBLE = {c: i for i, c in enumerate(_ALPHABET)}


def decode(code: str):
    """Decode a 6 or 8 character NES Game Genie string.

    Returns (address, value, compare) with compare == None for 6-char codes.
    Raises ValueError on invalid input.
    """
    code = code.strip().upper()
    if len(code) not in (6, 8):
        raise ValueError(f"invalid length {len(code)} for {code!r}")
    try:
        n = [_NIBBLE[c] for c in code]
    except KeyError as exc:
        raise ValueError(f"invalid letter {exc.args[0]!r} in {code!r}") from None

    A = 0x8000
    V = 0
    C = 0

    # Letter 1
    V |= (n[0] & 0x07)
    V |= (n[0] & 0x08) << 4
    # Letter 2
    V |= (n[1] & 0x07) << 4
    A |= (n[1] & 0x08) << 4
    # Letter 3
    A |= (n[2] & 0x07) << 4
    # Letter 4
    A |= (n[3] & 0x07) << 12
    A |= (n[3] & 0x08)
    # Letter 5
    A |= (n[4] & 0x07)
    A |= (n[4] & 0x08) << 8

    if len(code) == 6:
        # Letter 6
        A |= (n[5] & 0x07) << 8
        V |= (n[5] & 0x08)
        return A, V, None

    # 8-letter
    # Letter 6
    A |= (n[5] & 0x07) << 8
    C |= (n[5] & 0x08)
    # Letter 7
    C |= (n[6] & 0x07)
    C |= (n[6] & 0x08) << 4
    # Letter 8
    C |= (n[7] & 0x07) << 4
    V |= (n[7] & 0x08)
    return A, V, C


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 1
    for code in argv[1:]:
        try:
            addr, value, compare = decode(code)
        except ValueError as exc:
            print(f"{code:10s} ERROR: {exc}")
            continue
        cstr = "-" if compare is None else f"0x{compare:02x}"
        print(
            f"{code:10s} {len(code)}  addr=0x{addr:04x} "
            f"value=0x{value:02x} compare={cstr}"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
