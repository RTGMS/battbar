# Reads the battery level that Windows exposes for paired Bluetooth devices.
# Output is a single JSON document on stdout so the Electron main process can
# parse it without relying on localized console text.

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$batteryKey = '{104EA319-6EE2-4701-BD47-8DDBF425BBE5} 2'
$presentKey = '{83DA6326-97A6-4088-9453-A1923F573B29} 15'
$seen = @{}
$results = New-Object System.Collections.Generic.List[object]

foreach ($deviceClass in @('Bluetooth', 'Mouse')) {
    $devices = @(Get-PnpDevice -Class $deviceClass -ErrorAction SilentlyContinue)
    foreach ($device in $devices) {
        if ([string]::IsNullOrWhiteSpace($device.InstanceId)) { continue }
        if ($seen.ContainsKey($device.InstanceId)) { continue }
        $seen[$device.InstanceId] = $true

        $batteryProperty = Get-PnpDeviceProperty -InstanceId $device.InstanceId -KeyName $batteryKey -ErrorAction SilentlyContinue
        if ($null -eq $batteryProperty) { continue }
        if ($batteryProperty.Type -eq 'Empty' -or $null -eq $batteryProperty.Data) { continue }

        $level = 0
        if (-not [int]::TryParse(([string]$batteryProperty.Data), [ref]$level)) { continue }
        if ($level -lt 0 -or $level -gt 100) { continue }

        $isPresent = $null
        $presentProperty = Get-PnpDeviceProperty -InstanceId $device.InstanceId -KeyName $presentKey -ErrorAction SilentlyContinue
        if ($null -ne $presentProperty -and $presentProperty.Type -ne 'Empty' -and $null -ne $presentProperty.Data) {
            try { $isPresent = [bool]$presentProperty.Data } catch { $isPresent = $null }
        }

        # A known-but-absent node often keeps its old battery value. Do not show it.
        if ($isPresent -eq $false) { continue }

        $results.Add([pscustomobject]@{
            name       = [string]$device.FriendlyName
            instanceId = [string]$device.InstanceId
            battery    = [int]$level
            status     = [string]$device.Status
            present    = $isPresent
            class      = [string]$device.Class
        })
    }
}

if ($results.Count -eq 0) {
    Write-Output '[]'
}
else {
    Write-Output (ConvertTo-Json -InputObject @($results) -Compress -Depth 4)
}
