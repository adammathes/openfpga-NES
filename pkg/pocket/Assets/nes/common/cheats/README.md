Pocket NES - Cheat Codes
========================

Drop text files with Game Genie codes (one code per line) here or anywhere on
the SD card. Load them by opening the core, navigating to Core Settings
-> Cheats, and browsing to the .gg / .cht file you want. After loading, turn
cheats on or off at any time with the "Enable Cheats" toggle.

File format
-----------
* One Game Genie code per line (6 or 8 letters from APZLGITYEOXUKSVN).
* Anything after the code on the line (tabs, spaces, a descriptive name) is
  ignored, so it is fine to annotate each entry:

      SXIOPO   Infinite lives (Super Mario Bros.)
      GXXZPOVG Infinite energy (Metroid)

* Case-insensitive.
* Lines starting with # or ; are treated as comments.
* Empty lines are ignored.
* Up to 4 codes may be loaded at once (keeps the FPGA fit on the Pocket).
  Extra codes in the file are parsed but dropped.

This format is compatible with the plain-text cheat lists commonly used by
MiSTer FPGA and RetroArch's NES cheat packs, so the same files can be reused.

Activating / deactivating
-------------------------
* Toggle "Enable Cheats" in the core menu. When the toggle is off, no codes
  are applied even if a cheat file is loaded.
* Loading a new ROM clears any previously-loaded cheats.
* Loading a new cheat file replaces the current set.
