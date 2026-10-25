@echo off
rem ===========================================================================
rem  run_alert.bat -- ModelSim regression for alert_ovl (border-only blink)
rem  MS = ModelSim ASE 10.3c (same as run_cn.bat / run_zoom.bat)
rem ===========================================================================
set MS=D:\altera\14.1\modelsim_ase\win32aloem
set PATH=%MS%;%PATH%
cd /d "%~dp0"
if exist work_alert rmdir /s /q work_alert
%MS%\vlib.exe work_alert
%MS%\vlog.exe -quiet -work work_alert ../b_display/alert_ovl.v tb_alert_ovl.v
if errorlevel 1 goto :fail
%MS%\vsim.exe -c -quiet work_alert.tb_alert_ovl -do "run -all; quit -f"
if errorlevel 1 goto :fail
echo ALERT SIM DONE
exit /b 0
:fail
echo ALERT SIM FAILED
exit /b 1
