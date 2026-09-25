#requires -Version 7.2
# Hora Certa para AzuraCast no Windows; execute pelo hora-certa.bat.
param(
    [Parameter(Position = 0)][ValidateSet('install', 'run', 'status', 'disable', 'cron')][string]$Command = 'status',
    [switch]$NextDay,
    [switch]$Plan,
    [switch]$ApiSync,
    [ValidatePattern('^\d{4}-\d{2}-\d{2}$')][string]$Date
)
$ErrorActionPreference = 'Stop'
$script:Root = Join-Path $env:ProgramData 'AzuraCastHoraCerta'
$script:InstalledScript = Join-Path $script:Root 'hora-certa-windows.ps1'
$script:InstalledBat = Join-Path $script:Root 'hora-certa.bat'
$script:SettingsPath = Join-Path $script:Root 'settings.json'
$script:KeyPath = Join-Path $script:Root 'api-key.dpapi'
$script:TaskName = 'AzuraCastHoraCerta'
$script:Utf8 = [Text.UTF8Encoding]::new($false)

function Fail([string]$Message) { throw $Message }
function Ask([string]$Label, [string]$Default = '') {
    if ($Default) { $value = Read-Host "$Label [$Default]" } else { $value = Read-Host $Label }
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value.Trim()
}
function Confirm([string]$Label) {
    return ((Read-Host "$Label [s/N]") -match '^(?i:s|sim)$')
}
function Require-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Fail 'Abra o terminal como Administrador e execute hora-certa.bat install.'
    }
}
function Assert-Windows {
    if (-not $IsWindows) { Fail 'Use hora-certa.sh no host Linux; hora-certa.bat requer Windows.' }
}
function Is-Reparse([string]$Path) {
    return (([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}
function Assert-Media([psobject]$Config) {
    $station = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($Config.StationDir))
    $media = [IO.Path]::Combine($station, 'media')
    $voiceRoot = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($Config.AudioDir))
    if (-not ([IO.Directory]::Exists($station) -and [IO.Directory]::Exists($media) -and [IO.Directory]::Exists($voiceRoot))) {
        Fail 'Estação, station/media ou pasta das vozes inexistente neste Windows.'
    }
    $prefix = [IO.Path]::TrimEndingDirectorySeparator($media) + [IO.Path]::DirectorySeparatorChar
    if (-not $voiceRoot.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        Fail 'A pasta das vozes precisa estar dentro de station/media para aparecer no AzuraCast.'
    }
    if ($station.StartsWith('\\') -or $voiceRoot.StartsWith('\\')) {
        Fail 'Pastas UNC/rede exigem credenciais de serviço específicas. Use um volume local acessível ao Docker e à tarefa SYSTEM.'
    }
    if (([IO.DriveInfo]::new([IO.Path]::GetPathRoot($station))).DriveType -ne [IO.DriveType]::Fixed -or
        ([IO.DriveInfo]::new([IO.Path]::GetPathRoot($voiceRoot))).DriveType -ne [IO.DriveType]::Fixed) {
        Fail 'Drive de rede/mapeado não funciona de modo confiável sob SYSTEM; use unidade local fixa.'
    }
    foreach ($folder in @($station, $media, $voiceRoot, (Join-Path $voiceRoot 'Feminino'), (Join-Path $voiceRoot 'Masculino'))) {
        if (-not [IO.Directory]::Exists($folder)) { Fail "Pasta ausente: $folder" }
        if (Is-Reparse $folder) { Fail "Link/junction não permitido na pasta de mídia: $folder" }
    }
    $cursor = $media
    foreach ($part in ([IO.Path]::GetRelativePath($media, $voiceRoot) -split '[\\/]')) {
        $cursor = Join-Path $cursor $part
        if (Is-Reparse $cursor) { Fail "Link/junction intermediário não permitido: $cursor" }
    }
    $relative = [IO.Path]::GetRelativePath($media, $voiceRoot).Replace('\', '/')
    if ($relative -eq '.' -or $relative.StartsWith('../') -or $relative.Contains("`n") -or $relative.Contains("`r")) {
        Fail 'Subpasta relativa inválida para a agenda M3U.'
    }
    return [pscustomobject]@{ Station = $station; Media = $media; Audio = $voiceRoot; Relative = $relative }
}
function Get-Zone([string]$Iana) {
    if ($Iana -notmatch '^[A-Za-z_]+(/[A-Za-z0-9_+\-]+)+$') { Fail 'Informe um fuso IANA válido (exemplo: Europe/Lisbon).' }
    try { return [TimeZoneInfo]::FindSystemTimeZoneById($Iana) }
    catch { Fail "O Windows/PowerShell não reconhece o fuso $Iana. Confira ICU e o nome IANA." }
}
function Assert-ServiceExecutable([string]$File) {
    $full = [IO.Path]::GetFullPath($File)
    $home = [IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd([char[]]@('\', '/')) + [IO.Path]::DirectorySeparatorChar
    if ($full.StartsWith($home, [StringComparison]::OrdinalIgnoreCase) -or (Is-Reparse $full)) {
        Fail "Binário em perfil de usuário ou link não confiável para a tarefa SYSTEM: $full. Instale para todos os usuários."
    }
}
function Assert-Settings([psobject]$Config, [switch]$AllowPendingStation) {
    if ($Config.MinuteStart -lt 0 -or $Config.MinuteEnd -gt 59 -or $Config.MinuteStart -gt $Config.MinuteEnd) { Fail 'Intervalo de minutos inválido.' }
    if ($Config.HourStart -lt 0 -or $Config.HourEnd -gt 23 -or $Config.HourStart -gt $Config.HourEnd) { Fail 'Intervalo de horas inválido.' }
    $null = Get-Zone $Config.Timezone
    $null = Assert-Media $Config
    if (-not (([IO.File]::Exists($Config.Ffmpeg)) -and ([IO.File]::Exists($Config.Ffprobe)))) { Fail 'ffmpeg.exe e ffprobe.exe precisam existir.' }
    Assert-ServiceExecutable $Config.Ffmpeg
    Assert-ServiceExecutable $Config.Ffprobe
    if (-not $AllowPendingStation -and $Config.StationId -notmatch '^[1-9][0-9]*$') { Fail 'ID numérico da estação inválido.' }
    $uri = $null
    if (-not [Uri]::TryCreate($Config.ApiUrl, [UriKind]::Absolute, [ref]$uri)) { Fail 'URL da API inválida.' }
    if ($uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -ne '/') { Fail 'URL base precisa terminar no domínio/porta, sem /api, usuário ou parâmetros.' }
    $loopback = $uri.Host -in @('localhost', '127.0.0.1')
    if ($uri.Scheme -ne 'https' -and -not ($uri.Scheme -eq 'http' -and $loopback)) { Fail 'Use HTTPS ou HTTP somente em localhost/127.0.0.1.' }
    if ($Config.ApiHost -and ($Config.ApiHost -notmatch '^[A-Za-z0-9.-]+$' -or -not ($uri.Scheme -eq 'http' -and $loopback))) { Fail 'Host virtual permitido apenas na API local HTTP.' }
}
function Get-Plan([psobject]$Config, [datetime]$Day) {
    $index = [int]$Day.Date.Subtract([datetime]'2020-01-01').TotalDays
    $range = [int]$Config.MinuteEnd - [int]$Config.MinuteStart + 1
    $minute = [int]$Config.MinuteStart + (($index % $range + $range) % $range)
    $hoursPerDay = [int]$Config.HourEnd - [int]$Config.HourStart + 1
    $items = [System.Collections.Generic.List[object]]::new()
    for ($hour = [int]$Config.HourStart; $hour -le [int]$Config.HourEnd; $hour++) {
        $serial = $index * $hoursPerDay + $hour - [int]$Config.HourStart
        $voice = if ((($serial % 2 + 2) % 2) -eq 0) { 'Feminino' } else { 'Masculino' }
        $items.Add([pscustomobject]@{ Hour = $hour; Minute = $minute; Voice = $voice })
    }
    return $items.ToArray()
}
function Test-Audio([string]$File, [psobject]$Config) {
    if (-not [IO.File]::Exists($File) -or (Is-Reparse $File) -or ([IO.FileInfo]::new($File).Length -eq 0)) { Fail "MP3 ausente ou inseguro: $File" }
    $codec = & $Config.Ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 $File 2>$null
    if ($LASTEXITCODE -ne 0 -or ($codec -join '').Trim() -ne 'mp3') { Fail "MP3/codec inválido: $File" }
    & $Config.Ffmpeg -nostdin -v error -xerror -i $File -f null '-' 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "MP3 truncado: $File" }
}
function Get-Inputs([psobject]$Config, [psobject]$Entry) {
    $hh = '{0:D2}' -f $Entry.Hour; $mm = '{0:D2}' -f $Entry.Minute
    $voiceDir = Join-Path $Config.AudioDir $Entry.Voice
    if ($Entry.Minute -eq 0) {
        $hour = Join-Path $voiceDir "HRS${hh}_0.mp3"
        Test-Audio $hour $Config
        return [pscustomobject]@{ Hour = $hour; Minute = $null }
    }
    $hour = Join-Path $voiceDir "HRS${hh}.mp3"
    $minute = Join-Path $voiceDir "MIN${mm}.mp3"
    Test-Audio $hour $Config; Test-Audio $minute $Config
    return [pscustomobject]@{ Hour = $hour; Minute = $minute }
}
function Check-AllAudio([psobject]$Config) {
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($voice in @('Feminino', 'Masculino')) {
        $folder = Join-Path $Config.AudioDir $voice
        for ($hour = [int]$Config.HourStart; $hour -le [int]$Config.HourEnd; $hour++) {
            $hh = '{0:D2}' -f $hour
            if ($Config.MinuteStart -eq 0) { $null = $seen.Add((Join-Path $folder "HRS${hh}_0.mp3")) }
            if ($Config.MinuteEnd -gt 0) { $null = $seen.Add((Join-Path $folder "HRS${hh}.mp3")) }
        }
        for ($minute = [int]$Config.MinuteStart; $minute -le [int]$Config.MinuteEnd; $minute++) {
            if ($minute -gt 0) { $null = $seen.Add((Join-Path $folder ('MIN{0:D2}.mp3' -f $minute))) }
        }
    }
    foreach ($file in $seen) { Test-Audio $file $Config }
    Write-Host "VALIDADO: $($seen.Count) arquivos para todo o intervalo, sem gravar mídia."
}
function New-Client([psobject]$Config, [string]$Key) {
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    if ($Config.ApiUrl -match '^http://') { $handler.UseProxy = $false }
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(90)
    if ($Key) { $client.DefaultRequestHeaders.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Key) }
    if ($Config.ApiHost) { $client.DefaultRequestHeaders.Host = $Config.ApiHost }
    return $client
}
function Api([Net.Http.HttpClient]$Client, [psobject]$Config, [string]$Method, [string]$Route, [object]$Data = $null, [string]$ImportFile = '') {
    $url = "$($Config.ApiUrl.TrimEnd('/'))/api/$Route"
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), $url)
    $multi = $null; $fileStream = $null
    try {
        if ($ImportFile) {
            $fileStream = [IO.File]::OpenRead($ImportFile)
            $multi = [Net.Http.MultipartFormDataContent]::new()
            $part = [Net.Http.StreamContent]::new($fileStream)
            $part.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::Parse('audio/x-mpegurl')
            $multi.Add($part, 'playlist_file', [IO.Path]::GetFileName($ImportFile))
            $request.Content = $multi
        } elseif ($null -ne $Data) {
            $json = ConvertTo-Json -InputObject $Data -Depth 20 -Compress
            $request.Content = [Net.Http.StringContent]::new($json, $script:Utf8, 'application/json')
        }
        $response = $Client.SendAsync($request).GetAwaiter().GetResult()
        try {
            if (-not $response.IsSuccessStatusCode) { Fail "API retornou HTTP $([int]$response.StatusCode) em $Method /api/$Route" }
            $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            if ([string]::IsNullOrWhiteSpace($body)) { return $null }
            if ($Route -eq 'openapi.yml') { return $body }
            return ,(ConvertFrom-Json -InputObject $body -Depth 50 -NoEnumerate)
        } finally { $response.Dispose() }
    } finally {
        $request.Dispose()
        if ($multi) { $multi.Dispose() }
        if ($fileStream) { $fileStream.Dispose() }
    }
}
function Playlists([Net.Http.HttpClient]$Client, [psobject]$Config, [string]$Name) {
    $route = "station/$($Config.StationId)/playlists?searchPhrase=$([Uri]::EscapeDataString($Name))"
    $list = Api $Client $Config GET $route
    if ($null -eq $list) { Fail 'Lista vazia inesperada da API.' }
    if ($list -is [Array]) { return @($list) }
    if ($null -ne $list.rows) { return @($list.rows) }
    Fail 'Formato da lista de playlists inesperado.'
}
function Protect-Key([string]$Key) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Key)
    $temporary = "$($script:KeyPath).$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        $encrypted = [Security.Cryptography.ProtectedData]::Protect($bytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
        [IO.File]::WriteAllBytes($temporary, $encrypted)
        [IO.File]::Move($temporary, $script:KeyPath, $true)
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
}
function Read-Key {
    if (-not [IO.File]::Exists($script:KeyPath)) { Fail 'Chave protegida não encontrada; execute install novamente.' }
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($script:KeyPath), $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
    try { return [Text.Encoding]::UTF8.GetString($bytes) }
    finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}
function Save-Json([string]$Path, [object]$Value) {
    $temp = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temp, (ConvertTo-Json -InputObject $Value -Depth 20), $script:Utf8)
        [IO.File]::Move($temp, $Path, $true)
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}
function Install-Task([string]$Pwsh) {
    $service = New-Object -ComObject 'Schedule.Service'
    $service.Connect()
    $definition = $service.NewTask(0)
    $definition.RegistrationInfo.Description = 'Hora certa AzuraCast: prepara a playlist do dia seguinte na estação configurada.'
    $definition.Principal.UserId = 'SYSTEM'
    $definition.Principal.LogonType = 5 # TASK_LOGON_SERVICE_ACCOUNT
    $definition.Principal.RunLevel = 1 # Mais alto
    $definition.Settings.Enabled = $true
    $definition.Settings.StartWhenAvailable = $true
    $definition.Settings.MultipleInstances = 2 # Ignorar novo disparo se estiver em execução
    $definition.Settings.ExecutionTimeLimit = 'PT10M'
    $trigger = $definition.Triggers.Create(2) # TASK_TRIGGER_DAILY
    $trigger.StartBoundary = [datetime]::Today.ToString('yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
    $trigger.DaysInterval = 1
    $trigger.Repetition.Interval = 'PT1M'
    $trigger.Repetition.Duration = 'P1D'
    # Também cobre o dia da instalação, quando o gatilho diário à meia-noite já passou.
    $firstDay = $definition.Triggers.Create(1) # TASK_TRIGGER_TIME
    $firstDay.StartBoundary = [datetime]::Now.AddMinutes(1).ToString('yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
    $firstDay.Repetition.Interval = 'PT1M'
    $firstDay.Repetition.Duration = 'P1D'
    $action = $definition.Actions.Create(0)
    $action.Path = $Pwsh
    $action.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $script:InstalledScript + '" cron'
    $null = $service.GetFolder('\').RegisterTaskDefinition($script:TaskName, $definition, 6, 'SYSTEM', $null, 5)
}
function Set-PrivateFolder {
    & icacls.exe $script:Root '/inheritance:r' '/grant:r' '*S-1-5-18:(OI)(CI)(F)' '*S-1-5-32-544:(OI)(CI)(F)' | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail 'Falha ao limitar acesso à configuração e à chave da API.' }
}
function Build([psobject]$Config, [datetime]$Day, [switch]$Preview) {
    $paths = Assert-Media $Config
    $entries = @(Get-Plan $Config $Day)
    foreach ($item in $entries) { Write-Host ('  {0:D2}:{1:D2} {2}' -f $item.Hour, $item.Minute, $item.Voice) }
    if ($Preview) { return $null }
    $out = Join-Path $paths.Audio 'Gerados'; $cache = Join-Path $out 'Cache'
    foreach ($dir in @($out, $cache)) {
        if ([IO.Directory]::Exists($dir) -and (Is-Reparse $dir)) { Fail "Link de saída inseguro: $dir" }
        [IO.Directory]::CreateDirectory($dir) | Out-Null
    }
    $lockFile = Join-Path $out '.hora-certa.lock'
    $lock = $null
    try {
        $lock = [IO.File]::Open($lockFile, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch [IO.IOException] { Fail 'Outra execução está criando a agenda. Aguarde e repita.' }
    try {
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add('#EXTM3U')
        foreach ($item in $entries) {
            $hh = '{0:D2}' -f $item.Hour; $mm = '{0:D2}' -f $item.Minute
            $files = Get-Inputs $Config $item
            if ($item.Minute -eq 0) {
                $lines.Add("$($paths.Relative)/$($item.Voice)/HRS${hh}_0.mp3")
                continue
            }
            $hourHash = (Get-FileHash -LiteralPath $files.Hour -Algorithm SHA256).Hash
            $minHash = (Get-FileHash -LiteralPath $files.Minute -Algorithm SHA256).Hash
            $material = "$($files.Hour)|$hourHash|$($files.Minute)|$minHash"
            $digest = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($material))
            $hash = ([Convert]::ToHexString($digest)).Substring(0, 16).ToLowerInvariant()
            $name = "HoraCerta_${hh}${mm}_$($item.Voice)_${hash}.mp3"
            $final = Join-Path $cache $name
            if (-not [IO.File]::Exists($final)) {
                $temp = Join-Path $cache ".audio-$([Guid]::NewGuid().ToString('N')).mp3"
                try {
                    $filter = '[0:a]aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo[a];[1:a]aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo[b];[a][b]concat=n=2:v=0:a=1,alimiter=limit=0.89125[out]'
                    & $Config.Ffmpeg -nostdin -hide_banner -loglevel error -y -i $files.Hour -i $files.Minute -filter_complex $filter -map '[out]' -codec:a libmp3lame -b:a 192k -ar 48000 -ac 2 $temp 2>$null | Out-Null
                    if ($LASTEXITCODE -ne 0) { Fail "Falha ao combinar áudio $hh`:$mm" }
                    Test-Audio $temp $Config
                    [IO.File]::Move($temp, $final)
                } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
            } else { Test-Audio $final $Config }
            $lines.Add("$($paths.Relative)/Gerados/Cache/$name")
        }
        $compact = $Day.ToString('yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture)
        $agenda = Join-Path $out "agenda-$compact.m3u"
        $temporary = "$agenda.$([Guid]::NewGuid().ToString('N')).tmp"
        try {
            [IO.File]::WriteAllLines($temporary, [string[]]$lines.ToArray(), $script:Utf8)
            [IO.File]::Move($temporary, $agenda, $true)
        } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
        Write-Host "GERADO: $agenda"
        return $agenda
    } finally { if ($lock) { $lock.Dispose() } }
}
function Cleanup-Old([Net.Http.HttpClient]$Client, [psobject]$Config, [datetime]$Today) {
    $paths = Assert-Media $Config
    $out = Join-Path $paths.Audio 'Gerados'; $removed = 0
    foreach ($file in @(Get-ChildItem -LiteralPath $out -Filter 'agenda-????????.m3u' -File | Sort-Object Name)) {
        if ($file.Name -notmatch '^agenda-(\d{8})\.m3u$' -or (Is-Reparse $file.FullName)) { continue }
        $old = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($Matches[1], 'yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$old)) { continue }
        if ($old.Date -ge $Today.Date.AddDays(-14)) { continue }
        $lines = [IO.File]::ReadAllLines($file.FullName, $script:Utf8)
        if ($lines.Count -lt 2 -or $lines[0] -ne '#EXTM3U') { continue }
        $valid = $true
        foreach ($line in $lines[1..($lines.Count - 1)]) { if (-not $line.StartsWith("$($paths.Relative)/", [StringComparison]::Ordinal)) { $valid = $false } }
        if (-not $valid) { continue }
        $name = "Hora Certa Auto $($old.ToString('yyyyMMdd'))"
        $marker = "AZHC-v1 $($old.ToString('yyyy-MM-dd'))"
        try {
            $same = @(Playlists $Client $Config $name | Where-Object { $_.name -eq $name })
            if (@($same | Where-Object { $_.description -ne $marker }).Count -ne 0) { continue }
            $ours = @($same | Where-Object { $_.description -eq $marker })
            if ($ours.Count -gt 1) { continue }
            if ($ours.Count -eq 1) {
                $id = [string]$ours[0].id
                if ($id -notmatch '^[1-9][0-9]*$') { continue }
                $detail = Api $Client $Config GET "station/$($Config.StationId)/playlist/$id"
                $schedule = @($detail.schedule_items)
                if ($detail.name -ne $name -or $detail.description -ne $marker -or $detail.type -ne 'once_per_hour' -or $detail.source -ne 'songs' -or $schedule.Count -ne 1 -or $schedule[0].start_date -ne $old.ToString('yyyy-MM-dd') -or $schedule[0].end_date -ne $old.ToString('yyyy-MM-dd')) { continue }
                $null = Api $Client $Config DELETE "station/$($Config.StationId)/playlist/$id"
            }
            [IO.File]::Delete($file.FullName)
            Write-Host "LIMPEZA: playlist/agenda $($old.ToString('yyyy-MM-dd')) removidas; MP3 preservados."
            $removed++
            if ($removed -ge 20) { break }
        } catch { Write-Warning "Limpeza adiada para $($old.ToString('yyyy-MM-dd')): $($_.Exception.Message)"; break }
    }
}
function Sync-Playlist([Net.Http.HttpClient]$Client, [psobject]$Config, [datetime]$Day, [string]$Agenda) {
    $dayText = $Day.ToString('yyyy-MM-dd'); $compact = $Day.ToString('yyyyMMdd')
    $name = "Hora Certa Auto $compact"; $marker = "AZHC-v1 $dayText"
    $matching = @(Playlists $Client $Config $name | Where-Object { $_.name -eq $name })
    if (@($matching | Where-Object { $_.description -ne $marker }).Count -gt 0) { Fail 'Existe outra playlist com o mesmo nome; nenhuma alteração feita.' }
    $ours = @($matching | Where-Object { $_.description -eq $marker })
    if ($ours.Count -gt 1) { Fail 'Playlists duplicadas com nosso marcador. Corrija no painel.' }
    $minute = @(Get-Plan $Config $Day)[0].Minute
    if ($ours.Count -eq 0) {
        $payload = @{
            name = $name; description = $marker; type = 'once_per_hour'; source = 'songs'; order = 'sequential'
            play_per_hour_minute = $minute; is_enabled = $false; backend_options = @('interrupt')
            schedule_items = @(@{ start_time = ([int]$Config.HourStart * 100 + $minute); end_time = ([int]$Config.HourEnd * 100 + 59); start_date = $dayText; end_date = $dayText; days = @(); loop_once = $false })
        }
        $created = Api $Client $Config POST "station/$($Config.StationId)/playlists" $payload
        $id = [string]$created.id
    } else { $id = [string]$ours[0].id }
    if ($id -notmatch '^[1-9][0-9]*$') { Fail 'Resposta de playlist sem ID válido; revise no painel antes de tentar novamente.' }
    $details = Api $Client $Config GET "station/$($Config.StationId)/playlist/$id"
    if ($details.description -ne $marker -or $details.type -ne 'once_per_hour' -or $details.source -ne 'songs' -or $details.order -ne 'sequential' -or [int]$details.play_per_hour_minute -ne $minute -or @($details.schedule_items | Where-Object { $_.start_date -eq $dayText -and $_.end_date -eq $dayText }).Count -lt 1) {
        Fail 'Detalhes da playlist na API não correspondem à agenda esperada.'
    }
    if (-not $details.is_enabled) {
        $null = Api $Client $Config DELETE "station/$($Config.StationId)/playlist/$id/empty"
        $imported = Api $Client $Config POST "station/$($Config.StationId)/playlist/$id/import" $null $Agenda
        $expected = [int]$Config.HourEnd - [int]$Config.HourStart + 1
        if (-not $imported.success -or @($imported.import_results).Count -ne $expected -or @($imported.import_results | Where-Object { $null -ne $_.match }).Count -ne $expected) {
            Fail 'Importação incompleta; playlist permanece desativada até a indexação da mídia.'
        }
        $null = Api $Client $Config PUT "station/$($Config.StationId)/playlist/$id" @{ is_enabled = $true }
        $details = Api $Client $Config GET "station/$($Config.StationId)/playlist/$id"
        if (-not $details.is_enabled) { Fail 'Playlist não ficou ativa após importar a mídia.' }
    }
    Write-Host "API: playlist ativa, ID=$id, data=$dayText."
    $zone = Get-Zone $Config.Timezone
    $today = [TimeZoneInfo]::ConvertTimeFromUtc([datetime]::UtcNow, $zone).Date
    Cleanup-Old $Client $Config $today
}
function Run-Worker([switch]$Scheduled) {
    if (-not [IO.File]::Exists($script:SettingsPath)) { Fail 'Instalação não encontrada. Execute hora-certa.bat install.' }
    $config = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($script:SettingsPath, $script:Utf8)) -Depth 50
    Assert-Settings $config
    $zone = Get-Zone $config.Timezone
    $now = [TimeZoneInfo]::ConvertTimeFromUtc([datetime]::UtcNow, $zone)
    if ($Scheduled) {
        if ($now.Hour -ne 23 -or $now.Minute -notin @(10, 20, 30, 40, 50)) { return }
        $day = $now.Date.AddDays(1)
    } elseif ($Date) {
        $day = [datetime]::ParseExact($Date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    } elseif ($NextDay) { $day = $now.Date.AddDays(1) }
    else { $day = $now.Date }
    $transcript = $false
    if ($Scheduled) {
        $logPath = Join-Path $script:Root 'hora-certa.log'
        if ([IO.File]::Exists($logPath) -and ([IO.FileInfo]::new($logPath).Length -gt 5MB)) {
            [IO.File]::Move($logPath, "$logPath.1", $true)
        }
        Start-Transcript -Path $logPath -Append | Out-Null
        $transcript = $true
    }
    try {
        Write-Host "Data: $($day.ToString('yyyy-MM-dd')); fuso: $($config.Timezone)"
        $agenda = Build $config $day -Preview:$Plan
        if ($Plan) { return }
        if (-not $ApiSync -and -not $Scheduled) { Write-Warning 'M3U no disco não ativa playlist; execute run -NextDay -ApiSync.'; return }
        $client = New-Client $config (Read-Key)
        try { Sync-Playlist $client $config $day $agenda }
        finally { $client.Dispose() }
    } catch {
        if ($Scheduled) { Write-Warning "Execução agendada falhou: $($_.Exception.Message)" }
        throw
    } finally { if ($transcript) { Stop-Transcript | Out-Null } }
}
function Install-Main {
    Require-Admin
    $pwsh = (Get-Command pwsh.exe -CommandType Application).Source
    Assert-ServiceExecutable $pwsh
    if ([IO.Path]::GetFullPath($PSCommandPath).Equals([IO.Path]::GetFullPath($script:InstalledScript), [StringComparison]::OrdinalIgnoreCase)) { Fail 'Execute a nova cópia baixada, fora da pasta de instalação.' }
    $companion = Join-Path $PSScriptRoot 'hora-certa.bat'
    if (-not [IO.File]::Exists($companion)) { Fail 'Mantenha .bat e .ps1 juntos para instalar.' }
    $station = Ask 'Caminho COMPLETO da estação (a pasta que contém media)'
    $voices = Ask 'Caminho COMPLETO da pasta das vozes (contém Feminino e Masculino)'
    $tz = Ask 'Fuso IANA usado pela estação (exemplo: Europe/Lisbon)'
    $minStart = Ask 'Minuto inicial 0-59' '3'; $minEnd = Ask 'Minuto final 0-59' '27'
    $hourStart = Ask 'Primeira hora 0-23' '6'; $hourEnd = Ask 'Última hora 0-23' '23'
    foreach ($value in @($minStart, $minEnd, $hourStart, $hourEnd)) { if ($value -notmatch '^(0|[1-9][0-9]?)$') { Fail "Número inválido: $value" } }
    $ffmpegCommand = Get-Command ffmpeg.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $ffmpeg = Ask 'Caminho completo do ffmpeg.exe' $(if ($ffmpegCommand) { $ffmpegCommand.Source } else { '' })
    $ffprobeCommand = Get-Command ffprobe.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $ffprobe = Ask 'Caminho completo do ffprobe.exe' $(if ($ffprobeCommand) { $ffprobeCommand.Source } else { '' })
    $api = Ask 'URL base do AzuraCast (HTTPS ou localhost HTTP; sem /api)'
    $hostHeader = if ($api -match '^http://') { Ask 'Host virtual local, se necessário (vazio = automático)' } else { '' }
    $config = [pscustomobject]@{
        StationDir = $station; AudioDir = $voices; Timezone = $tz; MinuteStart = [int]$minStart; MinuteEnd = [int]$minEnd
        HourStart = [int]$hourStart; HourEnd = [int]$hourEnd; Ffmpeg = $ffmpeg; Ffprobe = $ffprobe
        ApiUrl = $api.TrimEnd('/'); ApiHost = $hostHeader; StationId = ''
    }
    Assert-Settings $config -AllowPendingStation
    $paths = Assert-Media $config
    Write-Host "Caminho da estação: $($paths.Station)"
    Write-Host "Pasta das vozes: $($paths.Audio)"
    Write-Host "Caminho M3U relativo a media/: $($paths.Relative)"
    if (-not (Confirm 'Os dois caminhos apontam para a MESMA mídia vista pelo AzuraCast?')) { Fail 'Instalação cancelada.' }
    $zone = Get-Zone $tz
    $day = [TimeZoneInfo]::ConvertTimeFromUtc([datetime]::UtcNow, $zone).Date.AddDays(1)
    foreach ($entry in @(Get-Plan $config $day)) { Write-Host ('  {0:D2}:{1:D2} {2}' -f $entry.Hour, $entry.Minute, $entry.Voice) }
    Check-AllAudio $config
    $bootstrap = New-Client $config ''
    try {
        try {
            $spec = Api $bootstrap $config GET 'openapi.yml'
            foreach ($route in @('/station/{station_id}/playlists', '/station/{station_id}/playlist/{id}/import', '/station/{station_id}/playlist/{id}/empty')) {
                if (-not $spec.Contains($route)) { Fail "OpenAPI não contém a rota $route" }
            }
        } catch {
            Write-Warning "OpenAPI indisponível ou incompatível: $($_.Exception.Message)"
            $openApiMissing = $true
        }
        $null = Api $bootstrap $config GET 'status'
        $stations = Api $bootstrap $config GET 'stations'
        Write-Host 'Estações encontradas:'
        foreach ($row in @($stations)) { Write-Host "  ID=$($row.id) nome=$($row.name) shortcode=$($row.shortcode)" }
        $id = Ask 'ID numérico da estação (consulte a lista acima)'
        if ($id -notmatch '^[1-9][0-9]*$') { Fail 'ID inválido.' }
        $config.StationId = $id
        Assert-Settings $config
        $stationInfo = Api $bootstrap $config GET "station/$id"
        Write-Host "Na API: ID=$id, nome=$($stationInfo.name), shortcode=$($stationInfo.shortcode), fuso=$($stationInfo.timezone)"
        if ($stationInfo.timezone -and $stationInfo.timezone -ne $tz) { Fail 'O fuso da estação na API difere do informado. Corrija antes de instalar.' }
        if (-not (Confirm 'Confirma que a estação da API usa ESTA pasta de mídia?')) { Fail 'ID/pasta não confirmados.' }
        Write-Host 'Cole a chave de API (a digitação é invisível).'
        $secure = Read-Host 'Chave de API com permissão para gerenciar playlists' -AsSecureString
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { $key = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer); $secure.Dispose() }
        if ($key -notmatch '^[A-Za-z0-9._:-]{8,250}$') { Fail 'Chave vazia ou formato inválido.' }
        $client = New-Client $config $key
        try { $null = Playlists $client $config 'Hora Certa Auto' }
        finally { $client.Dispose() }
        if ($openApiMissing -and -not (Confirm 'A API autenticada funciona, mas OpenAPI falhou. Continuar?')) { Fail 'Instalação cancelada.' }
        if (-not (Confirm 'Instalar, criar playlist inicial e agendar a tarefa diária?')) { Fail 'Instalação cancelada.' }
        if ([IO.Directory]::Exists($script:Root) -and (([IO.File]::Exists($script:SettingsPath)) -or (Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue))) {
            if (-not (Confirm 'Já existe instalação; criar backup e substituir?')) { Fail 'Arquivos existentes preservados.' }
        }
        [IO.Directory]::CreateDirectory($script:Root) | Out-Null
        Set-PrivateFolder
        if ([IO.File]::Exists($script:SettingsPath)) {
            $backup = Join-Path $script:Root "backup-$([datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))"
            [IO.Directory]::CreateDirectory($backup) | Out-Null
            foreach ($old in @($script:InstalledScript, $script:InstalledBat, $script:SettingsPath, $script:KeyPath)) {
                if ([IO.File]::Exists($old)) { [IO.File]::Copy($old, (Join-Path $backup ([IO.Path]::GetFileName($old)))) }
            }
        }
        [IO.File]::Copy($PSCommandPath, $script:InstalledScript, $true)
        [IO.File]::Copy($companion, $script:InstalledBat, $true)
        Save-Json $script:SettingsPath $config
        Protect-Key $key
        $key = $null
        Write-Host 'Gerando e importando a agenda inicial...'
        $installedClient = New-Client $config (Read-Key)
        try {
            $agenda = Build $config $day
            try { Sync-Playlist $installedClient $config $day $agenda }
            catch { Write-Warning "Sincronização inicial pendente: $($_.Exception.Message)" }
        } finally { $installedClient.Dispose() }
        Install-Task $pwsh
        Write-Host "INSTALADO: $($script:InstalledBat)"
        Write-Host "Tarefa: $($script:TaskName) | Configuração: $($script:SettingsPath)"
    } finally { $bootstrap.Dispose() }
}
try {
    Assert-Windows
    if ($Plan -and $ApiSync) { Fail 'Use -Plan ou -ApiSync, separadamente.' }
    if ($NextDay -and $Date) { Fail 'Use -NextDay ou -Date AAAA-MM-DD.' }
    switch ($Command) {
        'install' { Install-Main }
        'run' { Run-Worker }
        'cron' { Run-Worker -Scheduled }
        'status' {
            Write-Host "Script instalado: $([IO.File]::Exists($script:InstalledScript))"
            Write-Host "Configuração presente: $([IO.File]::Exists($script:SettingsPath))"
            $task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
            Write-Host "Tarefa agendada: $($null -ne $task)"
            if ($task) { Write-Host "Estado: $($task.State)" }
        }
        'disable' {
            Require-Admin
            Disable-ScheduledTask -TaskName $script:TaskName -ErrorAction Stop | Out-Null
            Write-Host 'Tarefa desativada. Playlists já ativas devem ser desativadas pelo painel.'
        }
    }
} catch {
    Write-Error "ERRO: $($_.Exception.Message)" -ErrorAction Continue
    exit 2
}
