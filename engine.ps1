param([ValidateSet('Diagnose','Repair','RestartAdapter','Audio')][string]$Action='Diagnose')
$ErrorActionPreference='Stop'
$reportRoot=Join-Path $PSScriptRoot 'reports'
New-Item -ItemType Directory -Force -Path $reportRoot | Out-Null
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$script:log=Join-Path $reportRoot "$stamp-$Action.txt"
function Log([string]$Message) {
    $line="$(Get-Date -Format HH:mm:ss)  $Message"
    Add-Content -LiteralPath $script:log -Value $line -Encoding UTF8
    Write-Output $line
}
function Attempt([string]$Name,[scriptblock]$Block) {
    Log "--- $Name ---"
    try { & $Block | Out-String -Width 220 | ForEach-Object { if ($_.Trim()) { Log $_.Trim() } } }
    catch { Log "ОШИБКА: $($_.Exception.Message)" }
}
function NativePnp([string[]]$Arguments) {
    $result=& "$env:SystemRoot\System32\pnputil.exe" @Arguments 2>&1
    $code=$LASTEXITCODE
    Log ($result -join "`r`n")
    if ($code -eq 3010) { Log 'Windows требует перезагрузку. Автоматически она не выполняется.' }
    elseif ($code -ne 0) { throw "PnPUtil завершился с кодом $code" }
}
function Snapshot {
    Attempt 'Службы Bluetooth и звука' {
        Get-Service | Where-Object {$_.Name -match '^(bthserv|BTAGService|BluetoothUserService.*|Audiosrv|AudioEndpointBuilder)$'} |
            Select-Object Name,Status,StartType | Format-Table -AutoSize
    }
    Attempt 'Подключённые устройства Bluetooth (PnPUtil)' { NativePnp @('/enum-devices','/class','Bluetooth','/connected') }
    Attempt 'Все устройства Bluetooth, включая отключённые' { NativePnp @('/enum-devices','/class','Bluetooth') }
    Attempt 'Устройства Windows с ошибками' { NativePnp @('/enum-devices','/problem') }
    Attempt 'Коды состояния адаптеров' {
        $devices=@(Get-CimInstance Win32_PnPEntity -Filter "PNPClass='Bluetooth'")
        $devices | Select-Object Name,Present,ConfigManagerErrorCode,PNPDeviceID | Format-Table -AutoSize
        $devices | Select-Object Name,Present,ConfigManagerErrorCode,PNPDeviceID |
            ConvertTo-Json -Depth 4 | Set-Content (Join-Path $reportRoot "$stamp-devices.json") -Encoding UTF8
        $radios=@($devices | Where-Object {$_.PNPDeviceID -match '^(USB|PCI)\\' -and $_.Present})
        if (!$radios.Count) { Log 'Физический USB/PCI Bluetooth-адаптер не обнаружен среди присутствующих. Запуск службы сам по себе не доказывает восстановление.' }
        elseif (@($radios | Where-Object {$_.ConfigManagerErrorCode -ne 0}).Count) { Log 'У адаптера есть ошибка: смотрите ConfigManagerErrorCode (22 — отключён, 10/43 — сбой устройства/драйвера).' }
        else { Log 'Физический адаптер обнаружен без PnP-ошибки. Проверьте переключатель Bluetooth и фактическое подключение устройства.' }
    }
    Attempt 'Драйвер Bluetooth' {
        Get-CimInstance Win32_PnPSignedDriver -Filter "DeviceClass='BLUETOOTH'" |
            Select-Object DeviceName,DriverProviderName,DriverVersion,DriverDate,InfName | Format-Table -AutoSize
    }
    Attempt 'Процессы прежнего приложения записи' {
        $found=@(Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='pythonw.exe'" |
            Where-Object {$_.CommandLine -match 'meeting_listener\.py' -or $_.ExecutablePath -like '*\meeting-listener\.venv\Scripts\python*.exe'})
        $found | Select-Object ProcessId,Name,ExecutablePath | Format-Table -AutoSize
        if ($found.Count) { Log 'Приложение записи запущено. Нажмите в нём «Остановить» и дождитесь сохранения. Процессы не завершаются принудительно.' }
        else { Log 'Процессы прежнего приложения записи не найдены.' }
    }
    Attempt 'Последние события Bluetooth за 3 дня' {
        $events=@(Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=(Get-Date).AddDays(-3)} -MaxEvents 1500 |
            Where-Object {$_.ProviderName -match 'BTH|Bluetooth' -or ($_.ProviderName -match 'Kernel-PnP' -and $_.Message -match 'BTH|Bluetooth|VID_8087&PID_0AAA')} |
            Select-Object -First 30 TimeCreated,Id,ProviderName,Message)
        $events | Format-List
        if (!$events.Count) { Log 'В просмотренной выборке событий Bluetooth нет; это не исключает сбой.' }
    }
    Log 'Остановленная служба с типом Manual может быть нормой при отсутствии активного адаптера. Связь с приложением записи этим не установлена.'
}
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$admin=([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Log "Bluetooth Recovery | Действие: $Action | Администратор: $admin"
Log "Отчёт: $script:log"
if ($Action -eq 'Diagnose') { Snapshot; exit 0 }
if (!$admin) { Log 'Нужны права администратора. Откройте приложение через start-admin.cmd.'; exit 5 }
# Save the exact service configuration before changing anything.
$backup=Join-Path $reportRoot "$stamp-services-before.json"
Get-Service bthserv,BTAGService,Audiosrv,AudioEndpointBuilder |
    Select-Object Name,@{n='Status';e={$_.Status.ToString()}},@{n='StartType';e={$_.StartType.ToString()}} |
    ConvertTo-Json | Set-Content -LiteralPath $backup -Encoding UTF8
Log "Исходное состояние служб: $backup"
Snapshot
switch ($Action) {
    'Repair' {
        Attempt 'Включить отключённые физические Bluetooth-адаптеры' {
            $disabled=@(Get-CimInstance Win32_PnPEntity -Filter "PNPClass='Bluetooth'" |
                Where-Object {$_.Present -and $_.PNPDeviceID -match '^(USB|PCI)\\' -and $_.ConfigManagerErrorCode -eq 22})
            foreach ($device in $disabled) { NativePnp @('/enable-device',$device.PNPDeviceID) }
            if (!$disabled.Count) { Log 'Отключённых физических адаптеров с кодом 22 нет.' }
        }
        Attempt 'Запустить службу Bluetooth' {
            $svc=Get-Service bthserv
            if ($svc.StartType -eq 'Disabled') { Set-Service bthserv -StartupType Manual; Log 'Тип запуска изменён с Disabled на Manual.' }
            if ($svc.Status -ne 'Running') { Start-Service bthserv }
            (Get-Service bthserv) | Select-Object Name,Status,StartType
        }
        Attempt 'Повторно обнаружить оборудование' { NativePnp @('/scan-devices') }
    }
    'RestartAdapter' {
        Attempt 'Перезапуск присутствующего физического Bluetooth-адаптера' {
            $radios=@(Get-CimInstance Win32_PnPEntity -Filter "PNPClass='Bluetooth'" |
                Where-Object {$_.Present -and $_.PNPDeviceID -match '^(USB|PCI)\\'})
            if (!$radios.Count) { Log 'Присутствующего адаптера нет; перезапуск невозможен. Выполняется повторный поиск.' }
            foreach ($device in $radios) { NativePnp @('/restart-device',$device.PNPDeviceID) }
            NativePnp @('/scan-devices')
        }
    }
    'Audio' {
        Attempt 'Перезапустить службу Windows Audio' {
            # Do not force-stop dependent services or restart the endpoint builder.
            Restart-Service Audiosrv -ErrorAction Stop
            Get-Service Audiosrv | Select-Object Name,Status
        }
    }
}
Log 'Повторная диагностика после действий. Успех команд не равен подтверждению подключения.'
Snapshot
Log 'Проверьте Bluetooth в параметрах Windows и подключите мышь или наушники. Если адаптер по-прежнему отсутствует, сохраните работу и выполните полное выключение ПК; затем проверьте драйвер на сайте производителя компьютера.'
