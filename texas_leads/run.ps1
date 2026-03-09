# Texas Self-Storage Lead CSV Pipeline
# Requires: Python 3 with requests and shapely (pip install -r requirements.txt)
$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    if (Get-Command py -ErrorAction SilentlyContinue) { & py -3 -m pip install -q -r requirements.txt; & py -3 build_texas_storage_leads.py; exit }
    Write-Error "Python not found. Install Python 3 and run: pip install -r requirements.txt; python build_texas_storage_leads.py"
}
& python -m pip install -q -r requirements.txt
& python build_texas_storage_leads.py
