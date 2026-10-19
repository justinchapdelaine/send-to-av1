<#
SPDX-License-Identifier: GPL-3.0-or-later

.SYNOPSIS
    Audit the actual GUI's WPF properties, styles, resources, and API references.
.DESCRIPTION
    On Windows, use the installed WPF runtime. For a metadata-only audit on
    PowerShell 7.4+, provide .NET Framework reference assemblies and the net8.0
    System.Reflection.MetadataLoadContext.dll. No reference code is executed.
#>
[CmdletBinding()]
param([string]$ReferenceDirectory, [string]$MetadataLoadContextPath)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$context = $null
$script:checks = 0
$script:types = @{}
$script:flags = [Reflection.BindingFlags]'Public, Instance, Static, FlattenHierarchy, IgnoreCase'
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Get-WpfType {
    param([string]$Name)
    if ($script:types.ContainsKey($Name)) { return $script:types[$Name] }
    $names = @($Name)
    if ($Name.StartsWith('Windows.')) { $names = @('System.' + $Name) }
    elseif ($Name -notmatch '\.') {
        $names = foreach ($ns in @('System.Windows', 'System.Windows.Controls', 'System.Windows.Controls.Primitives',
                'System.Windows.Shapes', 'System.Windows.Documents', 'System.Windows.Media',
                'System.Windows.Media.Animation', 'System.Windows.Input')) { $ns + '.' + $Name }
    }
    foreach ($fullName in $names) {
        foreach ($assembly in $script:assemblies) {
            $type = $assembly.GetType($fullName, $false)
            if ($null -ne $type) { $script:types[$Name] = $type; return $type }
        }
    }
    return $null
}
function Get-WpfMember {
    param($Type, [string]$Name)
    $members = @($Type.GetMember($Name, $script:flags))
    Assert-True ($members.Count -gt 0) ('Unknown public WPF member: ' + $Type.FullName + '.' + $Name)
    return $members[0]
}
function Get-WpfProperty {
    param($Type, [string]$Name)
    $property = $Type.GetProperty($Name, $script:flags)
    Assert-True ($null -ne $property) ('Unknown WPF property: ' + $Type.FullName + '.' + $Name)
    return $property
}
function Test-XamlProperty {
    param($Type, [string]$Name, [bool]$Writable)
    if ($Name.Contains('.')) {
        $owner, $member = $Name.Split('.', 2)
        $ownerType = Get-WpfType $owner
        Assert-True ($null -ne $ownerType) ('Unknown attached-property owner: ' + $owner)
        $setter = $ownerType.GetMethod('Set' + $member, $script:flags)
        Assert-True ($null -ne $setter -and $setter.IsStatic) ('Unknown attached setter: ' + $Name)
        return $setter.GetParameters()[1].ParameterType
    }
    $property = Get-WpfProperty $Type $Name
    if ($Writable) { Assert-True ($null -ne $property.SetMethod -and $property.SetMethod.IsPublic) ('WPF property is not writable: ' + $Type.FullName + '.' + $Name) }
    return $property.PropertyType
}
function Test-XamlValue {
    param($Type, [string]$Value)
    if ($Value.StartsWith('{')) { return }
    if ($Type.IsEnum) {
        Assert-True ($null -ne $Type.GetField($Value, $script:flags)) ('Unknown WPF enum value: ' + $Type.FullName + '.' + $Value)
    }
    elseif ($Type.FullName -eq 'System.Boolean') {
        $parsed = $false
        Assert-True ([bool]::TryParse($Value, [ref]$parsed)) ('Invalid Boolean value: ' + $Value)
    }
    elseif ($Type.FullName -eq 'System.Double') {
        $parsed = 0.0
        Assert-True ([double]::TryParse($Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) ('Invalid numeric value: ' + $Value)
    }
    elseif ($Type.FullName -eq 'System.Windows.FontWeight') {
        Get-WpfProperty (Get-WpfType 'FontWeights') $Value | Out-Null
    }
    elseif ($Type.FullName -eq 'System.Windows.Input.Cursor') {
        Get-WpfProperty (Get-WpfType 'Cursors') $Value | Out-Null
    }
    elseif ($Type.FullName -eq 'System.Windows.Media.Brush' -and $Value -notmatch '^#(?:[\da-fA-F]{3,4}|[\da-fA-F]{6}|[\da-fA-F]{8})$') {
        Get-WpfProperty (Get-WpfType 'Colors') $Value | Out-Null
    }
}
function Test-XamlNode {
    param([Xml.XmlElement]$Node, $TargetType)
    if ($Node.LocalName.Contains('.')) {
        $owner, $property = $Node.LocalName.Split('.', 2)
        Get-WpfProperty (Get-WpfType $owner) $property | Out-Null
    }
    else {
        $type = Get-WpfType $Node.LocalName
        Assert-True ($null -ne $type) ('Unknown XAML type: ' + $Node.LocalName)
        if ($Node.LocalName -in @('Style', 'ControlTemplate') -and $Node.HasAttribute('TargetType')) {
            $TargetType = Get-WpfType $Node.GetAttribute('TargetType')
            Assert-True ($null -ne $TargetType) 'Unknown style/template target type.'
        }
        foreach ($attribute in $Node.Attributes) {
            if ($attribute.NamespaceURI -ne '') { continue } # xmlns and x: directives
            $valueType = Test-XamlProperty $type $attribute.LocalName $true
            if ($attribute.Value -match '^\{DynamicResource ([^}]+)\}$') {
                Assert-True ($script:palette.ContainsKey($Matches[1])) ('Missing palette brush: ' + $Matches[1])
                if ($Node.LocalName -ne 'Setter' -or $attribute.LocalName -ne 'Value') {
                    Assert-True ($valueType.FullName -eq 'System.Windows.Media.Brush') ('Brush resource assigned to a non-brush property: ' + $attribute.LocalName)
                }
            }
            elseif ($attribute.Value -match '^\{StaticResource ([^}]+)\}$') {
                Assert-True ($script:styles.ContainsKey($Matches[1])) ('Missing style resource: ' + $Matches[1])
            }
            elseif ($attribute.Value -match '^\{TemplateBinding ([^}]+)\}$') {
                $boundType = Test-XamlProperty $TargetType $Matches[1] $false
                Assert-True ($valueType.IsAssignableFrom($boundType)) ('Incompatible template binding: ' + $attribute.Value)
            }
            else { Test-XamlValue $valueType $attribute.Value }
        }
        if ($Node.LocalName -in @('Setter', 'Trigger', 'Condition') -and $Node.HasAttribute('Property')) {
            $ownerType = $TargetType
            if ($Node.HasAttribute('TargetName')) { $ownerType = $script:named[$Node.GetAttribute('TargetName')] }
            Assert-True ($null -ne $ownerType) 'A setter/trigger has no known target.'
            $valueType = Test-XamlProperty $ownerType $Node.GetAttribute('Property') ($Node.LocalName -eq 'Setter')
            if (-not $Node.GetAttribute('Property').Contains('.')) {
                $field = $ownerType.GetField(($Node.GetAttribute('Property') + 'Property'), $script:flags)
                Assert-True ($null -ne $field -and $field.FieldType.FullName -eq 'System.Windows.DependencyProperty') ('A setter/trigger does not reference a dependency property: ' + $Node.GetAttribute('Property'))
            }
            if ($Node.HasAttribute('Value') -and $Node.GetAttribute('Value') -match '^\{DynamicResource ([^}]+)\}$') {
                Assert-True ($script:palette.ContainsKey($Matches[1]) -and $valueType.FullName -eq 'System.Windows.Media.Brush') 'A style setter references a missing or incompatible palette brush.'
            }
            elseif ($Node.HasAttribute('Value')) { Test-XamlValue $valueType $Node.GetAttribute('Value') }
        }
    }
    foreach ($child in $Node.ChildNodes) {
        if ($child -is [Xml.XmlElement]) { Test-XamlNode $child $TargetType }
    }
}
function Get-AstWpfType {
    param($Node)
    if ($Node -is [Management.Automation.Language.TypeExpressionAst]) { return Get-WpfType $Node.TypeName.FullName }
    if ($Node -is [Management.Automation.Language.VariableExpressionAst]) {
        switch ($Node.VariablePath.UserPath) {
            'window' { return Get-WpfType 'Window' }
            'brush' { return Get-WpfType 'Windows.Media.SolidColorBrush' }
            'icon' { return Get-WpfType 'Windows.Media.Imaging.BitmapFrame' }
            'timer' { return Get-WpfType 'Windows.Threading.DispatcherTimer' }
            'themeTimer' { return Get-WpfType 'Windows.Threading.DispatcherTimer' }
        }
        return $null
    }
    if ($Node -is [Management.Automation.Language.IndexExpressionAst] -and $Node.Target.Extent.Text -eq '$controls') {
        return Get-WpfType 'FrameworkElement' # dynamically indexed controls use SetResourceReference
    }
    if ($Node -is [Management.Automation.Language.MemberExpressionAst]) {
        if ($Node.Expression.Extent.Text -eq '$controls') { return $script:named[$Node.Member.Value] }
        $parentType = Get-AstWpfType $Node.Expression
        if ($null -eq $parentType) { return $null }
        if ($Node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $Node.Member.Value -eq 'new') { return $parentType }
        $member = Get-WpfMember $parentType $Node.Member.Value
        switch ($member.MemberType.ToString()) {
            'Property' { return $member.PropertyType }
            'Field' { return $member.FieldType }
            'Method' { return $member.ReturnType }
        }
    }
    return $null
}
try {
    if ($ReferenceDirectory) {
        if (-not $MetadataLoadContextPath) { throw 'Supply -MetadataLoadContextPath for a metadata-only audit.' }
        $ReferenceDirectory = (Resolve-Path -LiteralPath $ReferenceDirectory).ProviderPath
        $MetadataLoadContextPath = (Resolve-Path -LiteralPath $MetadataLoadContextPath).ProviderPath
        Add-Type -Path $MetadataLoadContextPath
        $paths = [string[]](Get-ChildItem -LiteralPath $ReferenceDirectory -Filter '*.dll' -File).FullName
        $resolver = [Reflection.PathAssemblyResolver]::new($paths)
        $context = [Reflection.MetadataLoadContext]::new($resolver, 'mscorlib')
        $script:assemblies = foreach ($name in @('PresentationFramework', 'PresentationCore', 'WindowsBase')) {
            $context.LoadFromAssemblyPath((Join-Path $ReferenceDirectory ($name + '.dll')))
        }
    }
    else {
        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Use Windows, or supply reference assemblies for a metadata-only audit.' }
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
        $script:assemblies = @([Windows.Window].Assembly, [Windows.Media.Brush].Assembly, [Windows.DependencyObject].Assembly)
    }
    Import-Module (Join-Path $repoRoot 'src/AV1.Theme.psm1') -Force
    $script:palette = Get-AV1ThemePalette Light
    Import-Module (Join-Path $repoRoot 'src/AV1.Xaml.psm1') -Force
    foreach ($guiPath in @('src/Show-AV1Progress.ps1', 'src/Show-AV1Setup.ps1')) {
        $source = Get-Content -Raw -LiteralPath (Join-Path $repoRoot $guiPath)
        $match = [regex]::Match($source, '(?s)\[xml\]\$layout = @''\r?\n(.*?)\r?\n''@')
        Assert-True $match.Success 'No GUI XAML found.'
        [xml]$xaml = $match.Groups[1].Value
        Add-AV1WindowResources -Layout $xaml
        $script:named = @{}
        foreach ($node in $xaml.SelectNodes('//*[@Name]')) { $script:named[$node.GetAttribute('Name')] = Get-WpfType $node.LocalName }
        $script:styles = @{}
        $namespaces = [Xml.XmlNamespaceManager]::new($xaml.NameTable)
        $namespaces.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml')
        foreach ($node in $xaml.SelectNodes('//*[@x:Key]', $namespaces)) {
            $script:styles[$node.GetAttribute('Key', 'http://schemas.microsoft.com/winfx/2006/xaml')] = $node
        }
        Test-XamlNode $xaml.DocumentElement $null
        foreach ($path in @('src/AV1.Theme.psm1', $guiPath)) {
            $tokens = $null; $errors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot $path), [ref]$tokens, [ref]$errors)
            Assert-True ($errors.Count -eq 0) ('PowerShell parse failure: ' + $path)
            foreach ($node in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.MemberExpressionAst] }, $true)) {
                $type = Get-AstWpfType $node.Expression
                if ($null -eq $type -or -not $type.FullName.StartsWith('System.Windows.')) { continue }
                if ($node.Member.Value -eq 'new') {
                    $argumentCount = 0
                    if ($null -ne $node.Arguments) { $argumentCount = $node.Arguments.Count }
                    Assert-True (@($type.GetConstructors() | Where-Object { $_.GetParameters().Count -eq $argumentCount }).Count -gt 0) ('No matching WPF constructor: ' + $type.FullName)
                }
                else { Get-WpfMember $type $node.Member.Value | Out-Null }
            }
        }
    }
    Write-Host ('WPF API and XAML contract checks passed: {0}.' -f $script:checks)
}
finally { if ($null -ne $context) { $context.Dispose() } }
