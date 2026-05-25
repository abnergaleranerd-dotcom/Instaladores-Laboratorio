@echo off
:: ============================================================
::  LANÇADOR DO SETUP DE DESENVOLVIMENTO
::  Duplo clique neste arquivo para iniciar.
::  O Windows pedirá permissão de Administrador (UAC).
:: ============================================================

:: Verifica se já está rodando como Administrador
net session >nul 2>&1
if %errorLevel% == 0 goto :JaAdmin

:: Não é admin — relança o próprio .bat com elevação via PowerShell
echo Solicitando permissao de Administrador...
powershell -NoProfile -Command ^
  "Start-Process cmd -ArgumentList '/c \"%~f0\"' -Verb RunAs"
exit /b

:JaAdmin
:: ── Já é administrador ──────────────────────────────────────

:: Caminho do script PowerShell (mesma pasta deste .bat)
set "SCRIPT=%~dp0Setup-AmbienteDesenvolvimento.ps1"

if not exist "%SCRIPT%" (
    echo [ERRO] Arquivo nao encontrado: %SCRIPT%
    echo Certifique-se de que o .bat e o .ps1 estao na mesma pasta.
    pause
    exit /b 1
)

echo.
echo  Iniciando Setup do Ambiente de Desenvolvimento...
echo  Politica de execucao sera desbloqueada apenas para esta sessao.
echo.

:: Executa o .ps1 com:
::   -ExecutionPolicy Bypass  → ignora a política de execução do sistema
::   -NoProfile               → não carrega perfis de usuário (mais rápido)
::   -File                    → caminho do script
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"

:: Se o PowerShell sair com erro antes do Read-Host do script, mantém a janela
if %errorLevel% neq 0 (
    echo.
    echo [ERRO] O script encerrou com codigo de erro: %errorLevel%
    pause
)

exit /b
