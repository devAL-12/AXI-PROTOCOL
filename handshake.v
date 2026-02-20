`timescale 1ns / 1ps
// ============================================================================
// SYNTHESIZABLE VERSION - RTL Module (CORRECTED)
// ============================================================================
module handshake_rtl (
    input  wire        clk,
    input  wire        rst_n,
    
    // Master data input (from testbench)
    input  wire [7:0]  master_data_in,
    input  wire        master_start,
    
    // Outputs for monitoring
    output reg  [7:0]  master_data,
    output reg         master_valid,
    output reg  [7:0]  slave_data,
    output reg         slave_ready,
    output reg         transaction_done
);

    // State definitions
 localparam M_NEW_DATA        = 2'b00;
localparam M_WAIT_FOR_READY  = 2'b01;  // NEW STATE ADDED
localparam M_WAIT_FOR_SLAVE  = 2'b10;
    localparam S_WAIT_FOR_DATA  = 1'b0;
    localparam S_PROCESS_DATA   = 1'b1;
    
    // State registers
    reg  [1:0]m_state;
    reg s_state;

    // =========================================================================
    // MASTER LOGIC
    // FIX: Master now waits for slave_ready HIGH before asserting valid,
    //      and deasserts valid only after handshake (valid & ready both high).
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        master_data  <= 8'h00;
        master_valid <= 1'b0;
        m_state      <= M_NEW_DATA;
    end
    else begin
        case (m_state)

            M_NEW_DATA: begin
                if (master_start && slave_ready) begin
                    // Best case: kitchen free, take order immediately
                    master_data  <= master_data_in;
                    master_valid <= 1'b1;
                    m_state      <= M_WAIT_FOR_SLAVE;
                end
                else if (master_start && !slave_ready) begin
                    // Kitchen busy: write order down, hold it
                    master_data  <= master_data_in; // SAVE THE ORDER
                    master_valid <= 1'b0;
                    m_state      <= M_WAIT_FOR_READY; // Wait for kitchen
                end
                // if no master_start: just stay idle
            end

            M_WAIT_FOR_READY: begin
                // Waiter is HOLDING the order, waiting for kitchen
                if (slave_ready) begin
                    master_valid <= 1'b1;            // Kitchen free! Send now
                    m_state      <= M_WAIT_FOR_SLAVE;
                end
                else begin
                    master_valid <= 1'b0;            // Still waiting...
                    m_state      <= M_WAIT_FOR_READY;
                end
                // master_data is UNTOUCHED - order safely held
            end

            M_WAIT_FOR_SLAVE: begin
                if (slave_ready && master_valid) begin
                    master_valid <= 1'b0;        // Handshake done!
                    m_state      <= M_NEW_DATA;
                end
                else begin
                    master_valid <= 1'b1;        // Hold until confirmed
                    m_state      <= M_WAIT_FOR_SLAVE;
                end
            end

            default: begin
                m_state      <= M_NEW_DATA;
                master_valid <= 1'b0;
            end

        endcase
    end
end

    // =========================================================================
    // SLAVE LOGIC
    // FIX: slave_ready is pre-asserted (registered one cycle early) so the
    //      master always sees a stable ready BEFORE it asserts valid.
    //      No more same-cycle ready/valid race condition.
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            slave_data       <= 8'h00;
            slave_ready      <= 1'b0;   // Not ready during reset
            s_state          <= S_WAIT_FOR_DATA;
            transaction_done <= 1'b0;
        end
        else begin
            transaction_done <= 1'b0;  // Default: pulse signal, deassert every cycle

            case (s_state)
                S_WAIT_FOR_DATA: begin
                    slave_ready <= 1'b1;  // Pre-assert ready (registered, stable next cycle)

                    // FIX: Handshake only when BOTH master_valid AND slave_ready are high
                    if (master_valid && slave_ready) begin
                        slave_data       <= master_data;
                        slave_ready      <= 1'b0;   // Deassert during processing
                        transaction_done <= 1'b1;   // Pulse: valid transaction
                        s_state          <= S_PROCESS_DATA;
                    end
                end
                
                S_PROCESS_DATA: begin
                    // Processing done; go back and re-assert ready
                    // slave_ready will be asserted NEXT cycle (registered)
                    slave_ready <= 1'b0;   // Still busy this cycle
                    s_state     <= S_WAIT_FOR_DATA;
                end

                default: begin
                    s_state     <= S_WAIT_FOR_DATA;
                    slave_ready <= 1'b0;
                end
            endcase
        end
    end

endmodule
