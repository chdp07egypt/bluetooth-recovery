param([switch]$SmokeTest)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
$form=New-Object System.Windows.Forms.Form
$form.Text='Bluetooth — диагностика и восстановление'
$form.Size=New-Object System.Drawing.Size(1000,740)
$form.MinimumSize=New-Object System.Drawing.Size(900,650)
$form.StartPosition='CenterScreen'
$form.Font=New-Object System.Drawing.Font('Segoe UI',10)
$heading=New-Object System.Windows.Forms.Label
$heading.Text='Bluetooth: найти причину и восстановить подключение'
$heading.Font=New-Object System.Drawing.Font('Segoe UI',16,[System.Drawing.FontStyle]::Bold)
$heading.SetBounds(20,15,940,40)
$form.Controls.Add($heading)
$hint=New-Object System.Windows.Forms.Label
$hint.Text="Сначала выполните диагностику. Перед восстановлением остановите запись и дождитесь сохранения.`r`nОтчёты сохраняются в папке reports рядом с приложением. Драйверы и сопряжения не удаляются."
$hint.SetBounds(20,62,940,50)
$form.Controls.Add($hint)
$bar=New-Object System.Windows.Forms.FlowLayoutPanel
$bar.SetBounds(20,120,940,95)
$bar.Anchor='Top,Left,Right'
$form.Controls.Add($bar)
$output=New-Object System.Windows.Forms.RichTextBox
$output.SetBounds(20,225,940,420)
$output.Anchor='Top,Bottom,Left,Right'
$output.ReadOnly=$true
$output.BackColor=[System.Drawing.Color]::FromArgb(246,248,251)
$output.Font=New-Object System.Drawing.Font('Consolas',10)
$form.Controls.Add($output)
$status=New-Object System.Windows.Forms.Label
$status.SetBounds(20,656,940,30)
$status.Anchor='Bottom,Left,Right'
$status.Text='Готово. Диагностика не изменяет настройки Windows.'
$form.Controls.Add($status)
$script:job=$null
$script:actionButtons=@()
$engine=Join-Path $PSScriptRoot 'engine.ps1'
function Begin-Action([string]$Action) {
    if ($script:job) { return }
    if ($Action -ne 'Diagnose') {
        $admin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (!$admin) { [System.Windows.Forms.MessageBox]::Show('Закройте это окно и запустите start-admin.cmd. Windows запросит права администратора.','Нужны права администратора') | Out-Null; return }
        $message=switch ($Action) {
            'Repair' {'Будут включены отключённые Bluetooth-адаптеры, запущена служба Bluetooth и выполнен поиск оборудования. Продолжить?'}
            'RestartAdapter' {'Bluetooth-мышь, клавиатура и наушники временно отключатся. Продолжить перезапуск адаптера?'}
            'Audio' {'Звук всех приложений временно прервётся. Сначала остановите и сохраните запись встречи. Продолжить?'}
        }
        if ([System.Windows.Forms.MessageBox]::Show($message,'Восстановление','YesNo','Warning') -ne 'Yes') { return }
    }
    $output.Clear()
    $status.Text='Выполняется проверка; результаты появляются ниже…'
    foreach ($b in $script:actionButtons) {$b.Enabled=$false}
    $script:job=Start-Job -ScriptBlock {param($path,$mode) & $path -Action $mode} -ArgumentList $engine,$Action
}
function Button([string]$Text,[scriptblock]$Click,[bool]$ActionButton=$false) {
    $b=New-Object System.Windows.Forms.Button
    $b.Text=$Text; $b.AutoSize=$true; $b.Height=36; $b.Margin=New-Object System.Windows.Forms.Padding(0,0,8,8)
    $b.Add_Click($Click); $bar.Controls.Add($b)
    if ($ActionButton) {$script:actionButtons+= $b}
}
Button '1. Диагностика' {Begin-Action 'Diagnose'} $true
Button '2. Восстановить Bluetooth' {Begin-Action 'Repair'} $true
Button 'Перезапустить адаптер' {Begin-Action 'RestartAdapter'} $true
Button 'Восстановить звук' {Begin-Action 'Audio'} $true
Button 'Параметры Bluetooth' {Start-Process 'ms-settings:bluetooth'}
Button 'Отчёты' { $p=Join-Path $PSScriptRoot 'reports'; New-Item -ItemType Directory -Force -Path $p | Out-Null; Start-Process explorer.exe -ArgumentList ('"'+$p+'"') }
$timer=New-Object System.Windows.Forms.Timer
$timer.Interval=400
$timer.Add_Tick({
    if (!$script:job) {return}
    $lines=@(Receive-Job $script:job -ErrorAction Continue 2>&1)
    if ($lines.Count) {$output.AppendText(($lines -join "`r`n")+"`r`n"); $output.ScrollToCaret()}
    if ($script:job.State -in @('Completed','Failed','Stopped')) {
        $state=$script:job.State
        $tail=@(Receive-Job $script:job -ErrorAction Continue 2>&1)
        if ($tail.Count) {$output.AppendText(($tail -join "`r`n")+"`r`n")}
        if ($state -eq 'Failed') {$output.AppendText("Сбой: $($script:job.ChildJobs[0].JobStateInfo.Reason)`r`n")}
        Remove-Job $script:job; $script:job=$null
        foreach ($b in $script:actionButtons) {$b.Enabled=$true}
        $status.Text='Операция завершена. Проверьте ошибки в отчёте и подключение устройства.'
    }
})
$form.Add_FormClosing({param($sender,$eventArgs)
    if ($script:job) {$eventArgs.Cancel=$true; [System.Windows.Forms.MessageBox]::Show('Дождитесь завершения текущей операции.','Выполняется операция') | Out-Null}
})
if ($SmokeTest) {
    $form.CreateControl()
    if ($script:actionButtons.Count -ne 4) {throw 'Missing action buttons'}
    $form.Dispose(); 'GUI smoke test passed'; exit 0
}
$timer.Start()
[void]$form.ShowDialog()
$timer.Dispose(); $form.Dispose()
