@echo off
rem Offline regression for sd_read CMD18 multi-block streaming (v2 stop sequence).
rem Card model: sd_card_model.v (CMD17/CMD18, keeps streaming until CS rises).
set MS=D:\altera\14.1\modelsim_ase\win32aloem
cd /d E:\FPGA\ygcom\pre-release-testing\sim
if exist work_sd2 rmdir /s /q work_sd2
%MS%\vlib.exe work_sd2
if errorlevel 1 exit /b 1
%MS%\vlog.exe -quiet -work work_sd2 sd_card_model.v tb_sd_stream.v ..\a_image\sd_read.v ..\a_image\my_spi.v
if errorlevel 1 exit /b 1
%MS%\vsim.exe -c -quiet work_sd2.tb_sd_stream -do "run -all; quit -f"
exit /b %errorlevel%
