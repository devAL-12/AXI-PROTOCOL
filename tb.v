`timescale 1ns / 1ps
// ============================================================================
// TESTBENCH - Corrected Handshake RTL (with M_WAIT_FOR_READY state)
// Tests the critical bug fix: master_start pulse when slave not ready
// ============================================================================
module handshake_rtl_tb;

    // =========================================================================
    // DUT Signals
    // =========================================================================
    reg        clk;
    reg        rst_n;
    reg  [7:0] master_data_in;
    reg        master_start;

    wire [7:0] master_data;
    wire       master_valid;
    wire [7:0] slave_data;
    wire       slave_ready;
    wire       transaction_done;

    // =========================================================================
    // Scoreboard
    // =========================================================================
    integer pass_count;
    integer fail_count;
    integer test_num;
    reg [7:0] expected_data;

    // =========================================================================
    // DUT Instantiation
    // =========================================================================
    handshake_rtl DUT (
        .clk              (clk),
        .rst_n            (rst_n),
        .master_data_in   (master_data_in),
        .master_start     (master_start),
        .master_data      (master_data),
        .master_valid     (master_valid),
        .slave_data       (slave_data),
        .slave_ready      (slave_ready),
        .transaction_done (transaction_done)
    );

    // =========================================================================
    // Clock: 10ns period (100MHz)
    // =========================================================================
    initial clk = 0;
    always #5 clk = ~clk;

    // =========================================================================
    // Task: Reset
    // =========================================================================
    task apply_reset;
        begin
            rst_n          = 1'b0;
            master_start   = 1'b0;
            master_data_in = 8'h00;
            repeat(3) @(posedge clk); #1;
            rst_n = 1'b1;
            @(posedge clk); #1;
            $display("[%0t] RESET Released.", $time);
        end
    endtask

    // =========================================================================
    // Task: Normal Send
    // (waits for slave_ready THEN pulses start - classic happy path)
    // =========================================================================
    task send_normal;
        input [7:0] data;
        integer timeout;
        begin
            expected_data = data;
            $display("[%0t] [TEST %0d] NORMAL SEND: 0x%02X", $time, test_num, data);

            // Wait for slave ready
            timeout = 0;
            while (!slave_ready && timeout < 200) begin
                @(posedge clk); #1;
                timeout = timeout + 1;
            end
            if (timeout >= 200) begin
                $display("[%0t] ERROR: Slave never ready!", $time);
                fail_count = fail_count + 1;
                disable send_normal;
            end

            // Pulse start for exactly 1 tick
            master_data_in = data;
            master_start   = 1'b1;
            @(posedge clk); #1;
            master_start   = 1'b0;

            // Wait for done
            timeout = 0;
            while (!transaction_done && timeout < 200) begin
                @(posedge clk); #1;
                timeout = timeout + 1;
            end
            if (timeout >= 200) begin
                $display("[%0t] ERROR: Transaction never done!", $time);
                fail_count = fail_count + 1;
            end else begin
                check_result(data);
            end
            test_num = test_num + 1;
        end
    endtask

    // =========================================================================
    // Task: CRITICAL TEST - Pulse start when slave NOT ready
    // This is the exact bug scenario from previous code
    // =========================================================================
    task send_when_slave_busy;
        input [7:0] data;
        integer timeout;
        begin
            expected_data = data;
            $display("[%0t] [TEST %0d] BUG TEST - START PULSE WHEN SLAVE BUSY: 0x%02X",
                     $time, test_num, data);

            // FORCE slave to be busy - send a transaction first
            // but do NOT wait after - immediately send next
            master_data_in = 8'hAA;       // dummy first transaction
            master_start   = 1'b1;

            // Wait for slave ready before dummy
            timeout = 0;
            while (!slave_ready && timeout < 200) begin
                @(posedge clk); #1;
                timeout = timeout + 1;
            end
            @(posedge clk); #1;
            master_start = 1'b0;

            // Wait 1 cycle - slave is now BUSY (processing dummy)
            @(posedge clk); #1;

            // NOW send real data - slave_ready should be 0 here!
            master_data_in = data;
            master_start   = 1'b1;        // ONE TICK PULSE only
            @(posedge clk); #1;
            master_start   = 1'b0;        // Gone! slave still busy!

            $display("[%0t]   slave_ready at pulse time = %b (should be 0 to test bug)",
                     $time, slave_ready);

            // Wait for SECOND transaction_done (first was dummy)
            // Skip first done pulse
            timeout = 0;
            while (!transaction_done && timeout < 200) begin
                @(posedge clk); #1;
                timeout = timeout + 1;
            end
            // That was dummy done - now wait for real data done
            @(posedge clk); #1;
            timeout = 0;
            while (!transaction_done && timeout < 200) begin
                @(posedge clk); #1;
                timeout = timeout + 1;
            end

            if (timeout >= 200) begin
                $display("[%0t]   FAIL: Data 0x%02X was LOST (bug not fixed!)", $time, data);
                fail_count = fail_count + 1;
            end else begin
                check_result(data);
            end
            test_num = test_num + 1;
        end
    endtask

    // =========================================================================
    // Task: Check Result
    // =========================================================================
    task check_result;
        input [7:0] expected;
        begin
            if (slave_data === expected) begin
                $display("[%0t]   PASS: slave_data=0x%02X matches expected=0x%02X",
                         $time, slave_data, expected);
                pass_count = pass_count + 1;
            end else begin
                $display("[%0t]   FAIL: slave_data=0x%02X != expected=0x%02X",
                         $time, slave_data, expected);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // =========================================================================
    // Task: Back to Back - no gaps
    // =========================================================================
    task send_back_to_back;
        input [7:0] d0, d1, d2;
        begin
            $display("\n[%0t] === Back-to-Back Test ===", $time);
            send_normal(d0);
            send_normal(d1);
            send_normal(d2);
        end
    endtask

    // =========================================================================
    // Waveform Dump
    // =========================================================================
    initial begin
        $dumpfile("handshake_rtl_tb.vcd");
        $dumpvars(0, handshake_rtl_tb);
    end

    // =========================================================================
    // Transaction Monitor - watches every done pulse
    // =========================================================================
    always @(posedge clk) begin
        if (transaction_done) begin
            $display("[%0t] >>> transaction_done PULSE: slave_data=0x%02X master_data=0x%02X",
                     $time, slave_data, master_data);
        end
    end

    // =========================================================================
    // master_valid monitor
    // =========================================================================
    always @(posedge clk) begin
        if (master_valid)
            $display("[%0t]   master_valid=1 master_data=0x%02X slave_ready=%b",
                     $time, master_data, slave_ready);
    end

    // =========================================================================
    // MAIN TEST SEQUENCE
    // =========================================================================
    initial begin
        pass_count = 0;
        fail_count = 0;
        test_num   = 1;

        $display("=======================================================");
        $display("  Handshake RTL Testbench - Bug Fix Verification");
        $display("=======================================================\n");

        // -------------------------------------------------------------------
        // TEST 1: Reset Check
        // -------------------------------------------------------------------
        $display("--- TEST 1: Reset Behavior ---");
        apply_reset;
        if (master_valid===1'b0 && slave_ready===1'b0 && transaction_done===1'b0) begin
            $display("[%0t] PASS: All outputs 0 after reset", $time);
            pass_count = pass_count + 1;
        end else begin
            $display("[%0t] FAIL: Unexpected output after reset", $time);
            fail_count = fail_count + 1;
        end
        test_num = test_num + 1;
        @(posedge clk); #1;

        // -------------------------------------------------------------------
        // TEST 2: Normal Happy Path
        // -------------------------------------------------------------------
        $display("\n--- TEST 2: Normal Transaction (Happy Path) ---");
        send_normal(8'hA5);

        // -------------------------------------------------------------------
        // TEST 3: Another Normal
        // -------------------------------------------------------------------
        $display("\n--- TEST 3: Normal Transaction ---");
        send_normal(8'h3C);

        // -------------------------------------------------------------------
        // TEST 4: THE CRITICAL BUG TEST
        // start pulse when slave is busy (slave_ready=0)
        // Previous code would LOSE this data silently
        // Fixed code should HOLD and deliver it
        // -------------------------------------------------------------------
        $display("\n--- TEST 4: CRITICAL - Start Pulse When Slave Busy ---");
        send_when_slave_busy(8'hB7);

        // -------------------------------------------------------------------
        // TEST 5: Another Critical Bug Test with different data
        // -------------------------------------------------------------------
        $display("\n--- TEST 5: CRITICAL - Start Pulse When Slave Busy ---");
        send_when_slave_busy(8'h4F);

        // -------------------------------------------------------------------
        // TEST 6: Back-to-Back Normal
        // -------------------------------------------------------------------
        $display("\n--- TEST 6: Back-to-Back Transactions ---");
        send_back_to_back(8'h11, 8'h22, 8'h33);

        // -------------------------------------------------------------------
        // TEST 7: Edge Cases
        // -------------------------------------------------------------------
        $display("\n--- TEST 7: Edge Cases ---");
        send_normal(8'h00);   // All zeros
        send_normal(8'hFF);   // All ones

        // -------------------------------------------------------------------
        // TEST 8: Walking Ones
        // -------------------------------------------------------------------
        $display("\n--- TEST 8: Walking Ones Pattern ---");
        begin : walk
            integer i;
            for (i = 0; i < 8; i = i + 1)
                send_normal(8'h01 << i);
        end

        // -------------------------------------------------------------------
        // TEST 9: Random Burst
        // -------------------------------------------------------------------
        $display("\n--- TEST 9: Random Data Burst ---");
        begin : rand_test
            integer i;
            for (i = 0; i < 6; i = i + 1)
                send_normal($random % 256);
        end

        // -------------------------------------------------------------------
        // TEST 10: Reset Mid-Operation
        // -------------------------------------------------------------------
        $display("\n--- TEST 10: Reset During Transaction ---");
        begin
            master_data_in = 8'hDE;
            master_start   = 1'b1;
            @(posedge clk); #1;
            master_start = 1'b0;

            // Assert reset immediately
            rst_n = 1'b0;
            repeat(2) @(posedge clk); #1;

            if (master_valid===1'b0 && transaction_done===1'b0) begin
                $display("[%0t] PASS: Mid-reset cleared outputs correctly", $time);
                pass_count = pass_count + 1;
            end else begin
                $display("[%0t] FAIL: Mid-reset did not clear outputs", $time);
                fail_count = fail_count + 1;
            end
            test_num = test_num + 1;

            rst_n = 1'b1;
            @(posedge clk); #1;
        end

        // Post-reset recovery
        $display("\n--- Post-Reset Recovery ---");
        send_normal(8'hEF);
        send_normal(8'hCD);

        // -------------------------------------------------------------------
        // TEST 11: Multiple start pulses when slave busy
        // (stress test the wait_for_ready state)
        // -------------------------------------------------------------------
        $display("\n--- TEST 11: Rapid Pulse When Slave Busy ---");
        send_when_slave_busy(8'h99);
        send_when_slave_busy(8'h66);

        // Final gap
        repeat(5) @(posedge clk);

        // -------------------------------------------------------------------
        // SUMMARY
        // -------------------------------------------------------------------
        $display("\n=======================================================");
        $display("   FINAL TEST SUMMARY");
        $display("=======================================================");
        $display("   PASS  : %0d", pass_count);
        $display("   FAIL  : %0d", fail_count);
        $display("   TOTAL : %0d", pass_count + fail_count);
        $display("=======================================================");
        if (fail_count == 0)
            $display("   ?  ALL TESTS PASSED - Bug Fix Verified!");
        else
            $display("   ?  %0d TESTS FAILED - Check Log Above", fail_count);
        $display("=======================================================\n");

        $finish;
    end

    // =========================================================================
    // Watchdog Timer
    // =========================================================================
    initial begin
        #500000;
        $display("[%0t] WATCHDOG: Simulation timeout!", $time);
        $finish;
    end

endmodule
