@echo off
setlocal enableextensions

:: ============================================================
::  LANÇADOR DO SETUP DE DESENVOLVIMENTO
::  Duplo clique neste arquivo para iniciar.
::  O Windows pedirá confirmação de Administrador (UAC).
:: ============================================================

:: ── Verifica privilégios de Administrador ──────────────────
net session >nul 2>&1
if %errorlevel% equ 0 goto :JaAdmin

:: ── Ainda não é admin: reabre com UAC via VBScript ─────────
:: (Método VBScript é o mais confiável — evita escaping frágil no PowerShell)
echo Solicitando permissao de Administrador...

set "VBS_TEMP=%TEMP%\elevacao_setup.vbs"

echo Set oShell = CreateObject("Shell.Application")                          > "%VBS_TEMP%"
echo oShell.ShellExecute "%~s0", "", "%~dp0", "runas", 1                    >> "%VBS_TEMP%"

cscript //nologo "%VBS_TEMP%"
del "%VBS_TEMP%" 2>nul
exit /b

:: ── Já é Administrador ─────────────────────────────────────
:JaAdmin

set "SCRIPT=%~dp0Setup-AmbienteDesenvolvimento.ps1"

if not exist "%SCRIPT%" (
    echo.
    echo [ERRO] Arquivo nao encontrado:
    echo        %SCRIPT%
    echo.
    echo Certifique-se de que o .bat e o .ps1 estao na mesma pasta.
    pause
    exit /b 1
)

echo.
echo  =====================================================
echo   Setup do Ambiente de Desenvolvimento - pt-BR
echo  =====================================================
echo.
echo  Iniciando... (politica de execucao liberada so nesta sessao)
echo.

:: Executa o .ps1 com ExecutionPolicy Bypass apenas para esta sessão
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"

:: Captura código de saída do PowerShell
set "EXITCODE=%errorlevel%"

if %EXITCODE% neq 0 (
    echo.
    echo [ERRO] O script PowerShell encerrou com codigo: %EXITCODE%
    echo Verifique as mensagens acima para identificar o problema.
    pause
)

endlocal
exit /b %EXITCODE%
