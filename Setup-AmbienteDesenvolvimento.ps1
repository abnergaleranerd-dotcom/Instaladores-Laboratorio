#Requires -Version 5.1
# Desbloqueia a execução do script na sessão atual sem alterar a política global
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
<#
.SYNOPSIS
    Automatiza o setup completo do ambiente de desenvolvimento Windows.

.DESCRIPTION
    Script de provisionamento que instala e configura ferramentas de desenvolvimento
    usando o Winget como gerenciador de pacotes principal. Inclui Visual Studio 2022,
    VS Code com extensões, Git, .NET, Python, Node.js e demais utilitários.

.NOTES
    Versão    : 1.0.0
    Idioma    : Português do Brasil (pt-BR)
    Requisito : Windows 10/11 com Winget instalado, executado como Administrador.
#>

# =============================================================================
#region CONFIGURAÇÃO INICIAL E VERIFICAÇÕES
# =============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Pasta de downloads do usuário atual (destino para instaladores pesados)
$PastaDownloads = "$env:USERPROFILE\Downloads"

# Garante que a pasta de downloads existe
if (-not (Test-Path $PastaDownloads)) {
    New-Item -ItemType Directory -Path $PastaDownloads -Force | Out-Null
}

# ---------------------------------------------------------------------------
# Funções de log com cores padronizadas
# ---------------------------------------------------------------------------

function Escrever-Sucesso {
    param([string]$Mensagem)
    Write-Host "[OK] $Mensagem" -ForegroundColor Green
}

function Escrever-Download {
    param([string]$Mensagem)
    Write-Host "[DOWNLOAD] $Mensagem" -ForegroundColor Cyan
}

function Escrever-Aviso {
    param([string]$Mensagem)
    Write-Warning $Mensagem
}

function Escrever-Erro {
    param([string]$Mensagem)
    Write-Host "[ERRO] $Mensagem" -ForegroundColor Red
}

function Escrever-Info {
    param([string]$Mensagem)
    Write-Host "[INFO] $Mensagem" -ForegroundColor White
}

function Escrever-Secao {
    param([string]$Titulo)
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor DarkCyan
    Write-Host "  $Titulo" -ForegroundColor Cyan
    Write-Host ("=" * 70) -ForegroundColor DarkCyan
}

# Caminhos completos resolvidos uma única vez e reutilizados em todo o script
$script:WingetExe = $null
$script:CodeExe   = $null

# ---------------------------------------------------------------------------
# Localiza o winget.exe independentemente do PATH (essencial em sessões elevadas)
# ---------------------------------------------------------------------------

function Encontrar-Winget {
    # 1. PATH da sessão atual (funciona se winget já estiver acessível)
    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    # 2. Perfil do usuário logado — necessário porque sessões elevadas apontam
    #    LOCALAPPDATA para o perfil do sistema, não do usuário real
    $wingetEmPerfis = Get-Item "C:\Users\*\AppData\Local\Microsoft\WindowsApps\winget.exe" `
                        -ErrorAction SilentlyContinue |
                      Sort-Object LastWriteTime -Descending |
                      Select-Object -First 1 -ExpandProperty FullName
    if ($wingetEmPerfis) { return $wingetEmPerfis }

    # 3. Pacote MSIX instalado globalmente em ProgramFiles\WindowsApps
    $wingetMsix = Get-Item "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*\winget.exe" `
                    -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending |
                  Select-Object -First 1 -ExpandProperty FullName
    if ($wingetMsix) { return $wingetMsix }

    return $null
}

# ---------------------------------------------------------------------------
# Verificação de privilégios de Administrador
# ---------------------------------------------------------------------------

function Verificar-Administrador {
    $identidade  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal   = [Security.Principal.WindowsPrincipal] $identidade
    $ehAdmin     = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if (-not $ehAdmin) {
        Escrever-Erro "Este script precisa ser executado como Administrador."
        Escrever-Erro "Clique com o botão direito no PowerShell e selecione 'Executar como Administrador'."
        exit 1
    }

    Escrever-Sucesso "Privilégios de Administrador confirmados."
}

# ---------------------------------------------------------------------------
# Download robusto com fallback triplo (curl.exe → BITS → WebClient)
# ---------------------------------------------------------------------------

function Baixar-Arquivo {
    param(
        [string]$Url,
        [string]$Destino,
        [int]$TimeoutSegundos = 600
    )

    # --- Método 1: curl.exe nativo do Windows 10/11 (mais confiável, suporta redirect e timeout) ---
    $curlExe = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curlExe) {
        Escrever-Info "Usando curl.exe para download..."
        & curl.exe --location --silent --show-error --progress-bar `
                   --connect-timeout 30 `
                   --max-time $TimeoutSegundos `
                   --output $Destino `
                   $Url

        if ($LASTEXITCODE -eq 0 -and (Test-Path $Destino) -and (Get-Item $Destino).Length -gt 0) {
            return  # sucesso
        }
        Escrever-Aviso "curl.exe falhou (código $LASTEXITCODE). Tentando método alternativo..."
        Remove-Item $Destino -Force -ErrorAction SilentlyContinue
    }

    # --- Método 2: BITS (Background Intelligent Transfer Service) ---
    try {
        Escrever-Info "Usando BITS para download..."
        Import-Module BitsTransfer -ErrorAction Stop
        Start-BitsTransfer -Source $Url -Destination $Destino -TransferType Download -ErrorAction Stop

        if ((Test-Path $Destino) -and (Get-Item $Destino).Length -gt 0) {
            return  # sucesso
        }
    }
    catch {
        Escrever-Aviso "BITS falhou: $($_.Exception.Message). Tentando método alternativo..."
        Remove-Item $Destino -Force -ErrorAction SilentlyContinue
    }

    # --- Método 3: WebClient com timeout explícito (último recurso) ---
    Escrever-Info "Usando WebClient com timeout de $TimeoutSegundos segundos..."
    try {
        $cliente = New-Object System.Net.WebClient
        # Registra evento de progresso para evitar travamento silencioso
        $job = $cliente.DownloadFileTaskAsync($Url, $Destino)
        $limite = [datetime]::UtcNow.AddSeconds($TimeoutSegundos)

        while (-not $job.IsCompleted) {
            if ([datetime]::UtcNow -gt $limite) {
                $cliente.CancelAsync()
                throw "Timeout de $TimeoutSegundos segundos excedido durante o download."
            }
            Start-Sleep -Milliseconds 500
            Write-Host "." -NoNewline -ForegroundColor Cyan
        }
        Write-Host ""

        if ($job.IsFaulted) {
            throw $job.Exception.InnerException
        }
    }
    finally {
        $cliente.Dispose()
    }

    if (-not (Test-Path $Destino) -or (Get-Item $Destino).Length -eq 0) {
        throw "Todos os métodos de download falharam para: $Url"
    }
}

# ---------------------------------------------------------------------------
# Verificação e instalação do Winget
# ---------------------------------------------------------------------------

function Verificar-Winget {
    $script:WingetExe = Encontrar-Winget

    if (-not $script:WingetExe) {
        Escrever-Erro "winget.exe não encontrado em nenhum local conhecido."
        Escrever-Erro "Instale o 'App Installer' pela Microsoft Store e tente novamente."
        exit 1
    }

    # Garante que o diretório do winget esteja no PATH desta sessão
    $dirWinget = Split-Path $script:WingetExe -Parent
    if ($env:Path -notlike "*$dirWinget*") {
        $env:Path = "$dirWinget;$env:Path"
    }

    $versao = & $script:WingetExe --version 2>&1
    Escrever-Sucesso "Winget encontrado em: $script:WingetExe ($versao)"
}

#endregion

# =============================================================================
#region FUNÇÕES DE INSTALAÇÃO
# =============================================================================

# ---------------------------------------------------------------------------
# Instala um pacote via Winget com tratamento de erros individual
# ---------------------------------------------------------------------------

function Instalar-Pacote {
    param(
        [string]$NomeExibicao,
        [string]$IdPacote,
        [string]$Locale = ""
    )

    Escrever-Info "Instalando: $NomeExibicao ($IdPacote)..."

    try {
        # Códigos de saída conhecidos do winget que significam "ok"
        $codigosSucesso = @(
            0,              # Instalação concluída com êxito
            -1978335189,    # Já instalado na versão-alvo ou superior (APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE)
            -1978335153     # Já instalado; nenhuma ação necessária
        )
        # Códigos que indicam "nenhum instalador compatível" — dispara fallback sem locale
        $codigosSemLocale = @(
            -1978335216,    # 0x8A150030 APPINSTALLER_CLI_ERROR_NO_APPLICABLE_INSTALLER
            -1978335215     # 0x8A150031 variante observada em versões anteriores do winget
        )

        $argumentosBase = @(
            "install",
            "--id",     $IdPacote,
            "--source", "winget",          # força fonte winget; evita erro SSL do msstore
            "--silent",
            "--accept-package-agreements",
            "--accept-source-agreements",
            "--no-upgrade"
        )

        # ── Tentativa 1: com locale pt-BR (se informado) ──────────────────
        $argumentos = $argumentosBase
        if ($Locale -ne "") {
            $argumentos = $argumentosBase + @("--locale", $Locale)
        }

        # Usa o caminho completo resolvido em Verificar-Winget — sem depender do PATH
        & $script:WingetExe @argumentos
        $codigo = $LASTEXITCODE

        if ($codigo -in $codigosSucesso) {
            Escrever-Sucesso "$NomeExibicao instalado com sucesso."
            return
        }

        # ── Tentativa 2: sem locale (fallback quando pt-BR não existe para o pacote) ──
        if ($codigo -in $codigosSemLocale -and $Locale -ne "") {
            Escrever-Aviso "Locale '$Locale' não disponível para '$NomeExibicao'. Repetindo sem localização..."
            & $script:WingetExe @argumentosBase
            $codigo = $LASTEXITCODE

            if ($codigo -in $codigosSucesso) {
                Escrever-Sucesso "$NomeExibicao instalado (sem localização pt-BR)."
                return
            }
        }

        # ── Tentativa 3: sem --source (para pacotes ausentes no winget mas presentes no msstore) ──
        Escrever-Aviso "Pacote não encontrado na fonte 'winget'. Tentando sem filtro de fonte..."
        $argumentosSemFonte = $argumentosBase | Where-Object { $_ -ne "winget" -and $_ -ne "--source" }
        & $script:WingetExe @argumentosSemFonte
        $codigo = $LASTEXITCODE

        if ($codigo -in $codigosSucesso) {
            Escrever-Sucesso "$NomeExibicao instalado (fonte alternativa)."
            return
        }

        Escrever-Aviso "Winget encerrou com código $codigo ao instalar '$NomeExibicao'. Verifique manualmente."
    }
    catch {
        Escrever-Erro "Falha ao instalar '$NomeExibicao'`: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Localiza o executável do VS Code independentemente do PATH
# ---------------------------------------------------------------------------

function Encontrar-VSCode {
    # 1. PATH da sessão atual
    $cmd = Get-Command code -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    # 2. Enumera todos os perfis em C:\Users (glob via Get-Item falha em sessões elevadas)
    $perfis = Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue
    foreach ($perfil in $perfis) {
        $candidato = Join-Path $perfil.FullName "AppData\Local\Programs\Microsoft VS Code\bin\code.cmd"
        if (Test-Path $candidato) { return $candidato }
    }

    # 3. Instalação de sistema (instalador System do VS Code)
    foreach ($raiz in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $raiz) { continue }
        $candidato = "$raiz\Microsoft VS Code\bin\code.cmd"
        if (Test-Path $candidato) { return $candidato }
    }

    return $null
}

# ---------------------------------------------------------------------------
# Instala uma extensão do VS Code com tratamento de erros individual
# ---------------------------------------------------------------------------

function Instalar-ExtensaoVSCode {
    param([string]$IdExtensao)

    Escrever-Info "Instalando extensão: $IdExtensao..."

    try {
        if (-not $script:CodeExe) {
            Escrever-Aviso "VS Code não encontrado. Extensão '$IdExtensao' será pulada."
            return
        }

        # Em sessão elevada o USERPROFILE aponta para o perfil Admin/sistema.
        # Deriva o perfil real a partir do caminho do code.cmd encontrado,
        # ou usa WMI para obter o usuário interativo logado.
        $usuarioReal = $null
        if ($script:CodeExe -match "C:\\Users\\([^\\]+)\\") {
            $usuarioReal = $Matches[1]
        }
        else {
            $usuarioReal = (Get-WmiObject Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName -replace '.*\\'
        }

        $argumentosExt = @("--install-extension", $IdExtensao, "--force")

        if ($usuarioReal -and (Test-Path "C:\Users\$usuarioReal")) {
            $extensionsDir = "C:\Users\$usuarioReal\.vscode\extensions"
            $userDataDir   = "C:\Users\$usuarioReal\AppData\Roaming\Code"
            $argumentosExt += "--extensions-dir", $extensionsDir, "--user-data-dir", $userDataDir
        }

        & $script:CodeExe @argumentosExt 2>&1 | Out-Null

        if ($LASTEXITCODE -eq 0) {
            Escrever-Sucesso "Extensão '$IdExtensao' instalada."
        }
        else {
            Escrever-Aviso "Não foi possível instalar '$IdExtensao' (código $LASTEXITCODE)."
        }
    }
    catch {
        Escrever-Erro "Falha ao instalar extensão '$IdExtensao'`: $($_.Exception.Message)"
    }
}

#endregion

# =============================================================================
#region BLOCO PRINCIPAL DE EXECUÇÃO
# =============================================================================

Clear-Host
Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║     SETUP DO AMBIENTE DE DESENVOLVIMENTO - WINDOWS (pt-BR)      ║" -ForegroundColor Cyan
Write-Host "  ╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# --- Pré-requisitos ---
Verificar-Administrador
Verificar-Winget

Escrever-Info "Pasta de downloads temporários: $PastaDownloads"
Write-Host ""

# =============================================================================
#region 1. VISUAL STUDIO 2022 COMMUNITY (Instalação especial via bootstrapper)
# =============================================================================
Escrever-Secao "1/9 — Visual Studio 2022 Community"

try {
    $urlBootstrapper = "https://aka.ms/vs/17/release/vs_community.exe"
    $caminhoBootstrapper = Join-Path $PastaDownloads "vs_community.exe"

    # Baixa o bootstrapper oficial apenas se ainda não existir
    if (-not (Test-Path $caminhoBootstrapper)) {
        Escrever-Download "Baixando instalador do Visual Studio 2022 Community..."
        Escrever-Download "URL   : $urlBootstrapper"
        Escrever-Download "Destino: $caminhoBootstrapper"
        Escrever-Info "(O bootstrapper tem ~1 MB; o conteúdo real (~3-5 GB) é baixado durante a instalação)"

        Baixar-Arquivo -Url $urlBootstrapper -Destino $caminhoBootstrapper -TimeoutSegundos 120

        Escrever-Sucesso "Bootstrapper baixado com sucesso ($('{0:N0}' -f (Get-Item $caminhoBootstrapper).Length) bytes)."
    }
    else {
        Escrever-Info "Bootstrapper já existe em: $caminhoBootstrapper — pulando download."
    }

    # Executa a instalação passiva com as cargas de trabalho C# e C++
    Escrever-Info "Iniciando instalação passiva do Visual Studio 2022 (isso pode demorar vários minutos)..."

    $argumentosVS = @(
        "--add", "Microsoft.VisualStudio.Workload.ManagedDesktop",   # C# / .NET Desktop
        "--add", "Microsoft.VisualStudio.Workload.NativeDesktop",    # C++ Desktop
        "--includeRecommended",
        "--passive",
        "--norestart",
        "--lang", "pt-BR"
    )

    $processo = Start-Process -FilePath $caminhoBootstrapper `
                              -ArgumentList $argumentosVS `
                              -Wait `
                              -PassThru

    if ($processo.ExitCode -eq 0 -or $processo.ExitCode -eq 3010) {
        # 3010 = instalação bem-sucedida, reinicialização pendente
        Escrever-Sucesso "Visual Studio 2022 Community instalado com êxito."
        if ($processo.ExitCode -eq 3010) {
            Escrever-Aviso "Uma reinicialização do sistema é recomendada para concluir a instalação do VS2022."
        }
    }
    else {
        Escrever-Aviso "O instalador do VS2022 encerrou com código $($processo.ExitCode). Verifique os logs em %TEMP%\dd_setup_*.log"
    }
}
catch {
    Escrever-Erro "Falha durante a instalação do Visual Studio 2022: $($_.Exception.Message)"
}

#endregion

# =============================================================================
#region 2. VISUAL STUDIO CODE
# =============================================================================
Escrever-Secao "2/9 — Visual Studio Code"

Instalar-Pacote -NomeExibicao "Visual Studio Code" -IdPacote "Microsoft.VisualStudioCode" -Locale "pt-BR"

#endregion

# =============================================================================
#region 3. EXTENSÕES DO VS CODE
# =============================================================================
Escrever-Secao "3/9 — Extensões do Visual Studio Code"

# Localiza o code.exe/code.cmd — igual ao que fazemos com o winget
# (necessário porque sessões elevadas não herdam o PATH do usuário real)
$script:CodeExe = Encontrar-VSCode

if ($script:CodeExe) {
    # Adiciona o bin do VS Code ao PATH da sessão
    $dirCode = Split-Path $script:CodeExe -Parent
    if ($env:Path -notlike "*$dirCode*") { $env:Path = "$dirCode;$env:Path" }
    Escrever-Sucesso "VS Code encontrado em: $script:CodeExe"
}
else {
    Escrever-Aviso "VS Code não localizado nos caminhos conhecidos — extensões serão puladas."
    Escrever-Aviso "Caminhos verificados:"
    Escrever-Aviso "  C:\Users\*\AppData\Local\Programs\Microsoft VS Code\bin\code.cmd"
    Escrever-Aviso "  $env:ProgramFiles\Microsoft VS Code\bin\code.cmd"
}

$extensoesVSCode = @(
    @{ Id = "ms-dotnettools.csharp";            Desc = "C# / C# Dev Kit (suporte a .NET)"         },
    @{ Id = "ms-python.python";                 Desc = "Python (suporte completo à linguagem)"      },
    @{ Id = "ms-python.vscode-pylance";         Desc = "Pylance (motor de análise Python)"          },
    @{ Id = "ms-vscode-remote.remote-wsl";      Desc = "Remote WSL (integração com o WSL)"          },
    @{ Id = "eamodio.gitlens";                  Desc = "GitLens (visualização avançada do Git)"     },
    @{ Id = "esbenp.prettier-vscode";           Desc = "Prettier (formatador universal)"            },
    @{ Id = "usernamehw.errorlens";             Desc = "Error Lens (erros inline no editor)"        },
    @{ Id = "soloman1124.pbi-tools";            Desc = "PBI Tools (sintaxe M do Power BI)"          },
    @{ Id = "github.github-vscode-theme";       Desc = "GitHub Theme (tema escuro oficial)"         },
    @{ Id = "miguelsolorio.vesper";             Desc = "Vesper (tema minimalista escuro)"            }
)

foreach ($extensao in $extensoesVSCode) {
    Escrever-Info "→ $($extensao.Desc)"
    Instalar-ExtensaoVSCode -IdExtensao $extensao.Id
}

#endregion

# =============================================================================
#region 4. GIT
# =============================================================================
Escrever-Secao "4/9 — Git"

Instalar-Pacote -NomeExibicao "Git" -IdPacote "Git.Git" -Locale "pt-BR"

#endregion

# =============================================================================
#region 5. .NET SDK 8 / PYTHON 3.12 / NODE.JS LTS
# =============================================================================
Escrever-Secao "5/9 — .NET SDK 8 · Python 3.12 · Node.js LTS"

Instalar-Pacote -NomeExibicao ".NET SDK 8"    -IdPacote "Microsoft.DotNet.SDK.8"   -Locale "pt-BR"
Instalar-Pacote -NomeExibicao "Python 3.12"   -IdPacote "Python.Python.3.12"       -Locale "pt-BR"
Instalar-Pacote -NomeExibicao "Node.js LTS"   -IdPacote "OpenJS.NodeJS.LTS"        -Locale "pt-BR"

#endregion

# =============================================================================
#region 6. IDEs E FERRAMENTAS DE DESENVOLVIMENTO
# =============================================================================
Escrever-Secao "6/9 — IDEs e Ferramentas de Desenvolvimento"

Instalar-Pacote -NomeExibicao "PyCharm Community" -IdPacote "JetBrains.PyCharm.Community" -Locale "pt-BR"

#endregion

# =============================================================================
#region 7. FERRAMENTAS DE DADOS E VIRTUALIZAÇÃO
# =============================================================================
Escrever-Secao "7/9 — Dados, Virtualização e Navegador"

Instalar-Pacote -NomeExibicao "Power BI Desktop" -IdPacote "Microsoft.PowerBIDesktop"  -Locale "pt-BR"
Instalar-Pacote -NomeExibicao "VirtualBox"        -IdPacote "Oracle.VirtualBox"         -Locale "pt-BR"
Instalar-Pacote -NomeExibicao "Arc Browser"       -IdPacote "TheBrowserCompany.Arc"     -Locale "pt-BR"
Instalar-Pacote -NomeExibicao "PuTTY"             -IdPacote "PuTTY.PuTTY"              -Locale "pt-BR"

#endregion

# =============================================================================
#region 8. WSL — UBUNTU
# =============================================================================
Escrever-Secao "8/9 — WSL (Windows Subsystem for Linux) com Ubuntu"

try {
    Escrever-Info "Instalando o WSL com a distribuição Ubuntu..."
    Escrever-Aviso "Esta etapa pode solicitar reinicialização. Se pedido, reinicie e execute o script novamente."

    $processoWSL = Start-Process -FilePath "wsl" `
                                 -ArgumentList "--install", "-d", "Ubuntu" `
                                 -Wait `
                                 -PassThru `
                                 -NoNewWindow

    if ($processoWSL.ExitCode -eq 0 -or $processoWSL.ExitCode -eq 1) {
        Escrever-Sucesso "WSL com Ubuntu instalado (ou já estava instalado)."
    }
    else {
        Escrever-Aviso "WSL encerrou com código $($processoWSL.ExitCode). Pode ser necessário habilitar o recurso manualmente:"
        Escrever-Aviso "  dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart"
        Escrever-Aviso "  dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart"
    }
}
catch {
    Escrever-Erro "Falha ao instalar o WSL: $($_.Exception.Message)"
}

#endregion

# =============================================================================
#region 9. VERIFICAÇÃO DE SOFTWARES INDISPONÍVEIS NO WINGET
# =============================================================================
Escrever-Secao "9/9 — Verificação de Disponibilidade: Google Antigravity"

# Pesquisa o pacote no Winget para confirmar se existe
try {
    Escrever-Info "Verificando disponibilidade do 'Google Antigravity' no repositório do Winget..."
    $buscaAntigravity = & $script:WingetExe search "Google Antigravity" --accept-source-agreements 2>&1

    # Verifica se algum resultado relevante foi retornado
    if ($buscaAntigravity -match "Nenhum pacote encontrado" -or
        $buscaAntigravity -match "No package found"        -or
        $buscaAntigravity -notmatch "Google Antigravity") {

        throw "Pacote não encontrado no repositório oficial."
    }
    else {
        Escrever-Sucesso "Google Antigravity encontrado no Winget. Iniciando instalação..."
        Instalar-Pacote -NomeExibicao "Google Antigravity" -IdPacote "Google.Antigravity"
    }
}
catch {
    Write-Host ""
    Write-Warning @"
INSTALAÇÃO MANUAL NECESSÁRIA — Google Antigravity
─────────────────────────────────────────────────
O software 'Google Antigravity' NÃO está disponível no repositório oficial
do Winget e, por isso, não pôde ser instalado automaticamente.

Para instalar manualmente:
  1. Acesse o site oficial ou o repositório do projeto.
  2. Baixe o instalador compatível com sua versão do Windows.
  3. Execute o instalador e siga as instruções na tela.

Dica: Pesquise por 'Google Antigravity' no GitHub ou no site do fabricante
      para encontrar o instalador mais recente.
"@
    Write-Host ""
}

#endregion

# =============================================================================
#region RESUMO FINAL
# =============================================================================

Write-Host ""
Write-Host ("=" * 70) -ForegroundColor DarkCyan
Write-Host "  SETUP CONCLUÍDO" -ForegroundColor Green
Write-Host ("=" * 70) -ForegroundColor DarkCyan
Write-Host ""
Write-Host "  Etapas realizadas:" -ForegroundColor White
Write-Host "  [1] Visual Studio 2022 Community (C# + C++, pt-BR)"  -ForegroundColor Green
Write-Host "  [2] Visual Studio Code"                               -ForegroundColor Green
Write-Host "  [3] Extensões do VS Code (10 extensões)"             -ForegroundColor Green
Write-Host "  [4] Git"                                              -ForegroundColor Green
Write-Host "  [5] .NET SDK 8 · Python 3.12 · Node.js LTS"          -ForegroundColor Green
Write-Host "  [6] PyCharm Community"                                -ForegroundColor Green
Write-Host "  [7] Power BI Desktop · VirtualBox · Arc · PuTTY"     -ForegroundColor Green
Write-Host "  [8] WSL com Ubuntu"                                   -ForegroundColor Green
Write-Host "  [9] Google Antigravity — verificação concluída"       -ForegroundColor Yellow
Write-Host ""
Write-Host "  IMPORTANTE:" -ForegroundColor Yellow
Write-Host "  · Pode ser necessário REINICIAR o computador para concluir" -ForegroundColor Yellow
Write-Host "    a instalação do WSL e/ou do Visual Studio 2022."          -ForegroundColor Yellow
Write-Host "  · Após reiniciar, abra o VS Code para que as extensões"     -ForegroundColor Yellow
Write-Host "    sejam ativadas corretamente."                             -ForegroundColor Yellow
Write-Host ""
Write-Host ("=" * 70) -ForegroundColor DarkCyan
Write-Host ""

# Mantém a janela aberta para que o usuário leia o resultado final
Write-Host "  Pressione ENTER para fechar esta janela..." -ForegroundColor DarkGray
Read-Host | Out-Null

#endregion
