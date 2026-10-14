//======================================================================
// tb_keccak_sampler.v  --  Self-checking unit testbench for MODULE 3
//
// Satisfies Spec Section 4, Rule 5 "Unit Test" phase:
//   * KAT vectors match the NIST / Kyber reference
//   * Handshake never deadlocks
//   * Reset works correctly
//
// Golden vectors generated from Python hashlib (FIPS-202) and a
// Kyber reference implementation of Parse() and CBD_eta().
// Seed used everywhere: the 32 bytes 0x00,0x01,...,0x1F.
//
//   iverilog -g2005 -o sim tb_keccak_sampler.v keccak_sampler.v && vvp sim
//======================================================================
`timescale 1ns/1ps

module tb_keccak_sampler;

//---------------------------------------------------------------- clocking
reg clk = 1'b0;
always #5 clk = ~clk;                      // 100 MHz simulation clock

//---------------------------------------------------------------- DUT A (ETA1=2, Kyber-768)
reg         rst, in_valid, write_enable;
reg  [31:0] seed_data;
reg  [ 2:0] hash_mode;
wire        out_valid, write_ready, out_ready;
wire [11:0] sample_coeff;
wire [ 7:0] sample_addr;

keccak_sampler #(.K(3), .ETA1(2), .ETA2(2)) dut (
    .clk(clk), .rst(rst), .in_valid(in_valid), .seed_data(seed_data),
    .hash_mode(hash_mode), .write_enable(write_enable),
    .out_valid(out_valid), .sample_coeff(sample_coeff),
    .sample_addr(sample_addr), .write_ready(write_ready),
    .out_ready(out_ready));

//---------------------------------------------------------------- DUT B (ETA1=3, Kyber-512)
reg         rst3, in_valid3, we3;
reg  [31:0] seed3;
reg  [ 2:0] hm3;
wire        ov3, wr3, or3;
wire [11:0] sc3;
wire [ 7:0] sa3;

keccak_sampler #(.K(2), .ETA1(3), .ETA2(2)) dut3 (
    .clk(clk), .rst(rst3), .in_valid(in_valid3), .seed_data(seed3),
    .hash_mode(hm3), .write_enable(we3),
    .out_valid(ov3), .sample_coeff(sc3), .sample_addr(sa3),
    .write_ready(wr3), .out_ready(or3));

//---------------------------------------------------------------- scoreboard
integer errors  = 0;
integer checks  = 0;
integer poly_id = 0;                       // which polynomial is streaming
integer cyc     = 0;
integer t_start, t_stop;

reg [11:0] cap  [0:31][0:255];             // captured polynomials (DUT A)
reg [11:0] cap3 [0:255];                   // captured polynomial   (DUT B)
integer    poly_len [0:31];
reg [ 7:0] dig [0:63];                     // captured digest bytes
integer    dig_n;

reg  [7:0] exp_addr;                       // protocol monitor: next address
integer    mon_active;

always @(posedge clk) cyc = cyc + 1;

//---- capture + protocol monitor for DUT A --------------------------------
always @(posedge clk) begin
    if (!rst && out_valid) begin
        // Rule 3.3 : sample_addr must be a clean 0..255 sequential counter
        if (mon_active && (sample_addr !== exp_addr)) begin
            $display("  [PROTO] addr gap: expected %0d got %0d @cyc %0d",
                      exp_addr, sample_addr, cyc);
            errors = errors + 1;
        end
        cap[poly_id][sample_addr] = sample_coeff;
        dig[sample_addr]          = sample_coeff[7:0];
        poly_len[poly_id]         = poly_len[poly_id] + 1;
        dig_n                     = dig_n + 1;
        mon_active = 1; exp_addr = sample_addr + 8'd1;
        if (sample_addr == 8'd255) begin
            poly_id = poly_id + 1; mon_active = 0; exp_addr = 8'd0;
        end
    end
    // Rule 1.5 : ready lines idle HIGH, valid lines idle LOW under reset
    if (rst && cyc > 3) begin
        if (out_valid !== 1'b0)   begin $display("  [PROTO] out_valid high during reset");   errors = errors+1; end
        if (write_ready !== 1'b1) begin $display("  [PROTO] write_ready low during reset");  errors = errors+1; end
        if (out_ready   !== 1'b1) begin $display("  [PROTO] out_ready low during reset");    errors = errors+1; end
    end
end

always @(posedge clk) if (!rst3 && ov3) cap3[sa3] = sc3;

//---------------------------------------------------------------- helpers
task do_reset;
begin
    rst = 1; in_valid = 0; write_enable = 0; seed_data = 0; hash_mode = 0;
    poly_id = 0; dig_n = 0; mon_active = 0; exp_addr = 0;
    begin : zl integer z; for (z=0; z<32; z=z+1) poly_len[z] = 0; end
    repeat (4) @(negedge clk);
    rst = 0;
    @(negedge clk);
end endtask

// push one 32-bit word honouring write_ready (4-phase handshake)
task push(input [31:0] w);
begin
    @(negedge clk);
    while (!write_ready) @(negedge clk);
    seed_data = w; in_valid = 1; write_enable = 1;
    @(negedge clk);
    in_valid = 0; write_enable = 0;
end endtask

// push the 32-byte test seed 0x00..0x1F as 8 little-endian words
task push_seed;
    integer i; reg [31:0] w;
begin
    for (i = 0; i < 8; i = i + 1) begin
        w[ 7: 0] = 4*i;   w[15: 8] = 4*i+1;
        w[23:16] = 4*i+2; w[31:24] = 4*i+3;
        push(w);
    end
end endtask

task push3(input [31:0] w);
begin
    @(negedge clk); while (!wr3) @(negedge clk);
    seed3 = w; in_valid3 = 1; we3 = 1;
    @(negedge clk); in_valid3 = 0; we3 = 0;
end endtask

// wait until n polynomials have been captured (with a deadlock watchdog)
task wait_polys(input integer n, input integer limit);
    integer guard;
begin
    guard = 0;
    while ((poly_id < n) && (guard < limit)) begin @(posedge clk); guard = guard + 1; end
    if (poly_id < n) begin
        $display("  [DEADLOCK] only %0d/%0d polynomials after %0d cycles", poly_id, n, limit);
        errors = errors + 1;
    end
end endtask

task chk(input [255:0] name, input integer got, input integer exp);
begin
    checks = checks + 1;
    if (got !== exp) begin
        $display("  FAIL %0s : got %0d expected %0d", name, got, exp);
        errors = errors + 1;
    end
end endtask

// verify one captured polynomial against first-8 / last-8 / checksum
task check_poly(input [255:0] name, input integer p,
                input integer f0,f1,f2,f3,f4,f5,f6,f7,
                input integer l0,l1,l2,l3,l4,l5,l6,l7,
                input integer csum);
    integer i, s;
begin
    s = 0;
    for (i = 0; i < 256; i = i + 1) s = s + cap[p][i];
    chk({name,"[0]"}, cap[p][0], f0);  chk({name,"[1]"}, cap[p][1], f1);
    chk({name,"[2]"}, cap[p][2], f2);  chk({name,"[3]"}, cap[p][3], f3);
    chk({name,"[4]"}, cap[p][4], f4);  chk({name,"[5]"}, cap[p][5], f5);
    chk({name,"[6]"}, cap[p][6], f6);  chk({name,"[7]"}, cap[p][7], f7);
    chk({name,"[248]"},cap[p][248],l0); chk({name,"[249]"},cap[p][249],l1);
    chk({name,"[250]"},cap[p][250],l2); chk({name,"[251]"},cap[p][251],l3);
    chk({name,"[252]"},cap[p][252],l4); chk({name,"[253]"},cap[p][253],l5);
    chk({name,"[254]"},cap[p][254],l6); chk({name,"[255]"},cap[p][255],l7);
    chk({name,"-checksum"}, s, csum);
    chk({name,"-length"}, poly_len[p], 256);
end endtask

task show_digest(input [255:0] name, input integer nbytes);
    integer i;
begin
    $write("    %0s = ", name);
    for (i = 0; i < nbytes; i = i + 1) $write("%02x", dig[i]);
    $write("\n");
end endtask

task chk_digest(input [255:0] name, input integer nbytes, input [511:0] golden);
    integer i; reg [7:0] g;
begin
    checks = checks + 1;
    for (i = 0; i < nbytes; i = i + 1) begin
        g = golden[(nbytes-1-i)*8 +: 8];
        if (dig[i] !== g) begin
            $display("  FAIL %0s byte %0d : got %02x expected %02x", name, i, dig[i], g);
            errors = errors + 1;
            i = nbytes;                       // stop at first mismatch
        end
    end
    chk({name,"-bytecount"}, dig_n, nbytes);
end endtask

//======================================================================
//  TEST SEQUENCE
//======================================================================
integer i, s3;

initial begin
    $dumpfile("keccak_sampler.vcd");
    $dumpvars(1, tb_keccak_sampler);

    rst3 = 1; in_valid3 = 0; we3 = 0; seed3 = 0; hm3 = 0;

    $display("======================================================");
    $display(" MODULE 3 : keccak_sampler.v  --  unit test");
    $display("======================================================");

    //------------------------------------------------------------------
    $display("\n[T1] Reset / idle handshake state");
    do_reset;
    chk("idle-out_valid",   out_valid,   0);
    chk("idle-write_ready", write_ready, 1);
    chk("idle-out_ready",   out_ready,   1);

    //------------------------------------------------------------------
    $display("\n[T2] SHA3-256 KAT  (legacy mode 010, 32-byte message)");
    do_reset;
    hash_mode = 3'b010;
    push_seed;
    repeat (700) @(posedge clk);
    show_digest("SHA3-256", 32);
    chk_digest("SHA3-256", 32,
      512'h050a48733bd5c2756ba95c5828cc83ee16fabcd3c086885b7744f84a0f9e0d94);

    //------------------------------------------------------------------
    $display("\n[T3] SHA3-512 KAT  (legacy mode 011, 32-byte message)");
    do_reset;
    hash_mode = 3'b011;
    push_seed;
    repeat (700) @(posedge clk);
    show_digest("SHA3-512", 64);
    chk_digest("SHA3-512", 64,
      512'hcbd3f6eeba676b21e0f2c47522292482fd830f330c1d84a794bb94728b2d93febe4c18eae5a7e017e35fa090de24262e70951ad1d7dfb3a8c96d1134fb1879f2);

    //------------------------------------------------------------------
    $display("\n[T4/T5] Sampler KATs via autonomous TEST program (111)");
    do_reset;
    hash_mode = 3'b111;
    t_start = cyc;
    push_seed;                     // entry 24 : Parse(seed, j=0, i=0)
    wait_polys(1, 20000);
    t_stop = cyc;
    check_poly("UNIFORM", 0,
        481,1919,1434,2359,327,1066,3001,649,
        1796,3263,3011,1370,1926,2513,2367,3216, 428176);
    $display("    uniform polynomial: %0d cycles (3 Keccak blocks consumed)",
             t_stop - t_start);

    t_start = cyc;
    push_seed;                     // entry 25 : CBD_eta1(seed, nonce=0)
    wait_polys(2, 20000);
    t_stop = cyc;
    check_poly("CBD-eta2", 1,
        3328,0,1,1,3327,1,0,0,
        0,0,0,3328,2,0,0,1, 229704);
    $display("    CBD polynomial    : %0d cycles", t_stop - t_start);

    //------------------------------------------------------------------
    $display("\n[T6] CBD eta=3 KAT  (second instance, K=2 / ETA1=3)");
    repeat (4) @(negedge clk); rst3 = 0; hm3 = 3'b111;
    for (i = 0; i < 8; i = i + 1) begin
        seed3[ 7: 0] = 4*i;   seed3[15: 8] = 4*i+1;
        seed3[23:16] = 4*i+2; seed3[31:24] = 4*i+3;
        push3(seed3);
    end
    repeat (20000) @(posedge clk);   // skip entry 24 (uniform) ...
    for (i = 0; i < 8; i = i + 1) begin
        seed3[ 7: 0] = 4*i;   seed3[15: 8] = 4*i+1;
        seed3[23:16] = 4*i+2; seed3[31:24] = 4*i+3;
        push3(seed3);
    end
    repeat (20000) @(posedge clk);   // ... then entry 25 (CBD eta1=3)
    s3 = 0; for (i = 0; i < 256; i = i + 1) s3 = s3 + cap3[i];
    chk("CBD-eta3[0]",   cap3[0],   0);
    chk("CBD-eta3[1]",   cap3[1],   2);
    chk("CBD-eta3[6]",   cap3[6],   3);
    chk("CBD-eta3[253]", cap3[253], 3328);
    chk("CBD-eta3-checksum", s3, 259680);

    //------------------------------------------------------------------
    $display("\n[T7] AUTONOMOUS KEYGEN  (mode 100) -- one start, zero CPU help");
    do_reset;
    hash_mode = 3'b100;
    t_start = cyc;
    push_seed;                     // only input the whole flow ever needs
    wait_polys(15, 300000);
    t_stop = cyc;

    $display("    polynomials produced autonomously = %0d  (expect %0d)", poly_id, 15);
    chk("keygen-poly-count", poly_id, 15);

    check_poly("A^[0][0]", 0,
        2553,2758,1118,1335,2151,792,1681,1071,
        1375,2692,2042,2243,1080,2398,1043,1945, 420896);
    check_poly("A^[0][1]", 1,
        1443,768,3151,2500,1526,2050,2108,1764,
        833,3240,730,1269,3299,2478,1343,1644, 411743);
    check_poly("s[0]", 9,
        1,3328,0,3328,3328,1,2,0,
        3327,3328,0,3328,3328,0,3327,3328, 286289);
    check_poly("e[0]", 12,
        0,0,1,1,3328,3327,0,0,
        3328,3328,3328,0,3327,1,3327,0, 306246);

    $display("    total KeyGen hash schedule = %0d cycles", t_stop - t_start);
    $display("    external start pulses required = 1  (baseline: 15)");

    //------------------------------------------------------------------
    $display("\n[T8] Reset during operation returns the engine to idle");
    hash_mode = 3'b100;
    push_seed;
    repeat (50) @(posedge clk);
    rst = 1; repeat (3) @(negedge clk);
    chk("rst-out_valid",   out_valid,   0);
    chk("rst-write_ready", write_ready, 1);
    rst = 0;

    //------------------------------------------------------------------
    $display("\n======================================================");
    if (errors == 0) $display(" RESULT: PASS  (%0d checks, 0 errors)", checks);
    else             $display(" RESULT: FAIL  (%0d checks, %0d errors)", checks, errors);
    $display("======================================================");
    $finish;
end

//---------------------------------------------------------------- watchdog
initial begin
    #40_000_000;
    $display(" [WATCHDOG] simulation exceeded time budget -- possible deadlock");
    $finish;
end

endmodule
