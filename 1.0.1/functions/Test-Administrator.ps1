function Test-Administrator
{
    [OutputType([bool])]
    param()
    process {
        If ($IsWindows) {
            [Security.Principal.WindowsPrincipal]$user = [Security.Principal.WindowsIdentity]::GetCurrent();
            $isAdmin = $user.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator);

            if(-not $isAdmin) {
                Write-Host "This script must be executed as Administrator." -ForegroundColor red -BackgroundColor white
            }

            return $isAdmin
        }
        If ($IsMacOS) {
            return True
        }
    }
}