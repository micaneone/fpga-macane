@echo off
REM ==== D1 回归：menu / bri / transition 三个台子 ====
set MS=D:\altera\14.1\modelsim_ase\win32aloem
cd /d E:\FPGA\ygcom\pre-release-testing\sim
if exist work_d1 rmdir /s /q work_d1
"%MS%\vlib.exe" work_d1
"%MS%\vlog.exe" -quiet -work work_d1 ..\b_display\font_rom.v ..\b_display\menu_ovl.v ..\b_display\bri_scale.v ..\b_display\transition.v ..\b_display\transition_ctrl.v
"%MS%\vlog.exe" -quiet -work work_d1 tb_menu_font.v tb_bri_scale.v tb_transition.v
"%MS%\vmap.exe" work_d1 work_d1
echo #### tb_menu_font
"%MS%\vsim.exe" -c -quiet work_d1.tb_menu_font -do "run -all; quit -f"
echo #### tb_bri_scale
"%MS%\vsim.exe" -c -quiet work_d1.tb_bri_scale -do "run -all; quit -f"
echo #### tb_transition
"%MS%\vsim.exe" -c -quiet work_d1.tb_transition -do "run -all; quit -f"
