# AXI-PROTOCOL

# Handshake RTL Protocol — Verilog Implementation

A synthesizable, AXI4-Stream-style **valid/ready handshake protocol** implemented in Verilog, targeting Xilinx FPGAs (tested on `xc7vx485tffg1157-1` via Vivado 2020.1).

---

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Module Interface](#module-interface)
- [Architecture](#architecture)
  - [Master FSM](#master-fsm)
  - [Slave FSM](#slave-fsm)
- [Handshake Protocol](#handshake-protocol)
- [State Machines](#state-machines)
- [Timing Diagram](#timing-diagram)
- [Design Decisions & Bug Fixes](#design-decisions--bug-fixes)
- [File Structure](#file-structure)
- [Simulation](#simulation)
- [Vivado Setup](#vivado-setup)
- [Known Warnings](#known-warnings)

---

## Overview

This module implements a **two-party handshake** between a Master (producer) and Slave (consumer) using registered `valid` and `ready` signals. The design guarantees:

- **Zero data loss** — even if `master_start` pulses while the slave is busy
- **No race conditions** — `slave_ready` is pre-registered (stable one cycle before use)
- **AXI4-Stream compliance** — transaction only occurs when both `valid=1` AND `ready=1`

---

## Features

- ✅ Synthesizable RTL (no behavioral-only constructs)
- ✅ Active-low asynchronous reset
- ✅ 3-state Master FSM with data hold capability
- ✅ 2-state Slave FSM with pre-asserted ready
- ✅ Single-cycle `transaction_done` pulse
- ✅ `default` cases in all FSMs (prevents latch inference)
- ✅ Verified in Vivado 2020.1 XSim (25 transactions, all PASS)

---

## Module Interface

```verilog
module handshake_rtl (
    input  wire        clk,             // System clock
    input  wire        rst_n,           // Active-low async reset

    // Master inputs
    input  wire [7:0]  master_data_in,  // Data to send
    input  wire        master_start,    // 1-cycle pulse to trigger transfer

    // Monitored outputs
    output reg  [7:0]  master_data,     // Registered data being sent
    output reg         master_valid,    // Master: "my data is valid"
    output reg  [7:0]  slave_data,      // Data received by slave
    output reg         slave_ready,     // Slave: "I am ready to receive"
    output reg         transaction_done // 1-cycle pulse on successful transfer
);
```

### Port Descriptions

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `clk` | input | 1 | System clock (100 MHz tested) |
| `rst_n` | input | 1 | Async reset, active-LOW |
| `master_data_in` | input | 8 | Raw data from upstream/testbench |
| `master_start` | input | 1 | One-tick trigger pulse |
| `master_data` | output | 8 | Registered copy of data in flight |
| `master_valid` | output | 1 | Asserted when master holds valid data |
| `slave_data` | output | 8 | Data latched by slave on handshake |
| `slave_ready` | output | 1 | Asserted when slave can accept data |
| `transaction_done` | output | 1 | One-clock-cycle pulse per transaction |

---

## Architecture

```
                        handshake_rtl
         ┌──────────────────────────────────────────┐
         │                                          │
clk ─────┤──────────────────────────────────────►  │
rst_n ───┤──────────────────────────────────────►  │
         │                                          │
master_  │   ┌─────────────────────┐               │──► master_data[7:0]
data_in ─┤──►│                     │               │──► master_valid
         │   │    MASTER FSM       │               │
master_  │   │  M_NEW_DATA         │               │
start ───┤──►│  M_WAIT_FOR_READY   │               │
         │   │  M_WAIT_FOR_SLAVE   │               │
         │   └──────────┬──────────┘               │
         │              │ master_valid              │
         │              │ master_data               │
         │   ┌──────────▼──────────┐               │
         │   │                     │               │──► slave_data[7:0]
         │   │    SLAVE FSM        │               │──► slave_ready
         │   │  S_WAIT_FOR_DATA    │               │──► transaction_done
         │   │  S_PROCESS_DATA     │               │
         │   └──────────┬──────────┘               │
         │              │ slave_ready               │
         │              └──────(feedback)──────────►│
         └──────────────────────────────────────────┘
```

---

## Master FSM

### States

| State | Value | Description |
|-------|-------|-------------|
| `M_NEW_DATA` | `2'b00` | Idle — waiting for `master_start` |
| `M_WAIT_FOR_READY` | `2'b01` | Holding data — waiting for slave to free up |
| `M_WAIT_FOR_SLAVE` | `2'b10` | Handshake in progress — holding `valid` HIGH |

### Transition Diagram

```
            rst_n=0
               │
               ▼
       ┌───────────────┐
       │  M_NEW_DATA   │◄──────────────────────────────────┐
       │  (Idle)       │                                   │
       └───────┬───────┘                                   │
               │                                    handshake complete
       ┌───────┴────────┐                       (valid=1 && ready=1)
       │                │                                   │
  start && ready    start && !ready                         │
       │                │                                   │
       │                ▼                                   │
       │     ┌─────────────────────┐                        │
       │     │  M_WAIT_FOR_READY  │                        │
       │     │  (Holding data)    │                        │
       │     └──────────┬──────────┘                        │
       │                │                                   │
       │            ready=1                                 │
       │                │                                   │
       ▼                ▼                                   │
       ┌────────────────────────┐                           │
       │    M_WAIT_FOR_SLAVE    │───────────────────────────┘
       │  (Handshake pending)   │
       └────────────────────────┘
```

---

## Slave FSM

### States

| State | Value | Description |
|-------|-------|-------------|
| `S_WAIT_FOR_DATA` | `1'b0` | Ready — `slave_ready` pre-asserted |
| `S_PROCESS_DATA` | `1'b1` | Busy — one cycle processing delay |

### Transition Diagram

```
            rst_n=0
               │
               ▼
       ┌────────────────────┐
       │  S_WAIT_FOR_DATA   │◄──────────────────────┐
       │  slave_ready = 1   │                        │
       └────────┬───────────┘                        │
                │                              (back to free)
       master_valid=1 && slave_ready=1               │
                │                                    │
                ▼                                    │
       ┌────────────────────┐                        │
       │  S_PROCESS_DATA    │────────────────────────┘
       │  slave_ready = 0   │  (1 cycle)
       └────────────────────┘
```

---

## Handshake Protocol

The handshake follows the **AXI4-Stream valid/ready** rule:

```
  A transaction occurs ONLY when:
  ┌─────────────────────────────────┐
  │  master_valid = 1               │
  │       AND                       │
  │  slave_ready  = 1               │
  │                                 │
  │  simultaneously on a clock edge │
  └─────────────────────────────────┘
```

Neither side drops its signal until both conditions are confirmed true. This prevents data loss in all timing scenarios.

---

## Timing Diagram

```
Cycle:        1      2      3      4      5      6
              ↑      ↑      ↑      ↑      ↑      ↑
clk:        __|‾|__|‾|__|‾|__|‾|__|‾|__|‾|__|‾|__

slave_ready:  0      1      1      0      0      1
                     ↑ pre-asserted      ↑ ready again

master_start: 0      1      0      0      0      0
                     ↑ one-tick pulse

master_valid: 0      0      1      1      0      0
                            ↑ asserted when ready seen

master_data:  X      X    [D]    [D]     X      X

Handshake:                  ✓ (cycle 3: valid=1 && ready=1)

slave_data:   X      X      X    [D]     X      X
                                  ↑ captured

transaction_
done:         0      0      0      1      0      0
                                   ↑ 1-cycle pulse
```

---

## Design Decisions & Bug Fixes

### Bug 1 — Original: Same-cycle `ready`/`valid` Race

**Problem:** The original code set `slave_ready=1` and checked `master_valid` in the same always block evaluation, creating a potential race condition in synthesis.

**Fix:** `slave_ready` is now registered (set at the start of `S_WAIT_FOR_DATA`), so it is stable one full clock cycle before the master samples it.

---

### Bug 2 — Original: Missing `M_WAIT_FOR_READY` State

**Problem:** If `master_start` pulsed (one tick only) while `slave_ready=0`, the master saved the data but returned to `M_NEW_DATA`. On the next cycle, `master_start=0` — so no branch matched and the data was silently abandoned.

```
Tick 1: start=1, ready=0 → data saved, stay in M_NEW_DATA
Tick 2: start=0, ready=1 → no branch matches → DATA LOST ❌
```

**Fix:** Added `M_WAIT_FOR_READY` state. The FSM holds the data independently of `master_start` and waits until `slave_ready=1` before proceeding.

```
Tick 1: start=1, ready=0 → data saved, move to M_WAIT_FOR_READY
Tick 2: start=0, ready=1 → slave free! assert valid → DATA SAFE ✅
```

---

### Bug 3 — Testbench: Wrong Reset Check

**Problem:** The testbench checked `slave_ready=0` after reset, but the RTL correctly asserts `slave_ready=1` one cycle after reset (slave enters `S_WAIT_FOR_DATA` and pre-asserts ready).

**Fix:** The reset check should NOT require `slave_ready=0`. After reset the slave is correctly ready to receive — this is expected behavior.

---

### Bug 4 — Testbench: Pulse-Counting Off-by-One

**Problem:** The `send_when_slave_busy` task waited for a second `transaction_done` pulse after skipping the first, but the real data pulse had already fired and been missed — causing false FAIL reports.

**Fix:** Consume the dummy transaction's done pulse explicitly before sending real data, then wait for exactly one more done pulse.

---

## File Structure

```
protocol_handshake/
│
├── handshake.v          # RTL design (handshake_rtl module)
├── tb.v                 # Testbench (handshake_rtl_tb module)
└── README.md            # This file
```

---

## Simulation

### Vivado 2020.1 — XSim Results

```
=======================================================
  Handshake RTL Testbench — Bug Fix Verification
=======================================================

  TEST 1  : Reset Behavior          → PASS
  TEST 2  : Normal Send 0xA5        → PASS
  TEST 3  : Normal Send 0x3C        → PASS
  TEST 4  : Start pulse, slave busy → PASS  ← key bug fix
  TEST 5  : Start pulse, slave busy → PASS
  TEST 6  : Back-to-Back (3x)       → PASS
  TEST 7  : Edge cases 0x00, 0xFF   → PASS
  TEST 8  : Walking ones (8x)       → PASS
  TEST 9  : Random burst (6x)       → PASS
  TEST 10 : Reset mid-operation     → PASS
  TEST 11 : Rapid pulse stress      → PASS

=======================================================
   PASS  : 25
   FAIL  : 0
   TOTAL : 25
   ✅ ALL TESTS PASSED
=======================================================
```

### Running Simulation

1. Open Vivado 2020.1
2. Create project targeting `xc7vx485tffg1157-1`
3. Add `handshake.v` and `tb.v` as source files
4. Set `handshake_rtl_tb` as the top simulation module
5. Run Behavioral Simulation
6. In TCL console: `run 10 us`

---

## Vivado Setup

```tcl
create_project protocol_handshake ./protocol_handshake -part xc7vx485tffg1157-1
add_files handshake.v
add_files tb.v
update_compile_order -fileset sources_1
launch_simulation
run 10 us
```

---

## Known Warnings

```
WARNING: [XSIM 43-4100] Module handshake_rtl has a timescale but at
least one module in design doesn't have timescale.
```

**Cause:** The testbench file is missing `` `timescale 1ns/1ps `` at the top.

**Fix:** Add to the first line of `tb.v`:
```verilog
`timescale 1ns / 1ps
```

This warning does not affect functional simulation results but should be resolved before any timing simulation or synthesis.

---

## Target Device

| Parameter | Value |
|-----------|-------|
| Family | Virtex-7 |
| Device | xc7vx485t |
| Package | ffg1157 |
| Speed Grade | -1 |
| Tool | Vivado 2020.1 |
| Simulation | XSim (Behavioral) |

---

## License

MIT License — free to use, modify, and distribute with attribution.
