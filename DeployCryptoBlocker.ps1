# DeployCryptoBlocker.ps1
#
################################ Functions ################################

function ConvertFrom-Json20([Object] $obj)
{
    Add-Type -AssemblyName System.Web.Extensions
    $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    return ,$serializer.DeserializeObject($obj)
}

Function New-CBArraySplit {

    param(
        $extArr,
        $depth = 1
    )

    $extArr = $extArr | Sort-Object -Unique

    # Concatenate the input array
    $conStr = $extArr -join ','
    $outArr = @()

    # If the input string breaks the 4Kb limit
    If ($conStr.Length -gt 4096) {
        # Pull the first 4096 characters and split on comma
        $conArr = $conStr.SubString(0,4096).Split(',')
        # Find index of the last guaranteed complete item of the split array in the input array
        $endIndex = [array]::IndexOf($extArr,$conArr[-2])
        # Build shorter array up to that indexNumber and add to output array
        $shortArr = $extArr[0..$endIndex]
        $outArr += [psobject] @{
            index = $depth
            array = $shortArr
        }

        # Then call this function again to split further
        $newArr = $extArr[($endindex + 1)..($extArr.Count -1)]
        $outArr += New-CBArraySplit $newArr -depth ($depth + 1)
        
        return $outArr
    }
    # If the concat string is less than 4096 characters already, just return the input array
    Else {
        return [psobject] @{
            index = $depth
            array = $extArr
        }  
    }
}

################################ Functions ################################

# Add to all drives
$drivesContainingShares = Get-WmiObject Win32_Share | Select Name,Path,Type | Where-Object { $_.Type -eq 0 } | Select -ExpandProperty Path | % { "$((Get-Item -ErrorAction SilentlyContinue $_).Root)" } | Select -Unique
if ($drivesContainingShares -eq $null -or $drivesContainingShares.Length -eq 0)
{
    Write-Host "No drives containing shares were found. Exiting.."
    exit
}

Write-Host "The following shares needing to be protected: $($drivesContainingShares -Join ",")"

$majorVer = [System.Environment]::OSVersion.Version.Major
$minorVer = [System.Environment]::OSVersion.Version.Minor

Write-Host "Checking File Server Resource Manager.."

Import-Module ServerManager

if ($majorVer -ge 6)
{
    $checkFSRM = Get-WindowsFeature -Name FS-Resource-Manager

    if ($minorVer -ge 2 -and $checkFSRM.Installed -ne "True")
    {
        # Server 2012
        Write-Host "FSRM not found.. Installing (2012).."
        Install-WindowsFeature -Name FS-Resource-Manager -IncludeManagementTools
    }
    elseif ($minorVer -ge 1 -and $checkFSRM.Installed -ne "True")
    {
        # Server 2008 R2
        Write-Host "FSRM not found.. Installing (2008 R2).."
        Add-WindowsFeature FS-FileServer, FS-Resource-Manager
    }
    elseif ($checkFSRM.Installed -ne "True")
    {
        # Server 2008
        Write-Host "FSRM not found.. Installing (2008).."
        &servermanagercmd -Install FS-FileServer FS-Resource-Manager
    }
}
else
{
    # Assume Server 2003
    Write-Host "Other version of Windows detected! Quitting.."
    return
}

$fileGroupName = "CryptoBlockerGroup"
$fileTemplateName = "CryptoBlockerTemplate"
$fileScreenName = "CryptoBlockerScreen"

$webClient = New-Object System.Net.WebClient
$jsonStr = $webClient.DownloadString("https://fsrm.experiant.ca/api/v1/get")
$monitoredExtensions = @(ConvertFrom-Json20($jsonStr) | % { $_.filters })


If (Test-Path .\SkipList.txt) {
    $exclusions = Get-Content .\SkipList.txt
    ForEach ($exclusion in $exclusions) {
        if ($exclusion) {
            $monitoredExtensions = $monitoredExtensions.replace($exclusion.trim(),$null)
        }
    }
}
Else 
{
    $emptyFile = `
`
"#
# Add one filescreen per line that you want to ignore
#
# For example, if *.doc files are being blocked by the list but you want 
# to allow them, simply add a new line in this file that exactly matches 
# the filescreen:
#
# *.doc
#
# The script will check this file every time it runs and remove these 
# entries before applying the list to your FSRM implementation.
#

"
    Add-Content .\SkipList.txt $emptyFile

}


# Split the $monitoredExtensions array into fileGroups of less than 4kb to allow processing by filescrn.exe
$fileGroups = New-CBArraySplit $monitoredExtensions
ForEach ($group in $fileGroups) {
    $group | Add-Member -MemberType NoteProperty -Name fileGroupName -Value "$FileGroupName$($group.index)"
}

# Perform these steps for each of the 4KB limit split fileGroups
ForEach ($group in $fileGroups) {
    Write-Host "Adding/replacing File Group [$($group.fileGroupName)] with monitored file [$($group.array -Join ",")].."
    &filescrn.exe filegroup Delete "/Filegroup:$($group.fileGroupName)" /Quiet
    &filescrn.exe Filegroup Add "/Filegroup:$($group.fileGroupName)" "/Members:$($group.array -Join '|')"
}

Write-Host "Adding/replacing File Screen Template [$fileTemplateName] with Event Notification [$eventConfFilename] and Command Notification [$cmdConfFilename].."
&filescrn.exe Template Delete /Template:$fileTemplateName /Quiet
# Build the argument list with all required fileGroups
$screenArgs = 'Template','Add',"/Template:$fileTemplateName"
ForEach ($group in $fileGroups) {
    $screenArgs += "/Add-Filegroup:$($group.fileGroupName)"
}

&filescrn.exe $screenArgs

Write-Host "Adding/replacing File Screens.."
$drivesContainingShares | % {
    Write-Host "`tAdding/replacing File Screen for [$_] with Source Template [$fileTemplateName].."
    &filescrn.exe Screen Delete "/Path:$_" /Quiet
    &filescrn.exe Screen Add "/Path:$_" "/SourceTemplate:$fileTemplateName"
}
