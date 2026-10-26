# Bluejay luci3Dfix: AM32-style 3D mode for 8-bit ESCs

**luci3Dfix** is a fork of [Bluejay](https://github.com/bird-sanctuary/bluejay)
that changes only one thing: how the ESC reverses the motor in bidirectional
(3D) mode. The goal is to make 3D flight on 8-bit EFM8 ESCs as reliable as on
32-bit ESCs running [AM32](https://github.com/am32-firmware/AM32), with no
desyncs and no stalls when you flip direction.

Everything else (DShot, bidirectional telemetry, EDT, startup tunes, the
settings layout) is stock Bluejay. In ESC Configurator the firmware shows up as
`Bluejayluci3Dfix`.

> **Status: experimental.** The firmware builds and is going through
> props-off bench testing. It has **not been flight-tested yet**. Always test
> with props off first, and keep the stock Bluejay hex for your board at hand
> to roll back.

## Supported targets

| Board | ESC layout | MCU | Deadtime | PWM |
|-------|-----------|-----|----------|-----|
| Happymodel Mobula8 (2023) AIO | `Z_H_30` | EFM8BB21 | 30 | 48 kHz (24 / 96 build on request) |

This is the only target for now. Other Bluejay layouts compile from this
source, but they are untested with the new reversal logic. More targets will be
added once the Mobula8 flies 3D cleanly.

## Why stock Bluejay desyncs in 3D

When the stick crosses centre in 3D mode, stock Bluejay does this:

1. **Reverse-drives the motor to brake it.** It flips its expected back-EMF
   polarity and drives the motor 180° out of phase. The brake force was meant
   to be capped at startup power, but `set_pwm_limit` overwrites that cap every
   electrical revolution. In practice the brake force follows your stick.
2. **Flips direction while the rotor still spins at about 5000 erpm.** At that
   point it sets only the *initial run* phase, not the real *startup* phase.
   It gets no long zero-cross timeouts, no extra comparator samples and no
   startup power limit. It commutates the other way and hopes to catch sync.
3. **Recovers from a failed reversal with a full stop and restart.** A
   comparator timeout leads to `exit_run_mode`. All interrupts are turned off,
   the motor is dead for 100 ms, and then it starts over from `motor_start`.
   During those 100 ms no DShot frames are decoded and no telemetry is sent.
   After more than 3 failed starts in a row it beeps and has to be re-armed.

There is also a decoding bug. Zero-throttle frames and DShot command frames go
through the same "subtract 2000" test as throttle, and come out as a *reverse*
request. Simply passing through stick centre could trigger a reversal nobody
asked for.

## How AM32 does it

AM32 (`setInput()` in `Src/main.c`) handles a direction change very
differently:

- **It refuses to reverse while the motor is fast.** If the requested
  direction is opposite to the spin, AM32 forces the throttle to **0**. The
  motor keeps commutating normally while its complementary PWM drag-brakes it.
  Nothing is ever driven out of phase.
- **It flips once the motor is slow enough**, below a speed threshold scaled
  from motor KV and with duty under 10%. It then resets its zero-cross count
  and drops into its robust, startup-style zero-cross detection (polling
  mode). There is no power-off, no blackout and no stall counter: the motor
  simply restarts in place.
- **It ignores direction for inputs below 48.** Zero throttle and DShot
  commands never change direction.
- **A 3D desync doesn't stop the motor.** It falls back to the robust
  detection and keeps going.

## What luci3Dfix changes

The same strategy, written in Bluejay's 8051 assembly. No AM32 code is copied,
only the behaviour. Every change is marked `[3D fix]` in the source.

| # | Where | Change | Why |
|---|-------|--------|-----|
| 1 | `src/Modules/Isrs.asm` | Zero-throttle and DShot command frames no longer change the requested direction (`Flag_Rcp_Dir_Rev`). | Matches AM32's "inputs below 48 have no direction" rule and removes the spurious reversals. |
| 2 | `src/Bluejay.asm` (`run6_bidir`) and the ISR | A reversal request now **coasts at zero power while still commutating**. A new flag, `Flag_Dir_Change_Coast`, forces PWM to exactly 0 in the DShot ISR. | Zero-power commutation is a state Bluejay already tracks reliably, the same as zero throttle in flight, so sync is never lost. The old out-of-phase brake is gone. |
| 3 | `src/Bluejay.asm` (`bidir_restart`) | Once `Comm_Period4x_H >= BIDIR_REVERSE_PERIOD_H`, the motor **restarts in place** in the new direction through the real startup sequence (startup power limits, long zero-cross timeouts, many comparator samples). | AM32's "flip when slow, then restart robustly". There is no clock switch, no stall bookkeeping and no 100 ms pause. |
| 3b | `exit_run_mode_on_timeout` | A comparator timeout while coasting goes to `bidir_restart` instead of the stall path. With the stick centred it is a normal stop. | Reversals no longer count as stalls, so no beeps and no pause. |
| 3c | `exit_run_mode_on_timeout` | A desync while running in 3D with throttle also restarts in place. It is still reported as a stall over extended telemetry. Normal (non-3D) mode is unchanged. | AM32 keeps going after a 3D desync. Trade-off: a jammed motor in 3D retries at startup power without the 100 ms rest in between. |
| 4 | Stall restart path | Interrupts stay on during the 100 ms stall wait, and the restart is skipped if throttle dropped to zero. | DShot decoding and telemetry no longer black out. |
| 5 | `src/Settings/BluejaySettings.asm` | New build setting `BIDIR_REVERSE_PERIOD_H`, default `40h` (about 5000 erpm). | Tuning knob for how slow the motor must be before it reverses. |

### Does this touch braking?

Only the direction-change brake, which is the one being replaced. Everything
else is unchanged:

| Braking | Changed? |
|---------|----------|
| Direction-change brake (`Flag_Dir_Change_Brake`) | **Replaced** by the zero-power coast. |
| Braking strength (complementary PWM, damped light) | **No code change.** It is what slows the motor during the coast now, so keep it high (100% is the default) for quick reversals. |
| Brake on stop | **No.** It runs only on a normal stop (`exit_run_mode_no_stall`). |
| Turtle mode (DShot reverse command) | **No.** It uses the programmed direction at motor start, a separate path. |

### Reversal sequence at a glance

```
stick flips direction
        │
        ▼
power → 0, keep commutating (drag brake from braking strength)
        │
        ├── stick back to the old direction? ──► coast cancelled, power returns
        │
        ▼
motor slower than BIDIR_REVERSE_PERIOD_H  (or zero-cross timeout)
        │
        ▼
bidir_restart: flip direction, full startup sequence, no power-off or pause
        │
        ▼
normal running in the new direction
```

## Building

### Windows

1. Install **Simplicity Studio 5** from Silicon Labs. In its Installation
   Manager, add the 8-bit / EFM8 (8051) toolchain. This installs Keil 8051
   v9.60.
2. **Activate the free Keil license** for EFM8 in Simplicity Studio, using your
   Silicon Labs account. Without it, the link fails with
   `L250: CODE SIZE LIMIT IN RESTRICTED VERSION EXCEEDED`.
3. From the repository folder, run:
   ```powershell
   powershell -ExecutionPolicy Bypass -File tools\build-windows.ps1 -Layout Z -Mcu H -Deadtime 30 -Pwm 48
   ```
   Use the PWM frequency you run now (ESC Configurator shows it: 24, 48 or 96).
   If Keil is installed somewhere else, add
   `-KeilPath "C:\path\to\keil_8051\9.60\BIN"`.
4. The output is `build\hex\Z_H_30_48_luci3Dfix.hex`.

### Linux / CI

The upstream Makefile works unchanged: `make LAYOUT=Z MCU=H DEADTIME=30 PWM=48`
(Keil under Wine, see the
[Bluejay wiki](https://github.com/bird-sanctuary/bluejay/wiki/Building-from-source)).

## Flashing

1. Connect the quad to Betaflight with **props off**.
2. Open [ESC Configurator](https://esc-configurator.com), connect, and read
   settings. Note the current firmware, version and settings.
3. Choose **Flash all**, then **Select file manually**, and pick the `.hex`.
4. After flashing, check that the name reads `Bluejayluci3Dfix`. Set **Motor
   direction** to bidirectional (or use Betaflight's 3D feature), and keep
   braking strength at 100%.

## Test plan

Props **off** first, then props on, in a safe place.

1. Turn on Betaflight's 3D feature with bidirectional DShot and extended DShot
   telemetry enabled.
2. **Slow sweeps through centre.** The motor should stop, then start the other
   way with a normal startup: no stutter, no stall beeps.
3. **Fast flicks** from about 50% forward to 50% reverse. Expect a short coast
   (tens of milliseconds), then a clean restart. Watch eRPM in the Betaflight
   Motors tab.
4. **Flick back during the coast.** Power should simply return in the original
   direction.
5. **Check telemetry.** The extended telemetry stall and desync events (ESC
   telemetry or blackbox) should no longer appear on every reversal.

### Tuning

`BIDIR_REVERSE_PERIOD_H` in `src/Settings/BluejaySettings.asm` sets how slow
the motor must be before it reverses. A higher value means a slower speed:
smoother restarts, but a slightly longer delay before reversing.

| Value | ≈ erpm |
|-------|--------|
| `20h` | 10000 |
| `30h` | 6700 |
| `40h` (default) | 5000 |
| `60h` | 3300 |
| `80h` | 2500 |

If the restart kicks or desyncs, raise it. If reversals feel laggy but restarts
are clean, lower it.

## Upstream and license

Based on [`bird-sanctuary/bluejay`](https://github.com/bird-sanctuary/bluejay)
`main` (v0.21.x). Reversal behaviour inspired by
[AM32](https://github.com/am32-firmware/AM32). Licensed GPLv3, like both
projects.
