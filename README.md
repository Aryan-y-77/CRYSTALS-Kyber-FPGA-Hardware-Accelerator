## Module 4: Client I/O Packer

### Overview
The Client I/O Packer is a Verilog RTL module developed for the CRYSTALS-Kyber FPGA Hardware Accelerator project. It packs compressed coefficient data into 32-bit output words and unpacks incoming words into coefficient pairs.

### Features
- 32-bit external data interface.
- 52-bit internal shift register for buffering packed data.
- Supports 12-bit coefficient mode and Kyber compression modes.
- Supports runtime selection of Kyber parameter sets: K-512, K-768, and K-1024.
- Encoder and decoder operation selected through `io_mode`.
- Configuration handshake through `cfg_valid` and `cfg_ready`.
- Status and flow-control signals, including `out_valid`, `out_ready`, and `buffer_full`.

### Files
| File | Description |
|---|---|
| `client_io_packer.v` | Synthesizable Verilog RTL for the Client I/O Packer |
| `tb_client_io_packer.v` | Testbench for functional simulation |

### Configuration
The module uses `cfg_k_sel` to select the Kyber parameter set:

| `cfg_k_sel` | Parameter set |
|---|---|
| `2'b00` | K-512 |
| `2'b01` | K-768 |
| `2'b10` | K-1024 |

Compression modes:

| `compress_mode` | Description |
|---|---|
| `2'b00` | 12-bit coefficient mode |
| `2'b01` | \(d_u\) compression |
| `2'b10` | \(d_v\) compression |
| `2'b11` | Reserved |

### Verification
The RTL was synthesized using Xilinx Vivado 2025.1 for the Zynq-7000 target `xc7z020clg484-1`.

The current behavioral testbench completed successfully and reported:

`ALL FUNCTIONAL TESTS PASSED`

The testbench exercises encoding, decoding, coefficient round trips, and selected Kyber parameter configurations. This result applies to the scenarios covered by the testbench; further timing and FPGA implementation checks are still required.

### Simulation
1. Open the Vivado project.
2. Add `client_io_packer.v` under Design Sources.
3. Add `tb_client_io_packer.v` under Simulation Sources.
4. Set `tb_client_io_packer` as the simulation top.
5. Run **Behavioral Simulation** and inspect the console output for the test results.

### Target Platform
- FPGA family: Zynq-7000
- Target part: `xc7z020clg484-1`
- HDL: Verilog
- Tool: Xilinx Vivado 2025.1