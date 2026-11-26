# Main clock from VeriComm: 500 Hz = 2,000,000 ns. Change this period if CLK_FREQ changes.
create_clock -name clk -period 2000000.000 [get_ports {clk}]
derive_clock_uncertainty
