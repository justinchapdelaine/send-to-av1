<#
SPDX-License-Identifier: GPL-3.0-or-later

.SYNOPSIS
    Include shared control styles before WPF resolves a window's static resources.
#>
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Add-AV1WindowResources {
    param([Parameter(Mandatory = $true)][xml]$Layout)

    $path = Join-Path (Split-Path -Parent $PSScriptRoot) 'resources/AV1.Controls.xaml'
    [xml]$shared = Get-Content -Raw -LiteralPath $path
    $resources = $Layout.DocumentElement.SelectSingleNode('*[local-name()="Window.Resources"]')
    if ($null -eq $resources) { throw 'The window layout has no resource section.' }
    foreach ($node in $shared.DocumentElement.ChildNodes) {
        if ($node -is [Xml.XmlElement]) {
            $resources.AppendChild($Layout.ImportNode($node, $true)) | Out-Null
        }
    }
}

Export-ModuleMember -Function Add-AV1WindowResources
