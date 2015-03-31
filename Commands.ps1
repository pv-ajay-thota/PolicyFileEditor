#requires -Version 2.0

$scriptRoot = Split-Path $MyInvocation.MyCommand.Path
. "$scriptRoot\Common.ps1"

<#
.SYNOPSIS
   Creates or modifies a value in a .pol file.
.DESCRIPTION
   Creates or modifies a value in a .pol file.  By default, also updates the version number in the policy's gpt.ini file.
.PARAMETER Path
   Path to the .pol file that is to be modified.
.PARAMETER Key
   The registry key inside the .pol file that you want to modify.
.PARAMETER ValueName
   The name of the registry value.  May be set to an empty string to modify the default value of a key.
.PARAMETER Data
   The new value to assign to the registry key / value.  Cannot be $null, but can be set to an empty string or empty array.
.PARAMETER Type
   The type of registry value to set in the policy file.  Cannot be set to Unknown or None, but all other values of the RegistryValueKind enum are legal.
.PARAMETER NoGptIniUpdate
   When this switch is used, the command will not attempt to update the version number in the gpt.ini file
.EXAMPLE
   Set-PolicyFileEntry -Path $env:systemroot\system32\GroupPolicy\Machine\registry.pol -Key Software\Policies\Something -ValueName SomeValue -Data 'Hello, World!' -Type String

   Assigns a value of 'Hello, World!' to the String value Software\Policies\Something\SomeValue in the local computer Machine GPO.  Updates the Machine version counter in $env:systemroot\system32\GroupPolicy\gpt.ini
.EXAMPLE
   Set-PolicyFileEntry -Path $env:systemroot\system32\GroupPolicy\Machine\registry.pol -Key Software\Policies\Something -ValueName SomeValue -Data 'Hello, World!' -Type String -NoGptIniUpdate

   Same as example 1, except this one does not update gpt.ini right away.  This can be useful if you want to set multiple
   values in the policy file and only trigger a single Group Policy refresh.
.EXAMPLE
   Set-PolicyFileEntry -Path $env:systemroot\system32\GroupPolicy\Machine\registry.pol -Key Software\Policies\Something -ValueName SomeValue -Data '0x12345' -Type DWord

   Example demonstrating that strings with valid numeric data (including hexadecimal strings beginning with 0x) can be assigned to the numeric types DWord, QWord and Binary.
.INPUTS
   None.  This command does not accept pipeline input.
.OUTPUTS
   None.  This command does not generate output.
.NOTES
   If the specified policy file already contains the correct value, the file will not be modified, and the gpt.ini file will not be updated.
.LINK
   Get-PolicyFileEntry
.LINK
   Remove-PolicyFileEntry
.LINK
   Update-GptIniVersion
.LINK
   about_RegistryValuesForAdminTemplates
#>

function Set-PolicyFileEntry
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string] $Path,

        [Parameter(Mandatory = $true, Position = 1)]
        [string] $Key,

        [Parameter(Mandatory = $true, Position = 2)]
        [AllowEmptyString()]
        [string] $ValueName,

        [Parameter(Mandatory = $true, Position = 3)]
        [AllowEmptyString()]
        [AllowEmptyCollection()]
        [object] $Data,

        [ValidateScript({
            if ($_ -eq [Microsoft.Win32.RegistryValueKind]::Unknown)
            {
                throw 'Unknown is not a valid value for the Type parameter'
            }

            if ($_ -eq [Microsoft.Win32.RegistryValueKind]::None)
            {
                throw 'None is not a valid value for the Type parameter'
            }

            return $true
        })]
        [Microsoft.Win32.RegistryValueKind] $Type = [Microsoft.Win32.RegistryValueKind]::String,

        [switch] $NoGptIniUpdate
    )

    $policyFile = OpenPolicyFile -Path $Path -ErrorAction Stop
    $existingEntry = $policyFile.GetValue($key, $ValueName)

    if ($null -ne $existingEntry -and $Type -eq (PolEntryTypeToRegistryValueKind $existingEntry.Type))
    {
        $existingData = GetEntryData -Entry $existingEntry -Type $Type
        if (DataIsEqual $Data $existingData -Type $Type)
        {
            Write-Verbose 'Specified policy setting is already configured.  No changes were made.'
            return
        }
    }

    try
    {
        switch ($Type)
        {
            ([Microsoft.Win32.RegistryValueKind]::Binary)
            {
                $bytes = $Data -as [byte[]]
                if ($null -eq $bytes)
                {
                    throw 'When -Type is set to Binary, -Data must be passed a Byte[] array.'
                }
                else
                {
                    $policyFile.SetBinaryValue($Key, $ValueName, $bytes)
                }

                break
            }

            ([Microsoft.Win32.RegistryValueKind]::String)
            {
                $string = $Data.ToString()
                $policyFile.SetStringValue($Key, $ValueName, $string)
                break
            }

            ([Microsoft.Win32.RegistryValueKind]::ExpandString)
            {
                $string = $Data.ToString()
                $policyFile.SetStringValue($Key, $ValueName, $string, $true)
                break
            }

            ([Microsoft.Win32.RegistryValueKind]::DWord)
            {
                $dword = $Data -as [UInt32]
                if ($null -eq $dword)
                {
                    throw 'When -Type is set to DWord, -Data must be passed a valid UInt32 value.'
                }
                else
                {
                    $policyFile.SetDWORDValue($key, $ValueName, $dword)
                }

                break
            }

            ([Microsoft.Win32.RegistryValueKind]::QWord)
            {
                $qword = $Data -as [UInt64]
                if ($null -eq $qword)
                {
                    throw 'When -Type is set to QWord, -Data must be passed a valid UInt64 value.'
                }
                else
                {
                    $policyFile.SetQWORDValue($key, $ValueName, $qword)
                }

                break
            }

            ([Microsoft.Win32.RegistryValueKind]::MultiString)
            {
                $strings = [string[]] @(
                    foreach ($item in $data)
                    {
                        $item.ToString()
                    }
                )

                $policyFile.SetMultiStringValue($Key, $ValueName, $strings)

                break
            }

        } # switch ($Type)

        $doUpdateGptIni = -not $NoGptIniUpdate
        SavePolicyFile -PolicyFile $policyFile -UpdateGptIni:$doUpdateGptIni -ErrorAction Stop
    }
    catch
    {
        throw
    }
}

<#
.SYNOPSIS
   Retrieves the current setting(s) from a .pol file.
.DESCRIPTION
   Retrieves the current setting(s) from a .pol file.
.PARAMETER Path
   Path to the .pol file that is to be read.
.PARAMETER Key
   The registry key inside the .pol file that you want to read.
.PARAMETER ValueName
   The name of the registry value.  May be set to an empty string to read the default value of a key.
.PARAMETER All
   Switch indicating that all entries from the specified .pol file should be output, instead of searching for a specific key / ValueName pair.
.EXAMPLE
   Get-PolicyFileEntry -Path $env:systemroot\system32\GroupPolicy\Machine\registry.pol -Key Software\Policies\Something -ValueName SomeValue

   Reads the value of Software\Policies\Something\SomeValue from the Machine admin templates of the local GPO.
   Either returns an object with the data and type of this registry value (if present), or returns nothing, if not found.
.EXAMPLE
   Get-PolicyFileEntry -Path $env:systemroot\system32\GroupPolicy\Machine\registry.pol -All

   Outputs all of the registry values from the local machine Administrative Templates
.INPUTS
   None.  This command does not accept pipeline input.
.OUTPUTS
   If the specified registry value is found, the function outputs a PSCustomObject with the following properties:
      ValueName:  The same value that was passed to the -ValueName parameter
      Key:        The same value that was passed to the -Key parameter
      Data:       The current value assigned to the specified Key / ValueName in the .pol file.
      Type:       The RegistryValueKind type of the specified Key / ValueName in the .pol file.
   If the specified registry value is not found in the .pol file, the command returns nothing.  No error is produced.
.LINK
   Set-PolicyFileEntry
.LINK
   Remove-PolicyFileEntry
.LINK
   Update-GptIniVersion
.LINK
   about_RegistryValuesForAdminTemplates
#>

function Get-PolicyFileEntry
{
    [CmdletBinding(DefaultParameterSetName = 'ByKeyAndValue')]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string] $Path,

        [Parameter(Mandatory = $true, Position = 1, ParameterSetName = 'ByKeyAndValue')]
        [string] $Key,

        [Parameter(Mandatory = $true, Position = 2, ParameterSetName = 'ByKeyAndValue')]
        [string] $ValueName,

        [Parameter(Mandatory = $true, ParameterSetName = 'All')]
        [switch] $All
    )

    $policyFile = OpenPolicyFile -Path $Path -ErrorAction Stop

    if ($PSCmdlet.ParameterSetName -eq 'ByKeyAndValue')
    {
        $entry = $policyFile.GetValue($Key, $ValueName)

        if ($null -ne $entry)
        {
            PolEntryToPsObject -PolEntry $entry
        }
    }
    else
    {
        foreach ($entry in $policyFile.Entries)
        {
            PolEntryToPsObject -PolEntry $entry
        }
    }
}

<#
.SYNOPSIS
   Removes a value from a .pol file.
.DESCRIPTION
   Removes a value from a .pol file.  By default, also updates the version number in the policy's gpt.ini file.
.PARAMETER Path
   Path to the .pol file that is to be modified.
.PARAMETER Key
   The registry key inside the .pol file from which you want to remove a value.
.PARAMETER ValueName
   The name of the registry value to be removed.  May be set to an empty string to remove the default value of a key.
.PARAMETER NoGptIniUpdate
   When this switch is used, the command will not attempt to update the version number in the gpt.ini file
.EXAMPLE
   Remove-PolicyFileEntry -Path $env:systemroot\system32\GroupPolicy\Machine\registry.pol -Key Software\Policies\Something -ValueName SomeValue

   Removes the value Software\Policies\Something\SomeValue from the local computer Machine GPO, if present.  Updates the Machine version counter in $env:systemroot\system32\GroupPolicy\gpt.ini
.INPUTS
   None.  This command does not accept pipeline input.
.OUTPUTS
   None.  This command does not generate output.
.NOTES
   If the specified policy file is already not present in the .pol file, the file will not be modified, and the gpt.ini file will not be updated.
.LINK
   Get-PolicyFileEntry
.LINK
   Set-PolicyFileEntry
.LINK
   Update-GptIniVersion
.LINK
   about_RegistryValuesForAdminTemplates
#>

function Remove-PolicyFileEntry
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string] $Path,

        [Parameter(Mandatory = $true, Position = 1)]
        [string] $Key,

        [Parameter(Mandatory = $true, Position = 2)]
        [string] $ValueName,

        [switch] $NoGptIniUpdate
    )

    $policyFile = OpenPolicyFile -Path $Path -ErrorAction Stop
    $entry = $policyFile.GetValue($Key, $ValueName)

    if ($null -eq $entry)
    {
        Write-Verbose 'Specified policy setting already does not exist.  No changes were made.'
        return
    }

    $policyFile.DeleteValue($Key, $ValueName)
    $doUpdateGptIni = -not $NoGptIniUpdate
    SavePolicyFile -PolicyFile $policyFile -UpdateGptIni:$doUpdateGptIni -ErrorAction Stop
}

<#
.SYNOPSIS
   Increments the version counter in a gpt.ini file.
.DESCRIPTION
   Increments the version counter in a gpt.ini file.
.PARAMETER Path
   Path to the gpt.ini file that is to be modified.
.PARAMETER PolicyType
   Can be set to either 'Machine', 'User', or both.  This affects how the value of the Version number in the ini file is changed.
.EXAMPLE
   Update-GptIniVersion -Path $env:SystemRoot\system32\GroupPolicy\gpt.ini -PolicyType Machine

   Increments the Machine version counter of the local GPO.
.EXAMPLE
   Update-GptIniVersion -Path $env:SystemRoot\system32\GroupPolicy\gpt.ini -PolicyType User

   Increments the User version counter of the local GPO.
.EXAMPLE
   Update-GptIniVersion -Path $env:SystemRoot\system32\GroupPolicy\gpt.ini -PolicyType Machine,User

   Increments both the Machine and User version counters of the local GPO.
.INPUTS
   None.  This command does not accept pipeline input.
.OUTPUTS
   None.  This command does not generate output.
.NOTES
   A gpt.ini file contains only a single Version value.  However, this represents two separate counters, for machine and user versions.
   The high 16 bits of the value are the User counter, and the low 16 bits are the Machine counter.  For example (on PowerShell 3.0
   and later), the Version value when the Machine counter is set to 3 and the User counter is set to 5 can be found by evaluating this
   expression: (5 -shl 16) -bor 3 , which will show up as decimal value 327683 in the INI file.
.LINK
   Get-PolicyFileEntry
.LINK
   Set-PolicyFileEntry
.LINK
   Remove-PolicyFileEntry
.LINK
   about_RegistryValuesForAdminTemplates
#>

function Update-GptIniVersion
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateScript({
            if (Test-Path -LiteralPath $_ -PathType Leaf)
            {
                return $true
            }

            throw "Path '$_' does not exist."
        })]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Machine', 'User')]
        [string[]] $PolicyType
    )

    IncrementGptIniVersion @PSBoundParameters
}
