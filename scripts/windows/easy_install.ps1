# scripts\windows\easy_install.ps1 -- the "easy button" for FractalSQL on
# DuckDB, Windows edition.
#
# One command takes a bare Windows box from nothing to a loaded extension:
# it downloads the release artifact that matches windows_amd64 and the
# DuckDB version you target, verifies it, places it in DuckDB's local
# extension directory, and prints the exact LOAD line.
#
# A DuckDB extension is not a system package: there is no .msi here and
# nothing is registered with the OS. Install means "the file sits where
# DuckDB's own layout expects it" and uninstall means "delete the file".
#
# Usage (repo checkout / already-downloaded copy):
#   powershell -NoProfile -File scripts\windows\easy_install.ps1 [-Help]
#     [-DuckDb <path>] [-DuckDbVersion v1.5.6] [-Release v2.0.0]
#     [-WithReasoning [-ReasoningUrl <url>] [-ReasoningModel <name>]]
#     [-NoMcp] [-NoVerify] [-Uninstall] [-DryRun]
#
# The MCP server is installed by default, from the bundle's mcp\ folder, next to the DuckDB library it runs on
# (-NoMcp skips it). See docs\mcp-plugin.md.
#
# -WithReasoning without -ReasoningUrl runs the interactive provider
# wizard (local Ollama / cloud endpoint / skip) and prints the
# FSQL_REASONING_HTTP_* lines to set in the shell that runs duckdb.
#
# Requires PowerShell 5.1 or newer (no other host tooling).
#
# No telemetry. This script never reports what it found or what it did.

[CmdletBinding()]
param(
    [string]$DuckDb = $env:DUCKDB_BIN,
    [string]$DuckDbVersion = "v1.5.6",
    [string]$Release = "",
    [string]$ReasoningUrl = "",
    [string]$ReasoningModel = "",
    [switch]$WithReasoning,
    [switch]$NoMcp,
    [switch]$NoVerify,
    [switch]$Uninstall,
    [switch]$DryRun,
    [switch]$Help
)

# Stamped in by release.yml (the placeholder is replaced with the tag's version before this file is uploaded as a
# release asset). A stamped script installs the release it was published with; -Release still overrides. Run from a
# checkout (unstamped) it keeps the old default of the latest release.
$FsqlVersion = '@@FSQL_VERSION@@'
if ($FsqlVersion -like '@@*') { $FsqlVersion = '' }
if ([string]::IsNullOrEmpty($Release) -and $FsqlVersion -ne '') { $Release = "v$FsqlVersion" }

$RepoBase = "https://github.com/FractalSQLabs/fractalsql-ext"
# The DuckDB release matrix this build's CI uploads (release.yml).
$SupportedDuckDbVersions = @("v1.4.5", "v1.5.6", "v2.0.0")
$DefaultDuckDbVersion    = "v1.5.6"
# windows_amd64 only: upstream DuckDB publishes no matching Windows ARM64
# CLI binary, so an ARM64 extension file could never be loaded downstream.
$PlatformTag   = "windows_amd64"
$ExtensionName = "fractalsql.duckdb_extension"
# DuckDB's own extension directory: <root>\<duckdb_version>\<platform>\fractalsql.duckdb_extension is what
# LOAD 'fractalsql' finds (run the CLI with -unsigned). The directory is shared with every other extension, so
# the files added beside the extension carry a fractalsql prefix and uninstall removes exactly those.
$InstallRoot   = Join-Path $env:USERPROFILE ".duckdb\extensions"
# Where earlier versions of this script wrote; only our own files lived there. Cleaned up on install and uninstall.
$LegacyRoot    = Join-Path $env:USERPROFILE ".duckdb\extensions.local\fractalsql"
# The MCP server (one per DuckDB version, because it runs on that version's duckdb.dll) goes to
# <root>\<duckdb_version>\<platform>\, with its DLL, lock files and manifest beside it.
$McpRoot       = Join-Path $env:USERPROFILE ".duckdb\fractalsql-mcp"
$Script:TargetVersion = $DuckDbVersion

$ProgressPreference = "SilentlyContinue"

function Write-Step([string]$Message)   { Write-Host "==> $Message" }
function Write-Ok([string]$Message)     { Write-Host "  ok: $Message" }
function Write-Notice([string]$Message) { Write-Host "  warn: $Message" -ForegroundColor Yellow }

function Show-Help {
    foreach ($line in (Get-Content -Path $PSCommandPath)) {
        if (-not $line.StartsWith("#")) { break }
        Write-Host ($line -replace '^# ?', '')
    }
    exit 0
}

function Get-NormalizedVersion([string]$Version) {
    return "v" + ($Version -replace '^[vV]+', '')
}

function Resolve-DuckDbCli {
    if ([string]::IsNullOrEmpty($DuckDb)) {
        $found = Get-Command duckdb -ErrorAction SilentlyContinue
        if ($null -eq $found) { return "" }
        return "duckdb"
    }
    if (-not (Test-Path "$DuckDb")) {
        $found = Get-Command $DuckDb -ErrorAction SilentlyContinue
        if ($null -eq $found) {
            throw "DuckDb is '$DuckDb' but that is not an executable path nor a PATH command."
        }
    }
    return $DuckDb
}

function Get-DuckDbCliVersion([string]$Cli) {
    if ("" -eq $Cli) { return "" }
    $first = (& $Cli --version 2>$null | Select-Object -First 1)
    if ($null -eq $first) { return "" }
    return Get-NormalizedVersion (($first.ToString().Trim() -split '\s+')[0])
}

function New-TempDir([string]$Prefix) {
    return Join-Path ([System.IO.Path]::GetTempPath()) ($Prefix + [System.IO.Path]::GetRandomFileName())
}

# Downloads over https only. Returns $false on failure (a missing release
# asset or companion is a normal condition the callers handle), and keeps
# the underlying error description in $script:LastError for the caller.
function New-Download([string]$Url, [string]$OutPath) {
    $script:LastError = ""
    if ($DryRun) {
        Write-Step "(--DryRun) would download: $Url"
        Set-Content -Path $OutPath -Value "dry-run placeholder"
        return $true
    }
    # PowerShell 5.1 ships without TLS 1.2 enabled by default; the
    # release endpoints require it. Best effort: some locked-down
    # machines disallow touching the setting at all.
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {
    }
    try {
        Write-Step "Downloading $(Split-Path -Leaf $OutPath)..."
        Invoke-WebRequest -Uri $Url -OutFile $OutPath -UseBasicParsing
        return $true
    } catch {
        if ($null -ne $_.Exception -and $null -ne $_.Exception.Response) {
            $script:LastError = "$([int]$_.Exception.Response.StatusCode) $($_.Exception.Response.StatusCode)"
        } else {
            $script:LastError = $_.Exception.Message
        }
        return $false
    }
}

# Verify <File> against the release's SHA256SUMS. A missing SHA256SUMS or a missing line: warn and go on.
# A mismatch: hard stop.
function Test-Sha256Sums([string]$File, [string]$SumsUrl) {
    if ($DryRun) {
        Write-Step "(--DryRun) skipping checksum comparison."
        return $true
    }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("fsql_sha_" + [System.IO.Path]::GetRandomFileName())
    if (-not (New-Download $SumsUrl $tmp)) {
        Write-Notice "no SHA256SUMS listed for this release; verification skipped (checksum your download some other way)."
        return $false
    }
    $name = Split-Path -Leaf $File
    $expected = ""
    foreach ($line in (Get-Content -Path $tmp)) {
        $parts = ($line.ToString().Trim()) -split '\s+', 2
        if ($parts.Count -eq 2 -and ($parts[1].TrimStart('*') -eq $name)) { $expected = $parts[0].ToLowerInvariant(); break }
    }
    Remove-Item -ErrorAction SilentlyContinue -Path $tmp
    if ([string]::IsNullOrEmpty($expected)) {
        Write-Notice "SHA256SUMS has no line for $name; verification skipped."
        return $false
    }
    $actual = (Get-FileHash -Path $File -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($expected -ne $actual) {
        throw "sha256 mismatch for $name (expected $expected, got $actual). Delete the file and retry."
    }
    Write-Ok "sha256 verified."
    return $true
}

# The reasoning plugin DLL is built against the dynamic C runtime (/MD) and imports VCRUNTIME140.dll, which comes
# from the Microsoft Visual C++ 2015-2022 Redistributable (x64). The extension itself is built /MT and does not need
# it. Reads the 64-bit registry view so a 32-bit PowerShell host sees the same answer.
function Test-VcRuntimeInstalled {
    try {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
        $key = $base.OpenSubKey("SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\X64")
        if ($null -eq $key) { return $false }
        return ($key.GetValue("Installed") -eq 1)
    } catch {
        return $false
    }
}

# Extension install flow. Returns a small result table; the reasoning
# plugin path is filled only when -WithReasoning ran.
function Install-FractalSqlPackage {
    $extensionAsset = "fractalsql.$Script:TargetVersion.$PlatformTag.duckdb_extension"
    $bundleName = "fractalsql-ext-$Script:TargetVersion-$PlatformTag"
    $bundleAsset = "$bundleName.zip"
    if ([string]::IsNullOrEmpty($Release)) {
        $assetBase = "$RepoBase/releases/latest/download"
    } else {
        $assetBase = "$RepoBase/releases/download/$Release"
    }

    $tmpDir = New-TempDir "fsql_ext_"
    New-Item -ItemType Directory -Path $tmpDir | Out-Null
    $destDir = Join-Path $InstallRoot (Join-Path $Script:TargetVersion $PlatformTag)

    try {
        # One bundle per (DuckDB version, platform): the extension, the reasoning plugin with its .sig, the MCP
        # server and the licences. Only the extension (and, on request, the plugin) is installed from it.
        $tmpBundle = Join-Path $tmpDir $bundleAsset
        if (-not (New-Download "$assetBase/$bundleAsset" $tmpBundle)) {
            throw "download failed: $bundleAsset ($Script:LastError). Check that the release page ($RepoBase/releases) has a bundle for DuckDB $Script:TargetVersion / $PlatformTag, or pass -DuckDbVersion for a still-listed cell."
        }
        Test-Sha256Sums $tmpBundle "$assetBase/SHA256SUMS" | Out-Null

        $srcDir = Join-Path $tmpDir $bundleName
        if ($DryRun) {
            Write-Step "(--DryRun) would unpack $bundleAsset"
            New-Item -ItemType Directory -Force -Path $srcDir | Out-Null
            Set-Content -Path (Join-Path $srcDir $extensionAsset) -Value "dry-run placeholder"
        } else {
            Expand-Archive -Path $tmpBundle -DestinationPath $tmpDir -Force
            if (-not (Test-Path (Join-Path $srcDir $extensionAsset))) {
                throw "$bundleAsset does not contain $extensionAsset."
            }
        }

        $destFile = Join-Path $destDir $ExtensionName
        if ($DryRun) {
            Write-Step "(--DryRun) would install $extensionAsset into $destDir\"
        } else {
            New-Item -ItemType Directory -Force -Path $destDir | Out-Null
            Copy-Item -Path (Join-Path $srcDir $extensionAsset) -Destination $destFile -Force
            Write-Ok "Installed $destFile"
            if (Test-Path $LegacyRoot) {
                Remove-Item -Recurse -Force -Path $LegacyRoot
                Write-Ok "Removed the old install under $LegacyRoot (earlier versions of this script put the extension there; DuckDB never looked in it)."
            }
        }

        $pluginPath = ""
        if ($WithReasoning) {
            # The reasoning plugin ships in the bundle together with its detached Ed25519 signature
            # (fractalsql-reasoning-http.dll and .dll.sig). The plugin loads only with the .sig beside it,
            # so both are installed.
            if (-not (Test-VcRuntimeInstalled)) {
                Write-Notice "the reasoning plugin needs the Microsoft Visual C++ 2015-2022 Redistributable (x64) (VCRUNTIME140.dll), which was not found. Without it the plugin will not load. Install it from https://aka.ms/vs/17/release/vc_redist.x64.exe. The extension itself does not need it."
            }
            if ($DryRun) {
                Write-Step "(--DryRun) would install fractalsql-reasoning-http.dll and its .sig into $destDir\"
            } else {
                foreach ($part in @("", ".sig")) {
                    $srcPlugin = Join-Path $srcDir "fractalsql-reasoning-http.dll$part"
                    if (-not (Test-Path $srcPlugin)) {
                        throw "the reasoning plugin and its .sig are not in $bundleAsset. Check that the release carries them."
                    }
                    Copy-Item -Path $srcPlugin -Destination (Join-Path $destDir "fractalsql-reasoning-http.dll$part") -Force
                }
                Write-Ok "Installed $(Join-Path $destDir 'fractalsql-reasoning-http.dll') (with its .sig)"
            }
            $pluginPath = Join-Path $destDir "fractalsql-reasoning-http.dll"
        } else {
            Write-Notice "Skipping the reasoning plugin (optional tier). To add it later, re-run with -WithReasoning; configuration is documented in docs/reasoning-setup.md (env vars only: FRACTALSQL_REASONING_PLUGIN plus FSQL_REASONING_HTTP_*)."
        }

        # The licence notices travel in the bundle. Write them next to the extension -- and next to the plugin,
        # which lands in the same directory -- so the installed copy carries the notices.
        foreach ($notice in @("LICENSE", "LICENSE-THIRD-PARTY")) {
            $srcNotice = Join-Path $srcDir $notice
            if ($DryRun) {
                Write-Step "(--DryRun) would write fractalsql-$notice into $destDir\"
            } elseif (Test-Path $srcNotice) {
                Copy-Item -Path $srcNotice -Destination (Join-Path $destDir "fractalsql-$notice") -Force
                Write-Ok "Installed $(Join-Path $destDir "fractalsql-$notice")"
            } else {
                Write-Notice "no $notice in $bundleAsset; the notices are not installed beside the extension."
            }
        }
        # The MCP server, from the bundle's mcp\ folder. Its OpenSSL is linked statically and duckdb.dll sits beside it, so
        # nothing else needs installing.
        $mcpDir = ""
        if ($NoMcp) {
            Write-Step "Skipping the MCP server (-NoMcp)."
        } elseif ($DryRun) {
            Write-Step "(--DryRun) would install the MCP server from the bundle's mcp\ into $(Join-Path $McpRoot (Join-Path $Script:TargetVersion $PlatformTag))\"
        } elseif (-not (Test-Path (Join-Path $srcDir "mcp"))) {
            Write-Notice "no mcp\ folder in $bundleAsset; the MCP server was not installed."
        } else {
            $mcpDir = Join-Path $McpRoot (Join-Path $Script:TargetVersion $PlatformTag)
            New-Item -ItemType Directory -Force -Path $mcpDir | Out-Null
            Copy-Item -Path (Join-Path $srcDir "mcp\*") -Destination $mcpDir -Recurse -Force
            Get-ChildItem -LiteralPath (Join-Path $srcDir "mcp") -Force -File -Filter ".*" -ErrorAction SilentlyContinue |
                ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $mcpDir -Force }
            Write-Ok "Installed the MCP server into $mcpDir"
        }
        return @{ ExtensionPath = (Join-Path $destDir $ExtensionName); PluginPath = $pluginPath; McpDir = $mcpDir }
    } finally {
        # Clean up the staging dir even in dry-run: its placeholder file
        # has served every later dry-run step by then.
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue -Path $tmpDir
    }
}

function Remove-FractalSqlPackage {
    $destDir = Join-Path $InstallRoot (Join-Path $Script:TargetVersion $PlatformTag)
    $ours = @($ExtensionName, "fractalsql-LICENSE", "fractalsql-LICENSE-THIRD-PARTY",
              "fractalsql-reasoning-http.dll", "fractalsql-reasoning-http.dll.sig")
    if ($DryRun) {
        Write-Step "(--DryRun) would remove FractalSQL's files from $destDir and the old $LegacyRoot (other extensions are not touched)."
        return
    }
    $mcpDirU = Join-Path $McpRoot (Join-Path $Script:TargetVersion $PlatformTag)
    Write-Step "This deletes FractalSQL's files from $destDir ($ExtensionName, the notices and the reasoning plugin if present), the MCP server in $mcpDirU, and the old $LegacyRoot if it exists. Other extensions in that directory are not touched."
    $answer = Read-Host "Remove them? [y/N]"
    if ($answer -match '^[Yy]') {
        foreach ($f in $ours) { Remove-Item -Force -ErrorAction SilentlyContinue -Path (Join-Path $destDir $f) }
        if (Test-Path $mcpDirU) { Remove-Item -Recurse -Force -Path $mcpDirU }
        foreach ($d in @((Join-Path $McpRoot $Script:TargetVersion), $McpRoot)) {
            if ((Test-Path $d) -and -not (Get-ChildItem -Force -Path $d)) { Remove-Item -Force -Path $d }
        }
        if (Test-Path $LegacyRoot) { Remove-Item -Recurse -Force -Path $LegacyRoot }
        Write-Ok "Removed. DuckDB extensions leave no other trace."
    }
}

# Restore one environment variable the smoke test temporarily set.
function Undo-TempEnv([string]$Name, [string]$Previous) {
    if ([string]::IsNullOrEmpty($Previous)) {
        Remove-Item "Env:$Name" -ErrorAction SilentlyContinue
    } else {
        Set-Item "Env:$Name" $Previous
    }
}

# --- reasoning provider wizard ---------------------------------------------
# The interactive provider setup, matching docs/reasoning-setup.md: pick
# local Ollama, a cloud OpenAI-compatible endpoint, or skip; prompt for
# any missing piece; return shell-ready FSQL_REASONING_HTTP_* values
# (the plugin reads its configuration from the process environment, so
# "configure reasoning" here means those env lines, not a SQL file).

function Prompt-Value([string]$Label, [string]$Default) {
    if (-not [string]::IsNullOrEmpty($Default)) {
        $reply = Read-Host "$Label (default: $Default)"
    } else {
        $reply = Read-Host $Label
    }
    if ([string]::IsNullOrEmpty($reply)) { return $Default }
    return $reply
}

function Prompt-Secret([string]$Label) {
    $secure = Read-Host $Label -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Select-ReasoningProvider {
    Write-Step "Reasoning provider:"
    Write-Host "  1) Local Ollama"
    Write-Host "  2) Cloud / OpenAI-compatible endpoint"
    Write-Host "  3) Skip: search-only install, configure reasoning later"
    $choice = Prompt-Value "Choice" "1"
    # switch is a statement, not an expression: `return switch ...` is a
    # ParserError, so assign its output first.
    $provider = switch ($choice) { '1' { 'ollama' } '2' { 'openai-compatible' } default { 'skip' } }
    return $provider
}

# Prompts for any missing piece exactly as the wizard needs, and returns
# the (possibly still empty, for 'skip') Provider plus an ordered
# FSQL_REASONING_HTTP_* table the caller prints for the user's shell.
function Resolve-ReasoningConfig {
    param(
        [string]$Provider, [string]$Url, [string]$Model, [string]$Token,
        [string]$EmbedUrl, [string]$EmbedModel, [string]$Think, [string]$ThinkProvider
    )
    $envcfg = [ordered]@{}
    switch ($Provider) {
        'ollama' {
            if (-not $Url) { $Url = Prompt-Value "Chat URL" "http://127.0.0.1:11434/v1/chat/completions" }
            if (-not $Model) { $Model = Prompt-Value "Chat model" "gpt-oss:20b" }
            if (-not $EmbedUrl) { $EmbedUrl = $Url }
            if (-not $EmbedModel) { $EmbedModel = Prompt-Value "Embedding model" "nomic-embed-text" }
            if (-not $Think) { $Think = 'off' }
            if (-not $ThinkProvider) { $ThinkProvider = 'ollama' }
            $envcfg["FSQL_REASONING_HTTP_URL"] = $Url
            $envcfg["FSQL_REASONING_HTTP_ALLOW_PLAINTEXT"] = "on"
            $envcfg["FSQL_REASONING_HTTP_MODEL"] = $Model
            $envcfg["FSQL_REASONING_HTTP_EMBED_URL"] = $EmbedUrl
            $envcfg["FSQL_REASONING_HTTP_EMBED_MODEL"] = $EmbedModel
            $envcfg["FSQL_REASONING_HTTP_THINK"] = $Think
            $envcfg["FSQL_REASONING_HTTP_THINK_PROVIDER"] = $ThinkProvider
        }
        'openai-compatible' {
            if (-not $Url) { Write-Host "a URL is required for a cloud/OpenAI-compatible endpoint" -ForegroundColor Red; exit 1 }
            if (-not $Model) { $Model = Prompt-Value "Model" "gpt-4o-mini" }
            if (-not $Token) { $Token = Prompt-Secret "API token (masked input, never shown back or logged)" }
            $envcfg["FSQL_REASONING_HTTP_URL"] = $Url
            $envcfg["FSQL_REASONING_HTTP_TOKEN"] = $Token
            $envcfg["FSQL_REASONING_HTTP_MODEL"] = $Model
        }
        default {
            Write-Step "Skipping reasoning config. Search functions like fractal_search and fractal_search_explore work with no model."
        }
    }
    return [pscustomobject]@{ Provider = $Provider; Url = $Url; Model = $Model; Env = $envcfg }
}

# Run proof queries through the found CLI in ONE invocation, and capture
# all streams into the log. Environment variables set in this process
# reach the child duckdb process, so the same invocation can carry both
# the LOAD and the later SQL (per-session config cannot be injected via
# a side file).
function Invoke-SmokeTest([string]$Cli, [hashtable]$InstallResult) {
    if ($NoVerify) {
        Write-Step "Skipping the LOAD proof (-NoVerify)."
        return
    }
    if ("" -eq $Cli -or $DryRun) {
        return
    }
    $extensionPath = $InstallResult.ExtensionPath

    Write-Step "Smoke-testing the load with $Cli..."
    $loadLine = "LOAD '$($extensionPath -replace '\\', '/')'; SELECT fractal_edition(), fractal_version();"
    $proof = $null
    $proofError = ""
    try {
        $proof = & $Cli -unsigned -c $loadLine 2>&1
    } catch {
        $proofError = $_.Exception.Message
    }
    if ($null -ne $proof) {
        $proof | ForEach-Object { Write-Host "  $_" }
    }
    if ("" -ne $proofError) {
        Write-Notice "Proof failed: $proofError"
        Write-Notice "If the DuckDB version or platform tag does not match your build, the loader refuses the file with an ABI error."
        return
    }
    $proofText = ($proof | Out-String)
    if ($proofText -match 'Community') {
        Write-Ok "Proof: the extension reports the FractalSQL Community edition."
    } else {
        Write-Notice "The load output above does not show 'Community'. If the platform tag or DuckDB version does not match your build, the loader refuses the file with an ABI error."
    }

    # Optional reasoning smoke: same session that ran the LOAD, since the
    # plugin is per-process state, not per-connection config written to a
    # file. Needs a URL; without -ReasoningUrl this step is skipped and
    # reasoning-setup docs take over.
    $pluginPath = $InstallResult.PluginPath
    if ($WithReasoning -and "" -ne $pluginPath -and "" -ne $ReasoningUrl) {
        $prevPlugin = $env:FRACTALSQL_REASONING_PLUGIN
        $prevModel  = $env:FSQL_REASONING_HTTP_MODEL
        if ("" -eq $ReasoningModel) {
            $env:FSQL_REASONING_HTTP_MODEL = ""
        } else {
            $env:FSQL_REASONING_HTTP_MODEL = $ReasoningModel
        }
        $env:FRACTALSQL_REASONING_PLUGIN = $pluginPath
        # Wizard-resolved token (cloud endpoint): same temporary-set and
        # undo pattern as the plugin path above.
        $prevToken = $env:FSQL_REASONING_HTTP_TOKEN
        if ($null -ne $Script:ResolvedReasoningEnv -and
            $Script:ResolvedReasoningEnv.Contains("FSQL_REASONING_HTTP_TOKEN")) {
            $env:FSQL_REASONING_HTTP_TOKEN = $Script:ResolvedReasoningEnv["FSQL_REASONING_HTTP_TOKEN"]
        }
        $urlHasBeenSet = $false
        if ("" -eq $env:FSQL_REASONING_HTTP_URL) {
            $env:FSQL_REASONING_HTTP_URL = $ReasoningUrl
            $urlHasBeenSet = $true
        }
        Write-Step "Reasoning smoke test: fractal_reason('say ok')..."
        $reasonLine = "LOAD '$($extensionPath -replace '\\', '/')'; SELECT fractal_reason('say ok');"
        $reply = $null
        $reasonError = ""
        try {
            $reply = & $Cli -unsigned -c $reasonLine 2>&1
        } catch {
            $reasonError = $_.Exception.Message
        }
        if ($null -ne $reply) {
            $reply | ForEach-Object { Write-Host "  $_" }
        }
        $replyText = ($reply | Out-String)
        if ("" -eq $reasonError -and $replyText -match '(?i)error') {
            $reasonError = $replyText.Trim()
        }
        if ("" -eq $reasonError) {
            Write-Ok "Reasoning smoke returned a reply."
        } else {
            $out = $replyText.Trim()
            if ("" -ne $out) { $reasonError = "$reasonError | output: $out" }
            # Keep the underlying exception message in the log, plus the
            # timeout advice, exactly the pair a support reader needs.
            Write-Notice "Reasoning smoke failed: $reasonError"
            Write-Notice "If that looks like a timeout on a slow or cold model, retry after the model warms up, or raise the wait ceilings first: FSQL_REASONING_HTTP_TIMEOUT_MS (total) and FSQL_REASONING_HTTP_LOW_SPEED_SECS (slow-response window), set in the shell before starting duckdb. See docs/reasoning-setup.md 'Handling Constrained Hardware'."
        }
        Undo-TempEnv "FRACTALSQL_REASONING_PLUGIN" $prevPlugin
        Undo-TempEnv "FSQL_REASONING_HTTP_MODEL" $prevModel
        Undo-TempEnv "FSQL_REASONING_HTTP_TOKEN" $prevToken
        if ($urlHasBeenSet) {
            Undo-TempEnv "FSQL_REASONING_HTTP_URL" ""
        }
    }
}

# --- main -----------------------------------------------------------------
if ($Help) { Show-Help }
if ([string]::IsNullOrEmpty($env:USERPROFILE)) {
    throw "USERPROFILE is unset; cannot determine an install location."
}

$targetVersion = Get-NormalizedVersion $DuckDbVersion
$cli           = Resolve-DuckDbCli
$cliVersion    = Get-DuckDbCliVersion $cli

if ("" -ne $cliVersion) {
    Write-Step "duckdb CLI reports $cliVersion."
    if (-not $PSBoundParameters.ContainsKey("DuckDbVersion")) {
        if ($SupportedDuckDbVersions -contains $cliVersion) {
            $targetVersion = $cliVersion
            Write-Step "Matching the CLI's release cell."
        } else {
            Write-Notice "The CLI's version is not a cell this release ships (supported: $($SupportedDuckDbVersions -join ', ')); defaulting to $targetVersion."
        }
    } elseif (-not ($SupportedDuckDbVersions -contains $targetVersion)) {
        Write-Notice "Target $targetVersion is not a cell this release ships (supported: $($SupportedDuckDbVersions -join ', '))."
    }
}

Write-Step "Platform: $PlatformTag | DuckDB target: $targetVersion | install root: $InstallRoot"

if ($Uninstall) {
    Remove-FractalSqlPackage
    exit 0
}

$Script:TargetVersion = $targetVersion
$result = Install-FractalSqlPackage

# The provider wizard: fill in the reasoning configuration when
# -WithReasoning was asked for but no -ReasoningUrl was supplied.
$Script:ResolvedReasoningEnv = $null
if ($WithReasoning -and "" -ne $result.PluginPath -and
    "" -eq $ReasoningUrl -and -not $DryRun) {
    $provided = Select-ReasoningProvider
    $resolved = Resolve-ReasoningConfig -Provider $provided `
        -Url $ReasoningUrl -Model $ReasoningModel
    $ReasoningUrl  = $resolved.Url
    $ReasoningModel = $resolved.Model
    $Script:ResolvedReasoningEnv = $resolved.Env
}

if (-not $DryRun) {
    $installPath = $result.ExtensionPath
    Write-Step "Load it (and check the version) with:"
    Write-Host "  duckdb -unsigned -c ""LOAD '$(($installPath -replace '\\', '/'))'; SELECT fractal_edition(), fractal_version();"""
    Write-Host "  (short form from any session, since the file sits in DuckDB's own extension directory:"
    Write-Host "   duckdb -unsigned -c ""LOAD 'fractalsql'"")"
    if ("" -ne $result.McpDir) {
        Write-Step "Start the MCP server (stdio) against the installed extension with:"
        Write-Host "  `$env:FSQL_DUCKDB_EXTENSION = '$($installPath -replace '\\', '/')'; `$env:FSQL_DUCKDB_ALLOW_UNSIGNED = 'true'; & '$(Join-Path $result.McpDir 'fractalsql-ext-mcp.exe')'"
        Write-Host "  (add --http PORT for the HTTP transport; see $(Join-Path $result.McpDir 'README.md'))"
    }
}

# The optional LOAD proof: same invocation pattern for edition + version,
# and (with -WithReasoning and a URL) for the reasoning tier.
Invoke-SmokeTest $cli $result

if ($WithReasoning -and "" -ne $result.PluginPath -and -not $DryRun) {
    Write-Step "Reasoning plugin at $($result.PluginPath). Activate it per process:"
    Write-Host "  `$env:FRACTALSQL_REASONING_PLUGIN = '$(($result.PluginPath -replace '\\', '/'))'"
    Write-Notice "Then set FSQL_REASONING_HTTP_URL / FSQL_REASONING_HTTP_MODEL (etc.) in the shell that starts duckdb -- full walkthrough in docs/reasoning-setup.md."
    if ($null -ne $Script:ResolvedReasoningEnv -and $Script:ResolvedReasoningEnv.Count -gt 0) {
        Write-Host "  From the provider flow, set (per shell, before starting duckdb):"
        foreach ($k in $Script:ResolvedReasoningEnv.Keys) {
            if ($k -eq 'FSQL_REASONING_HTTP_TOKEN') { Write-Host "    `$env:$k = '***'" }
            else { Write-Host "    `$env:$k = '$($Script:ResolvedReasoningEnv[$k])'" }
        }
    }
}

Write-Ok "Done. Re-running this script is safe; it just re-copies the extension."