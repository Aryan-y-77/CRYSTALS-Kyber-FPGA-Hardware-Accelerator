`timescale 1ns/1ps
module tb_reduc;
    reg         clk, rst, in_valid;
    reg  [23:0] prod;
    wire        out_valid, in_ready;
    wire [11:0] res, quo;

    integer n_total, n_fail, k, j, seed;
    reg [23:0] pv;

    reduc uut (.clk(clk), .rst(rst), .in_valid(in_valid), .prod(prod),
               .out_valid(out_valid), .res(res), .quo(quo), .in_ready(in_ready));

    // 10 ns clock
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // Apply one input, wait one clock, check outputs
    task run_vec;
        input [23:0] p;
        input [11:0] er;
        input [11:0] eq;
        begin
            @(negedge clk);
            prod = p; in_valid = 1'b1;
            @(posedge clk); #1;              // outputs are registered at this edge
            n_total = n_total + 1;
            if (out_valid === 1'b1 && in_ready === 1'b1 && res === er && quo === eq) begin
                if (n_total <= 7) $display("PASS [vector %0d]", n_total);
            end else begin
                n_fail = n_fail + 1;
                $display("FAIL [vector %0d]: got res=%0d quo=%0d, expected res=%0d quo=%0d",
                         n_total, res, quo, er, eq);
            end
            in_valid = 1'b0;
        end
    endtask

    initial begin
        n_total = 0; n_fail = 0;
        rst = 1'b1; in_valid = 1'b0; prod = 24'd0;

        // synchronous reset for 2 cycles
        repeat (2) @(posedge clk);
        @(negedge clk) rst = 1'b0;

        // ---- 7 directed vectors
        run_vec(24'd0,        12'd0,    12'd0);
        run_vec(24'd3329,     12'd0,    12'd1);
        run_vec(24'd3328,     12'd3328, 12'd0);
        run_vec(24'd11075584, 12'd1,    12'd3327);   // 3328^2
        run_vec(24'd1,        12'd1,    12'd0);
        run_vec(24'd6658,     12'd0,    12'd2);
        run_vec(24'd5000000,  12'd3171, 12'd1501);

        // ---- corner cases around every multiple of q
        for (k = 0; k < 3328; k = k + 1)
            for (j = 0; j < 5; j = j + 1) begin
                case (j)
                    0: pv = k*3329;
                    1: pv = k*3329 + 1;
                    2: pv = k*3329 + 2;
                    3: pv = k*3329 + 3327;
                    default: pv = k*3329 + 3328;
                endcase
                if (pv <= 24'd11075584) run_vec(pv, pv % 3329, pv / 3329);
            end

        // ---- 100k random vectors in [0, 3328^2]
        seed = 1;
        for (k = 0; k < 100000; k = k + 1) begin
            pv = {$random(seed)} % 11075585;
            run_vec(pv, pv % 3329, pv / 3329);
        end

        // ---- summary
        if (n_fail == 0) $display("ALL %0d VECTORS PASSED", n_total);
        else             $display("FAILED %0d/%0d VECTORS", n_fail, n_total);
        $finish;
    end
endmodule