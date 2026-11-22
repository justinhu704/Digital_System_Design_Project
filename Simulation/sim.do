onerror {quit -code 1 -f}
if {![info exists mode]} {set mode Fast}
if {![file exists work]} {vlib work}
vlog sonar_support.v sonar_game_core.v text_lcd_driver.v submarine_sonar_top.v tb_sonar.v tb_top.v tb_lcd.v
proc run_checked {entity args} {
 eval vsim -c -onfinish stop $args work.$entity
 run -all
 if {[examine -radix decimal /$entity/errors] != 0} {quit -code 1 -f}
 quit -sim
}
if {$mode eq "Fast" || $mode eq "All"} {
 run_checked tb_sonar
 run_checked tb_top -gTEST_CLK_FREQ=1000000
 run_checked tb_lcd -gTEST_CLK_FREQ=1000000
}
if {$mode eq "Timing" || $mode eq "All"} {
 run_checked tb_lcd -gTEST_CLK_FREQ=24000000
 run_checked tb_lcd -gTEST_CLK_FREQ=50000000
}
quit -code 0 -f
