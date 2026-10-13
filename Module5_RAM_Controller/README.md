# Module 5: RAM Controller
### CRYSTALS-Kyber FPGA Hardware Accelerator

## 1. Overview

Module 5 implements the RAM Controller for the CRYSTALS-Kyber FPGA Hardware Accelerator.

The RAM Controller manages access to the internal memory banks used to store and retrieve polynomial coefficients and intermediate computation results during the Kyber Number Theoretic Transform (NTT) operations.

It acts as an interface between the memory banks and the other accelerator modules. It handles synchronous memory reads, writeback operations, memory address selection, and coefficient data packing for the sampler interface.

The module is designed in Verilog HDL and is being developed for integration into the complete FPGA accelerator.

---

## 2. Objectives

The main objectives of Module 5 are:

- Implement the memory banks required by the accelerator.
- Perform synchronous read and write operations.
- Select the appropriate memory bank using the bank selection signal.
- Maintain read-address information for subsequent writeback operations.
- Support 48-bit memory access for intermediate data through RAM4.
- Pack two 12-bit sampler coefficients into a single 24-bit memory word.
- Provide a memory interface that can be integrated with the other accelerator modules.
- Verify the controller's functionality using a Verilog testbench.

---

## 3. System Architecture

The RAM Controller contains five logical memory banks: RAM0, RAM1, RAM2, RAM3, and RAM4.

RAM0 and RAM1 are selected together using `bank_sel = 2'b00`.

RAM2 and RAM3 are selected together using `bank_sel = 2'b01`.

RAM4 is selected using `bank_sel = 2'b10`.

The selection `bank_sel = 2'b11` is reserved.

The controller supports two 24-bit read outputs, allowing data from two memory banks to be returned through `rd_data_a` and `rd_data_b`.

RAM4 is 48 bits wide. Its lower and upper 24-bit portions are provided through the two read outputs.

The sampler interface accepts individual 12-bit coefficients and combines consecutive even-indexed and odd-indexed coefficients into a 24-bit word.

### High-Level Block Diagram

                 +--------------------------+
                 |       RAM Controller     |
                 |                          |
                 |  Address Selection       |
                 |  Read/Write Control      |
                 |  Writeback Management    |
                 |  Sampler Data Packing    |
                 +------------+-------------+
                              |
             +----------------+----------------+
             |                |                |
        +----v----+       +---v-----+      +---v-----+
        | RAM0/1  |       | RAM2/3  |      |  RAM4   |
        | 24-bit  |       | 24-bit  |      | 48-bit  |
        +---------+       +---------+      +---------+
             ^                ^                ^
             +----------------+----------------+
                              |
                   Read Data / Write Data

---

## 4. Memory Organization

The controller declares five memory arrays.

| Memory | Data Width | Depth | Address Width | Purpose |
|--------|------------|-------|---------------|---------|
| RAM0 | 24 bits | 256 words | 8 bits | Coefficient storage |
| RAM1 | 24 bits | 256 words | 8 bits | Coefficient storage |
| RAM2 | 24 bits | 64 words | 6 bits | Intermediate coefficient storage |
| RAM3 | 24 bits | 64 words | 6 bits | Intermediate coefficient storage |
| RAM4 | 48 bits | 128 words | 7 bits | Wider intermediate data storage |

### RAM0 and RAM1

RAM0 and RAM1 each store 256 words of 24 bits.

The controller uses `addr_a` to access RAM0 and `addr_b` to access RAM1.

The sampler interface writes packed coefficient pairs to RAM0 or RAM1.

### RAM2 and RAM3

RAM2 and RAM3 each store 64 words of 24 bits.

The controller uses the lower six bits of the supplied addresses to access these memories.

### RAM4

RAM4 stores 128 words of 48 bits.

Each memory word is divided into two 24-bit portions:

- Bits `[23:0]`: Lower portion.
- Bits `[47:24]`: Upper portion.

The controller returns these portions through `rd_data_a` and `rd_data_b`, respectively.

During writeback, the two 24-bit inputs are combined into one 48-bit word.

---

## 5. Module Interface

### Main Control Signals

| Signal | Direction | Width | Description |
|--------|-----------|-------|-------------|
| `clk` | Input | 1 bit | Clock signal |
| `rst` | Input | 1 bit | Synchronous, active-high reset |
| `rd_en` | Input | 1 bit | Enables a memory read |
| `wr_en` | Input | 1 bit | Enables the main writeback operation |
| `bank_sel` | Input | 2 bits | Selects the memory bank or bank pair |
| `offset` | Input | 7 bits | Provides the RAM4 address offset |
| `mem_busy` | Output | 1 bit | Indicates that a valid sampler input cannot currently be accepted |

### Address and Data Signals

| Signal | Direction | Width | Description |
|--------|-----------|-------|-------------|
| `addr_a` | Input | 8 bits | Address for the first memory access |
| `addr_b` | Input | 8 bits | Address for the second memory access |
| `wr_data_a` | Input | 24 bits | First writeback data word |
| `wr_data_b` | Input | 24 bits | Second writeback data word |
| `rd_data_a` | Output | 24 bits | First read-data output |
| `rd_data_b` | Output | 24 bits | Second read-data output |

### Sampler Interface

| Signal | Direction | Width | Description |
|--------|-----------|-------|-------------|
| `sample_valid` | Input | 1 bit | Indicates that a sampler coefficient is available |
| `sample_coeff` | Input | 12 bits | Sampler coefficient |
| `sample_addr` | Input | 8 bits | Address/index associated with the coefficient |
| `sample_bank_sel` | Input | 2 bits | Selects the destination coefficient memory |
| `sample_ready` | Output | 1 bit | Indicates that the sampler input can be accepted |

A sampler transfer is accepted when both `sample_valid` and `sample_ready` are high at the rising edge of the clock.

---

## 6. Functional Operation

### 6.1 Synchronous Memory Read

When `rd_en` is asserted, the controller reads the selected memory bank or banks.

The `bank_sel` signal determines which memories are accessed.

For RAM0 and RAM1:
- `addr_a` selects the RAM0 word.
- `addr_b` selects the RAM1 word.

For RAM2 and RAM3:
- The lower six address bits select the corresponding memory words.

For RAM4:
- The controller calculates the read address using the lower seven bits of `addr_a` and the supplied `offset`.
- The 48-bit word is divided into two 24-bit outputs.

The read outputs are updated synchronously on the rising edge of the clock.

### 6.2 Main Memory Writeback

The controller stores the addresses and bank selection from a read operation.

When `wr_en` is asserted and a previous read address is valid, the controller uses the saved address information for writeback.

For RAM0 and RAM1, the two 24-bit writeback words are written to their corresponding saved addresses.

For RAM2 and RAM3, the saved addresses are restricted to six bits.

For RAM4, the two 24-bit writeback words are combined into one 48-bit word:

`{wr_data_b, wr_data_a}`

The combined word is written to the calculated RAM4 address.

This mechanism supports the use of previously captured memory addresses during a subsequent writeback operation.

### 6.3 RAM4 Address Offset

The RAM4 read address is calculated as:

`ram4_read_addr = addr_a[6:0] + offset`

The saved address and saved offset are used for the corresponding main writeback operation.

The offset must be chosen so that the resulting address remains within the valid RAM4 range of 0 to 127.

### 6.4 Sampler Coefficient Packing

The sampler supplies one 12-bit coefficient at a time.

Since RAM0 and RAM1 use 24-bit words, the controller combines two coefficients into a single word.

The controller uses the least significant bit of `sample_addr` to distinguish between even-indexed and odd-indexed coefficients.

**Even-indexed coefficient:**

When `sample_addr[0]` is zero, the controller temporarily stores:
- The coefficient.
- Its address.
- Its destination bank.

**Odd-indexed coefficient:**

When the matching odd-indexed coefficient arrives, the controller combines the two coefficients:

`{sample_even_coeff, sample_coeff}`

The resulting 24-bit word is written to RAM0 or RAM1, depending on the saved sampler bank selection.

The pair is stored at the address formed from the saved even coefficient address:

`sample_even_addr[7:1]`

The sampler input is accepted only when `sample_valid` and `sample_ready` are both high at the rising clock edge.

### 6.5 Busy and Ready Signals

`sample_ready` indicates whether the sampler coefficient can be accepted under the controller's current conditions.

The controller does not accept coefficients for unsupported sampler bank selections.

For an odd-indexed coefficient, the controller checks that a matching even-indexed coefficient is pending and that the main writeback conflict condition does not prevent the pair from being committed.

`mem_busy` is asserted when a sampler coefficient is valid but cannot be accepted:

`mem_busy = sample_valid && !sample_ready`

These signals allow the sampler to determine when it can transfer the next coefficient.

---

## 7. Reset Behaviour

The controller uses a synchronous, active-high reset.

When `rst` is asserted, the controller resets its internal control registers, including:

- Read-data outputs.
- Saved memory addresses.
- Saved bank selection.
- Saved RAM4 offset.
- Previous-read validity flag.
- Sampler coefficient-pair state.

**The RAM arrays are not cleared during reset.**

This avoids adding a reset operation across every memory location and allows the memory contents to be preserved when the controller's control logic is reset.

---

## 8. RTL Implementation

The design is implemented in synthesizable Verilog HDL.

The main source file is:

`memory_ram_controller.v`

The implementation contains the following functional sections:

1. Memory array declarations.
2. Previous-read address and bank tracking.
3. RAM4 address calculation.
4. Sampler coefficient-pair packing.
5. Sampler ready and busy generation.
6. Synchronous memory read logic.
7. Main memory writeback logic.
8. Synchronous reset and control-register management.

The memory arrays are described using Verilog register arrays. Their implementation as FPGA block RAM or other memory resources must be confirmed through Vivado synthesis reports.

---

## 9. Verification and Testbench

The controller is verified using a dedicated Verilog testbench.

Testbench source file:

`tb_memory_ram_controller.v`

The testbench instantiates the RAM Controller, generates the clock and reset signals, applies input sequences, and checks the expected outputs and behaviour.

The test scenarios cover memory access, address selection, read/write operations, RAM4 access, and sampler coefficient handling.

### Simulation Results

| Parameter | Result |
|-----------|--------|
| Tests passed | 17 |
| Tests failed | 0 |
| Simulation status | Passed |

The reported simulation result is **17 tests passed and 0 failed**.

These results indicate that the tested scenarios passed in the current testbench. They do not, by themselves, establish complete accelerator integration, FPGA timing closure, or successful hardware operation.

---

## 10. Development Tools and Target Hardware

| Item | Details |
|------|---------|
| Hardware description language | Verilog HDL |
| FPGA development environment | Xilinx Vivado 2025.1 |
| Target development board | Digilent ZedBoard |
| FPGA device family | Xilinx Zynq-7000 |
| Selected Vivado part | `xc7z020clg484-1` |
| Verification method | Verilog simulation |

The final implementation must be synthesized and checked against the resource and timing requirements of the selected FPGA device.

The target board and device configuration should remain consistent with the settings used for the complete accelerator.

---

## 11. Repository Structure

The Module 5 folder contains the main RTL implementation, testbench, and module-specific documentation.

```text
Module5_RAM_Controller/
|
|-- README.md
|-- memory_ram_controller.v
`-- tb_memory_ram_controller.v
