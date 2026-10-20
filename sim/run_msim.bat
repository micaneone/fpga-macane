@echo off
REM ==== offline bench runner: font_rom + menu_ovl ====
set MS=D:\altera\14.1\modelsim_ase\win32aloem
cd /d E:\FPGA\ygcom\pre-release-testing\sim
if exist work rmdir /s /q work
"%MS%\vlib.exe" work
"%MS%\vlog.exe" -quiet -work work ..\b_display\font_rom.v
"%MS%\vlog.exe" -quiet -work work ..\b_display\menu_ovl.v
"%MS%\vlog.exe" -quiet -work work tb_menu_font.v
"%MS%\vmap.exe" work work
"%MS%\vsim.exe" -c -quiet work.tb_menu_font -do "run -all; quit -f"
