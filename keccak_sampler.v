//======================================================================
// keccak_sampler.v   --  MODULE 3 (Vedh)
// CRYSTALS-Kyber FPGA Hardware Accelerator
// Autonomous Symmetric Hash Engine + Uniform / CBD Samplers
//
// Spec: "Kyber FPGA Arch Spec Reference Doc" v1.0, Section 3, Module 3
// Ref : Xing & Li, TCHES 2021, DOI 10.46586/tches.v2021.i2.328-356
//       NIST FIPS 202 (SHA-3 / SHAKE)
//
// Verilog-2001.  Single clock domain, synchronous active-HIGH reset.
// Port list is EXACTLY as mandated by Section 3 Module 3.B -- do not edit.
//======================================================================
`timescale 1ns/1ps
`default_nettype none

module keccak_sampler #(
    parameter K    = 3,     // Kyber module dimension (2/3/4)
    parameter ETA1 = 2,     // eta_1 (K-512:3, K-768/1024:2)
    parameter ETA2 = 2,     // eta_2 (always 2)
    parameter MODQ = 3329   // prime modulus q
) (
    input  wire        clk,          // System clock (positive-edge)
    input  wire        rst,          // Synchronous active-HIGH reset
    input  wire        in_valid,     // seed_data is stable / ready to absorb
    input  wire [31:0] seed_data,    // 32-bit seed word
    input  wire [ 2:0] hash_mode,    // 000=SHAKE128 001=SHAKE256/PRF
                                     // 010=SHA3-256 011=SHA3-512
                                     // 1xx = AUTONOMOUS programs (see below)
    input  wire        write_enable, // Secondary gate on seed absorption
    output reg         out_valid,    // sample_coeff / sample_addr are stable
    output reg  [11:0] sample_coeff, // Sampled coefficient  (Z_q or digest byte)
    output reg  [ 7:0] sample_addr,  // Write address into RAM (0..255)
    output wire        write_ready,  // ififo can accept another seed word
    output wire        out_ready     // ofifo can accept another sample
);

//----------------------------------------------------------------------
// hash_mode[2] == 0 : LEGACY single-call mode (baseline compatible).
//                     One hash is performed exactly as the master FSM asks.
// hash_mode[2] == 1 : AUTONOMOUS mode (NOVELTY).  The 1xx codes, declared
//                     "reserved" by the spec, select a program in the
//                     Order Sequence Table ROM:
//                       100 = KEYGEN  101 = ENCAP  110 = DECAP  111 = TEST
//                     One start, whole hash schedule runs with zero further
//                     master-FSM intervention.
//----------------------------------------------------------------------

//======================================================================
// 0.  Local constants
//======================================================================
localparam [2:0] M_SHAKE128 = 3'b000,
                 M_PRF      = 3'b001,   // SHAKE-256 keyed
                 M_SHA3_256 = 3'b010,
                 M_SHA3_512 = 3'b011;

// rate expressed in 32-bit words  (r/32)
//   SHAKE128 : 1344b = 42 w      PRF/SHA3-256 : 1088b = 34 w
//   SHA3-512 :  576b = 18 w
function [5:0] rate_w; input [2:0] m; begin
    case (m)
        M_SHAKE128 : rate_w = 6'd42;
        M_PRF      : rate_w = 6'd34;
        M_SHA3_256 : rate_w = 6'd34;
        default    : rate_w = 6'd18;
    endcase
end endfunction

// domain separation suffix : SHAKE -> 0x1F , SHA3 -> 0x06
function [7:0] dsuffix; input [2:0] m; begin
    dsuffix = m[1] ? 8'h06 : 8'h1F;
end endfunction

// FSM encoding
localparam [3:0] S_IDLE    = 4'd0,
                 S_FETCH   = 4'd1,
                 S_ABSORB  = 4'd2,
                 S_TAIL    = 4'd3,
                 S_PAD     = 4'd4,
                 S_PERM    = 4'd5,
                 S_SAMPLE  = 4'd6,
                 S_DIGEST  = 4'd7,
                 S_NEXTREP = 4'd8,
                 S_DONE    = 4'd9;

//======================================================================
// 1.  Input FIFO  (ififo, depth 32 x 32b  -- Appendix B)
//======================================================================
reg  [31:0] ififo [0:31];
reg  [ 5:0] ifi_wp, ifi_rp;
wire [ 5:0] ifi_cnt   = ifi_wp - ifi_rp;
wire        ifi_full  = (ifi_cnt == 6'd32);
wire        ifi_empty = (ifi_cnt == 6'd0);
wire        ifi_push  = in_valid & write_enable & ~ifi_full;

assign write_ready = ~ifi_full;

always @(posedge clk) begin
    if (rst) begin
        ifi_wp <= 6'd0;
    end else if (ifi_push) begin
        ififo[ifi_wp[4:0]] <= seed_data;
        ifi_wp <= ifi_wp + 6'd1;
    end
end

//======================================================================
// 2.  Output FIFO (ofifo, depth 16 x 20b = {addr[7:0],coeff[11:0]})
//======================================================================
reg  [19:0] ofifo [0:15];
reg  [ 4:0] ofi_wp, ofi_rp;
wire [ 4:0] ofi_cnt   = ofi_wp - ofi_rp;
wire        ofi_full  = (ofi_cnt == 5'd16);
wire        ofi_empty = (ofi_cnt == 5'd0);
reg         ofi_push;
reg  [19:0] ofi_din;

assign out_ready = ~ofi_full;          // back-pressure status to the master

always @(posedge clk) begin
    if (rst) begin
        ofi_wp <= 5'd0; ofi_rp <= 5'd0;
        out_valid <= 1'b0; sample_coeff <= 12'd0; sample_addr <= 8'd0;
    end else begin
        if (ofi_push && !ofi_full) begin
            ofifo[ofi_wp[3:0]] <= ofi_din;
            ofi_wp <= ofi_wp + 5'd1;
        end
        // drain one entry per cycle into the registered output port
        if (!ofi_empty) begin
            {sample_addr, sample_coeff} <= ofifo[ofi_rp[3:0]];
            out_valid <= 1'b1;
            ofi_rp    <= ofi_rp + 5'd1;
        end else begin
            out_valid <= 1'b0;
        end
    end
end

//======================================================================
// 3.  Keccak-f[1600] state and one-round-per-cycle permutation
//     Lane (x,y) is A[5*y+x]; state string bit 64*(5y+x)+z.
//======================================================================
reg  [63:0] A [0:24];
reg  [ 4:0] rnd;                        // round counter 0..23

function [63:0] rotl; input [63:0] x; input integer n; begin
    rotl = (n == 0) ? x : ((x << n) | (x >> (64-n)));
end endfunction

function [63:0] rc; input [4:0] i; begin
    case (i)
      5'd0 :rc=64'h0000000000000001; 5'd1 :rc=64'h0000000000008082;
      5'd2 :rc=64'h800000000000808A; 5'd3 :rc=64'h8000000080008000;
      5'd4 :rc=64'h000000000000808B; 5'd5 :rc=64'h0000000080000001;
      5'd6 :rc=64'h8000000080008081; 5'd7 :rc=64'h8000000000008009;
      5'd8 :rc=64'h000000000000008A; 5'd9 :rc=64'h0000000000000088;
      5'd10:rc=64'h0000000080008009; 5'd11:rc=64'h000000008000000A;
      5'd12:rc=64'h000000008000808B; 5'd13:rc=64'h800000000000008B;
      5'd14:rc=64'h8000000000008089; 5'd15:rc=64'h8000000000008003;
      5'd16:rc=64'h8000000000008002; 5'd17:rc=64'h8000000000000080;
      5'd18:rc=64'h000000000000800A; 5'd19:rc=64'h800000008000000A;
      5'd20:rc=64'h8000000080008081; 5'd21:rc=64'h8000000000008080;
      5'd22:rc=64'h0000000080000001; default:rc=64'h8000000080008008;
    endcase
end endfunction

// rho rotation offsets, indexed [5*y+x]
function integer rho_off; input integer idx; begin
    case (idx)
      0:rho_off=0;   1:rho_off=1;   2:rho_off=62;  3:rho_off=28;  4:rho_off=27;
      5:rho_off=36;  6:rho_off=44;  7:rho_off=6;   8:rho_off=55;  9:rho_off=20;
     10:rho_off=3;  11:rho_off=10; 12:rho_off=43; 13:rho_off=25; 14:rho_off=39;
     15:rho_off=41; 16:rho_off=45; 17:rho_off=15; 18:rho_off=21; 19:rho_off=8;
     20:rho_off=18; 21:rho_off=2;  22:rho_off=61; 23:rho_off=56; default:rho_off=14;
    endcase
end endfunction

// ---- combinational round function -----------------------------------
reg [63:0] C  [0:4];
reg [63:0] D  [0:4];
reg [63:0] TH [0:24];      // after theta
reg [63:0] B  [0:24];      // after rho + pi
reg [63:0] NX [0:24];      // after chi + iota
integer    x, y, i;

always @* begin
    for (x = 0; x < 5; x = x+1)
        C[x] = A[x] ^ A[x+5] ^ A[x+10] ^ A[x+15] ^ A[x+20];
    for (x = 0; x < 5; x = x+1)
        D[x] = C[(x+4)%5] ^ rotl(C[(x+1)%5], 1);
    for (y = 0; y < 5; y = y+1)
        for (x = 0; x < 5; x = x+1)
            TH[5*y+x] = A[5*y+x] ^ D[x];
    // rho + pi :  B[y][(2x+3y)%5] = rot(TH[x][y], r[x][y])
    for (y = 0; y < 5; y = y+1)
        for (x = 0; x < 5; x = x+1)
            B[5*((2*x+3*y)%5) + y] = rotl(TH[5*y+x], rho_off(5*y+x));
    // chi
    for (y = 0; y < 5; y = y+1)
        for (x = 0; x < 5; x = x+1)
            NX[5*y+x] = B[5*y+x] ^ ((~B[5*y+((x+1)%5)]) & B[5*y+((x+2)%5)]);
    // iota
    NX[0] = NX[0] ^ rc(rnd);
end

//======================================================================
// 4.  Order Sequence Table (OST) ROM + Endpoint Table  -- NOVELTY CORE
//
//  entry[31:29] MODE    hash variant
//  entry[28:27] SRC     00 = EXT(ififo) 01 = dgst[255:0] 10 = dgst[511:256]
//                       11 = EXT words THEN dgst[255:0]      (m || H(pk))
//  entry[26:25] TAIL    00 none  01 nonce byte  10 matrix index bytes
//  entry[24:23] SINK    00 coeff stream(256)  01 digest stream
//                       10 latch digest       11 latch + stream
//  entry[22]    ETASEL  1 -> ETA1, 0 -> ETA2   (also = TRANSPOSE for TAIL=10)
//  entry[21:16] NREP    repeat count - 1
//  entry[15: 8] PARAM0  nonce base
//  entry[ 7: 0] LEN_W   EXT source length in words (0 = stream until
//                       in_valid low and ififo empty)
//  32'hFFFFFFFF = TERMINATE
//======================================================================
localparam [5:0] KK1 = K*K-1;
localparam [5:0] K1  = K-1;
localparam [7:0] KB  = K;
localparam [7:0] K2B = 2*K;

localparam [5:0] OST_KEYGEN = 6'd0,
                 OST_ENCAP  = 6'd8,
                 OST_DECAP  = 6'd16,
                 OST_TEST   = 6'd24;

function [31:0] ost_rom; input [5:0] a; begin
  case (a)
    // ---------------- KEYGEN ------------------------------------------
    6'd0 : ost_rom = {M_SHA3_512,2'b00,2'b00,2'b10,1'b0,6'd0       ,8'd0 ,8'd8}; // (rho,sigma)=G(d)
    6'd1 : ost_rom = {M_SHAKE128,2'b01,2'b10,2'b00,1'b0,KK1        ,8'd0 ,8'd0}; // A-hat  (k*k polys)
    6'd2 : ost_rom = {M_PRF     ,2'b10,2'b01,2'b00,1'b1,K1         ,8'd0 ,8'd0}; // s
    6'd3 : ost_rom = {M_PRF     ,2'b10,2'b01,2'b00,1'b1,K1         ,KB     ,8'd0}; // e
    6'd4 : ost_rom = 32'hFFFFFFFF;
    // ---------------- ENCAP -------------------------------------------
    6'd8 : ost_rom = {M_SHA3_256,2'b00,2'b00,2'b10,1'b0,6'd0       ,8'd0 ,8'd0}; // H(pk), streamed
    6'd9 : ost_rom = {M_SHA3_512,2'b11,2'b00,2'b10,1'b0,6'd0       ,8'd0 ,8'd8}; // (Kbar,r)=G(m||H(pk))
    6'd10: ost_rom = {M_SHAKE128,2'b00,2'b10,2'b00,1'b1,KK1        ,8'd0 ,8'd8}; // A-hat^T
    6'd11: ost_rom = {M_PRF     ,2'b10,2'b01,2'b00,1'b1,K1         ,8'd0 ,8'd0}; // r
    6'd12: ost_rom = {M_PRF     ,2'b10,2'b01,2'b00,1'b0,K1         ,KB     ,8'd0}; // e1
    6'd13: ost_rom = {M_PRF     ,2'b10,2'b01,2'b00,1'b0,6'd0       ,K2B   ,8'd0}; // e2
    6'd14: ost_rom = 32'hFFFFFFFF;
    // ---------------- DECAP (FO re-encryption) -------------------------
    6'd16: ost_rom = {M_SHA3_256,2'b00,2'b00,2'b10,1'b0,6'd0       ,8'd0 ,8'd0}; // H(pk)
    6'd17: ost_rom = {M_SHA3_512,2'b11,2'b00,2'b10,1'b0,6'd0       ,8'd0 ,8'd8}; // (Kbar',r')
    6'd18: ost_rom = {M_SHAKE128,2'b00,2'b10,2'b00,1'b1,KK1        ,8'd0 ,8'd8}; // A-hat^T
    6'd19: ost_rom = {M_PRF     ,2'b10,2'b01,2'b00,1'b1,K1         ,8'd0 ,8'd0}; // r'
    6'd20: ost_rom = {M_PRF     ,2'b10,2'b01,2'b00,1'b0,K1         ,KB     ,8'd0}; // e1'
    6'd21: ost_rom = {M_PRF     ,2'b10,2'b01,2'b00,1'b0,6'd0       ,K2B   ,8'd0}; // e2'
    6'd22: ost_rom = {M_SHA3_256,2'b00,2'b00,2'b11,1'b0,6'd0       ,8'd0 ,8'd0}; // H(c) latch+stream
    6'd23: ost_rom = 32'hFFFFFFFF;
    // ---------------- TEST (unit-test hooks) ---------------------------
    6'd24: ost_rom = {M_SHAKE128,2'b00,2'b10,2'b00,1'b0,6'd0       ,8'd0 ,8'd8}; // Parse(rho,0,0)
    6'd25: ost_rom = {M_PRF     ,2'b00,2'b01,2'b00,1'b1,6'd0       ,8'd0 ,8'd8}; // CBD(sigma,0) eta1
    6'd26: ost_rom = 32'hFFFFFFFF;
    default: ost_rom = 32'hFFFFFFFF;
  endcase
end endfunction

// Endpoint Table : number of output items produced by one repetition.
function [8:0] endpoint_tbl; input [2:0] m; input [1:0] sink; begin
    if (sink == 2'b00)          endpoint_tbl = 9'd256;            // polynomial
    else if (m == M_SHA3_512)   endpoint_tbl = 9'd64;             // 512-bit digest
    else                        endpoint_tbl = 9'd32;             // 256-bit digest
end endfunction

//======================================================================
// 5.  Sequencer / sponge control registers
//======================================================================
reg  [3:0]  st, perm_ret;
reg  [5:0]  ost_ptr;
reg  [31:0] ent;                       // current OST entry
reg         auto_mode;

wire [2:0]  e_mode  = ent[31:29];
wire [1:0]  e_src   = ent[28:27];
wire [1:0]  e_tail  = ent[26:25];
wire [1:0]  e_sink  = ent[24:23];
wire        e_eta   = ent[22];
wire        e_trans = ent[22];
wire [5:0]  e_nrep  = ent[21:16];
wire [7:0]  e_par0  = ent[15:8];
wire [7:0]  e_lenw  = ent[7:0];

wire [5:0]  RATEW   = rate_w(e_mode);
wire [7:0]  ETA     = e_eta ? ETA1[7:0] : ETA2[7:0];
wire [5:0]  NEED    = (e_mode == M_SHAKE128) ? 6'd24 : {ETA[4:0],1'b0}; // 24 or 2*eta

reg  [5:0]  rep;                       // current repetition index
reg  [7:0]  mat_i, mat_j;              // matrix indices for TAIL=10
reg  [7:0]  wcnt;                      // source words consumed
reg  [5:0]  wptr;                      // word pointer inside the rate block
reg  [3:0]  eom_guard;                 // end-of-message guard for streaming

reg  [511:0] dgst;                     // latched digest (rho|sigma / Kbar|r)
reg  [511:0] src_buf;                  // replay buffer for repeated entries
reg          replay;

reg  [63:0] shreg;                     // bit-gather register
reg  [6:0]  bavail;                    // bits available in shreg
reg  [5:0]  sq_widx;                   // squeeze word index inside block
reg  [8:0]  ocnt;                      // output item counter (coeff / byte)
reg  [11:0] pend;                      // 2nd uniform candidate
reg         pend_v;

// source word multiplexer -------------------------------------------------
wire [7:0]  src_total = (e_src == 2'b00) ? e_lenw :
                        (e_src == 2'b11) ? (e_lenw + 8'd8) : 8'd8;
wire        src_is_ext = (e_src == 2'b00) || ((e_src == 2'b11) && (wcnt < e_lenw));
wire [8:0]  dg_sel     = (e_src == 2'b01) ? {4'd0,wcnt[4:0]} :
                         (e_src == 2'b10) ? ({4'd0,wcnt[4:0]} + 9'd8) :
                                            ({4'd0,wcnt[4:0]} - {1'b0,e_lenw});
wire [31:0] dgst_word  = dgst[ dg_sel[4:0]*32 +: 32 ];
reg  [31:0] src_word;                  // resolved inside the clocked block
wire        src_avail  = replay ? 1'b1 : (src_is_ext ? ~ifi_empty : 1'b1);
wire        streaming  = (e_lenw == 8'd0) && (e_src == 2'b00);
wire        len_done   = ~streaming && (wcnt == src_total);
wire        eom        = streaming && ifi_empty && ~in_valid && (eom_guard == 4'd8);

// tail word ---------------------------------------------------------------
wire [7:0]  nonce_v = e_par0 + {2'd0,rep};
wire [7:0]  tb0     = (e_tail == 2'b01) ? nonce_v :
                      (e_tail == 2'b10) ? (e_trans ? mat_i : mat_j) : dsuffix(e_mode);
wire [7:0]  tb1     = (e_tail == 2'b01) ? dsuffix(e_mode) :
                      (e_tail == 2'b10) ? (e_trans ? mat_j : mat_i) : 8'h00;
wire [7:0]  tb2     = (e_tail == 2'b10) ? dsuffix(e_mode) : 8'h00;
wire [31:0] tail_w  = {8'h00, tb2, tb1, tb0};

// squeeze / digest byte reads --------------------------------------------
wire [31:0] sq_word = sq_widx[0] ? A[sq_widx[5:1]][63:32] : A[sq_widx[5:1]][31:0];
wire [ 7:0] dg_byte = A[ocnt[8:3]][ ocnt[2:0]*8 +: 8 ];

// samplers ----------------------------------------------------------------
wire [11:0] u_c0 = shreg[11:0];
wire [11:0] u_c1 = shreg[23:12];
wire [2:0]  cbd_a = ({2'b0,shreg[0]} + {2'b0,(ETA>1)?shreg[1]:1'b0}
                                     + {2'b0,(ETA>2)?shreg[2]:1'b0});
wire [2:0]  cbd_b = ({2'b0,shreg[ETA[2:0]]}
                   + {2'b0,(ETA>1)?shreg[ETA[2:0]+3'd1]:1'b0}
                   + {2'b0,(ETA>2)?shreg[ETA[2:0]+3'd2]:1'b0});
wire [11:0] cbd_v = (cbd_a >= cbd_b) ? ({9'd0,cbd_a} - {9'd0,cbd_b})
                                     : (MODQ[11:0] - ({9'd0,cbd_b} - {9'd0,cbd_a}));

// helper task: XOR one 32-bit word into the sponge state (rate region)
task absorb_word; input [5:0] idx; input [31:0] dat; begin
    if (idx[0]) A[idx[5:1]][63:32] <= A[idx[5:1]][63:32] ^ dat;
    else        A[idx[5:1]][31:0]  <= A[idx[5:1]][31:0]  ^ dat;
end endtask

//======================================================================
// 6.  Main FSM
//======================================================================
integer j;
always @(posedge clk) begin
    // defaults ---------------------------------------------------------
    ofi_push <= 1'b0;

    if (rst) begin
        st <= S_IDLE; perm_ret <= S_IDLE; ost_ptr <= 6'd0; ent <= 32'hFFFFFFFF;
        ifi_rp <= 6'd0;
        auto_mode <= 1'b0; rep <= 6'd0; mat_i <= 8'd0; mat_j <= 8'd0;
        wcnt <= 8'd0; wptr <= 6'd0; rnd <= 5'd0; eom_guard <= 4'd0;
        dgst <= 512'd0; src_buf <= 512'd0; replay <= 1'b0;
        shreg <= 64'd0; bavail <= 7'd0; sq_widx <= 6'd0; ocnt <= 9'd0;
        pend <= 12'd0; pend_v <= 1'b0;
        for (j = 0; j < 25; j = j+1) A[j] <= 64'd0;
    end else begin
        // end-of-message guard counter for streaming sources
        if (ifi_empty && !in_valid) begin
            if (eom_guard != 4'd8) eom_guard <= eom_guard + 4'd1;
        end else eom_guard <= 4'd0;

        case (st)
        //--------------------------------------------------------------
        S_IDLE: begin
            if (in_valid && write_enable) begin
                auto_mode <= hash_mode[2];
                if (hash_mode[2]) begin
                    case (hash_mode[1:0])
                        2'b00: ost_ptr <= OST_KEYGEN;
                        2'b01: ost_ptr <= OST_ENCAP;
                        2'b10: ost_ptr <= OST_DECAP;
                        default: ost_ptr <= OST_TEST;
                    endcase
                    st <= S_FETCH;
                end else begin
                    // LEGACY: synthesise a single-call entry on the fly
                    ent <= {hash_mode, 2'b00, 2'b00,
                            (hash_mode[1] ? 2'b01 : 2'b00),
                            1'b0, 6'd0, 8'd0, 8'd0};
                    rep <= 6'd0; mat_i <= 8'd0; mat_j <= 8'd0; replay <= 1'b0;
                    wcnt <= 8'd0; wptr <= 6'd0;
                    for (j = 0; j < 25; j = j+1) A[j] <= 64'd0;
                    st <= S_ABSORB;
                end
            end
        end
        //--------------------------------------------------------------
        S_FETCH: begin
            ent    <= ost_rom(ost_ptr);
            rep    <= 6'd0; mat_i <= 8'd0; mat_j <= 8'd0; replay <= 1'b0;
            wcnt   <= 8'd0; wptr <= 6'd0;
            for (j = 0; j < 25; j = j+1) A[j] <= 64'd0;
            st <= (ost_rom(ost_ptr) == 32'hFFFFFFFF) ? S_DONE : S_ABSORB;
        end
        //--------------------------------------------------------------
        S_ABSORB: begin
            if (wptr == RATEW) begin
                // rate block full -> permute, then keep absorbing
                rnd <= 5'd0; perm_ret <= S_ABSORB; st <= S_PERM;
            end else if (len_done || eom) begin
                // prepare the squeeze-side counters before the final permute
                ocnt <= 9'd0; bavail <= 7'd0; shreg <= 64'd0;
                pend_v <= 1'b0; st <= S_TAIL;
            end else if (src_avail) begin
                // resolve the source word synchronously (LUT-RAM read)
                src_word = replay     ? src_buf[ wcnt[3:0]*32 +: 32 ] :
                           src_is_ext ? ififo[ ifi_rp[4:0] ] : dgst_word;
                absorb_word(wptr, src_word);
                if (!replay && (wcnt < 8'd16))
                    src_buf[ wcnt[3:0]*32 +: 32 ] <= src_word;
                if (!replay && src_is_ext) ifi_rp <= ifi_rp + 6'd1;
                wcnt <= wcnt + 8'd1;
                wptr <= wptr + 6'd1;
            end
        end
        //--------------------------------------------------------------
        S_TAIL: begin
            if (wptr == RATEW) begin
                rnd <= 5'd0; perm_ret <= S_TAIL; st <= S_PERM;
            end else if (wptr == RATEW - 6'd1) begin
                // suffix and the 0x80 terminator land in the same word
                absorb_word(wptr, tail_w | 32'h80000000);
                rnd <= 5'd0;
                perm_ret <= (e_sink == 2'b00) ? S_SAMPLE : S_DIGEST;
                st  <= S_PERM;
            end else begin
                absorb_word(wptr, tail_w);
                st <= S_PAD;
            end
        end
        //--------------------------------------------------------------
        S_PAD: begin
            absorb_word(RATEW - 6'd1, 32'h80000000);
            rnd <= 5'd0;
            perm_ret <= (e_sink == 2'b00) ? S_SAMPLE : S_DIGEST;
            st  <= S_PERM;
        end
        //--------------------------------------------------------------
        S_PERM: begin
            for (j = 0; j < 25; j = j+1) A[j] <= NX[j];
            if (rnd == 5'd23) begin
                rnd     <= 5'd0;
                wptr    <= 6'd0;
                sq_widx <= 6'd0;
                st      <= perm_ret;
            end else rnd <= rnd + 5'd1;
        end
        //--------------------------------------------------------------
        S_SAMPLE: begin
            if (bavail < {1'b0,NEED} && !(e_mode == M_SHAKE128 && pend_v)) begin
                if (sq_widx < RATEW) begin
                    shreg   <= shreg | ({32'd0, sq_word} << bavail);
                    bavail  <= bavail + 7'd32;
                    sq_widx <= sq_widx + 6'd1;
                end else begin
                    rnd <= 5'd0; perm_ret <= S_SAMPLE; st <= S_PERM;
                end
            end else if (!ofi_full) begin
                if (e_mode == M_SHAKE128) begin
                    //------- uniform rejection sampler (Parse) ----------
                    if (pend_v) begin
                        pend_v <= 1'b0;
                        if (pend < MODQ[11:0]) begin
                            ofi_push <= 1'b1; ofi_din <= {ocnt[7:0], pend};
                            ocnt <= ocnt + 9'd1;
                            if (ocnt == 9'd255) st <= S_NEXTREP;
                        end
                    end else begin
                        shreg  <= shreg >> 24;
                        bavail <= bavail - 7'd24;
                        pend   <= u_c1; pend_v <= 1'b1;
                        if (u_c0 < MODQ[11:0]) begin
                            ofi_push <= 1'b1; ofi_din <= {ocnt[7:0], u_c0};
                            ocnt <= ocnt + 9'd1;
                            if (ocnt == 9'd255) st <= S_NEXTREP;
                        end
                    end
                end else begin
                    //------- centred binomial sampler (CBD) -------------
                    shreg    <= shreg >> NEED;
                    bavail   <= bavail - {1'b0,NEED};
                    ofi_push <= 1'b1; ofi_din <= {ocnt[7:0], cbd_v};
                    ocnt     <= ocnt + 9'd1;
                    if (ocnt == 9'd255) st <= S_NEXTREP;
                end
            end
        end
        //--------------------------------------------------------------
        S_DIGEST: begin
            if (!ofi_full) begin
                if (e_sink[1]) dgst[ ocnt[5:0]*8 +: 8 ] <= dg_byte;
                if (e_sink[0]) begin
                    ofi_push <= 1'b1; ofi_din <= {ocnt[7:0], 4'h0, dg_byte};
                end
                ocnt <= ocnt + 9'd1;
                if (ocnt == endpoint_tbl(e_mode, e_sink) - 9'd1) st <= S_NEXTREP;
            end
        end
        //--------------------------------------------------------------
        S_NEXTREP: begin
            pend_v <= 1'b0;
            if (!auto_mode) begin
                st <= S_DONE;
            end else if (rep == e_nrep) begin
                ost_ptr <= ost_ptr + 6'd1;
                st      <= S_FETCH;
            end else begin
                rep    <= rep + 6'd1;
                replay <= (e_src != 2'b00) ? 1'b0 : 1'b1;
                wcnt   <= 8'd0; wptr <= 6'd0;
                if (e_tail == 2'b10) begin
                    if (mat_j == K-1) begin mat_j <= 8'd0; mat_i <= mat_i + 8'd1; end
                    else                    mat_j <= mat_j + 8'd1;
                end
                for (j = 0; j < 25; j = j+1) A[j] <= 64'd0;
                st <= S_ABSORB;
            end
        end
        //--------------------------------------------------------------
        S_DONE: begin
            if (!in_valid) st <= S_IDLE;
        end
        default: st <= S_IDLE;
        endcase
    end
end

endmodule
`default_nettype wire
