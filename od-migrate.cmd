@echo off
rem od-migrate.cmd - run od-migrate.ps1 from cmd.exe.
rem Usage: od-migrate.cmd <subcommand> [args...] [options]   (see: od-migrate.cmd help)
rem -ExecutionPolicy Bypass applies to this process only; it changes no system setting.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0od-migrate.ps1" %*
exit /b %ERRORLEVEL%
