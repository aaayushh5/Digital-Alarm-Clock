// =============================================================
//  Digital Alarm Clock
//  FSM States: DISPLAY (00), SET_TIME (01), SET_ALARM (10)
//  Board: Artix-7 100T (Nexys A7-100T), 100 MHz clock
//
//  8-digit 7-segment display layout (left → right):
//    [7]  [6]  [5]  [4]  [3]  [2]  [1]  [0]
//    BLK  BLK  H1   H0   M1   M0   S1   S0
//  Digits 7 & 6 are permanently blanked (unused).
//  In SET_TIME / SET_ALARM states, S1 & S0 are also blanked.
// =============================================================

module alarm_clock (
    input  wire        clk,      // 100 MHz system clock
    input  wire        M,        // Mode button (advances FSM)
    input  wire        sel,      // Select field
    input  wire        inc,      // Increment selected field
    input  wire        S,        // Set / commit edit_time
    input  wire        En,       // Alarm enable
    input  wire        R,        // Reset alarm
    output wire [6:0]  seg,      // 7-segment cathode segments (a–g), active-low
    output wire        dp,       // Decimal point (driven as separator)
    output wire [7:0]  an,       // 8 digit anodes (active-low)
    output reg         Al        // Alarm LED
);

// ─────────────────────────────────────────────
//  1.  Clock dividers
// ─────────────────────────────────────────────

// 1 Hz tick
reg [26:0] clk_cnt;
reg        tick_1hz;
always @(posedge clk) begin
    if (clk_cnt == 27'd99_999_999) begin
        clk_cnt  <= 0;
        tick_1hz <= 1;
    end else begin
        clk_cnt  <= clk_cnt + 1;
        tick_1hz <= 0;
    end
end

// ~1 kHz per digit refresh tick for 7-segment multiplexing
// 8 digits × ~1 kHz/digit → scan at 8 kHz, period = 12500 cycles @ 100 MHz
reg [13:0] ref_cnt;
reg        tick_refresh;
always @(posedge clk) begin
    if (ref_cnt == 14'd12_499) begin
        ref_cnt      <= 0;
        tick_refresh <= 1;
    end else begin
        ref_cnt      <= ref_cnt + 1;
        tick_refresh <= 0;
    end
end

// ─────────────────────────────────────────────
//  2.  Button edge detectors (rising-edge only)
// ─────────────────────────────────────────────

// Synchronisers + edge detect for all buttons
reg [1:0] M_sr, sel_sr, inc_sr, S_sr, R_sr;
wire M_pulse   = (M_sr   == 2'b01);
wire sel_pulse = (sel_sr == 2'b01);
wire inc_pulse = (inc_sr == 2'b01);
wire S_pulse   = (S_sr   == 2'b01);
wire R_pulse   = (R_sr   == 2'b01);

always @(posedge clk) begin
    M_sr   <= {M_sr[0],   M};
    sel_sr <= {sel_sr[0], sel};
    inc_sr <= {inc_sr[0], inc};
    S_sr   <= {S_sr[0],   S};
    R_sr   <= {R_sr[0],   R};
end

// ─────────────────────────────────────────────
//  3.  FSM
// ─────────────────────────────────────────────

localparam DISPLAY   = 2'b00;
localparam SET_TIME  = 2'b01;
localparam SET_ALARM = 2'b10;

reg [1:0] state;

always @(posedge clk) begin
    case (state)
        DISPLAY:   if (M_pulse) state <= SET_TIME;
        SET_TIME:  if (M_pulse) state <= SET_ALARM;
        SET_ALARM: if (M_pulse) state <= DISPLAY;
        default:                state <= DISPLAY;
    endcase
end

// ─────────────────────────────────────────────
//  4.  Current-time registers  (BCD)
//      H_1[1:0]  H_0[3:0]  :  M_1[2:0]  M_0[3:0]  :  S_1[2:0]  S_0[3:0]
// ─────────────────────────────────────────────

reg [1:0] H_1;   // 0–2
reg [3:0] H_0;   // 0–9  (but ≤3 when H_1==2)
reg [2:0] M_1;   // 0–5
reg [3:0] M_0;   // 0–9
reg [2:0] S_1;   // 0–5
reg [3:0] S_0;   // 0–9

always @(posedge clk) begin
    if (tick_1hz) begin
        // ── seconds ──────────────────────────────
        if (S_0 == 4'd9) begin
            S_0 <= 4'd0;
            if (S_1 == 3'd5) begin
                S_1 <= 3'd0;
                // ── minutes ───────────────────────
                if (M_0 == 4'd9) begin
                    M_0 <= 4'd0;
                    if (M_1 == 3'd5) begin
                        M_1 <= 3'd0;
                        // ── hours ─────────────────
                        if ({H_1, H_0} == 6'd23) begin
                            H_1 <= 2'd0; H_0 <= 4'd0;
                        end else if (H_0 == 4'd9) begin
                            H_0 <= 4'd0; H_1 <= H_1 + 1;
                        end else begin
                            H_0 <= H_0 + 1;
                        end
                    end else begin
                        M_1 <= M_1 + 1;
                    end
                end else begin
                    M_0 <= M_0 + 1;
                end
            end else begin
                S_1 <= S_1 + 1;
            end
        end else begin
            S_0 <= S_0 + 1;
        end
    end

    // ── SET button commits edit_time → curr_time (state 01) ──
    if (S_pulse && state == SET_TIME) begin
        H_1 <= edit_H_1; H_0 <= edit_H_0;
        M_1 <= edit_M_1; M_0 <= edit_M_0;
        S_1 <= 3'd0;     S_0 <= 4'd0;
    end
end

// ─────────────────────────────────────────────
//  5.  Alarm-time registers
//      AH_1[1:0]  AH_0[3:0]  :  AM_1[2:0]  AM_0[3:0]
// ─────────────────────────────────────────────

reg [1:0] AH_1;
reg [3:0] AH_0;
reg [2:0] AM_1;
reg [3:0] AM_0;

always @(posedge clk) begin
    if (S_pulse && state == SET_ALARM) begin
        AH_1 <= edit_H_1; AH_0 <= edit_H_0;
        AM_1 <= edit_M_1; AM_0 <= edit_M_0;
    end
end

// ─────────────────────────────────────────────
//  6.  Edit-time registers
//      edit_H_1[1:0]  edit_H_0[3:0]  :  edit_M_1[2:0]  edit_M_0[3:0]
// ─────────────────────────────────────────────

reg [1:0] edit_H_1;
reg [3:0] edit_H_0;
reg [2:0] edit_M_1;
reg [3:0] edit_M_0;

// Selected field encoding:
//   00 = edit_M_0 (default / LSB of minute)
//   01 = edit_M_1
//   10 = edit_H_0
//   11 = edit_H_1   (cycles back to 00 on next sel)
// Rotation: M_0 → M_1 → H_0 → H_1 → M_0 …
// (only 3 presses to cover all four, then wraps)
// Implementation: 2-bit field_sel
reg [1:0] field_sel;  // 00=M0, 01=M1, 10=H0, 11=H1

// Load edit registers from current or alarm time when entering a SET state
always @(posedge clk) begin
    // On entering SET_TIME, preload from curr_time
    if (M_pulse && state == DISPLAY) begin
        edit_H_1  <= H_1;  edit_H_0  <= H_0;
        edit_M_1  <= M_1;  edit_M_0  <= M_0;
        field_sel <= 2'b00;
    end
    // On entering SET_ALARM, preload from alarm_time
    if (M_pulse && state == SET_TIME) begin
        edit_H_1  <= AH_1; edit_H_0  <= AH_0;
        edit_M_1  <= AM_1; edit_M_0  <= AM_0;
        field_sel <= 2'b00;
    end

    // ── sel: cycle selected field ──────────────────
    if (sel_pulse && (state == SET_TIME || state == SET_ALARM))
        field_sel <= field_sel + 1;   // wraps 11→00 automatically

    // ── inc: increment selected field with BCD rollover ──
    if (inc_pulse && (state == SET_TIME || state == SET_ALARM)) begin
        case (field_sel)
            2'b00: begin  // edit_M_0 (0–9)
                if (edit_M_0 == 4'd9) edit_M_0 <= 4'd0;
                else                  edit_M_0 <= edit_M_0 + 1;
            end
            2'b01: begin  // edit_M_1 (0–5)
                if (edit_M_1 == 3'd5) edit_M_1 <= 3'd0;
                else                  edit_M_1 <= edit_M_1 + 1;
            end
            2'b10: begin  // edit_H_0 (0–9, but capped by H_1)
                // If H_1 == 2, H_0 can only go 0–3
                if (edit_H_1 == 2'd2) begin
                    if (edit_H_0 == 4'd3) edit_H_0 <= 4'd0;
                    else                  edit_H_0 <= edit_H_0 + 1;
                end else begin
                    if (edit_H_0 == 4'd9) edit_H_0 <= 4'd0;
                    else                  edit_H_0 <= edit_H_0 + 1;
                end
            end
            2'b11: begin  // edit_H_1 (0–2)
                if (edit_H_1 == 2'd2) edit_H_1 <= 2'd0;
                else begin
                    edit_H_1 <= edit_H_1 + 1;
                    // Clamp H_0 if new H_1 == 2 and H_0 > 3
                    if (edit_H_1 == 2'd1 && edit_H_0 > 4'd3)
                        edit_H_0 <= 4'd3;
                end
            end
        endcase
    end
end

// ─────────────────────────────────────────────
//  7.  Alarm logic
// ─────────────────────────────────────────────

wire time_match = (H_1  == AH_1) && (H_0  == AH_0) &&
                  (M_1  == AM_1) && (M_0  == AM_0) &&
                  (S_1  == 3'd0) && (S_0  == 4'd0);

always @(posedge clk) begin
    if (R_pulse)
        Al <= 1'b0;
    else if (En && time_match && tick_1hz)
        Al <= 1'b1;
end

// ─────────────────────────────────────────────
//  8.  Display mux: choose what digits to show
//
//  Physical digit index (an bit):
//    7    6    5    4    3    2    1    0
//   BLK  BLK  H1   H0   M1   M0   S1   S0
//
//  Decimal points light up between H0/M1 (an[4])
//  and M0/S1 (an[2]) as HH:MM:SS separators.
//  In SET states, S1 & S0 are blanked.
// ─────────────────────────────────────────────

// 8-entry digit array; indices 7 & 6 are permanently blank
wire [3:0] digit [7:0];

// Choose source based on FSM state
wire [1:0] disp_H1 = (state == DISPLAY) ? H_1  : edit_H_1;
wire [3:0] disp_H0 = (state == DISPLAY) ? H_0  : edit_H_0;
wire [2:0] disp_M1 = (state == DISPLAY) ? M_1  : edit_M_1;
wire [3:0] disp_M0 = (state == DISPLAY) ? M_0  : edit_M_0;

assign digit[7] = 4'd0;                    // unused (blanked below)
assign digit[6] = 4'd0;                    // unused (blanked below)
assign digit[5] = {2'b00, disp_H1};        // H tens
assign digit[4] = disp_H0;                 // H units
assign digit[3] = {1'b0,  disp_M1};        // M tens
assign digit[2] = disp_M0;                 // M units
assign digit[1] = {1'b0,  S_1};            // S tens
assign digit[0] = S_0;                     // S units

// Per-digit enable (0 = blank, 1 = show)
wire [7:0] digit_en;
assign digit_en[7] = 1'b0;                 // always blank
assign digit_en[6] = 1'b0;                 // always blank
assign digit_en[5] = 1'b1;
assign digit_en[4] = 1'b1;
assign digit_en[3] = 1'b1;
assign digit_en[2] = 1'b1;
assign digit_en[1] = (state == DISPLAY);   // blank in SET states
assign digit_en[0] = (state == DISPLAY);   // blank in SET states

// ─────────────────────────────────────────────
//  9.  7-segment multiplexer  (8 digits)
// ─────────────────────────────────────────────

reg [2:0] dig_idx;   // 0–7
always @(posedge clk) begin
    if (tick_refresh)
        dig_idx <= dig_idx + 1;   // free-running mod-8
end

// Anode: active-low one-hot across 8 digits
assign an = ~(8'b0000_0001 << dig_idx);

// Decimal point: light between H0↔M1 (idx 4) and M0↔S1 (idx 2)
// Active-low on Nexys A7
assign dp = ~((dig_idx == 3'd4) || (dig_idx == 3'd2));

// BCD → 7-segment decoder  (segments: gfedcba, active-low)
reg [6:0] seg_r;
always @(*) begin
    if (!digit_en[dig_idx]) begin
        seg_r = 7'b111_1111;  // blank
    end else begin
        case (digit[dig_idx])
            4'd0: seg_r = 7'b100_0000;
            4'd1: seg_r = 7'b111_1001;
            4'd2: seg_r = 7'b010_0100;
            4'd3: seg_r = 7'b011_0000;
            4'd4: seg_r = 7'b001_1001;
            4'd5: seg_r = 7'b001_0010;
            4'd6: seg_r = 7'b000_0010;
            4'd7: seg_r = 7'b111_1000;
            4'd8: seg_r = 7'b000_0000;
            4'd9: seg_r = 7'b001_0000;
            default: seg_r = 7'b111_1111;
        endcase
    end
end
assign seg = seg_r;

endmodule
