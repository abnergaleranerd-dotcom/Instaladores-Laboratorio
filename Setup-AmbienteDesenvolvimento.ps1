#Requires -Version 5.1
# Desbloqueia execução apenas para esta sessão — não altera política global
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

<#
.SYNOPSIS
    Setup automatizado do ambiente de desenvolvimento Windows (pt-BR).
.DESCRIPTION
    Instala e configura ferramentas via Winget. Baseado nos padrões
    testados em laboratório (--exact --force, sem --source, sem --locale).
.NOTES
    Versão    : 9.0
    Requisito : Windows 10/11, Winget instalado, executar como Administrador.
#>

# =============================================================================
# CONFIGURAÇÃO GLOBAL
# =============================================================================

# Continue: não para o script em erros não-críticos (padrão dos scripts de laboratório)
$ErrorActionPreference = "Continue"

# Pasta para downloads de instaladores pesados
$PastaInstaladores = "$env:USERPROFILE\Downloads"

# Referências globais resolvidas uma única vez
$script:WingetExe = $null
$script:CodeExe   = $null

# =============================================================================
# FUNÇÕES DE LOG
# =============================================================================

function Write-OK($msg)       { Write-Host "[OK] $msg" -ForegroundColor Green }
function Write-Info($msg)     { Write-Host "[INFO] $msg" -ForegroundColor White }
function Write-Aviso($msg)    { Write-Host "[AVISO] $msg" -ForegroundColor Yellow }
function Write-Falha($msg)    { Write-Host "[ERRO] $msg" -ForegroundColor Red }
function Write-Download($msg) { Write-Host "[DOWNLOAD] $msg" -ForegroundColor Cyan }

function Write-Secao($Titulo) {
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor DarkCyan
    Write-Host "  $Titulo" -ForegroundColor Cyan
    Write-Host ("=" * 70) -ForegroundColor DarkCyan
}

# =============================================================================
# FUNÇÕES UTILITÁRIAS
# =============================================================================

# ---------------------------------------------------------------------------
# Verifica privilégios de Administrador
# ---------------------------------------------------------------------------
function Verificar-Admin {
    $ehAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $ehAdmin) {
        Write-Falha "Este script precisa ser executado como Administrador."
        Write-Falha "Clique com o botão direito no arquivo .bat e escolha 'Executar como Administrador'."
        Start-Sleep 5
        exit 1
    }
    Write-OK "Privilégios de Administrador confirmados."
}

# ---------------------------------------------------------------------------
# Localiza o winget.exe em múltiplos locais (essencial em sessões elevadas)
# ---------------------------------------------------------------------------
function Encontrar-Winget {
    # 1. PATH da sessão atual
    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    # 2. Perfis de usuário (sessão elevada não herda LOCALAPPDATA do usuário real)
    $encontrado = Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue |
        ForEach-Object {
            $p = Join-Path $_.FullName "AppData\Local\Microsoft\WindowsApps\winget.exe"
            if (Test-Path $p) { $p }
        } | Select-Object -First 1
    if ($encontrado) { return $encontrado }

    # 3. Pacote MSIX global
    $msix = Get-Item "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*\winget.exe" `
                -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1 -ExpandProperty FullName
    if ($msix) { return $msix }

    return $null
}

# ---------------------------------------------------------------------------
# Instala um pacote via Winget
# Padrão validado em laboratório: --exact --force sem --source sem --locale
# --force: garante instalação mesmo quando há conflito de estado de versão
# --exact: evita correspondências parciais de ID
# ---------------------------------------------------------------------------
function Instalar-Pacote($Nome, $Id) {
    Write-Info "Instalando: $Nome ($Id)..."

    & $script:WingetExe install `
        --exact --id $Id `
        --accept-package-agreements `
        --accept-source-agreements `
        --silent --force

    switch ($LASTEXITCODE) {
        0            { Write-OK "$Nome instalado com sucesso." }
        -1978335189  { Write-OK "$Nome já estava instalado (versão atual ou superior)." }
        -1978335125  { Write-OK "$Nome já estava instalado." }
        -1978335153  { Write-OK "$Nome já estava instalado." }
        default      { Write-Aviso "$Nome — winget encerrou com código $LASTEXITCODE." }
    }
}

# ---------------------------------------------------------------------------
# Localiza o executável do VS Code (enumera perfis, não usa glob)
# ---------------------------------------------------------------------------
function Encontrar-VSCode {
    # 1. PATH da sessão
    $cmd = Get-Command code -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    # 2. Instalação por usuário — enumera C:\Users explicitamente
    $encontrado = Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue |
        ForEach-Object {
            $p = Join-Path $_.FullName "AppData\Local\Programs\Microsoft VS Code\bin\code.cmd"
            if (Test-Path $p) { $p }
        } | Select-Object -First 1
    if ($encontrado) { return $encontrado }

    # 3. Instalação de sistema
    foreach ($raiz in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $raiz) { continue }
        $p = "$raiz\Microsoft VS Code\bin\code.cmd"
        if (Test-Path $p) { return $p }
    }

    return $null
}

# ---------------------------------------------------------------------------
# Download robusto: curl.exe → BITS → Invoke-WebRequest
# ---------------------------------------------------------------------------
function Baixar-Arquivo($Url, $Destino, $Nome) {
    if (Test-Path $Destino) {
        Write-Info "$Nome já existe em $Destino — pulando download."
        return
    }

    Write-Download "Baixando $Nome..."
    Write-Download "Destino: $Destino"

    # Método 1: curl.exe nativo (timeout configurável, segue redirects)
    $curlExe = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curlExe) {
        curl.exe --location --silent --show-error --progress-bar `
                 --connect-timeout 30 --max-time 600 `
                 --output $Destino $Url
        if ($LASTEXITCODE -eq 0 -and (Test-Path $Destino) -and (Get-Item $Destino).Length -gt 0) {
            Write-OK "$Nome baixado ($('{0:N0}' -f (Get-Item $Destino).Length) bytes)."
            return
        }
        Remove-Item $Destino -Force -ErrorAction SilentlyContinue
        Write-Aviso "curl.exe falhou. Tentando BITS..."
    }

    # Método 2: BITS
    try {
        Start-BitsTransfer -Source $Url -Destination $Destino -TransferType Download -ErrorAction Stop
        if ((Test-Path $Destino) -and (Get-Item $Destino).Length -gt 0) {
            Write-OK "$Nome baixado via BITS."
            return
        }
    } catch {
        Remove-Item $Destino -Force -ErrorAction SilentlyContinue
        Write-Aviso "BITS falhou. Tentando Invoke-WebRequest..."
    }

    # Método 3: Invoke-WebRequest com progresso desabilitado
    try {
        $ProgressPreference = 'SilentlyContinue'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $Url -OutFile $Destino -UseBasicParsing
        Write-OK "$Nome baixado."
    } catch {
        Write-Falha "Todos os métodos de download falharam para $Nome`: $($_.Exception.Message)"
    }
}

# =============================================================================
# INÍCIO DA EXECUÇÃO
# =============================================================================

Clear-Host
Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║     SETUP DO AMBIENTE DE DESENVOLVIMENTO - WINDOWS (pt-BR)      ║" -ForegroundColor Cyan
Write-Host "  ║                        Versão 9.0                               ║" -ForegroundColor Cyan
Write-Host "  ╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# Pré-verificações
Verificar-Admin

$script:WingetExe = Encontrar-Winget
if (-not $script:WingetExe) {
    Write-Falha "winget.exe não encontrado. Instale o 'App Installer' pela Microsoft Store."
    exit 1
}
$versaoWinget = & $script:WingetExe --version 2>&1
Write-OK "Winget: $versaoWinget — $script:WingetExe"

if (-not (Test-Path $PastaInstaladores)) {
    New-Item -ItemType Directory -Path $PastaInstaladores -Force | Out-Null
}
Write-Info "Pasta de downloads: $PastaInstaladores"

# =============================================================================
#region 1. VISUAL STUDIO 2022 COMMUNITY
# =============================================================================
Write-Secao "1/9 — Visual Studio 2022 Community"

$urlVS       = "https://aka.ms/vs/17/release/vs_community.exe"
$caminhoVS   = Join-Path $PastaInstaladores "vs_community.exe"

Baixar-Arquivo -Url $urlVS -Destino $caminhoVS -Nome "VS 2022 Bootstrapper"

if (Test-Path $caminhoVS) {
    Write-Info "Iniciando instalação passiva do VS2022 (pode levar vários minutos)..."
    Write-Info "Cargas de trabalho: C# Desktop + C++ Desktop"

    $pVS = Start-Process -FilePath $caminhoVS -Wait -PassThru -ArgumentList `
        "--add", "Microsoft.VisualStudio.Workload.ManagedDesktop",
        "--add", "Microsoft.VisualStudio.Workload.NativeDesktop",
        "--includeRecommended",
        "--passive",
        "--norestart",
        "--lang", "pt-BR"

    switch ($pVS.ExitCode) {
        0    { Write-OK "Visual Studio 2022 instalado com sucesso." }
        3010 { Write-OK "Visual Studio 2022 instalado. Reinicialização recomendada." }
        default {
            Write-Aviso "VS2022 encerrou com código $($pVS.ExitCode)."
            Write-Aviso "Verifique os logs em: %TEMP%\dd_setup_*.log"
        }
    }
} else {
    Write-Falha "Bootstrapper não encontrado. VS2022 não será instalado."
}
#endregion

# =============================================================================
#region 2. VISUAL STUDIO CODE
# =============================================================================
Write-Secao "2/9 — Visual Studio Code"
Instalar-Pacote "Visual Studio Code" "Microsoft.VisualStudioCode"
#endregion

# =============================================================================
#region 3. EXTENSÕES DO VS CODE
# =============================================================================
Write-Secao "3/9 — Extensões do Visual Studio Code"

$script:CodeExe = Encontrar-VSCode

if ($script:CodeExe) {
    Write-OK "VS Code encontrado: $script:CodeExe"

    # Detecta o usuário real para instalar no perfil correto (não no perfil Admin)
    $usuarioReal = $null
    if ($script:CodeExe -match "C:\\Users\\([^\\]+)\\") {
        $usuarioReal = $Matches[1]
    }
    if (-not $usuarioReal) {
        $usuarioReal = (Get-WmiObject Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName -replace '.*\\'
    }

    # Apenas --extensions-dir: preserva acesso ao marketplace; grava no local correto
    $argsExt = @("--force")
    if ($usuarioReal -and (Test-Path "C:\Users\$usuarioReal")) {
        $extDir = "C:\Users\$usuarioReal\.vscode\extensions"
        $argsExt += "--extensions-dir", $extDir
        Write-Info "Extensões serão instaladas em: $extDir"
    }

    $extensoes = @(
        @{ Id = "ms-dotnettools.csharp";        Desc = "C# / C# Dev Kit"        },
        @{ Id = "ms-python.python";             Desc = "Python"                  },
        @{ Id = "ms-python.vscode-pylance";     Desc = "Pylance"                 },
        @{ Id = "ms-vscode-remote.remote-wsl";  Desc = "Remote WSL"              },
        @{ Id = "eamodio.gitlens";              Desc = "GitLens"                 },
        @{ Id = "esbenp.prettier-vscode";       Desc = "Prettier"                },
        @{ Id = "usernamehw.errorlens";         Desc = "Error Lens"              },
        @{ Id = "soloman1124.pbi-tools";        Desc = "PBI Tools (Power BI M)"  },
        @{ Id = "github.github-vscode-theme";   Desc = "GitHub Theme"            },
        @{ Id = "miguelsolorio.vesper";         Desc = "Vesper Theme"            }
    )

    foreach ($ext in $extensoes) {
        Write-Info "→ $($ext.Desc)"
        & $script:CodeExe --install-extension $ext.Id @argsExt 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-OK "Instalada: $($ext.Id)"
        } else {
            Write-Aviso "Não instalada: $($ext.Id) (código $LASTEXITCODE — pode não existir no marketplace)."
        }
    }
} else {
    Write-Aviso "VS Code não encontrado. Extensões serão puladas."
    Write-Aviso "Execute o script novamente após instalar o VS Code."
}
#endregion

# =============================================================================
#region 4. GIT
# =============================================================================
Write-Secao "4/9 — Git"
Instalar-Pacote "Git" "Git.Git"
#endregion

# =============================================================================
#region 5. .NET SDK 8 · PYTHON 3.12 · NODE.JS LTS
# =============================================================================
Write-Secao "5/9 — .NET SDK 8 · Python 3.12 · Node.js LTS"
Instalar-Pacote ".NET SDK 8"   "Microsoft.DotNet.SDK.8"
Instalar-Pacote "Python 3.12"  "Python.Python.3.12"
Instalar-Pacote "Node.js LTS"  "OpenJS.NodeJS.LTS"
#endregion

# =============================================================================
#region 6. PYCHARM COMMUNITY
# =============================================================================
Write-Secao "6/9 — PyCharm Community"
Instalar-Pacote "PyCharm Community" "JetBrains.PyCharm.Community"
#endregion

# =============================================================================
#region 7. POWER BI · VIRTUALBOX · ARC · PUTTY
# =============================================================================
Write-Secao "7/9 — Power BI Desktop · VirtualBox · Arc Browser · PuTTY"
Instalar-Pacote "Power BI Desktop" "Microsoft.PowerBI"
Instalar-Pacote "VirtualBox"       "Oracle.VirtualBox"
Instalar-Pacote "Arc Browser"      "TheBrowserCompany.Arc"
Instalar-Pacote "PuTTY"           "PuTTY.PuTTY"
#endregion

# =============================================================================
#region 8. WSL COM UBUNTU
# =============================================================================
Write-Secao "8/9 — WSL (Windows Subsystem for Linux) com Ubuntu"

Write-Info "Instalando WSL + Ubuntu..."
Write-Aviso "Se solicitado, reinicie o computador e execute o script novamente."

$pWSL = Start-Process -FilePath "wsl" `
            -ArgumentList "--install", "-d", "Ubuntu" `
            -Wait -PassThru -NoNewWindow

switch ($pWSL.ExitCode) {
    0  { Write-OK "WSL com Ubuntu instalado com sucesso." }
    1  { Write-OK "WSL já estava habilitado." }
    -1 { Write-OK "Ubuntu já está instalado no WSL." }
    default {
        Write-Aviso "WSL encerrou com código $($pWSL.ExitCode)."
        Write-Aviso "Se o Ubuntu não aparecer, habilite manualmente:"
        Write-Aviso "  dism /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all"
        Write-Aviso "  dism /online /enable-feature /featurename:VirtualMachinePlatform /all"
    }
}
#endregion

# =============================================================================
#region 9. GOOGLE ANTIGRAVITY
# =============================================================================
Write-Secao "9/9 — Google Antigravity"

Write-Host ""
Write-Host "  [AVISO] INSTALAÇÃO MANUAL NECESSÁRIA — Google Antigravity" -ForegroundColor Yellow
Write-Host "  ──────────────────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  O software 'Google Antigravity' NAO esta disponivel no" -ForegroundColor Yellow
Write-Host "  repositorio oficial do Winget." -ForegroundColor Yellow
Write-Host ""
Write-Host "  Para instalar manualmente:" -ForegroundColor White
Write-Host "    1. Acesse o site oficial ou repositorio do projeto." -ForegroundColor White
Write-Host "    2. Baixe o instalador para Windows." -ForegroundColor White
Write-Host "    3. Execute e siga as instrucoes." -ForegroundColor White
Write-Host ""
#endregion

# =============================================================================
# RESUMO FINAL
# =============================================================================
Write-Host ("=" * 70) -ForegroundColor Green
Write-Host "  SETUP CONCLUIDO" -ForegroundColor Green
Write-Host ("=" * 70) -ForegroundColor Green
Write-Host ""
Write-Host "  Instalacoes realizadas:" -ForegroundColor White
Write-Host "  [1] Visual Studio 2022 Community (C# + C++, pt-BR)" -ForegroundColor Green
Write-Host "  [2] Visual Studio Code"                              -ForegroundColor Green
Write-Host "  [3] Extensoes do VS Code (10 extensoes)"            -ForegroundColor Green
Write-Host "  [4] Git"                                            -ForegroundColor Green
Write-Host "  [5] .NET SDK 8 · Python 3.12 · Node.js LTS"        -ForegroundColor Green
Write-Host "  [6] PyCharm Community"                              -ForegroundColor Green
Write-Host "  [7] Power BI · VirtualBox · Arc · PuTTY"           -ForegroundColor Green
Write-Host "  [8] WSL com Ubuntu"                                 -ForegroundColor Green
Write-Host "  [9] Google Antigravity — instalacao manual"         -ForegroundColor Yellow
Write-Host ""
Write-Host "  PROXIMOS PASSOS:" -ForegroundColor Yellow
Write-Host "  >> REINICIE o computador para aplicar variaveis de ambiente." -ForegroundColor White
Write-Host "  >> Apos reiniciar, abra o VS Code para ativar as extensoes." -ForegroundColor White
Write-Host "  >> Instale o Google Antigravity manualmente." -ForegroundColor White
Write-Host ""
Write-Host ("=" * 70) -ForegroundColor Green
Write-Host ""

Read-Host "  Pressione ENTER para fechar" | Out-Null
