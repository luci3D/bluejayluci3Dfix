# Bluejay 3D-fix fork — project notes for Claude

- 8051 assembly (Keil AX51 syntax) for EFM8BB21/BB51 BLDC ESCs. Entry: `src/Bluejay.asm`, modules in `src/Modules/`.
- Goal of this fork: reliable bidirectional (3D) reversal, AM32-style. See `FORK_NOTES.md` for every change and the test plan.
- Test target: Mobula8 2023, layout `Z_H_30` (Z layout, MCU H = EFM8BB21, deadtime 30).
- Build on Windows: `tools\build-windows.ps1 -Layout Z -Mcu H -Deadtime 30 -Pwm 48` (Keil 8051 from Simplicity Studio). Linux/CI: `make LAYOUT=Z MCU=H DEADTIME=30 PWM=48` (Keil under Wine).
- Constraints: BB21 code must end before `CSEG_RESET` (19FDh); `jb/jnb/jc/jz/sjmp/djnz/cjne` are relative (±127 bytes) and `ajmp/acall` must stay in the same 2 KB page — prefer `ljmp`/`jmp` when code grows.
- ISRs: register bank 1 (Timer1/DShot decode), bank 2 (Timer0 telemetry). Main loop uses bank 0. Don't touch Temp7/Temp8 in bank 2.
- Mark fork-specific changes with a `[3D fix]` comment.
- Hardware safety: always suggest props-off bench tests before flight tests.
