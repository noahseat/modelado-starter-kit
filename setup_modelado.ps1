<#
.SYNOPSIS
    Configurador del entorno de modelado (Python, Git, VS Code, dbt, DbSchema).
    Funciona SIN permisos de administrador: todo se instala en el perfil del usuario.

.DESCRIPTION
    Lo único que se pide al usuario es su código de SQUAD (ej.: SG_3).

    Modos:
      -DryRun    No modifica nada. Solo muestra lo que haría.
      -TestMode  Instala todo en %USERPROFILE%\modelado_test. No toca tu PATH
                 ni la asociación de ficheros .dbs.
      (ninguno)  Instalación real en %USERPROFILE%.

    Parámetros para automatizar (GitHub Actions):
      -Squad SG_3   No pregunta el squad.
      -NoPause      No espera ENTER al final y nunca abre ventanas ni pide datos.
      -AllowAdmin   Permite ejecutar como administrador. SOLO funciona dentro de
                    GitHub Actions y SOLO junto con -TestMode o -DryRun.

    Estructura esperada junto al script:
      installers\python\    Winpython64-3.11.8.0dot.exe
      installers\git\       PortableGit-x.xx.x-64-bit.7z.exe
      installers\vscode\    VSCode-win32-x64-x.xx.x.zip
      installers\dbschema\  dbschema_windows_10_1_4.zip

.EXAMPLE
    .\setup_modelado.ps1 -TestMode
    .\setup_modelado.ps1 -Squad SG_3
    .\setup_modelado.ps1 -TestMode -Squad SG_3 -NoPause -AllowAdmin   # GitHub Actions
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$TestMode,
    [string]$Squad,
    [switch]$NoPause,
    [switch]$AllowAdmin,
    [switch]$SkipDbt,
    [switch]$SkipVSCodeExtension,
    [switch]$SkipDbsAssociation
)

$ErrorActionPreference = 'Stop'

# ============================================================
# CONFIGURACIÓN
# ============================================================

$SETUP_VERSION         = '1.3.0'
$PYTHON_VERSION        = '3.11.8'
$DBT_CORE_VERSION      = '1.11.6'
$DBT_SNOWFLAKE_VERSION = '1.11.2'
$VSCODE_EXTENSION      = 'YuTengjing.open-in-external-app'
$PIP_TRUSTED_HOSTS     = @('--trusted-host', 'pypi.org',
                           '--trusted-host', 'pypi.python.org',
                           '--trusted-host', 'files.pythonhosted.org')

$IsCI = ($env:GITHUB_ACTIONS -eq 'true') -or ($env:CI -eq 'true')

$ScriptRoot    = $PSScriptRoot
$InstallersDir = Join-Path $ScriptRoot 'installers'

if ($TestMode) { $Root = Join-Path $env:USERPROFILE 'modelado_test' }
else           { $Root = $env:USERPROFILE }

$PortablesDir = Join-Path $Root 'portables'
$GitDir       = Join-Path $PortablesDir 'PortableGit'
$VSCodeDir    = Join-Path $PortablesDir 'VSCode'
$DbSchemaDir  = Join-Path $PortablesDir 'dbschema_windows'
$DbtDir       = Join-Path $Root '.dbt'
$LogDir       = Join-Path $Root 'modelado_setup_logs'

if ($TestMode) { $DesktopDir = Join-Path $Root 'Escritorio' }
else           { $DesktopDir = [Environment]::GetFolderPath('Desktop') }

$Timestamp     = Get-Date -Format 'yyyyMMdd_HHmmss'
$Results       = New-Object System.Collections.ArrayList
$PythonExe     = $null
$PythonDir     = $null
$PythonScripts = $null
$DbtExe        = $null
$ActivationCmd = $null
$exitCode      = 0

# ============================================================
# SALIDA POR PANTALLA
# ============================================================

function Write-Step { param([string]$m) Write-Host ''; Write-Host "==> $m" -ForegroundColor Cyan }
function Write-OK   { param([string]$m) Write-Host "  [OK]    $m" -ForegroundColor Green }
function Write-Info { param([string]$m) Write-Host "          $m" -ForegroundColor Gray }
function Write-Warn { param([string]$m) Write-Host "  [AVISO] $m" -ForegroundColor Yellow }
function Write-Fail { param([string]$m) Write-Host "  [ERROR] $m" -ForegroundColor Red }
function Write-Dry  { param([string]$m) Write-Host "  [DRY]   $m" -ForegroundColor DarkGray }

function Add-Result {
    param([string]$Component, [string]$Status, [string]$Detail = '')
    [void]$Results.Add([pscustomobject]@{
        Componente = $Component
        Estado     = $Status
        Detalle    = $Detail
    })
}

function Exit-Setup {
    param([int]$Code)
    if (-not $NoPause) { Read-Host 'Pulsa ENTER para cerrar' | Out-Null }
    exit $Code
}

# ============================================================
# FUNCIONES AUXILIARES
# ============================================================

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Directory {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { return }
    if ($DryRun) { Write-Dry "Crearía carpeta: $Path"; return }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    Write-OK "Carpeta creada: $Path"
}

function Find-Installer {
    param([string]$SubFolder, [string[]]$Patterns)
    $dir = Join-Path $InstallersDir $SubFolder
    if (-not (Test-Path -LiteralPath $dir)) { return $null }
    foreach ($pattern in $Patterns) {
        $file = Get-ChildItem -LiteralPath $dir -Filter $pattern -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1
        if ($file) { return $file }
    }
    return $null
}

# Busca un ejecutable ya instalado dentro de portables (instalaciones previas hechas a mano)
function Find-ExistingExe {
    param([string]$Name, [int]$Depth = 3)
    if (-not (Test-Path -LiteralPath $PortablesDir)) { return $null }
    $f = Get-ChildItem -LiteralPath $PortablesDir -Filter $Name -File -Recurse -Depth $Depth -ErrorAction SilentlyContinue |
         Select-Object -First 1
    if ($f) { return $f.FullName }
    return $null
}

# Ejecuta un programa externo capturando la salida (sin que stderr rompa el script en PS 5.1)
function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    $output = & $Exe @Arguments 2>&1 | ForEach-Object { "$_" }
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = (($output | Out-String).Trim())
    }
}

# Ejecuta un programa externo mostrando la salida en directo (pip)
function Invoke-NativeLive {
    param([string]$Exe, [string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    & $Exe @Arguments 2>&1 | ForEach-Object { "$_" } | Out-Host
    return $LASTEXITCODE
}

# Autoextraíbles 7-Zip (WinPython, PortableGit): -y = sin preguntas, -o = destino
function Expand-SevenZipSfx {
    param([string]$Exe, [string]$Destination)
    $proc = Start-Process -FilePath $Exe -ArgumentList @('-y', "-o`"$Destination`"") -Wait -PassThru
    return $proc.ExitCode
}

# Descomprime un zip y deja el contenido directamente en $Destination
# (si el zip trae una única carpeta raíz, se "aplana" para que la ruta no lleve versión)
function Expand-ZipFlat {
    param([string]$Zip, [string]$Destination)

    if (Test-Path -LiteralPath $Destination) {
        $old = "${Destination}_incompleto_$Timestamp"
        Rename-Item -LiteralPath $Destination -NewName (Split-Path -Leaf $old)
        Write-Warn "Había una carpeta incompleta. Renombrada a: $old"
    }

    $staging = Join-Path $PortablesDir ('_tmp_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    try {
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [System.IO.Compression.ZipFile]::ExtractToDirectory($Zip, $staging)
        }
        catch {
            Expand-Archive -LiteralPath $Zip -DestinationPath $staging -Force
        }

        $items  = @(Get-ChildItem -LiteralPath $staging -Force)
        $source = $staging
        if ($items.Count -eq 1 -and $items[0].PSIsContainer) { $source = $items[0].FullName }

        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        Get-ChildItem -LiteralPath $source -Force | Move-Item -Destination $Destination -Force
    }
    finally {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-PortablePythonExe {
    if (-not (Test-Path -LiteralPath $PortablesDir)) { return $null }
    $all = @(Get-ChildItem -LiteralPath $PortablesDir -Filter 'python.exe' -File -Recurse -Depth 3 -ErrorAction SilentlyContinue |
             Where-Object { $_.FullName -notmatch '\\(Lib|venv|\.venv|Scripts)\\' })
    # Prioridad: carpeta python-3.11.8*, después cualquier python.exe de portables
    $best = $all | Where-Object { $_.Directory.Name -like "python-$PYTHON_VERSION*" } | Select-Object -First 1
    if (-not $best) { $best = $all | Select-Object -First 1 }
    if ($best) { return $best.FullName }
    return $null
}

function Get-PipPackageVersion {
    param([string]$Package)
    if (-not $PythonExe) { return $null }
    $r = Invoke-Native $PythonExe @('-m', 'pip', 'show', $Package, '--disable-pip-version-check')
    if ($r.ExitCode -ne 0) { return $null }
    foreach ($line in ($r.Output -split "`r?`n")) {
        if ($line -match '^Version:\s*(.+)$') { return $Matches[1].Trim() }
    }
    return $null
}

# ---------- PATH (solo usuario, nunca sistema) ----------

function Get-UserPathRaw {
    $key = Get-Item -Path 'HKCU:\Environment'
    # Se lee SIN expandir para conservar entradas tipo %USERPROFILE%\...
    return [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
}

function Add-UserPathEntries {
    param([string[]]$Paths)

    $raw     = Get-UserPathRaw
    $entries = New-Object System.Collections.Generic.List[string]
    foreach ($e in ($raw -split ';')) { if ($e.Trim()) { $entries.Add($e.Trim()) } }

    $changed = $false
    foreach ($p in $Paths) {
        $norm    = $p.TrimEnd('\')
        $already = $false
        foreach ($e in $entries) {
            if ([Environment]::ExpandEnvironmentVariables($e).TrimEnd('\') -ieq $norm) { $already = $true; break }
        }
        if ($already) { Write-OK "Ya estaba en el PATH: $p"; continue }

        # Se inserta ANTES de WindowsApps para que el alias de Microsoft Store no "robe" python.exe
        $idx = -1
        for ($i = 0; $i -lt $entries.Count; $i++) {
            if ($entries[$i] -match 'Microsoft\\WindowsApps\\?$') { $idx = $i; break }
        }
        if ($idx -ge 0) { $entries.Insert($idx, $p) } else { $entries.Add($p) }

        Write-OK "Añadido al PATH del usuario: $p"
        $changed = $true
    }

    if (-not $changed) { return }

    $backup = Join-Path $LogDir "path_usuario_backup_$Timestamp.txt"
    Set-Content -LiteralPath $backup -Value $raw -Encoding UTF8
    Write-Info "Copia de seguridad del PATH anterior: $backup"

    New-ItemProperty -Path 'HKCU:\Environment' -Name 'Path' -Value ($entries -join ';') `
        -PropertyType ExpandString -Force | Out-Null

    # Esta llamada además notifica a Windows del cambio (las terminales NUEVAS verán el PATH)
    [Environment]::SetEnvironmentVariable('MODELADO_SETUP_VERSION', $SETUP_VERSION, 'User')
}

function Add-SessionPath {
    param([string[]]$Paths)
    foreach ($p in $Paths) {
        if ($p -and (Test-Path -LiteralPath $p) -and (($env:PATH -split ';') -notcontains $p)) {
            $env:PATH = "$p;$env:PATH"
        }
    }
}

function Ensure-RegKey {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
}

function New-DesktopShortcut {
    param([string]$Name, [string]$Target)
    if (-not $Target -or -not (Test-Path -LiteralPath $Target)) { return }
    $lnk = Join-Path $DesktopDir "$Name.lnk"
    if (Test-Path -LiteralPath $lnk) { Write-OK "El acceso directo ya existe: $Name"; return }
    if ($DryRun) { Write-Dry "Crearía acceso directo: $lnk"; return }
    try {
        Ensure-Directory $DesktopDir
        $shell = New-Object -ComObject WScript.Shell
        $sc = $shell.CreateShortcut($lnk)
        $sc.TargetPath       = $Target
        $sc.WorkingDirectory = Split-Path -Parent $Target
        $sc.Save()
        Write-OK "Acceso directo creado: $Name"
    }
    catch {
        Write-Warn "No se pudo crear el acceso directo de $Name (posible política corporativa). Créalo a mano."
    }
}

# ============================================================
# CABECERA Y COMPROBACIONES PREVIAS
# ============================================================

Write-Host ''
Write-Host '=============================================' -ForegroundColor DarkYellow
Write-Host '     CONFIGURADOR ENTORNO DE MODELADO'          -ForegroundColor Yellow
Write-Host "     v$SETUP_VERSION  -  sin administrador"     -ForegroundColor Yellow
Write-Host '=============================================' -ForegroundColor DarkYellow
Write-Host ''
if ($DryRun)   { Write-Host 'MODO: DRY RUN - no se realizará ningún cambio' -ForegroundColor Cyan }
if ($TestMode) { Write-Host 'MODO: TEST - entorno aislado en modelado_test' -ForegroundColor Cyan }
if (-not $DryRun -and -not $TestMode) { Write-Host 'MODO: REAL' -ForegroundColor Red }
if ($IsCI)     { Write-Host 'ENTORNO: CI (GitHub Actions)' -ForegroundColor Cyan }
Write-Host ''
Write-Host "Usuario Windows : $env:USERNAME"
Write-Host "Perfil          : $env:USERPROFILE"
Write-Host "Raíz utilizada  : $Root"
Write-Host "Carpeta script  : $ScriptRoot"

Write-Step '0. Comprobaciones previas'

# -AllowAdmin solo es válido en CI y nunca en modo real
if ($AllowAdmin) {
    if (-not $IsCI) {
        Write-Fail '-AllowAdmin solo se puede usar dentro de GitHub Actions.'
        Exit-Setup 1
    }
    if (-not ($TestMode -or $DryRun)) {
        Write-Fail '-AllowAdmin exige -TestMode o -DryRun. Nunca se permite en modo real.'
        Exit-Setup 1
    }
}

if (Test-IsAdmin) {
    if ($AllowAdmin) {
        Write-Warn 'Ejecutando como administrador (permitido solo por ser CI + modo prueba).'
    }
    else {
        Write-Fail 'No ejecutes este configurador como administrador.'
        Write-Info 'Cierra esta ventana y lánzalo con tu usuario normal.'
        Exit-Setup 1
    }
}
else {
    Write-OK 'Ejecutando con usuario estándar (sin administrador).'
}

if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Fail "Se necesita PowerShell 5 o superior (tienes $($PSVersionTable.PSVersion))."
    Exit-Setup 1
}

if (-not [Environment]::Is64BitOperatingSystem) {
    Write-Fail 'Los portables son de 64 bits y este Windows no lo es.'
    Exit-Setup 1
}

if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    Write-Warn "PowerShell está en modo '$($ExecutionContext.SessionState.LanguageMode)' por política corporativa."
    Write-Info 'Algunos pasos (accesos directos, descompresión rápida) pueden fallar; el script seguirá.'
}

if (-not (Test-Path -LiteralPath $InstallersDir)) {
    Write-Warn "No existe la carpeta installers junto al script: $InstallersDir"
    Write-Info 'Solo se configurarán las herramientas que ya estén instaladas en portables.'
}
else {
    foreach ($f in @('python', 'git', 'vscode', 'dbschema')) {
        if (Test-Path -LiteralPath (Join-Path $InstallersDir $f)) { Write-OK "installers\$f" }
        else { Write-Warn "Falta installers\$f" }
    }
}

# ============================================================
# PROCESO PRINCIPAL
# ============================================================

$transcriptStarted = $false

try {

    # ---------- 1. Squad (único dato que se pide) ----------
    Write-Step '1. Squad'

    $squadPattern = '^[A-Z0-9]+(_[A-Z0-9]+)*$'

    if ($Squad) {
        $SquadCode = $Squad.Trim().ToUpper()
        if ($SquadCode -notmatch $squadPattern) {
            throw "El squad '$Squad' no tiene un formato válido. Ejemplo: SG_3"
        }
        Write-OK "Squad recibido por parámetro: $SquadCode"
    }
    elseif ($NoPause) {
        throw 'Con -NoPause hay que indicar el squad con -Squad (ej.: -Squad SG_3).'
    }
    else {
        do {
            $SquadCode = (Read-Host '  Indica tu SQUAD (ej.: SG_3)').Trim().ToUpper()
            $valid = $SquadCode -match $squadPattern
            if (-not $valid) { Write-Warn 'Formato no válido. Ejemplo correcto: SG_3' }
        } while (-not $valid)
    }

    $TransformName = "SU_SQUAD_${SquadCode}_TRANSFORM"
    $TransformDir  = Join-Path $DbtDir $TransformName
    $KeyDest       = Join-Path $TransformDir "${TransformName}_private_key.p8"
    Write-OK "Perfil dbt: $TransformName"

    # ---------- 2. Estructura ----------
    Write-Step '2. Estructura de carpetas'

    foreach ($d in @($Root, $PortablesDir, $DbtDir, $TransformDir, $LogDir)) { Ensure-Directory $d }
    Write-OK 'Estructura preparada.'

    if (-not $DryRun) {
        Start-Transcript -Path (Join-Path $LogDir "setup_$Timestamp.log") | Out-Null
        $transcriptStarted = $true
    }

    # ---------- 3. Python ----------
    Write-Step "3. Python $PYTHON_VERSION (WinPython portable)"

    $PythonExe = Get-PortablePythonExe
    if ($PythonExe) {
        Write-OK "Ya existe: $PythonExe"
    }
    else {
        $inst = Find-Installer 'python' @('Winpython64-*.exe', '*.exe')
        if (-not $inst) {
            Write-Fail "No hay Python en $PortablesDir ni instalador en installers\python"
        }
        elseif ($DryRun) {
            Write-Dry "Extraería $($inst.Name) en $PortablesDir"
        }
        else {
            Unblock-File -LiteralPath $inst.FullName -ErrorAction SilentlyContinue
            Write-Info "Extrayendo $($inst.Name) (puede tardar unos minutos)..."
            [void](Expand-SevenZipSfx $inst.FullName $PortablesDir)
            $PythonExe = Get-PortablePythonExe

            if (-not $PythonExe) {
                if ($NoPause) {
                    Write-Fail 'La extracción automática de WinPython no ha funcionado (modo desatendido: no se abre el asistente).'
                }
                else {
                    Write-Warn 'La extracción automática no ha funcionado. Se abrirá el asistente de WinPython.'
                    Write-Info "Cuando pida carpeta de destino, indica: $PortablesDir"
                    Start-Process -FilePath $inst.FullName -Wait
                    $PythonExe = Get-PortablePythonExe
                }
            }
        }
    }

    if ($PythonExe) {
        $v = Invoke-Native $PythonExe @('--version')
        if ($v.Output -match [regex]::Escape($PYTHON_VERSION)) {
            Write-OK $v.Output
            Add-Result 'Python' 'OK' $v.Output
        }
        else {
            Write-Warn "Versión distinta a la homologada ($PYTHON_VERSION): $($v.Output)"
            Add-Result 'Python' 'AVISO' $v.Output
        }
        $PythonDir     = Split-Path -Parent $PythonExe
        $PythonScripts = Join-Path $PythonDir 'Scripts'
        $DbtExe        = Join-Path $PythonScripts 'dbt.exe'
        Add-SessionPath @($PythonDir, $PythonScripts)
    }
    elseif ($DryRun) { Add-Result 'Python' 'SIMULADO' }
    else             { Add-Result 'Python' 'FALTA' 'Revisa installers\python' }

    # ---------- 4. Git ----------
    Write-Step '4. Git (PortableGit)'

    $GitExe = Join-Path $GitDir 'bin\git.exe'
    if (-not (Test-Path -LiteralPath $GitExe) -and (Test-Path -LiteralPath $PortablesDir)) {
        $found = Get-ChildItem -LiteralPath $PortablesDir -Filter 'git.exe' -File -Recurse -Depth 3 -ErrorAction SilentlyContinue |
                 Where-Object { $_.Directory.Name -eq 'bin' -and $_.FullName -notmatch '\\mingw64\\' } |
                 Select-Object -First 1
        if ($found) { $GitExe = $found.FullName; $GitDir = Split-Path -Parent $found.DirectoryName }
    }

    if (Test-Path -LiteralPath $GitExe) {
        Write-OK "Ya existe: $GitDir"
    }
    else {
        $inst = Find-Installer 'git' @('PortableGit-*.7z.exe', '*.exe')
        if (-not $inst) {
            Write-Fail "No hay Git en $PortablesDir ni instalador en installers\git"
        }
        elseif ($DryRun) {
            Write-Dry "Extraería $($inst.Name) en $GitDir"
        }
        else {
            Unblock-File -LiteralPath $inst.FullName -ErrorAction SilentlyContinue
            Write-Info "Extrayendo $($inst.Name)..."
            [void](Expand-SevenZipSfx $inst.FullName $GitDir)
        }
    }

    if (Test-Path -LiteralPath $GitExe) {
        Add-SessionPath @((Join-Path $GitDir 'bin'))
        $v = Invoke-Native $GitExe @('--version')
        Write-OK $v.Output
        Add-Result 'Git' 'OK' $v.Output
    }
    elseif ($DryRun) { Add-Result 'Git' 'SIMULADO' }
    else             { Add-Result 'Git' 'FALTA' 'Revisa installers\git' }

    # ---------- 5. Visual Studio Code ----------
    Write-Step '5. Visual Studio Code (portable)'

    $CodeExe = Join-Path $VSCodeDir 'Code.exe'
    if (-not (Test-Path -LiteralPath $CodeExe)) {
        $found = Find-ExistingExe 'Code.exe' 2
        if ($found) { $CodeExe = $found; $VSCodeDir = Split-Path -Parent $found }
    }
    $CodeCmd = Join-Path $VSCodeDir 'bin\code.cmd'

    if (Test-Path -LiteralPath $CodeExe) {
        Write-OK "Ya existe: $VSCodeDir"
    }
    else {
        $inst = Find-Installer 'vscode' @('VSCode-win32-x64-*.zip', '*.zip')
        if (-not $inst) {
            Write-Fail "No hay VS Code en $PortablesDir ni zip en installers\vscode"
        }
        elseif ($DryRun) {
            Write-Dry "Descomprimiría $($inst.Name) en $VSCodeDir"
        }
        else {
            Unblock-File -LiteralPath $inst.FullName -ErrorAction SilentlyContinue
            Write-Info "Descomprimiendo $($inst.Name) (puede tardar)..."
            Expand-ZipFlat $inst.FullName $VSCodeDir
        }
    }

    if (Test-Path -LiteralPath $CodeExe) {
        # En TEST: carpeta "data" = modo portable -> extensiones y ajustes quedan dentro de modelado_test
        if ($TestMode) { Ensure-Directory (Join-Path $VSCodeDir 'data') }

        Add-SessionPath @((Join-Path $VSCodeDir 'bin'))
        Write-OK 'Visual Studio Code disponible.'
        Add-Result 'VS Code' 'OK'

        if (-not $SkipVSCodeExtension -and (Test-Path -LiteralPath $CodeCmd)) {
            if ($DryRun) {
                Write-Dry "Instalaría la extensión $VSCODE_EXTENSION"
            }
            else {
                $list = Invoke-Native $CodeCmd @('--list-extensions')
                if ($list.Output -match [regex]::Escape($VSCODE_EXTENSION)) {
                    Write-OK 'Extensión Open in External App ya instalada.'
                }
                else {
                    $r = Invoke-Native $CodeCmd @('--install-extension', $VSCODE_EXTENSION)
                    if ($r.ExitCode -eq 0) { Write-OK 'Extensión Open in External App instalada.' }
                    else { Write-Warn 'No se pudo instalar la extensión (¿red o marketplace bloqueado?). Instálala desde VS Code.' }
                }
            }
        }
    }
    elseif ($DryRun) { Add-Result 'VS Code' 'SIMULADO' }
    else             { Add-Result 'VS Code' 'FALTA' 'Revisa installers\vscode' }

    # ---------- 6. dbt ----------
    Write-Step "6. dbt-core $DBT_CORE_VERSION + dbt-snowflake $DBT_SNOWFLAKE_VERSION"

    if ($SkipDbt) {
        Write-Warn 'Omitido (-SkipDbt).'
        Add-Result 'dbt' 'OMITIDO'
    }
    elseif (-not $PythonExe) {
        if ($DryRun) {
            Write-Dry "Instalaría dbt-core==$DBT_CORE_VERSION y dbt-snowflake==$DBT_SNOWFLAKE_VERSION con el Python portable"
            Add-Result 'dbt' 'SIMULADO'
        }
        else {
            Write-Fail 'Sin el Python portable no se puede instalar dbt.'
            Add-Result 'dbt' 'FALTA' 'Requiere Python'
        }
    }
    else {
        $core = Get-PipPackageVersion 'dbt-core'
        $snow = Get-PipPackageVersion 'dbt-snowflake'

        if ($core -eq $DBT_CORE_VERSION -and $snow -eq $DBT_SNOWFLAKE_VERSION) {
            Write-OK "Ya instalados (dbt-core $core, dbt-snowflake $snow)."
        }
        elseif ($DryRun) {
            Write-Dry "Instalaría versiones fijadas (actual: dbt-core=$core, dbt-snowflake=$snow)"
        }
        else {
            # Siempre con la ruta completa del Python portable, nunca "python" a secas
            $pipArgs = @('-m', 'pip', 'install', '--upgrade', '--disable-pip-version-check',
                         "dbt-core==$DBT_CORE_VERSION", "dbt-snowflake==$DBT_SNOWFLAKE_VERSION")

            Write-Info 'Instalando con pip (puede tardar varios minutos)...'
            $code = Invoke-NativeLive $PythonExe $pipArgs

            if ($code -ne 0) {
                Write-Warn 'Ha fallado. Reintentando con --trusted-host (red SEAT)...'
                $code = Invoke-NativeLive $PythonExe ($pipArgs + $PIP_TRUSTED_HOSTS)
            }
            if ($code -ne 0) {
                Write-Fail 'No se pudo instalar dbt.'
                Write-Info 'Conéctate al hotspot del móvil y vuelve a lanzar el script: no reinstala lo que ya está bien.'
            }

            $core = Get-PipPackageVersion 'dbt-core'
            $snow = Get-PipPackageVersion 'dbt-snowflake'
        }

        if ($core -eq $DBT_CORE_VERSION -and $snow -eq $DBT_SNOWFLAKE_VERSION) {
            Add-Result 'dbt' 'OK' "core $core / snowflake $snow"
        }
        elseif ($DryRun) { Add-Result 'dbt' 'SIMULADO' }
        else             { Add-Result 'dbt' 'ERROR' "core=$core / snowflake=$snow" }
    }

    # ---------- 7. DbSchema ----------
    Write-Step '7. DbSchema 10.1.4 (portable)'

    $DbSchemaExe = Join-Path $DbSchemaDir 'DbSchema.exe'
    if (-not (Test-Path -LiteralPath $DbSchemaExe)) {
        $found = Find-ExistingExe 'DbSchema.exe' 2
        if ($found) {
            $DbSchemaExe = $found
            $DbSchemaDir = Split-Path -Parent $found
            if ((Split-Path -Leaf $DbSchemaDir) -match '\d') {
                Write-Warn "DbSchema está en una ruta con versión ($DbSchemaDir). La guía recomienda portables\dbschema_windows."
            }
        }
    }

    if (Test-Path -LiteralPath $DbSchemaExe) {
        Write-OK "Ya existe: $DbSchemaDir"
    }
    else {
        $inst = Find-Installer 'dbschema' @('dbschema_windows*.zip', '*.zip')
        if (-not $inst) {
            Write-Fail "No hay DbSchema en $PortablesDir ni zip en installers\dbschema"
        }
        elseif ($DryRun) {
            Write-Dry "Descomprimiría $($inst.Name) en $DbSchemaDir (ruta SIN versión)"
        }
        else {
            Unblock-File -LiteralPath $inst.FullName -ErrorAction SilentlyContinue
            Write-Info "Descomprimiendo $($inst.Name)..."
            Expand-ZipFlat $inst.FullName $DbSchemaDir
            if (-not (Test-Path -LiteralPath $DbSchemaExe)) {
                Write-Warn "No se encuentra DbSchema.exe en la raíz de $DbSchemaDir. Revisa el contenido del zip."
            }
        }
    }

    if (Test-Path -LiteralPath $DbSchemaExe) {
        Write-OK 'DbSchema disponible.'
        Add-Result 'DbSchema' 'OK'

        if (-not $SkipDbsAssociation) {
            if ($TestMode) {
                Write-Info 'Modo TEST: no se asocian los .dbs (es un ajuste de tu usuario real).'
            }
            elseif ($DryRun) {
                Write-Dry 'Asociaría los .dbs con DbSchema solo para tu usuario (HKCU, sin admin).'
            }
            else {
                try {
                    $cls    = 'HKCU:\Software\Classes'
                    $progId = 'DbSchema.Project'
                    Ensure-RegKey "$cls\.dbs"
                    Set-ItemProperty -Path "$cls\.dbs" -Name '(default)' -Value $progId
                    Ensure-RegKey "$cls\$progId\shell\open\command"
                    Set-ItemProperty -Path "$cls\$progId" -Name '(default)' -Value 'DbSchema Project'
                    Set-ItemProperty -Path "$cls\$progId\shell\open\command" -Name '(default)' -Value "`"$DbSchemaExe`" `"%1`""
                    Write-OK 'Ficheros .dbs asociados a DbSchema (usuario actual).'
                    Write-Info 'Si Windows los sigue abriendo con otra app: clic derecho > Abrir con > DbSchema.exe > Usar siempre.'
                }
                catch {
                    Write-Warn 'No se pudo asociar .dbs (posible política). Hazlo a mano con "Abrir con".'
                }
            }
        }
    }
    elseif ($DryRun) { Add-Result 'DbSchema' 'SIMULADO' }
    else             { Add-Result 'DbSchema' 'FALTA' 'Revisa installers\dbschema' }

    # ---------- 8. PATH ----------
    Write-Step '8. PATH'

    $UserPathEntries = @()
    if ($PythonDir) { $UserPathEntries += $PythonDir; $UserPathEntries += $PythonScripts }
    if (Test-Path -LiteralPath (Join-Path $GitDir 'bin'))    { $UserPathEntries += (Join-Path $GitDir 'bin') }
    if (Test-Path -LiteralPath (Join-Path $VSCodeDir 'bin')) { $UserPathEntries += (Join-Path $VSCodeDir 'bin') }

    if ($DryRun) {
        if ($UserPathEntries.Count -eq 0) {
            Write-Dry 'Añadiría al PATH del USUARIO: Python, Python\Scripts, PortableGit\bin y VSCode\bin'
        }
        foreach ($p in $UserPathEntries) { Write-Dry "Añadiría al PATH del USUARIO: $p" }
        Write-Dry 'El PATH del sistema no se toca nunca.'
    }
    elseif ($TestMode) {
        # En TEST no se toca tu PATH: se genera un lanzador que activa el entorno solo en esa ventana
        $ActivationCmd = Join-Path $Root 'abrir_terminal_test.cmd'
        $lines = @(
            '@echo off',
            "set `"PATH=$($UserPathEntries -join ';');%PATH%`"",
            'echo Entorno de TEST activado (solo en esta ventana).',
            'cmd /k'
        )
        Set-Content -LiteralPath $ActivationCmd -Value $lines -Encoding Default
        Write-OK "Lanzador de pruebas creado: $ActivationCmd"
        Write-Info 'Tu PATH real NO se ha modificado.'
        Add-Result 'PATH' 'OK' 'Solo lanzador de test'
    }
    else {
        if ($UserPathEntries.Count -gt 0) {
            Add-UserPathEntries $UserPathEntries
            Add-Result 'PATH usuario' 'OK'
        }
        else {
            Write-Warn 'No hay rutas que añadir.'
            Add-Result 'PATH usuario' 'AVISO' 'Sin herramientas'
        }
    }

    # ---------- 9. Carpeta .dbt del squad ----------
    Write-Step "9. Carpeta .dbt del squad ($TransformName)"

    if ($DryRun) {
        Write-Dry "La private key debería quedar en: $KeyDest"
    }
    elseif (Test-Path -LiteralPath $KeyDest) {
        Write-OK "Private key en su sitio: $KeyDest"
        Add-Result 'Private key' 'OK'
    }
    elseif ($IsCI) {
        # En CI nunca hay private key (y nunca debe subirse al repo)
        Write-Info 'CI: no se comprueba la private key.'
        Add-Result 'Private key' 'OMITIDO' 'CI'
    }
    else {
        Write-Warn 'Todavía no está la private key. Cuando la tengas, cópiala con este nombre:'
        Write-Info $KeyDest
        Add-Result 'Private key' 'PENDIENTE' 'Copiar .p8'
    }

    # ---------- 10. Accesos directos ----------
    Write-Step '10. Accesos directos'
    New-DesktopShortcut 'Visual Studio Code' $CodeExe
    New-DesktopShortcut 'DbSchema' $DbSchemaExe
    if ($TestMode) { Write-Info "En modo TEST se crean en: $DesktopDir" }

    # ---------- 11. Comprobación final ----------
    Write-Step '11. Comprobación final'

    if ($DryRun) {
        Write-Dry 'Ejecutaría python --version, git --version y dbt --version.'
    }
    else {
        if ($PythonExe) { Write-OK (Invoke-Native $PythonExe @('--version')).Output }
        if (Test-Path -LiteralPath $GitExe) { Write-OK (Invoke-Native $GitExe @('--version')).Output }
        if ($DbtExe -and (Test-Path -LiteralPath $DbtExe)) {
            $r = Invoke-Native $DbtExe @('--version')
            foreach ($line in ($r.Output -split "`r?`n")) { Write-Info $line }
        }

        if (-not $TestMode -and $PythonExe) {
            # ¿Qué python.exe encontrará una terminal NUEVA? (PATH sistema + PATH usuario)
            $combined = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                        [Environment]::GetEnvironmentVariable('Path', 'User')
            $firstPython = $null
            foreach ($d in ($combined -split ';')) {
                if (-not $d.Trim()) { continue }
                try {
                    $candidate = Join-Path ([Environment]::ExpandEnvironmentVariables($d.Trim())) 'python.exe'
                    if (Test-Path -LiteralPath $candidate) { $firstPython = $candidate; break }
                }
                catch { }
            }

            if ($firstPython -and ($firstPython -ne $PythonExe)) {
                Write-Warn "Una terminal nueva usará antes este python: $firstPython"
                if ($firstPython -match 'WindowsApps') {
                    Write-Info 'Desactiva los alias: Configuración > Alias de ejecución de aplicaciones > python.exe y python3.exe'
                }
                else {
                    Write-Info 'Hay otro Python en el PATH del sistema. Consúltalo con soporte o usa la ruta completa.'
                }
            }
            elseif ($firstPython) {
                Write-OK 'Las terminales nuevas usarán el Python portable.'
            }
        }
    }

    # ---------- Resumen ----------
    Write-Host ''
    Write-Host '=============================================' -ForegroundColor DarkYellow
    Write-Host '                  RESUMEN'                      -ForegroundColor Yellow
    Write-Host '=============================================' -ForegroundColor DarkYellow
    $Results | Format-Table -AutoSize | Out-Host

    $pending = @($Results | Where-Object { $_.Estado -in @('FALTA', 'ERROR', 'PENDIENTE') })

    if ($DryRun) {
        Write-Host 'Simulación completada. No se ha modificado nada.' -ForegroundColor Green
    }
    elseif ($pending.Count -gt 0) {
        Write-Host "Configuración INCOMPLETA: $($pending.Count) punto(s) en FALTA / ERROR / PENDIENTE." -ForegroundColor Yellow
        Write-Host 'Corrígelos y vuelve a lanzar el script: no repite lo que ya está bien.'
        if ($TestMode) { Write-Host "Para deshacer la prueba, borra la carpeta: $Root" }
        $exitCode = 2
    }
    elseif ($TestMode) {
        Write-Host 'Prueba completada. Tu entorno real no se ha modificado.' -ForegroundColor Green
        Write-Host "Todo está en: $Root"
        if ($ActivationCmd) { Write-Host "Para probar las herramientas abre: $ActivationCmd" }
        Write-Host "Para deshacer la prueba, borra la carpeta: $Root"
    }
    else {
        Write-Host 'Configuración completada.' -ForegroundColor Green
        Write-Host 'Cierra esta ventana y abre una terminal NUEVA para que coja el PATH.'
        Write-Host 'Comprueba: python --version  |  git --version  |  dbt --version'
    }
}
catch {
    Write-Fail "Error inesperado: $($_.Exception.Message)"
    Write-Info "Línea: $($_.InvocationInfo.ScriptLineNumber)"
    $exitCode = 1
}
finally {
    if ($transcriptStarted) {
        Stop-Transcript | Out-Null
        Write-Info "Log guardado en: $LogDir"
    }
    Write-Host ''
    if (-not $NoPause) { Read-Host 'Pulsa ENTER para cerrar' | Out-Null }
}

exit $exitCode
