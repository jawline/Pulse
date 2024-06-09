module Uart_tx (
    uart_rx,
    clear,
    clock,
    data_out_valid,
    data_out,
    parity_error,
    stop_bit_unstable
);

    input uart_rx;
    input clear;
    input clock;
    output data_out_valid;
    output [7:0] data_out;
    output parity_error;
    output stop_bit_unstable;

    /* signal declarations */
    wire _39 = 1'b0;
    wire _40;
    wire _41;
    wire _28 = 1'b0;
    wire _27;
    wire _42;
    wire _2;
    wire [7:0] _48 = 8'b00000000;
    wire [7:0] _47 = 8'b00000000;
    wire [7:0] _168 = 8'b00000000;
    wire _163;
    wire _162;
    wire _161;
    wire _160;
    wire _159;
    wire _158;
    wire [6:0] _151;
    wire [5:0] _152;
    wire [4:0] _153;
    wire [3:0] _154;
    wire [2:0] _155;
    wire [1:0] _156;
    wire _157;
    wire [7:0] _164;
    wire _149;
    wire _148;
    wire _147;
    wire _146;
    wire _145;
    wire _144;
    wire [6:0] _137;
    wire [5:0] _138;
    wire [4:0] _139;
    wire [3:0] _140;
    wire [2:0] _141;
    wire [1:0] _142;
    wire _143;
    wire [7:0] _150;
    wire _135;
    wire _134;
    wire _133;
    wire _132;
    wire _131;
    wire _130;
    wire [6:0] _123;
    wire [5:0] _124;
    wire [4:0] _125;
    wire [3:0] _126;
    wire [2:0] _127;
    wire [1:0] _128;
    wire _129;
    wire [7:0] _136;
    wire _121;
    wire _120;
    wire _119;
    wire _118;
    wire _117;
    wire _116;
    wire [6:0] _109;
    wire [5:0] _110;
    wire [4:0] _111;
    wire [3:0] _112;
    wire [2:0] _113;
    wire [1:0] _114;
    wire _115;
    wire [7:0] _122;
    wire _107;
    wire _106;
    wire _105;
    wire _104;
    wire _103;
    wire _102;
    wire [6:0] _95;
    wire [5:0] _96;
    wire [4:0] _97;
    wire [3:0] _98;
    wire [2:0] _99;
    wire [1:0] _100;
    wire _101;
    wire [7:0] _108;
    wire _93;
    wire _92;
    wire _91;
    wire _90;
    wire _89;
    wire _88;
    wire [6:0] _81;
    wire [5:0] _82;
    wire [4:0] _83;
    wire [3:0] _84;
    wire [2:0] _85;
    wire [1:0] _86;
    wire _87;
    wire [7:0] _94;
    wire _79;
    wire _78;
    wire _77;
    wire _76;
    wire _75;
    wire _74;
    wire [6:0] _67;
    wire [5:0] _68;
    wire [4:0] _69;
    wire [3:0] _70;
    wire [2:0] _71;
    wire [1:0] _72;
    wire _73;
    wire [7:0] _80;
    wire _65;
    wire _64;
    wire _63;
    wire _62;
    wire _61;
    wire _60;
    wire [6:0] _53;
    wire [5:0] _54;
    wire [4:0] _55;
    wire [3:0] _56;
    wire [2:0] _57;
    wire [1:0] _58;
    wire _59;
    wire [7:0] _66;
    reg [7:0] data_with_new_bit;
    wire [7:0] _166;
    wire _46;
    wire [7:0] _167;
    wire _44;
    wire [7:0] _169;
    wire [7:0] _4;
    reg [7:0] _49;
    wire _20 = 1'b0;
    wire _19 = 1'b0;
    wire _178 = 1'b0;
    wire _174 = 1'b1;
    wire _172 = 1'b0;
    wire _173;
    wire _175;
    wire _176;
    wire _171;
    wire _177;
    wire _170;
    wire _179;
    wire _6;
    reg _22;
    wire _224;
    wire _225;
    wire _226;
    wire _223 = 1'b0;
    wire [1:0] _24 = 2'b00;
    wire [1:0] _23 = 2'b00;
    wire _217 = 1'b0;
    wire _8;
    wire _218;
    wire _219;
    wire [1:0] _220;
    wire [2:0] _212 = 3'b111;
    wire [2:0] _51 = 3'b000;
    wire [2:0] _50 = 3'b000;
    wire [2:0] _186 = 3'b000;
    wire [2:0] _182 = 3'b001;
    wire [2:0] _183;
    wire [2:0] _184;
    wire _181;
    wire [2:0] _185;
    wire _180;
    wire [2:0] _187;
    wire [2:0] _9;
    reg [2:0] which_data_bit;
    wire _213;
    wire [1:0] _214;
    wire [1:0] _215;
    wire [1:0] _210;
    wire [1:0] _37 = 2'b00;
    wire [1:0] _35 = 2'b00;
    wire [1:0] _34 = 2'b00;
    wire [1:0] _194 = 2'b00;
    wire [1:0] _190 = 2'b01;
    wire [1:0] _191;
    wire [1:0] _192;
    wire _189;
    wire [1:0] _193;
    wire _188;
    wire [1:0] _195;
    wire [1:0] _10;
    reg [1:0] _36;
    wire _38;
    wire [1:0] _207;
    wire [13:0] _32 = 14'b00000000000000;
    wire vdd = 1'b1;
    wire [13:0] _30 = 14'b00000000000000;
    wire _12;
    wire [13:0] _29 = 14'b00000000000000;
    wire _14;
    wire [13:0] _200 = 14'b00000000000000;
    wire [13:0] _198 = 14'b00000000000001;
    wire [13:0] _199;
    wire [13:0] _196 = 14'b10011100001111;
    wire _197;
    wire [13:0] _201;
    wire [13:0] _15;
    reg [13:0] _31;
    wire switch_cycle;
    wire [1:0] _208;
    wire [1:0] _26 = 2'b11;
    wire _206;
    wire [1:0] _209;
    wire [1:0] _204 = 2'b10;
    wire _205;
    wire [1:0] _211;
    wire [1:0] _45 = 2'b01;
    wire _203;
    wire [1:0] _216;
    wire [1:0] _43 = 2'b00;
    wire _202;
    wire [1:0] _221;
    wire [1:0] _16;
    reg [1:0] current_state;
    wire _222;
    wire _227;
    wire _17;

    /* logic */
    assign _40 = _38 ? _39 : _28;
    assign _41 = switch_cycle ? _40 : _28;
    assign _27 = current_state == _26;
    assign _42 = _27 ? _41 : _28;
    assign _2 = _42;
    assign _163 = _49[0:0];
    assign _162 = _151[0:0];
    assign _161 = _152[0:0];
    assign _160 = _153[0:0];
    assign _159 = _154[0:0];
    assign _158 = _155[0:0];
    assign _151 = _49[7:1];
    assign _152 = _151[6:1];
    assign _153 = _152[5:1];
    assign _154 = _153[4:1];
    assign _155 = _154[3:1];
    assign _156 = _155[2:1];
    assign _157 = _156[0:0];
    assign _164 = { _8, _157, _158, _159, _160, _161, _162, _163 };
    assign _149 = _49[0:0];
    assign _148 = _137[0:0];
    assign _147 = _138[0:0];
    assign _146 = _139[0:0];
    assign _145 = _140[0:0];
    assign _144 = _141[0:0];
    assign _137 = _49[7:1];
    assign _138 = _137[6:1];
    assign _139 = _138[5:1];
    assign _140 = _139[4:1];
    assign _141 = _140[3:1];
    assign _142 = _141[2:1];
    assign _143 = _142[1:1];
    assign _150 = { _143, _8, _144, _145, _146, _147, _148, _149 };
    assign _135 = _49[0:0];
    assign _134 = _123[0:0];
    assign _133 = _124[0:0];
    assign _132 = _125[0:0];
    assign _131 = _126[0:0];
    assign _130 = _128[0:0];
    assign _123 = _49[7:1];
    assign _124 = _123[6:1];
    assign _125 = _124[5:1];
    assign _126 = _125[4:1];
    assign _127 = _126[3:1];
    assign _128 = _127[2:1];
    assign _129 = _128[1:1];
    assign _136 = { _129, _130, _8, _131, _132, _133, _134, _135 };
    assign _121 = _49[0:0];
    assign _120 = _109[0:0];
    assign _119 = _110[0:0];
    assign _118 = _111[0:0];
    assign _117 = _113[0:0];
    assign _116 = _114[0:0];
    assign _109 = _49[7:1];
    assign _110 = _109[6:1];
    assign _111 = _110[5:1];
    assign _112 = _111[4:1];
    assign _113 = _112[3:1];
    assign _114 = _113[2:1];
    assign _115 = _114[1:1];
    assign _122 = { _115, _116, _117, _8, _118, _119, _120, _121 };
    assign _107 = _49[0:0];
    assign _106 = _95[0:0];
    assign _105 = _96[0:0];
    assign _104 = _98[0:0];
    assign _103 = _99[0:0];
    assign _102 = _100[0:0];
    assign _95 = _49[7:1];
    assign _96 = _95[6:1];
    assign _97 = _96[5:1];
    assign _98 = _97[4:1];
    assign _99 = _98[3:1];
    assign _100 = _99[2:1];
    assign _101 = _100[1:1];
    assign _108 = { _101, _102, _103, _104, _8, _105, _106, _107 };
    assign _93 = _49[0:0];
    assign _92 = _81[0:0];
    assign _91 = _83[0:0];
    assign _90 = _84[0:0];
    assign _89 = _85[0:0];
    assign _88 = _86[0:0];
    assign _81 = _49[7:1];
    assign _82 = _81[6:1];
    assign _83 = _82[5:1];
    assign _84 = _83[4:1];
    assign _85 = _84[3:1];
    assign _86 = _85[2:1];
    assign _87 = _86[1:1];
    assign _94 = { _87, _88, _89, _90, _91, _8, _92, _93 };
    assign _79 = _49[0:0];
    assign _78 = _68[0:0];
    assign _77 = _69[0:0];
    assign _76 = _70[0:0];
    assign _75 = _71[0:0];
    assign _74 = _72[0:0];
    assign _67 = _49[7:1];
    assign _68 = _67[6:1];
    assign _69 = _68[5:1];
    assign _70 = _69[4:1];
    assign _71 = _70[3:1];
    assign _72 = _71[2:1];
    assign _73 = _72[1:1];
    assign _80 = { _73, _74, _75, _76, _77, _78, _8, _79 };
    assign _65 = _53[0:0];
    assign _64 = _54[0:0];
    assign _63 = _55[0:0];
    assign _62 = _56[0:0];
    assign _61 = _57[0:0];
    assign _60 = _58[0:0];
    assign _53 = _49[7:1];
    assign _54 = _53[6:1];
    assign _55 = _54[5:1];
    assign _56 = _55[4:1];
    assign _57 = _56[3:1];
    assign _58 = _57[2:1];
    assign _59 = _58[1:1];
    assign _66 = { _59, _60, _61, _62, _63, _64, _65, _8 };
    always @* begin
        case (which_data_bit)
        0: data_with_new_bit <= _66;
        1: data_with_new_bit <= _80;
        2: data_with_new_bit <= _94;
        3: data_with_new_bit <= _108;
        4: data_with_new_bit <= _122;
        5: data_with_new_bit <= _136;
        6: data_with_new_bit <= _150;
        default: data_with_new_bit <= _164;
        endcase
    end
    assign _166 = switch_cycle ? data_with_new_bit : _49;
    assign _46 = current_state == _45;
    assign _167 = _46 ? _166 : _49;
    assign _44 = current_state == _43;
    assign _169 = _44 ? _168 : _167;
    assign _4 = _169;
    always @(posedge _14) begin
        _49 <= _4;
    end
    assign _173 = _8 == _172;
    assign _175 = _173 ? _174 : _22;
    assign _176 = switch_cycle ? _175 : _22;
    assign _171 = current_state == _26;
    assign _177 = _171 ? _176 : _22;
    assign _170 = current_state == _43;
    assign _179 = _170 ? _178 : _177;
    assign _6 = _179;
    always @(posedge _14) begin
        _22 <= _6;
    end
    assign _224 = ~ _22;
    assign _225 = _38 ? _224 : _223;
    assign _226 = switch_cycle ? _225 : _223;
    assign _8 = uart_rx;
    assign _218 = _8 == _217;
    assign _219 = switch_cycle & _218;
    assign _220 = _219 ? _45 : current_state;
    assign _183 = which_data_bit + _182;
    assign _184 = switch_cycle ? _183 : which_data_bit;
    assign _181 = current_state == _45;
    assign _185 = _181 ? _184 : which_data_bit;
    assign _180 = current_state == _43;
    assign _187 = _180 ? _186 : _185;
    assign _9 = _187;
    always @(posedge _14) begin
        which_data_bit <= _9;
    end
    assign _213 = which_data_bit == _212;
    assign _214 = _213 ? _26 : current_state;
    assign _215 = switch_cycle ? _214 : current_state;
    assign _210 = switch_cycle ? _26 : current_state;
    assign _191 = _36 + _190;
    assign _192 = switch_cycle ? _191 : _36;
    assign _189 = current_state == _26;
    assign _193 = _189 ? _192 : _36;
    assign _188 = current_state == _43;
    assign _195 = _188 ? _194 : _193;
    assign _10 = _195;
    always @(posedge _14) begin
        _36 <= _10;
    end
    assign _38 = _36 == _37;
    assign _207 = _38 ? _43 : current_state;
    assign _12 = clear;
    assign _14 = clock;
    assign _199 = _31 + _198;
    assign _197 = _31 == _196;
    assign _201 = _197 ? _200 : _199;
    assign _15 = _201;
    always @(posedge _14) begin
        if (_12)
            _31 <= _30;
        else
            _31 <= _15;
    end
    assign switch_cycle = _31 == _32;
    assign _208 = switch_cycle ? _207 : current_state;
    assign _206 = current_state == _26;
    assign _209 = _206 ? _208 : current_state;
    assign _205 = current_state == _204;
    assign _211 = _205 ? _210 : _209;
    assign _203 = current_state == _45;
    assign _216 = _203 ? _215 : _211;
    assign _202 = current_state == _43;
    assign _221 = _202 ? _220 : _216;
    assign _16 = _221;
    always @(posedge _14) begin
        if (_12)
            current_state <= _24;
        else
            current_state <= _16;
    end
    assign _222 = current_state == _26;
    assign _227 = _222 ? _226 : _223;
    assign _17 = _227;

    /* aliases */

    /* output assignments */
    assign data_out_valid = _17;
    assign data_out = _49;
    assign parity_error = _2;
    assign stop_bit_unstable = _22;

endmodule
