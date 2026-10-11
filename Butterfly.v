//=============================================================================
// File        : butterfly_ntt.v
// Module      : butterfly_ntt
// Owner       : Aryan  --  MODULE 2 : NTT Butterfly Datapath Core
// Reference   : Xing & Li, "A Compact Hardware Implementation of CCA-Secure
//               Key Exchange Mechanism CRYSTALS-KYBER on FPGA", TCHES 2021(2),
//               pp. 328-356, DOI:10.46586/tches.v2021.i2.328-356
//               -> Algorithms 2 & 3 (rearranged iterative DIT NTT / DIF INTT)
//               -> Section 3.1 (unified butterfly unit), Table 1, Fig. 3
//               -> Section 3.3 (Karatsuba point-wise multiplication)
//
// Scope       : Implements Sections A (math baseline), B (port header) and
//               C (port definition table) of "MODULE 2" in the Top-Level
//               System Integration & Port Specification, v1.0.
//               Section D (Novelty Exploration Directive -- dual-mode
//               intt_sel redesign, folded n^-1 scaling, etc.) is
//               intentionally OUT OF SCOPE for this file.
//
// -----------------------------------------------------------------------
// IMPLEMENTATION NOTES / OPEN ITEMS FOR TEAM REVIEW
// -----------------------------------------------------------------------
// 1. reduc.v is treated as purely combinational, per its OWN port table
//    ("in_ready ... Tied HIGH permanently; combinational design has zero
//    latency; no stall possible"). butterfly_ntt.v therefore drives
//    `prod` combinationally and reads back `res` in the SAME cycle, then
//    registers its own coeff_U/coeff_T once, on the next clock edge.
//    This satisfies the master timing contract (Rule 2: butterfly out_valid
//    asserted exactly one cycle after in_valid).
//
// 2. Two reduc.v instances (reduc_a, reduc_b) are instantiated, matching
//    the paper's own statement (Sec. 5.1: "two reduction units are
//    adopted") -- one feeds the coeff_U path, one feeds the coeff_T path.
//
// 3. PORT-LEVEL AMBIGUITY -- Karatsuba PWM0 mathematically needs four
//    scalar inputs per cycle (f2i, f2i+1, g2i, g2i+1), but the Section B
//    port header only exposes three 12-bit data buses (coeff_u, coeff_t,
//    twiddle_factor) into a SINGLE butterfly_ntt.v instance, and the
//    Section C port table documents coeff_u/coeff_t as carrying ONLY
//    f2i/f2i+1 during PWM0 -- it is silent on where the g-pair enters.
//    The exact internal routing is shown in the reference paper's
//    Figure 10, which is not reproduced as text in the spec doc, so it
//    cannot be transcribed exactly here. This file makes the following
//    EXPLICIT, FLAGGED ASSUMPTION instead of inventing new ports:
//       -> During PWM0, `twiddle_factor` is repurposed to carry g2i
//          (the same-index coefficient of the second polynomial).
//       -> This instance therefore produces s0 = f2i+f2i+1 (-> coeff_U)
//          and m0 = f2i*g2i, reduced (-> coeff_T).
//       -> The sibling butterfly_ntt.v instance that handles the other
//          half of the butterfly pair (per master_top.v, which
//          instantiates TWO of these units per the architecture text in
//          Section 3, Module 2A) is fed the g-pair on ITS coeff_u/
//          coeff_t and f2i+1 on ITS twiddle_factor input, producing s1
//          and m1. master_top.v / memory_ram_controller.v are
//          responsible for cross-routing s0/s1/m0/m1 through RAM4 for
//          consumption in the PWM1 cycle.
//    RECOMMENDATION: confirm against Figure 10 and, if the real wiring
//    differs, file a formal Change Request per Section 4 rather than
//    patching this file ad hoc, since other engineers' RAM/RTL depend on
//    a stable port list.
//
// 4. INTTm (message-bit fusion) and COMPs (noise fusion ahead of
//    Compress) both require, per the spec prose, an extra operand
//    (a decompressed message bit, and a noise sample respectively) that
//    has NO dedicated port anywhere in the Section B header. Likewise,
//    DECOMP conceptually needs the quotient path that Appendix A's
//    cross-reference table describes as "quo_w[11:0]: reduc.v/quo ->
//    butterfly_ntt.v (compress)", but no such input exists on this
//    module's port list either. These three modes are implemented below
//    as best-effort placeholders using only the existing ports, clearly
//    marked with TODOs. They should not be relied on for
//    compress/decompress correctness until the missing ports
//    (msg_bit_in, noise_in, quo_in) are added via a reviewed interface
//    change -- silently repurposing more ports for these low-frequency
//    modes was judged less safe than flagging the gap explicitly.
//
// 5. Section B's port header for butterfly_ntt.v has NO in_ready output,
//    even though Interface Contract Rule 1.3 lists butterfly_ntt.v as a
//    module that "must be able to accept and correctly process one
//    complete data word on the very next rising edge" (i.e. behaves as
//    if in_ready were tied high). Because there is genuinely no signal
//    here to communicate back-pressure upstream, this module protects an
//    unconsumed result (out_valid=1, out_ready=0) by holding it and
//    DROPPING any new in_valid presented during the stall, rather than
//    silently overwriting unconsumed data. Per Rule 1.3, the real
//    fix is for upstream (memory_ram_controller.v via master_top.v's
//    FSM) to guarantee out_ready is high before presenting new data, so
//    this drop path should never actually be exercised in a correct
//    system; it exists purely as a safety net.
//=============================================================================

`timescale 1ns / 1ps

module butterfly_ntt (
    input  wire        clk,             // System clock (positive-edge)
    input  wire        rst,             // Synchronous active-HIGH reset
    input  wire        in_valid,        // Input coefficient pair is stable
    input  wire [11:0] coeff_u,         // 12-bit even-index input coefficient
    input  wire [11:0] coeff_t,         // 12-bit odd-index input coefficient
    input  wire [11:0] twiddle_factor,  // 12-bit twiddle (ROM_fwd / ROM_bwd)
    input  wire [9:0]  op_sel,          // 10-bit operation selector (Table 1)
    input  wire [2:0]  stage_idx,       // Current NTT/INTT stage [0..6]
    output reg         out_valid,       // Output coefficient pair is stable
    output reg  [11:0] coeff_U,         // 12-bit upper butterfly output
    output reg  [11:0] coeff_T,         // 12-bit lower butterfly output
    input  wire        out_ready        // Downstream consumer ready
);

    // ------------------------------------------------------------------
    // Local parameters : prime modulus & named opcodes (Table 1 codes,
    // exactly as enumerated for op_sel in the Section C port table).
    // ------------------------------------------------------------------
    localparam [11:0] Q = 12'd3329;

    localparam [9:0] OP_NTT    = 10'b11_0000_0000; // CT forward NTT
    localparam [9:0] OP_INTT   = 10'b00_0111_0000; // GS inverse INTT
    localparam [9:0] OP_PWM0   = 10'b00_0001_1010; // Karatsuba PWM, cycle 0
    localparam [9:0] OP_PWM1   = 10'b10_0011_1101; // Karatsuba PWM, cycle 1
    localparam [9:0] OP_INTTM  = 10'b11_1111_0000; // INTT + message fuse
    localparam [9:0] OP_COMPS  = 10'b00_0110_1000; // Compress + noise fuse
    localparam [9:0] OP_DECOMP = 10'b00_0000_0000; // Decompress

    // stage_idx is consumed by master_top.v's twiddle-ROM address
    // sequencer upstream (per the port table: "Used to select correct
    // ROM address offset for twiddle ROM lookup"); this unit only needs
    // the already-resolved twiddle_factor value, so stage_idx has no
    // internal datapath role here beyond being available for debug/ILA
    // observation if the team later wants it tapped.
    // verilator lint_off UNUSEDSIGNAL
    wire [2:0] _unused_stage_idx = stage_idx;
    // verilator lint_on UNUSEDSIGNAL

    // ------------------------------------------------------------------
    // Combinational modular arithmetic helpers -- all constant-time
    // (single conditional add/sub, no division, no variable-length loop)
    // ------------------------------------------------------------------
    function automatic [11:0] mod_add(input [11:0] a, input [11:0] b);
        reg [12:0] s;
        begin
            s = a + b;
            mod_add = (s >= Q) ? (s - Q) : s[11:0];
        end
    endfunction

    function automatic [11:0] mod_sub(input [11:0] a, input [11:0] b);
        begin
            mod_sub = (a >= b) ? (a - b) : (a + Q - b);
        end
    endfunction

    // 2^-1 mod q = 1665. Implemented via the standard constant-time
    // identity  half(x) = (x + q*[x odd]) >> 1 , which is mathematically
    // equivalent to x*1665 mod q but avoids a second multiply/reduce.
    // (This identity is part of the *baseline* GS-INTT math -- Algorithm
    // 3 literally divides by 2 every stage -- so using it here is not a
    // Section-D novelty item, just an efficient way to realize Algorithm 3.)
    function automatic [11:0] mod_half(input [11:0] a);
        reg [12:0] tmp;
        begin
            tmp = a[0] ? (a + Q) : {1'b0, a};
            mod_half = tmp[12:1];
        end
    endfunction

    // ------------------------------------------------------------------
    // Modular multiply: raw 24-bit products feed two external reduc.v
    // instances (Modified Barrett Reduction, Module 1 / Bhavesh).
    // reduc.v is combinational (see note 1), so res_a/res_b are valid
    // in the same cycle prod_a/prod_b are driven.
    // ------------------------------------------------------------------
    reg  [23:0] prod_a, prod_b;
    wire [11:0] res_a,  res_b;
    wire [11:0] quo_a,  quo_b;   // quotient outputs -- see note 4 (DECOMP)
    wire        redv_a, redv_b;  // unused here; reduc.v is comb (note 1)

    reduc reduc_a (
        .clk      (clk),
        .rst      (rst),
        .in_valid (in_valid),
        .prod     (prod_a),
        .out_valid(redv_a),
        .res      (res_a),
        .quo      (quo_a),
        .in_ready ()
    );

    reduc reduc_b (
        .clk      (clk),
        .rst      (rst),
        .in_valid (in_valid),
        .prod     (prod_b),
        .out_valid(redv_b),
        .res      (res_b),
        .quo      (quo_b),
        .in_ready ()
    );

    // ------------------------------------------------------------------
    // Combinational per-mode datapath
    // ------------------------------------------------------------------
    reg [11:0] U_comb, T_comb;

    always @(*) begin
        // Safe defaults; also covers any undecoded op_sel value.
        prod_a = 24'd0;
        prod_b = 24'd0;
        U_comb = 12'd0;
        T_comb = 12'd0;

        case (op_sel)

            // ---------------------------------------------------------
            // CT forward NTT (DIT), one stage (Algorithm 2):
            //   coeff_U = coeff_u + twiddle*coeff_t (mod q)
            //   coeff_T = coeff_u - twiddle*coeff_t (mod q)
            // ---------------------------------------------------------
            OP_NTT: begin
                prod_a = coeff_t * twiddle_factor;
                U_comb = mod_add(coeff_u, res_a);
                T_comb = mod_sub(coeff_u, res_a);
            end

            // ---------------------------------------------------------
            // GS inverse INTT (DIF), one stage (Algorithm 3), with the
            // n^-1 scaling distributed as a per-stage x2^-1 halving:
            //   coeff_U = (coeff_u + coeff_t) * 2^-1           (mod q)
            //   coeff_T = twiddle * (coeff_u - coeff_t) * 2^-1 (mod q)
            // ---------------------------------------------------------
            OP_INTT: begin
                U_comb = mod_half(mod_add(coeff_u, coeff_t));
                prod_b = mod_half(mod_sub(coeff_u, coeff_t)) * twiddle_factor;
                T_comb = res_b;
            end

            // ---------------------------------------------------------
            // Karatsuba PWM, cycle 0 -- see file header note 3 for the
            // twiddle_factor-as-g2i assumption made here:
            //   s0 = f2i + f2i+1          -> coeff_U
            //   m0 = reduc(f2i * g2i)     -> coeff_T
            // ---------------------------------------------------------
            OP_PWM0: begin
                U_comb = mod_add(coeff_u, coeff_t);   // s0 = f2i + f2i+1
                prod_a = coeff_u * twiddle_factor;     // f2i * g2i
                T_comb = res_a;                        // m0
            end

            // ---------------------------------------------------------
            // Karatsuba PWM, cycle 1. Per the port table:
            //   coeff_u = m0 (from RAM4), coeff_t = m1 (from RAM4)
            //   twiddle_factor = zeta^(2*br(i)+1)
            //   m3    = reduc(m1 * twiddle)
            //   h2i   = m0 + m3                    -> coeff_U
            //   (h2i+1 = m2 - s2 needs m2 = s0*s1, the cross product
            //    produced by the *sibling* butterfly unit from its own
            //    s0/s1 pair -- see note 3. This unit computes the
            //    -s2 subtrahend it owns; master_top.v's accumulator
            //    combines it with the sibling's m2 before RAM writeback,
            //    consistent with the top-level dataflow in the
            //    Appendix A wiring table.)
            // ---------------------------------------------------------
            OP_PWM1: begin
                prod_b = coeff_t * twiddle_factor;               // m3
                U_comb = mod_add(coeff_u, res_b);                // h2i = m0+m3
                T_comb = mod_sub(12'd0, mod_add(coeff_u, coeff_t)); // -s2
            end

            // ---------------------------------------------------------
            // INTTm : identical GS-INTT butterfly, with the decompressed
            // message bit meant to fuse into the otherwise-idle
            // add2/sub2/add3/sub3 operators (per reference paper text).
            // No dedicated message-bit port exists on this interface
            // (note 4) -- behaves as plain INTT until that port is
            // added via a reviewed Change Request.
            // ---------------------------------------------------------
            OP_INTTM: begin
                U_comb = mod_half(mod_add(coeff_u, coeff_t));
                prod_b = mod_half(mod_sub(coeff_u, coeff_t)) * twiddle_factor;
                T_comb = res_b;
                // TODO(interface): += Decompress_q(Decode_1(msg_bit), 1)
                // once a msg_bit_in port is agreed and added.
            end

            // ---------------------------------------------------------
            // COMPs : noise sample fused into the DIF butterfly ahead of
            // Compress(). No dedicated noise-sample port exists (note
            // 4); coeff_t is provisionally reused to carry the noise
            // sample e' for this cycle only.
            // ---------------------------------------------------------
            OP_COMPS: begin
                U_comb = mod_sub(coeff_u, coeff_t);  // u - e'  (approx.)
                T_comb = 12'd0;
                // TODO(interface): the actual Compress_q(u-e', d_u)
                // division by 2^d still has to happen downstream in
                // client_io_packer.v; this stage only performs the
                // noise subtraction, not the division.
            end

            // ---------------------------------------------------------
            // DECOMP : Decompress_q(Decode(c), d) = round(q * c / 2^d).
            // Requires the compressed value's bit-width d (owned by
            // client_io_packer.v's compress_mode) and effectively a
            // multiply-by-q, i.e. the reverse direction implied by
            // Appendix A's "quo_w -> butterfly_ntt.v (compress)" wire,
            // which is absent from this module's Section B port list
            // (note 4). Passed through unmodified pending that fix.
            // ---------------------------------------------------------
            OP_DECOMP: begin
                U_comb = coeff_u;
                T_comb = coeff_t;
            end

            default: begin
                U_comb = 12'd0;
                T_comb = 12'd0;
            end
        endcase
    end

    // ------------------------------------------------------------------
    // 4-phase handshake / single registered output stage.
    // See file header note 5 regarding the missing in_ready port.
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            out_valid <= 1'b0;
            coeff_U   <= 12'd0;
            coeff_T   <= 12'd0;
        end else if (out_valid && !out_ready) begin
            out_valid <= out_valid;
            coeff_U   <= coeff_U;
            coeff_T   <= coeff_T;
        end else if (in_valid) begin
            coeff_U   <= U_comb;
            coeff_T   <= T_comb;
            out_valid <= 1'b1;
        end else begin
            out_valid <= 1'b0;
        end
    end

endmodule