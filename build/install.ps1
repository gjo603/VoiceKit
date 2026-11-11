# VoiceKit one-line installer (ASCII only: Windows PowerShell 5.1 reads a
# BOM-less script as ANSI).
#
# Press Win+R, paste this, press Enter:
#
#   powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/gjo603/VoiceKit/master/build/install.ps1 | iex"
#
# It downloads the newest VoiceKit-Setup.zip from GitHub Releases, unpacks it
# to a temp folder and runs the same Install-VoiceKit.cmd the zip and the .exe
# use. Nothing needs to be preinstalled and nothing needs admin rights. A file
# PowerShell downloads is not tagged as "from the internet", so this route
# shows no SmartScreen prompt (the unsigned .exe does).
#
# No `exit` anywhere: under `irm | iex` it would close the caller's own shell.
& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'   # the progress bar makes 5.1 downloads crawl
    $url  = 'https://github.com/gjo603/VoiceKit/releases/latest/download/VoiceKit-Setup.zip'
    $work = Join-Path $env:TEMP ('VoiceKitSetup_' + [IO.Path]::GetRandomFileName())
    try {
        Write-Host ''
        Write-Host '  Downloading VoiceKit...'
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        $zip = Join-Path $work 'VoiceKit-Setup.zip'
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
        Write-Host '  Unpacking...'
        $pkg = Join-Path $work 'pkg'
        Expand-Archive -LiteralPath $zip -DestinationPath $pkg -Force
        $installer = Join-Path $pkg 'Install-VoiceKit.cmd'
        if (-not (Test-Path -LiteralPath $installer)) { throw 'The download did not contain Install-VoiceKit.cmd.' }
        & $env:ComSpec /c "`"$installer`""
        if ($LASTEXITCODE -ne 0) { throw "The installer reported a problem (code $LASTEXITCODE)." }
    } catch {
        Write-Host ''
        Write-Host ('  VoiceKit was not installed: ' + $_.Exception.Message) -ForegroundColor Red
        Write-Host '  You can download it by hand instead:'
        Write-Host '    https://github.com/gjo603/VoiceKit/releases/latest'
        Write-Host ''
        try { [void](Read-Host '  Press Enter to close') } catch { }
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}
