onerror {quit -code 1 -f}
if {![file exists work]} {vlib work}
vlog sonar_support.v sonar_game_core.v text_lcd_driver.v submarine_sonar_top.v tb_sonar.v tb_lcd.v tb_game.v
proc run_checked {entity} {
 vsim -c -onfinish stop work.$entity
 run -all
 if {[examine -radix decimal /$entity/errors] != 0} {quit -code 1 -f}
 quit -sim
}
run_checked tb_sonar
run_checked tb_lcd
run_checked tb_game
quit -code 0 -f
