$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function ReplaceStringsInString
{
    Param(
        [Parameter(Mandatory=$true)] [string]$text,
        [Hashtable]$replacements
    )

    if ($replacements -ne $null) 
    {
        foreach ($replacement in $replacements.GetEnumerator())
        {
            $text = $text -replace $replacement.Name, $replacement.Value
        }
    }
    $text
}

function ReplaceStringsInFile
{
    Param(
        [Parameter(Mandatory=$true)] [string]$filePath,
        [Hashtable]$replacements
    )

    if ($replacements -ne $null) 
    {
        $content = [System.IO.File]::ReadAllText($filePath)
        $content = ReplaceStringsInString -text $content -replacements $replacements
        [System.IO.File]::WriteAllText($filePath, $content, [System.Text.Encoding]::UTF8)
    }
}

function AddProjectItem
{
    Param(
        [Parameter(Mandatory=$true)] $project,
        [Parameter(Mandatory=$true)] [string]$destinationProjectRelativePath,
        [Parameter(Mandatory=$true)] [string]$templatePackageFolder,
        [Parameter(Mandatory=$true)] [string]$templateProjectRelativePath,
        [Hashtable]$contentReplacements
    )

    $projectFolder = Split-Path -Path $project.FullName -Parent

    $templatePath = Join-Path -Path $projectFolder -ChildPath $templateProjectRelativePath
    if (-not(Test-Path $templatePath))
    {
        $toolsPath = $PSScriptRoot
        $templatePath = Join-Path -Path $toolsPath -ChildPath "$templatePackageFolder\$templateProjectRelativePath"
        if (-not(Test-Path $templatePath)) { throw "Template file not found: $templatePath" }
    }

    $destinationPath = Join-Path -Path $projectFolder -ChildPath $destinationProjectRelativePath
    $destinationFolder = Split-Path -Path $destinationPath -Parent
    if (-not(Test-Path -Path $destinationFolder)) { $null = New-Item $destinationFolder -ItemType Directory -Force }

    if (Test-Path -Path $destinationPath) { Write-Host "NOT adding project item because it already exists: $destinationPath"; return }
    Write-Host "Adding project item: $destinationPath"
    Copy-Item -Path $templatePath -Destination $destinationPath -Force
    ReplaceStringsInFile -filePath $destinationPath -replacements $contentReplacements

    $null = $project.ProjectItems.AddFromFile($destinationPath)
    $null = $dte.ItemOperations.OpenFile($destinationPath)
}

function AddProjectItemsFromDirectory
{
    Param(
        [Parameter(Mandatory=$true)] $project,
        [Parameter(Mandatory=$true)] [string]$sourceDirectory,
        [string]$destinationDirectory,
        [Hashtable]$nameReplacements,
        [Hashtable]$contentReplacements
    )

    if (-not(Test-Path -Path $sourceDirectory)) { return }
    if ("$destinationDirectory" -eq '') { $destinationDirectory = Split-Path -Path $project.FullName -Parent }

    Get-ChildItem $sourceDirectory | ForEach-Object {
        $itemName = ReplaceStringsInString -text $_.Name -replacements $nameReplacements
        $destinationPath = Join-Path -Path $destinationDirectory -ChildPath $itemName
        $destinationPathExists = Test-Path -Path $destinationPath
        if ($_.PSIsContainer)
        {
            if (-not $destinationPathExists) { $null = New-Item -Path $destinationPath -ItemType directory }
            AddProjectItemsFromDirectory -project $project -sourceDirectory $_.FullName -destinationDirectory $destinationPath -nameReplacements $nameReplacements -contentReplacements $contentReplacements
        } else {
            if ($destinationPathExists) {
                Write-Host "NOT adding project item because it already exists: $destinationPath"
            } else {
                Write-Host "Adding project item: $destinationPath"
                Copy-Item -Path $_.FullName -Destination $destinationPath -Force
                ReplaceStringsInFile -filePath $destinationPath -replacements $contentReplacements
            }
            $null = $project.ProjectItems.AddFromFile($destinationPath)
        }
    }
}

function GetProjectPlatform
{
    Param([Parameter(Mandatory=$true)] $project, [switch]$allowUnknown)

    try   { $targetFrameworkMoniker = $project.Properties.Item("TargetFrameworkMoniker").Value } 
    catch { $targetFrameworkMoniker = 'none' }
    # E.g. valid target framework monikers are:
    # Windows Store:   .NETCore,Version=v4.5
    # Windows Phone:   WindowsPhone,Version=v8.0
    # Xamarin.Android: MonoAndroid,Version=v4.2
    # Xamarin.iOS:     TODO CHECK: MonoTouch?,?

    $targetFrameworkName = $targetFrameworkMoniker.Split(',')[0]
    switch ($targetFrameworkName)
    {
        'MonoAndroid'  { $platform = "android" }
        'MonoTouch'    { $platform = "ios"     }
        '.NETCore'     { $platform = "ws"      }
        'WindowsPhone' { $platform = "wp"      }
        default {
            if ($allowUnknown) { $platform = '' } else { throw "Unsupported target framework: " + $targetFrameworkName } 
        }
    }

    $platform
}

Function IsApplicationProject
{
    Param([Parameter(Mandatory=$true)] $project)

    $projectFileContent = [System.IO.File]::ReadAllText($project.FullName)
    $platform = GetProjectPlatform -project $project

    switch ($platform)
    {
        'android' { $isApplication = $projectFileContent -match '<\s*AndroidApplication\s*>\s*true\s*</\s*AndroidApplication\s*>' }
        'ios'     { $isApplication = $projectFileContent -match '<\s*OutputType\s*>\s*Exe\s*</\s*OutputType\s*>' }
        'ws'      { $isApplication = $projectFileContent -match '<\s*OutputType\s*>\s*AppContainerExe\s*</\s*OutputType\s*>' }
        'wp'      { $isApplication = $projectFileContent -match '<\s*SilverlightApplication\s*>\s*true\s*</\s*SilverlightApplication\s*>' }
        default   { throw "Unknown platform: " + $platform }
    }

    $isApplication
}

function EnsureConditionalCompilationSymbol
{
    Param(
        [Parameter(Mandatory=$true)] $project,
        [Parameter(Mandatory=$true)] [string]$define
    )

    if ($define -ne $null)
    {
        # Add the #define for the target framework, if needed.
        Write-Host "Ensuring $define conditional compilation symbol for all project configurations and platforms"
        $project.ConfigurationManager.ConfigurationRowNames | foreach-object {
            $project.ConfigurationManager.ConfigurationRow($_) | foreach-object { 
                $property = $_.Properties.Item('DefineConstants')
                if ($property -ne $null)
                {
                    $value = "$($property.value)".Trim()
                    if ($value -notmatch "\W*$define\W*") {
                        if ($value -ne '') { $value += ';' }
                        $value += $define
                        $property.value = $value
                    }
                }
            } 
        }
    }
}

function AddCsCodeFromInlineTemplate
{
    Param(
        [Parameter(Mandatory=$true)] [string]$csCode,
        [Parameter(Mandatory=$true)] [string]$templateName,
        [Hashtable]$replacements
    )

    # Format of an inline code template (first is an empty line):

    #
    # /* TODO: For each $templateName, any text
    # * optional comment lines
    # template lines
    # * optional comment lines
    # */

    $match = [regex]::Match($csCode, "(?m)\r\n\s*\r\n\s*/\*\s*TODO:\s+For\s+each\s+$templateName,[^\r\n]*\r\n(\s*\*\s[^\r\n]*\r\n)*(?<Template>(\s*[^\*\s][^\r\n]*\r\n)+)(\s*\*\s[^\r\n]*\r\n)*\s*\*/")
    if (-not ($match.Success)) { return $null }
    $captures = $match.Captures
    if (($captures -eq $null) -or ($captures.Count -eq 0)) { return $null }

    for ($i = $captures.Count - 1; $i -ge 0; $i--) # Iterate backwards through the text to keep unprocessed match positions valid while we insert text
    {
        $capture = $captures.Item($i)
        $insertPosition = $capture.Index + 2 # Insert right after the starting newline of the match
        $capture.Groups['Template'].Captures | ForEach-Object {
            $template = $_.Value
            $newCode = ReplaceStringsInString -text $template -replacements $replacements
            $csCode = $csCode.Insert($insertPosition, $newCode)
        }
    }

    $csCode
}

function Install-Mvvm
{
    Param(
       [string]$ProjectName
    )

    $projects = @()
    if ("$ProjectName" -eq '') { 
        $libraryProject = GetDefaultProject
        if ($libraryProject -eq $null)  { Write-Host "No library project found. Add a class library project for your target platform to the solution."; return }
        $applicationProject = GetDefaultProject -application
        if ($libraryProject -eq $null)  { Write-Host "No application project found. Add an application project for your target platform to the solution."; return }
 
        $projects += $libraryProject
        $projects += $applicationProject
    } else {
        $project = Get-Project $ProjectName
        if ($project -eq $null)  { Write-Host "Project '$ProjectName' not found in solution."; return }

        $projects += $project;
    }

    foreach ($project in $projects)
    {
        $ProjectName = $project.Name

        # Get the application name from the solution file name
        $solutionName = Split-Path ($project.DTE.Solution.FullName) -Leaf
        $appName = $solutionName.Split('.')[0]
        $defaultNamespace = $project.Properties.Item("DefaultNamespace").Value
        $platform = GetProjectPlatform -project $project
        $isApplication = IsApplicationProject -project $project
        $projectType = ('library', 'application')[$isApplication]

        Write-Host "Installing MvvmQuickCross $platform $projectType files in project $ProjectName ..."

        $toolsPath = $PSScriptRoot
        $nameReplacements = @{
            "_APPNAME_" = $appName
        }

        $csContentReplacements = GetContentReplacements -project $project -cs -isApplication:$isApplication
        $installSharedCode = -not $isApplication
        # TODO: ?check if the shared code is already present in another (referenced?) project in the solution, if not, install the shared code into the same project - to also support one-project solutions?
        #       OR: if shared code not installed, fail and give message to install and reference first? nonblocking Dialog needed?
        if ($installSharedCode) # Do the shared library file actions
        {
            $contentReplacements = @{
                '_APPNAME_' = $appName;
                'MvvmQuickCross\.Templates' = $defaultNamespace
            }
            $librarySourceDirectory = Join-Path -Path $toolsPath -ChildPath library
            AddProjectItemsFromDirectory -project $project -sourceDirectory $librarySourceDirectory -contentReplacements $contentReplacements

            # Create default project items
            AddProjectItem -project $project `
                            -destinationProjectRelativePath ('I{0}Navigator.cs' -f $appName) `
                            -templatePackageFolder          'library' `
                            -templateProjectRelativePath    'MvvmQuickCross\Templates\I_APPNAME_Navigator.cs' `
                            -contentReplacements            $csContentReplacements
            AddProjectItem -project $project `
                            -destinationProjectRelativePath ('{0}Application.cs' -f $appName) `
                            -templatePackageFolder          'library' `
                            -templateProjectRelativePath    'MvvmQuickCross\Templates\_APPNAME_Application.cs' `
                            -contentReplacements            $csContentReplacements
            New-ViewModel -ViewModelName Main
        }

        if ($isApplication) {
            $contentReplacements = @{
                '_APPNAME_' = $appName;
                'MvvmQuickCrossLibrary\.Templates' = $csContentReplacements['MvvmQuickCrossLibrary\.Templates'];
                'MvvmQuickCross\.Templates' = $defaultNamespace
            }

            $appSourceDirectory = Join-Path -Path $toolsPath -ChildPath "app.$platform"
            AddProjectItemsFromDirectory -project $project -sourceDirectory $appSourceDirectory -contentReplacements $contentReplacements

            # Create default project items
            switch ($platform)
            {
                'android' {
                    AddProjectItem -project $project `
                                   -destinationProjectRelativePath ('{0}Navigator.cs' -f $appName) `
                                   -templatePackageFolder          'app.android' `
                                   -templateProjectRelativePath    'MvvmQuickCross\Templates\_APPNAME_Navigator.cs' `
                                   -contentReplacements            $csContentReplacements
                    New-View -ViewName Main -ViewType MainLauncher
                }
                'wp' {
                    AddProjectItem -project $project `
                                   -destinationProjectRelativePath ('MvvmQuickCross\App.xaml.cs' -f $appName) `
                                   -templatePackageFolder          'app.wp' `
                                   -templateProjectRelativePath    'MvvmQuickCross\Templates\App.xaml.cs' `
                                   -contentReplacements            $csContentReplacements
                    AddProjectItem -project $project `
                                   -destinationProjectRelativePath ('{0}Navigator.cs' -f $appName) `
                                   -templatePackageFolder          'app.wp' `
                                   -templateProjectRelativePath    'MvvmQuickCross\Templates\_APPNAME_Navigator.cs' `
                                   -contentReplacements            $csContentReplacements
                    New-View -ViewName Main
                }
            }
        }

        $platformDefines = @{
            'android' = '__ANDROID__';
            'ios'     = '__IOS__';
            'ws'      = 'NETFX_CORE';
            'wp'      = 'WINDOWS_PHONE'
        }
        EnsureConditionalCompilationSymbol -project $project -define $platformDefines[$platform]

    }
}

function GetContentReplacements
{
    Param(
        [Parameter(Mandatory=$true)] $project,
        [switch]$cs,
        [switch]$isApplication
    )

    if ($cs) {
        $defaultNamespace = $project.Properties.Item("DefaultNamespace").Value
        $contentReplacements = @{
            'MvvmQuickCross.Templates' = $defaultNamespace;
            '(?m)^\s*#if\s+TEMPLATE\s+[^\r\n]*[\r\n]+' = '';
            '(?m)^\s*#endif\s+//\s*TEMPLATE[^\r\n]*[\r\n]*' = ''
        } 
        if ($isApplication) {
            $libraryProject = GetDefaultProject
            if ($libraryProject -eq $null)  { throw "No library project found. Add a class library project for your target platform to the solution." }
            $libraryDefaultNamespace = $libraryProject.Properties.Item("DefaultNamespace").Value
            $contentReplacements.Add('MvvmQuickCrossLibrary\.Templates', $libraryDefaultNamespace)
            $libraryAssemblyName =  $libraryProject.Properties.Item("AssemblyName").Value
            $contentReplacements.Add('MvvmQuickCrossLibraryAssembly', $libraryAssemblyName)
        }
    } else {
        $contentReplacements = @{ }
    }

    $solutionName = Split-Path ($project.DTE.Solution.FullName) -Leaf
    $appName = $solutionName.Split('.')[0]
    $contentReplacements.Add('_APPNAME_', $appName)

    $contentReplacements
}

function New-ViewModel
{
    Param(
        [Parameter(Mandatory=$true)] [string]$ViewModelName,
        [string]$ProjectName
    )

    if ("$ProjectName" -eq '') { $project = GetDefaultProject } else { $project = Get-Project $ProjectName }
    if ($project -eq $null)  { Write-Host "Project '$ProjectName' not found."; return }
    $ProjectName = $project.Name
    
    if (IsApplicationProject -project $project)
    {
        Write-Host "Project $ProjectName is an application project; view models should be coded in a library project. Either specify a library project with the ProjectName parameter, or omit the ProjectName parameter to use the first class library project in the solution."
        return
    }

    $csContentReplacements = GetContentReplacements -project $project -cs
    $csContentReplacements.Add('_VIEWNAME_', $ViewModelName)

    AddProjectItem -project $project `
                   -destinationProjectRelativePath ('ViewModels\{0}ViewModel.cs' -f $ViewModelName) `
                   -templatePackageFolder          'library' `
                   -templateProjectRelativePath    'MvvmQuickCross\Templates\_VIEWNAME_ViewModel.cs' `
                   -contentReplacements            $csContentReplacements
}

function GetDefaultProject
{
    Param([switch]$application)

    foreach ($project in $dte.Solution.Projects)
    {
        $platform = GetProjectPlatform -project $project -allowUnknown
        if ($platform -ne '')
        {
            $isApplication = IsApplicationProject -project $project
            if (-not ($application -xor $isApplication)) { return $project }
        }
    }

    return $null
}

function AddCsCodeFromInlineTemplateInVsEditor
{
    Param(
        [Parameter(Mandatory=$true)] [string]$itemPath,
        [Parameter(Mandatory=$true)] [string]$templateName,
        [Hashtable]$replacements
    )

    $window = $dte.ItemOperations.OpenFile($destinationPath)
    $document = $window.Document
    $textDocument = $document.Object('TextDocument')
    $editPoint = $textDocument.StartPoint.CreateEditPoint()
    $csCode = $editPoint.GetText($textDocument.EndPoint)
    
    $csCode = AddCsCodeFromInlineTemplate -csCode $csCode -templateName $templateName -replacements $replacements

}


function New-View
{
    Param(
        [Parameter(Mandatory=$true)] [string]$ViewName,
        [string]$ViewType,
        [string]$ViewModelName,
        [string]$ProjectName
    )

    if ("$ViewModelName" -eq '') { $ViewModelName = $ViewName }
    if ("$ProjectName" -eq '') { $project = Get-Project } else { $project = Get-Project $ProjectName }
    if ($project -eq $null)  { Write-Host "Project '$ProjectName' not found."; return }
    $ProjectName = $project.Name
    
    if (-not(IsApplicationProject -project $project))
    {
        Write-Host "Project $ProjectName is not an application project; views should be coded in an application project. Specify an application project with the ProjectName parameter or select an application project as the default project in the Package Manager Console."
        return
    }

    # Create the view model if it does not exist:
    New-ViewModel -ViewModelName $ViewModelName

    # Add the shared navigation code for the new view:
    $libraryProject = GetDefaultProject
    # TODO

    $csContentReplacements = GetContentReplacements -project $project -cs -isApplication
    $csContentReplacements.Add('_VIEWNAME_', $ViewName)

    $platform = GetProjectPlatform -project $project
    switch ($platform)
    {
        'android' {
            if ("$ViewType" -eq '') { $ViewType = 'Activity' }
            AddProjectItem -project $project `
                           -destinationProjectRelativePath ('{0}View.cs' -f $ViewName) `
                           -templatePackageFolder          'app.android' `
                           -templateProjectRelativePath    ('MvvmQuickCross\Templates\_VIEWNAME_{0}View.cs' -f $ViewType) `
                           -contentReplacements            $csContentReplacements
            AddProjectItem -project $project `
                           -destinationProjectRelativePath ('Resources\Layout\{0}View.axml' -f $ViewName) `
                           -templatePackageFolder          'app.android' `
                           -templateProjectRelativePath    'MvvmQuickCross\Templates\_VIEWNAME_View.axml.template' `
                           -contentReplacements            @{ '_VIEWNAME_' = $ViewName }
        }

        'wp' {
            if ("$ViewType" -eq '') { $ViewType = 'Page' }
            AddProjectItem -project $project `
                           -destinationProjectRelativePath ('{0}View.xaml' -f $ViewName) `
                           -templatePackageFolder          'app.wp' `
                           -templateProjectRelativePath    ('MvvmQuickCross\Templates\_VIEWNAME_{0}View.xaml.template' -f $ViewType) `
                           -contentReplacements            $csContentReplacements
            AddProjectItem -project $project `
                           -destinationProjectRelativePath ('{0}View.xaml.cs' -f $ViewName) `
                           -templatePackageFolder          'app.wp' `
                           -templateProjectRelativePath    ('MvvmQuickCross\Templates\_VIEWNAME_{0}View.xaml.cs' -f $ViewType) `
                           -contentReplacements            $csContentReplacements
        }

        default { Write-Host "New-View currenty only supports Android application projects"; return }
    }
}

Export-ModuleMember -Function Install-Mvvm
Export-ModuleMember -Function New-ViewModel
Export-ModuleMember -Function New-View