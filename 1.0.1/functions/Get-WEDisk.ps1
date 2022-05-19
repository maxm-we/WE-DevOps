function Get-WEDisk {
    [CmdletBinding()]
    param (
    )

    begin {
        # Loudly check for admin
        if(-not (Test-Administrator)) { return }
    }

    process {
        $Disks = Get-Disk | Sort-Object Number
        $outObj = [System.Collections.ArrayList]@()
        foreach ($disk in $Disks)
        {
            $partitions = Get-Partition -DiskNumber $disk.Number
            foreach ($part in ($partitions | Where-Object {$_.DriveLetter}))
            {
                $null = $outObj.Add([pscustomobject] @{
                    Number = $disk.number
                    AWSVolume = $disk.AdapterSerialNumber.Replace("vol","vol-")
                    DiskSizeGB = $disk.size/1gb
                    DriveLetter = $part.DriveLetter
                    PartitionSize = $part.size/1gb
                })
            }
        }
        $outObj
    }

}
