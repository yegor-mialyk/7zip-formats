@echo off
set INCLUDE=C:\Program Files (x86)\Windows Kits\10\Include\10.0.26100.0\um;C:\Program Files (x86)\Windows Kits\10\Include\10.0.26100.0\shared

del *.dll *.res *.format

pp Manifest.pp
pp Ha.pp

rc Ha.g.rc

dcc32 Ha.pas -NSSystem;Winapi;Vcl -q -u..\..\Projects\Lib
if %errorlevel% neq 0 exit /b 1
ren Ha.dll Ha.x86.format

dcc64 Ha.pas -NSSystem;Winapi;Vcl -q -u..\..\Projects\Lib
if %errorlevel% neq 0 exit /b 1
ren Ha.dll Ha.x64.format
