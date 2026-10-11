//=============================================================================
// File   : tb_butterfly_ntt.v
// Purpose: Self-checking testbench for butterfly_ntt.v (Module 2 / Aryan).
//
// Coverage:
//   1. Reset behavior              (out_valid must clear synchronously)
//   2. Directed sanity vector      (f = [1,1,...] per Rule 5's own
//                                    "Pair Integration" test criterion)
//   3. Randomized CT-NTT checks    (op_sel = OP_NTT)
//   4. Randomized GS-INTT checks   (op_sel = OP_INTT)
//   5. PWM0 checks                 (under the twiddle-as-g2i assumption
//                                    documented in butterfly_ntt.v's
//                                    header note 3)
//   6. Handshake / stall behavior  (Rule 1.2: hold when out_ready=0;
//                                    Rule 1.5: clean recovery after rst)
//
// This is a Verilog-2001 testbench (no SystemVerilog assertions), so all
// checking is done with plain Verilog tasks + a running error counter,
// compatible with Icarus Verilog (iverilog/vvp) or Vivado xsim.
//
// Run (Icarus):
//   iverilog -o sim tb_butterfly_ntt.v butterfly_ntt.v reduc_tb_stub.v
//   vvp sim
//=============================================================================

`timescale 1ns / 1ps

module tb_butterfly_ntt;

    // ------------------------------------------------------------------
    // Opcodes -- must mirror butterfly_ntt.v exactly
    // ------------------------------------------------------------------
    localparam [11:0] Q = 12'd3329;

    localparam [9:0] OP_NTT    = 10'b11_0000_0000;
    localparam [9:0] OP_INTT   = 10'b00_0111_0000;
    localparam [9:0] OP_PWM0   = 10'b00_0001_1010;
    localparam [9:0] OP_PWM1   = 10'b10_0011_1101;

    // ------------------------------------------------------------------
    // DUT I/O
    // ------------------------------------------------------------------
    reg         clk;
    reg         rst;
    reg         in_valid;
    reg  [11:0] coeff_u;
    reg  [11:0] coeff_t;
    reg  [11:0] twiddle_factor;
    reg  [9:0]  op_sel;
    reg  [2:0]  stage_idx;
    wire        out_valid;
    wire [11:0] coeff_U;
    wire [11:0] coeff_T;
    reg         out_ready;

    integer errors;
    integer checks;

    butterfly_ntt dut (
        .clk            (clk),
        .rst            (rst),
        .in_valid       (in_valid),
        .coeff_u        (coeff_u),
        .coeff_t        (coeff_t),
        .twiddle_factor (twiddle_factor),
        .op_sel         (op_sel),
        .stage_idx      (stage_idx),
        .out_valid      (out_valid),
        .coeff_U        (coeff_U),
        .coeff_T        (coeff_T),
        .out_ready      (out_ready)
    );

    // ------------------------------------------------------------------
    // Clock : 10 ns period (100 MHz sim clock; well above the 161 MHz
    // Fmax target isn't being checked here -- this is a functional
    // testbench, not a timing/STA run)
    // ------------------------------------------------------------------
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ------------------------------------------------------------------
    // Golden reference model -- deliberately re-implemented independently
    // (not by copy-pasting the DUT's functions) so a bug shared between
    // DUT and checker doesn't silently pass.
    // ------------------------------------------------------------------
    function automatic [11:0] ref_add(input [11:0] a, input [11:0] b);
        reg [12:0] s;
        begin
            s = a + b;
            ref_add = (s >= Q) ? s - Q : s[11:0];
        end
    endfunction

    function automatic [11:0] ref_sub(input [11:0] a, input [11:0] b);
        begin
            ref_sub = (a >= b) ? (a - b) : (a + Q - b);
        end
    endfunction

    function automatic [11:0] ref_mul(input [11:0] a, input [11:0] b);
        reg [23:0] p;
        begin
            p = a * b;
            ref_mul = p % Q;
        end
    endfunction

    function automatic [11:0] ref_half(input [11:0] a);
        // independent derivation: 2^-1 mod 3329 == 1665
        begin
            ref_half = ref_mul(a, 12'd1665);
        end
    endfunction

    // ------------------------------------------------------------------
    // Helper task: drive one operand set for one cycle, wait for the
    // registered result, and compare against expected (exp_U, exp_T).
    // Assumes out_ready is high and the pipe is not stalled.
    // ------------------------------------------------------------------
    task automatic apply_and_check;
        input [9:0]  t_op_sel;
        input [11:0] t_u, t_t, t_tw;
        input [2:0]  t_stage;
        input [11:0] exp_U, exp_T;
        input [8*40-1:0] label; // ASCII test label for failure messages
        begin
            @(negedge clk);
            op_sel         = t_op_sel;
            coeff_u        = t_u;
            coeff_t        = t_t;
            twiddle_factor = t_tw;
            stage_idx      = t_stage;
            in_valid       = 1'b1;

            @(negedge clk); // one clock later: result is registered
            in_valid = 1'b0;

            checks = checks + 1;
            if (out_valid !== 1'b1) begin
                errors = errors + 1;
                $display("[FAIL] %0s : out_valid did not assert (got %b)",
                          label, out_valid);
            end else if (coeff_U !== exp_U || coeff_T !== exp_T) begin
                errors = errors + 1;
                $display("[FAIL] %0s : u=%0d t=%0d tw=%0d -> got U=%0d T=%0d, expected U=%0d T=%0d",
                          label, t_u, t_t, t_tw, coeff_U, coeff_T, exp_U, exp_T);
            end else begin
                $display("[PASS] %0s : u=%0d t=%0d tw=%0d -> U=%0d T=%0d",
                          label, t_u, t_t, t_tw, coeff_U, coeff_T);
            end
        end
    endtask

    integer i;
    reg [11:0] r_u, r_t, r_tw;
    reg [11:0] exp_U_r, exp_T_r;

    // ------------------------------------------------------------------
    // Main stimulus
    // ------------------------------------------------------------------
    initial begin
        errors    = 0;
        checks    = 0;
        rst       = 1'b1;
        in_valid  = 1'b0;
        out_ready = 1'b1;
        coeff_u        = 12'd0;
        coeff_t        = 12'd0;
        twiddle_factor = 12'd0;
        op_sel         = OP_NTT;
        stage_idx      = 3'd0;

        // -------------------------------------------------------------
        // 1. Reset check
        // -------------------------------------------------------------
        repeat (3) @(negedge clk);
        if (out_valid !== 1'b0) begin
            errors = errors + 1;
            $display("[FAIL] reset : out_valid not cleared under rst (got %b)", out_valid);
        end else begin
            $display("[PASS] reset : out_valid correctly held low under rst");
        end
        rst = 1'b0;
        @(negedge clk);

        // -------------------------------------------------------------
        // 2. Directed sanity vector -- f = [1,1,...,1], twiddle = 1
        //    (mirrors Rule 5's own "Pair Integration" acceptance test:
        //    "produces correct NTT transform for test vector f=[1,1,...]")
        //    CT-NTT: U = u + tw*t = 1 + 1*1 = 2 ; T = u - tw*t = 1-1 = 0
        // -------------------------------------------------------------
        apply_and_check(OP_NTT, 12'd1, 12'd1, 12'd1, 3'd0,
                         12'd2, 12'd0, "NTT_directed_ones");

        // GS-INTT on the same directed vector:
        // U = (1+1)*half = 2*1665 mod q ; T = tw*(1-1)*half = 0
        exp_U_r = ref_half(ref_add(12'd1, 12'd1));
        exp_T_r = ref_mul(12'd1, ref_half(ref_sub(12'd1, 12'd1)));
        apply_and_check(OP_INTT, 12'd1, 12'd1, 12'd1, 3'd0,
                         exp_U_r, exp_T_r, "INTT_directed_ones");

        // -------------------------------------------------------------
        // 3. Randomized CT-NTT checks
        // -------------------------------------------------------------
        for (i = 0; i < 25; i = i + 1) begin
            r_u  = $urandom_range(0, Q-1);
            r_t  = $urandom_range(0, Q-1);
            r_tw = $urandom_range(0, Q-1);
            exp_U_r = ref_add(r_u, ref_mul(r_t, r_tw));
            exp_T_r = ref_sub(r_u, ref_mul(r_t, r_tw));
            apply_and_check(OP_NTT, r_u, r_t, r_tw, i[2:0],
                             exp_U_r, exp_T_r, "NTT_random");
        end

        // -------------------------------------------------------------
        // 4. Randomized GS-INTT checks
        // -------------------------------------------------------------
        for (i = 0; i < 25; i = i + 1) begin
            r_u  = $urandom_range(0, Q-1);
            r_t  = $urandom_range(0, Q-1);
            r_tw = $urandom_range(0, Q-1);
            exp_U_r = ref_half(ref_add(r_u, r_t));
            exp_T_r = ref_mul(ref_half(ref_sub(r_u, r_t)), r_tw);
            apply_and_check(OP_INTT, r_u, r_t, r_tw, i[2:0],
                             exp_U_r, exp_T_r, "INTT_random");
        end

        // -------------------------------------------------------------
        // 5. PWM0 checks (twiddle_factor stands in for g2i -- see
        //    butterfly_ntt.v header note 3):
        //      coeff_U = s0 = f2i + f2i+1
        //      coeff_T = m0 = reduc(f2i * g2i)
        // -------------------------------------------------------------
        for (i = 0; i < 10; i = i + 1) begin
            r_u  = $urandom_range(0, Q-1); // f2i
            r_t  = $urandom_range(0, Q-1); // f2i+1
            r_tw = $urandom_range(0, Q-1); // g2i (repurposed twiddle bus)
            exp_U_r = ref_add(r_u, r_t);
            exp_T_r = ref_mul(r_u, r_tw);
            apply_and_check(OP_PWM0, r_u, r_t, r_tw, 3'd0,
                             exp_U_r, exp_T_r, "PWM0_random");
        end

        // -------------------------------------------------------------
        // 6. Handshake / stall test (Rule 1.2: producer must hold
        //    out_valid + data stable while out_ready is low, and must
        //    not lose the held result)
        // -------------------------------------------------------------
        @(negedge clk);
        op_sel         = OP_NTT;
        coeff_u        = 12'd100;
        coeff_t        = 12'd7;
        twiddle_factor = 12'd3;
        stage_idx      = 3'd1;
        in_valid       = 1'b1;
        out_ready      = 1'b0;       // downstream NOT ready
        @(negedge clk);
        in_valid = 1'b0;

        exp_U_r = ref_add(12'd100, ref_mul(12'd7, 12'd3));
        exp_T_r = ref_sub(12'd100, ref_mul(12'd7, 12'd3));

        checks = checks + 1;
        if (out_valid !== 1'b1 || coeff_U !== exp_U_r || coeff_T !== exp_T_r) begin
            errors = errors + 1;
            $display("[FAIL] stall_hold(cycle0) : out_valid=%b U=%0d T=%0d (expected U=%0d T=%0d)",
                       out_valid, coeff_U, coeff_T, exp_U_r, exp_T_r);
        end else begin
            $display("[PASS] stall_hold(cycle0) : result latched correctly, out_ready low");
        end

        // Hold for a few extra cycles with out_ready still low, and with
        // a *different* in_valid input applied -- per note 5, this new
        // input must be dropped, not corrupt the held result.
        coeff_u  = 12'd999;
        coeff_t  = 12'd999;
        in_valid = 1'b1;
        repeat (3) begin
            @(negedge clk);
            checks = checks + 1;
            if (out_valid !== 1'b1 || coeff_U !== exp_U_r || coeff_T !== exp_T_r) begin
                errors = errors + 1;
                $display("[FAIL] stall_hold(repeat) : held result corrupted -> U=%0d T=%0d (expected U=%0d T=%0d)",
                           coeff_U, coeff_T, exp_U_r, exp_T_r);
            end else begin
                $display("[PASS] stall_hold(repeat) : held result still stable, spurious in_valid ignored");
            end
        end

        // Release backpressure: result should be consumed and out_valid
        // should drop (no further in_valid pending).
        in_valid  = 1'b0;
        out_ready = 1'b1;
        @(negedge clk);
        checks = checks + 1;
        if (out_valid !== 1'b0) begin
            errors = errors + 1;
            $display("[FAIL] stall_release : out_valid did not clear after consumption (got %b)", out_valid);
        end else begin
            $display("[PASS] stall_release : out_valid cleared cleanly after out_ready asserted");
        end

        // -------------------------------------------------------------
        // Summary
        // -------------------------------------------------------------
        $display("--------------------------------------------------");
        if (errors == 0)
            $display("ALL %0d CHECKS PASSED", checks);
        else
            $display("%0d / %0d CHECKS FAILED", errors, checks);
        $display("--------------------------------------------------");

        $finish;
    end

    // Safety timeout in case of a hang (e.g. out_valid never asserts)
    initial begin
        #100000;
        $display("[FAIL] TIMEOUT -- simulation did not finish in time");
        $finish;
    end

endmodule