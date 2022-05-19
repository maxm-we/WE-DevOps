$LandingForm__frmMain.Add_Loaded({
    $LandingForm__frmMain.Icon = "$caller_root\media\logo.ico"
})

$LandingForm__btnDatabaseRestore.Add_Click({
    [void]$DatabaseRestore.ShowDialog()
})