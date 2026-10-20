# luci3Dfix — a Bluejay fork for reliable 3D mode

Goal: make bidirectional (3D) mode reliable on 8-bit EFM8 ESCs by adopting the
reversal strategy AM32 uses, while keeping the rest of Bluejay untouched.

Target hardware for first tests: **Happymodel Mobula8 (2023) AIO — ESC layout `Z_H_30`**
(layout Z, EFM8BB21 MCU, deadtime 30). The STM32F411 on that board is the
flight controller running Betaflight; the ESC side is the EFM8BB21.

Branch: `luci3Dfix`. Name tag shown in ESC Configurator: `Bluejayluci3Dfix` (16-character limit, keeps the Bluejay prefix).

## What changed and why

| # | File | Change | Why |
|---|------|--------|-----|
| 1 | `src/Modules/Isrs.asm` | Zero-throttle and DShot command frames no longer update `Flag_Rcp_Dir_Rev`. | They went through the "subtract 2000" test and were read as a low-range (reverse) request, triggering spurious reversals. AM32 ignores direction for inputs < 48. |
| 2 | `src/Bluejay.asm` (`run6_bidir`) + ISR | Reversal = **coast with zero power while still commutating**, instead of driving the motor 180° out of phase at the requested throttle. New flag `Flag_Dir_Change_Coast` forces PWM to 0 in the DShot ISR. | Zero-power commutation is a state Bluejay already tracks reliably (same as zero throttle in the air). Old active braking used stick throttle (its intended limit was overwritten by `set_pwm_limit`). |
| 3 | `src/Bluejay.asm` (`bidir_restart`) | Once `Comm_Period4x_H >= BIDIR_REVERSE_PERIOD_H`, restart **in place** through the normal startup sequence (startup power limits, long ZC timeouts, many comparator samples). | Old code flipped direction mid-spin without startup handling, then usually desynced → stall → 100 ms restart. |
| 3b | `exit_run_mode_on_timeout` | A comparator timeout while coasting goes to `bidir_restart` instead of the stall path (stick centred → normal stop). | Avoid the stall counter / beeps / 100 ms pause on reversals. |
| 3c | `exit_run_mode_on_timeout` | A desync (comparator timeout) while running in bidirectional mode with throttle also goes to `bidir_restart`, still flagged as a stall over EDT. Unidirectional mode is unchanged. | AM32 keeps going after a 3D desync instead of stopping; Bluejay used to cut the motor for 100 ms. Trade-off: a jammed motor in 3D retries at startup power without the 100 ms rest. |
| 4 | stall restart path | Interrupts stay enabled during the 100 ms stall wait; restart is skipped if throttle went to zero. | DShot decoding and telemetry no longer black out for 100 ms. |
| — | `src/Settings/BluejaySettings.asm` | New `BIDIR_REVERSE_PERIOD_H` (default `40h` ≈ 5000 erpm). | Tuning knob for when to reverse. |

Coast deceleration comes from the existing **Braking strength** setting (zero
duty with complementary PWM = drag brake). Keep it high (default 100%) for
fast reversals.

## Building on Windows

1. Install **Simplicity Studio 5** (Silicon Labs) and, inside it, the 8051 / EFM8
   toolchain — this installs Keil 8051 with a free license for EFM8 parts
   (you may need to activate it with your Silicon Labs account).
2. From the repo folder:
   ```powershell
   powershell -ExecutionPolicy Bypass -File tools\build-windows.ps1 -Layout Z -Mcu H -Deadtime 30 -Pwm 48
   ```
   Use the PWM frequency you currently run (ESC Configurator shows it: 24/48/96).
   If Keil is elsewhere, add `-KeilPath "C:\path\to\keil_8051\9.60\BIN"`.
3. Output: `build\hex\Z_H_30_48_luci3Dfix.hex`.

If assembly fails with a "target out of range" error, a short jump needs to
become a long one — send me the `.LST` error lines.

## Flashing

1. Connect the quad to Betaflight, **props off**.
2. Open https://esc-configurator.com → Connect → Read settings. Save a note of
   the current firmware/version and settings (and keep the stock Bluejay hex for
   `Z_H_30` handy so you can roll back).
3. "Flash all" → *Select file manually* → the `.hex` above.
4. After flashing, confirm name `Bluejayluci3Dfix`, set **Motor direction =
   Bidirectional** (or leave it to Betaflight's 3D mode), braking strength 100%.

## Test plan (props OFF first, then props on in a safe place)

1. **Bench, 3D mode on** (`set 3d_deadband...` defaults, Betaflight 3D feature on,
   bidirectional DShot + extended telemetry enabled).
2. Slow stick sweeps through centre: motor should stop, then start the other way
   with a normal startup — no stutter, no stall beeps.
3. Fast flicks from ~50% forward to ~50% reverse: expect a short coast
   (~tens of ms), then a clean restart. Watch Betaflight Motors tab eRPM.
4. Flick back to the original direction mid-coast: power should just return.
5. Check EDT stall/desync events (Betaflight ESC telemetry / blackbox): they
   should no longer appear on every reversal.
6. Tune `BIDIR_REVERSE_PERIOD_H`: if the restart kicks or desyncs, raise it
   (`60h`, `80h`); if reversal feels laggy and restarts are clean, lower it (`30h`).

## Upstream

Based on `bird-sanctuary/bluejay` `main` (v0.21.x). Licensed GPLv3 like upstream.
