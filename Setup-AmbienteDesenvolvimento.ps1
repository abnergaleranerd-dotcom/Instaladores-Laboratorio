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
    try {
        $versaoWinget = winget --version 2>$null
        Escrever-Sucesso "Winget encontrado: $versaoWinget"
    }
    catch {
        Escrever-Erro "Winget não encontrado. Instale o 'App Installer' pela Microsoft Store e execute o script novamente."
        exit 1
    }
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
        $argumentos = @(
            "install",
            "--id", $IdPacote,
            "--silent",
            "--accept-package-agreements",
            "--accept-source-agreements",
            "--no-upgrade"
        )

        # Adiciona a localidade pt-BR quando especificada
        if ($Locale -ne "") {
            $argumentos += "--locale"
            $argumentos += $Locale
        }

        $resultado = & winget @argumentos 2>&1

        # O Winget retorna código 0 para sucesso e -1978335189 para "já instalado"
        if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq -1978335189) {
            Escrever-Sucesso "$NomeExibicao instalado com sucesso (ou já estava instalado)."
        }
        else {
            Escrever-Aviso "Winget retornou código $LASTEXITCODE ao instalar $NomeExibicao. Verifique manualmente."
        }
    }
    catch {
        Escrever-Erro "Falha ao instalar $NomeExibicao`: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Instala uma extensão do VS Code com tratamento de erros individual
# ---------------------------------------------------------------------------

function Instalar-ExtensaoVSCode {
    param([string]$IdExtensao)

    Escrever-Info "Instalando extensão: $IdExtensao..."

    try {
        # Localiza o executável 'code' no PATH
        $caminhoCode = Get-Command code -ErrorAction SilentlyContinue

        if (-not $caminhoCode) {
            Escrever-Aviso "O executável 'code' não foi encontrado no PATH. Reinicie o terminal após instalar o VS Code e execute novamente."
            return
        }

        $saida = & code --install-extension $IdExtensao --force 2>&1

        if ($LASTEXITCODE -eq 0) {
            Escrever-Sucesso "Extensão '$IdExtensao' instalada."
        }
        else {
            Escrever-Aviso "Não foi possível instalar a extensão '$IdExtensao'. Saída: $saida"
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

# Atualiza o PATH da sessão atual para que o 'code' seja encontrado imediatamente
$env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
            [System.Environment]::GetEnvironmentVariable("Path", "User")

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
    $buscaAntigravity = winget search "Google Antigravity" --accept-source-agreements 2>&1

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
