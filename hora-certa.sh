#!/usr/bin/env bash
# Hora Certa: instalador interativo + gerador + sincronização API + cron.
# Instalação no HOST: sudo bash hora-certa.sh install
# Operação: sudo bash /opt/azuracast-hora-certa/hora-certa.sh run --next-day --api-sync
# Consulta: sudo bash /opt/azuracast-hora-certa/hora-certa.sh status
# Parada do agendamento: sudo bash /opt/azuracast-hora-certa/hora-certa.sh disable
set -Eeuo pipefail
umask 027
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SELF=$(readlink -f -- "${BASH_SOURCE[0]}")
INSTALL_DIR=/opt/azuracast-hora-certa
INSTALLED_SCRIPT="$INSTALL_DIR/hora-certa.sh"
CONFIG_DIR="$INSTALL_DIR/hora-certa-config"
CONFIG_FILE="$CONFIG_DIR/settings.env"
CRON_FILE=/etc/cron.d/azuracast-hora-certa
STATION_PATH_FILE="$INSTALL_DIR/station-path"
INSTALL_LOCK=/run/lock/azuracast-hora-certa.install.lock
RETENTION_DAYS=14
PLAYLIST_JSON_FILTER='{name:$name,description:$marker,type:"once_per_hour",source:"songs",order:"sequential",
  play_per_hour_minute:$minute,is_enabled:false,backend_options:["interrupt"],
  schedule_items:[{start_time:$start,end_time:$finish,start_date:$day,end_date:$day,
                   days:[],loop_once:false}]}'

playlist_json() {
    jq -n --arg name "$1" --arg marker "$2" --arg day "$3" \
        --argjson minute "$4" --argjson start "$5" --argjson finish "$6" \
        "$PLAYLIST_JSON_FILTER"
}

ask() {
    local label=$1 default=$2 answer
    read -r -p "$label [$default]: " answer || { printf '\nEntrada cancelada.\n' >&2; exit 2; }
    printf '%s' "${answer:-$default}"
}
ask_required() {
    local label=$1 answer
    read -r -p "$label: " answer || installer_fail 'Entrada cancelada.'
    [[ -n "$answer" ]] || installer_fail "Informe $label."
    printf '%s' "$answer"
}
check_station_path() {
    local path=$1
    [[ "$path" == /* && "$path" != *$'\n'* && "$path" != *$'\r'* &&
       -d "$path" && ! -L "$path" ]] || installer_fail 'Caminho da estação inválido; informe a pasta absoluta no host.'
}
confirm() {
    local answer
    read -r -p "$1 [s/N]: " answer || return 1
    [[ "$answer" == s || "$answer" == S || "$answer" == sim || "$answer" == SIM ]]
}
installer_fail() { printf 'ERRO: %s\n' "$*" >&2; exit 2; }
install_deps() {
    local missing=() cmd
    for cmd in ffmpeg ffprobe flock sha256sum curl jq setpriv awk; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    ((${#missing[@]} == 0)) && return 0
    printf 'Dependências ausentes: %s\n' "${missing[*]}"
    command -v apt-get >/dev/null || installer_fail 'Instale as dependências manualmente neste sistema e execute novamente.'
    confirm 'Instalar automaticamente ffmpeg, curl, jq, util-linux, gawk e cron pelo apt?' || installer_fail 'Instalação interrompida.'
    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y ffmpeg curl jq util-linux gawk cron
    for cmd in "${missing[@]}"; do command -v "$cmd" >/dev/null || installer_fail "Ainda falta $cmd"; done
}
openapi_check() {
    local base=$1 spec=$2 route http_code
    shift 2
    printf 'Consultando OpenAPI da própria rádio...\n'
    http_code=$(curl "$@" --silent --show-error --connect-timeout 7 --max-time 35 \
        -o "$spec" -w '%{http_code}' "$base/api/openapi.yml") || installer_fail 'Não consegui conectar à API. Verifique DNS, TLS e saída HTTPS do host.'
    if [[ "$http_code" != 200 ]]; then
        printf 'AVISO: /api/openapi.yml respondeu HTTP %s. Vou conferir as rotas públicas e autenticadas antes de oferecer continuação.\n' "$http_code" >&2
        return 1
    fi
    grep -Eq '^openapi:|^swagger:' "$spec" || installer_fail 'Resposta de OpenAPI inesperada; abortando antes de alterar a rádio.'
    for route in '/station/{station_id}/playlists' '/station/{station_id}/playlist/{id}/import' '/station/{station_id}/playlist/{id}/empty'; do
        grep -Fq -- "$route" "$spec" || installer_fail "Rota ausente nesta instalação: $route"
    done
}
install_main() {
    [[ $EUID == 0 ]] || installer_fail 'Execute a instalação como root: sudo bash arquivo.sh install'
    [[ -t 0 ]] || installer_fail 'A instalação requer terminal interativo para coletar as opções e a chave.'
    [[ -f "$SELF" && ! -L "$SELF" ]] || installer_fail 'Execute a partir de um arquivo .sh regular (não por pipe ou link simbólico).'
    exec 8>"$INSTALL_LOCK"
    flock -n 8 || installer_fail 'Outra instalação já está em andamento.'
    printf 'Instalação da Hora Certa no host AzuraCast\nA chave será digitada sem eco e guardada fora da pasta media.\n'
    install_deps
    local station media_root media_relative tz min1 min2 hr1 hr2 api api_host station_id uid gid key key_file name
    local spec tmp_config tmp_key tmp_script tmp_path curl_config stations_json detected status=0 openapi_available=true api_status
    local -a api_curl_opts=()
    station=$(ask_required 'Caminho absoluto da estação no host (pasta com media/)')
    check_station_path "$station"
    station=$(realpath -e -- "$station") || installer_fail 'Não foi possível resolver o caminho da estação.'
    [[ -d "$station/media" && ! -L "$station/media" ]] || installer_fail 'Não encontrei a pasta media da estação.'
    media_root=$(ask_required 'Caminho COMPLETO da pasta com Feminino/ e Masculino/ (dentro de media/)')
    [[ "$media_root" == /* && "$media_root" != *$'\n'* && "$media_root" != *$'\r'* && -d "$media_root" ]] || installer_fail 'Pasta das vozes inexistente ou caminho inválido.'
    media_root=$(realpath -e -- "$media_root") || installer_fail 'Não consegui resolver a pasta das vozes.'
    [[ "$media_root" == "$station/media/"* && ! -L "$media_root" ]] || installer_fail 'Pasta das vozes precisa estar dentro de station/media para ser indexada pelo AzuraCast.'
    media_relative="${media_root#"$station/media/"}"
    [[ -n "$media_relative" && "$media_relative" != *$'\n'* && "$media_relative" != *$'\r'* ]] || installer_fail 'Nome de pasta de mídia inválido.'
    for name in Feminino Masculino; do
        [[ -d "$media_root/$name" && ! -L "$media_root/$name" ]] || installer_fail "Falta pasta $name na estação."
    done
    uid=$(stat -c %u -- "$station"); gid=$(stat -c %g -- "$station")
    [[ "$uid" =~ ^[0-9]+$ && "$gid" =~ ^[0-9]+$ && "$uid" != 0 ]] || installer_fail 'O diretório da estação deve pertencer a um usuário não root com acesso de escrita à mídia.'
    setpriv --reuid="$uid" --regid="$gid" --clear-groups test -w "$media_root" || installer_fail 'O usuário da estação não pode gravar na subpasta de mídia.'
    tz=$(ask_required 'Fuso IANA da estação (exemplo: Europe/Lisbon)')
    min1=$(ask 'Minuto inicial do ciclo diário (00-59)' '3')
    min2=$(ask 'Minuto final do ciclo diário (00-59)' '27')
    hr1=$(ask 'Primeira hora diária (00-23)' '6')
    hr2=$(ask 'Última hora diária (00-23)' '23')
    HCP_STATION_DIR="$station" HCP_MEDIA_DIR="$media_root" HCP_TIMEZONE="$tz" HCP_MIN_START="$min1" HCP_MIN_END="$min2" \
      HCP_HOUR_START="$hr1" HCP_HOUR_END="$hr2" /bin/bash "$SELF" --plan --next-day || installer_fail 'Corrija os parâmetros apresentados.'
    api=$(ask_required 'URL base do AzuraCast (HTTPS, sem /api; ou HTTP em localhost)')
    [[ "$api" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ ||
       "$api" =~ ^http://(127\.0\.0\.1|localhost)(:[0-9]+)?$ ]] || installer_fail 'Informe URL HTTPS ou HTTP local 127.0.0.1/localhost (sem /api).'
    api_host=
    if [[ "$api" == http://* ]]; then
        api_host=$(ask 'Host virtual do AzuraCast, se exigido pelo proxy local (vazio = sem Host extra)' '')
        [[ -z "$api_host" || "$api_host" =~ ^[A-Za-z0-9.-]+$ ]] || installer_fail 'Host virtual inválido.'
        api_curl_opts=(--noproxy '*' -H "Host: $api_host")
        printf 'API local selecionada: a chave será enviada somente ao loopback do host.\n'
    fi
    spec=$(mktemp); tmp_key=$(mktemp); curl_config=$(mktemp)
    chmod 600 "$spec" "$tmp_key" "$curl_config"
    trap 'rm -f -- "${spec:-}" "${tmp_key:-}" "${curl_config:-}" "${tmp_config:-}" "${tmp_script:-}" "${tmp_path:-}"' EXIT
    if ! openapi_check "$api" "$spec" "${api_curl_opts[@]}"; then openapi_available=false; fi
    api_status=$(curl "${api_curl_opts[@]}" --silent --show-error --connect-timeout 7 --max-time 35 -o /dev/null -w '%{http_code}' "$api/api/status") || installer_fail 'A API não responde; verifique o proxy e o container AzuraCast.'
    [[ "$api_status" == 200 ]] || installer_fail "A API /api/status respondeu HTTP $api_status. Corrija o servidor/proxy antes de instalar; nenhum cron foi criado."
    stations_json=$(curl "${api_curl_opts[@]}" --fail --silent --show-error --connect-timeout 7 --max-time 35 "$api/api/stations") || installer_fail 'Não consegui consultar estações públicas.'
    detected=$(jq -r --arg slug "${station##*/}" 'if type=="array" then [.[] | select(.shortcode==$slug) | .id] | first // empty else empty end' <<< "$stations_json") || installer_fail 'JSON de estações inválido.'
    [[ "$detected" =~ ^[0-9]*$ ]] || detected=
    if [[ -n "$detected" ]]; then
        station_id=$(ask 'ID numérico da estação no AzuraCast' "$detected")
    else
        station_id=$(ask_required 'ID numérico da estação no AzuraCast (consulte /api/stations)')
    fi
    [[ "$station_id" =~ ^[1-9][0-9]*$ ]] || installer_fail 'ID numérico inválido.'
    local station_json actual_slug actual_name
    station_json=$(curl "${api_curl_opts[@]}" --fail --silent --show-error --connect-timeout 7 --max-time 35 "$api/api/station/$station_id") || installer_fail 'ID inexistente na API pública.'
    actual_slug=$(jq -r '.shortcode // empty' <<< "$station_json") || installer_fail 'Dados da estação inválidos.'
    actual_name=$(jq -r '.name // empty' <<< "$station_json") || installer_fail 'Nome da estação inválido.'
    [[ -n "$actual_slug" && "$actual_slug" != null ]] || installer_fail 'A API não informou o identificador da estação; confirme o ID no painel.'
    printf 'Estação na API: ID %s | nome "%s" | identificador "%s"\nMídia no host: %s\n' \
        "$station_id" "${actual_name:-sem nome}" "$actual_slug" "$media_root"
    printf 'Confira em AzuraCast > Administração > Armazenamento que a pasta atende à estação informada.\n'
    confirm 'Confirma que o ID da API e esta pasta pertencem à MESMA estação?' || installer_fail 'ID e pasta não confirmados; nenhum arquivo foi instalado.'
    local station_tz
    station_tz=$(jq -r '.timezone // empty' <<< "$station_json") || installer_fail 'Fuso da estação inválido.'
    if [[ -n "$station_tz" && "$station_tz" != "$tz" ]]; then
        installer_fail "Fuso da estação ($station_tz) difere do fuso configurado ($tz). Ajuste para evitar anúncio fora do horário."
    fi
    local key_attempt key_valid=false
    printf 'A digitação da chave fica invisível, sem asteriscos. Cole no terminal e pressione Enter.\n'
    for key_attempt in 1 2 3; do
        if ! IFS= read -r -s -p 'Cole sua chave de API autorizada para gerenciar playlists: ' key < /dev/tty; then
            printf '\n' >&2
            installer_fail 'Não consegui ler a chave pelo terminal. Execute via SSH interativo.'
        fi
        printf '\nRecebi %d caracteres (chave oculta).\n' "${#key}"
        if [[ "$key" =~ ^[A-Za-z0-9._:-]{8,250}$ ]]; then
            key_valid=true
            break
        fi
        if [[ -z "$key" ]]; then
            printf 'Nenhum caractere recebido. Use Ctrl+Shift+V ou o menu Colar do terminal e tente novamente.\n' >&2
        else
            printf 'Chave recebida, mas com formato inválido (8 a 250 caracteres; sem espaços). Confira a cópia e tente novamente.\n' >&2
        fi
        unset key
    done
    [[ "$key_valid" == true ]] || installer_fail 'Não consegui receber uma chave válida após 3 tentativas; nenhum arquivo foi instalado.'
    printf '%s\n' "$key" > "$tmp_key"
    printf 'header = "Authorization: Bearer %s"\n' "$key" > "$curl_config"
    unset key
    curl --config "$curl_config" "${api_curl_opts[@]}" --fail --silent --show-error --connect-timeout 7 --max-time 35 \
      "$api/api/station/$station_id/playlists" | jq -e 'type=="array" or (type=="object" and (.rows|type)=="array")' >/dev/null || installer_fail 'Chave sem acesso à lista de playlists ou resposta inesperada.'
    playlist_json 'Hora Certa Auto TESTE' 'AZHC-v1 2026-01-01' '2026-01-01' 21 621 2359 >/dev/null \
      || installer_fail 'Não consegui gerar o JSON da playlist; nenhuma alteração foi feita.'
    HCP_STATION_DIR="$station" HCP_MEDIA_DIR="$media_root" HCP_TIMEZONE="$tz" HCP_MIN_START="$min1" HCP_MIN_END="$min2" \
      HCP_HOUR_START="$hr1" HCP_HOUR_END="$hr2" /bin/bash "$SELF" --check-all --next-day \
      || installer_fail 'Faltam MP3 no intervalo completo de horas/minutos/vozes; nada foi instalado.'
    if [[ "$openapi_available" == false ]]; then
        printf 'OpenAPI indisponível, mas /api/status, estações e listagem autenticada de playlists responderam corretamente.\n'
        confirm 'Continuar sem validar o documento OpenAPI nesta execução?' || installer_fail 'Instalação interrompida; nenhum arquivo de instalação foi criado.'
    fi
    printf 'Validação concluída. Dono da estação: UID=%s GID=%s. A agenda será preparada para amanhã.\n' "$uid" "$gid"
    confirm 'Instalar script, guardar chave, gerar áudios, sincronizar playlist e ativar cron?' || installer_fail 'Instalação cancelada sem gravação.'
    [[ ! -L "$INSTALL_DIR" && ! -L "$CONFIG_DIR" && ! -L "$INSTALLED_SCRIPT" && ! -L "$CRON_FILE" && ! -L "$STATION_PATH_FILE" ]] || installer_fail 'Caminho de instalação simbólico inseguro.'
    if [[ -e "$CRON_FILE" || -e "$CONFIG_FILE" || -e "$INSTALLED_SCRIPT" || -e "$STATION_PATH_FILE" ]]; then
        confirm 'Já existem arquivos de instalação; criar cópia de segurança e substituir?' || installer_fail 'Arquivos existentes preservados.'
    fi
    install -d -m 755 -o root -g root "$INSTALL_DIR"
    install -d -m 700 -o "$uid" -g "$gid" "$CONFIG_DIR"
    local backup="$CONFIG_DIR/backup-$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -m 700 -- "$backup"
    for old in "$INSTALLED_SCRIPT" "$CONFIG_FILE" "$CONFIG_DIR/api-key" "$CRON_FILE" "$STATION_PATH_FILE"; do
        [[ ! -f "$old" ]] || cp -p -- "$old" "$backup/$(basename "$old")"
    done
    key_file="$CONFIG_DIR/api-key"
    tmp_config=$(mktemp "$CONFIG_DIR/.settings.XXXXXX")
    tmp_script=$(mktemp "$INSTALL_DIR/.hora-certa.XXXXXX")
    install -m 755 -- "$SELF" "$tmp_script"
    printf '%s\n' "HCP_STATION_DIR=$(printf '%q' "$station")" "HCP_MEDIA_DIR=$(printf '%q' "$media_root")" "HCP_TIMEZONE=$(printf '%q' "$tz")" \
        "HCP_MIN_START=$(printf '%q' "$min1")" "HCP_MIN_END=$(printf '%q' "$min2")" \
        "HCP_HOUR_START=$(printf '%q' "$hr1")" "HCP_HOUR_END=$(printf '%q' "$hr2")" \
        "HCP_API_URL=$(printf '%q' "$api")" "HCP_API_HOST=$(printf '%q' "$api_host")" "HCP_STATION_ID=$(printf '%q' "$station_id")" \
        "HCP_API_KEY_FILE=$(printf '%q' "$key_file")" > "$tmp_config"
    chmod 600 "$tmp_config"
    chown "$uid:$gid" "$tmp_config"
    install -m 600 -o "$uid" -g "$gid" "$tmp_key" "$CONFIG_DIR/.api-key-new"
    mv -f -- "$CONFIG_DIR/.api-key-new" "$key_file"
    mv -f -- "$tmp_config" "$CONFIG_FILE"; tmp_config=
    mv -f -- "$tmp_script" "$INSTALLED_SCRIPT"; tmp_script=
    tmp_path=$(mktemp "$INSTALL_DIR/.station-path.XXXXXX")
    printf '%s\n' "$station" > "$tmp_path"
    chmod 600 "$tmp_path"; chown root:root "$tmp_path"
    mv -f -- "$tmp_path" "$STATION_PATH_FILE"; tmp_path=
    printf 'Validando os MP3 originais e gerando a agenda de amanhã...\n'
    /bin/bash "$INSTALLED_SCRIPT" run --next-day || installer_fail 'Falha na geração; corrija os MP3 antes de ativar o cron.'
    printf 'Importando a playlist de amanhã...\n'
    if ! /bin/bash "$INSTALLED_SCRIPT" run --next-day --api-sync; then
        printf 'AVISO: sincronização inicial falhou; veja o erro acima. O cron tentará novamente às 23h; erros de chave/contrato exigem correção manual.\n' >&2
        status=1
    fi
    local cron_tmp
    cron_tmp=$(mktemp /etc/cron.d/.hora-certa-XXXXXX)
    printf 'SHELL=/bin/bash\nPATH=/usr/local/bin:/usr/bin:/bin\n* * * * * root /bin/bash %s --cron >> /var/log/azuracast-hora-certa.log 2>&1\n' "$INSTALLED_SCRIPT" > "$cron_tmp"
    chmod 644 "$cron_tmp"; chown root:root "$cron_tmp"; mv -f -- "$cron_tmp" "$CRON_FILE"
    if command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; then
        if systemctl list-unit-files cron.service --no-legend 2>/dev/null | grep -q '^cron.service'; then
            systemctl enable --now cron || installer_fail 'Falha ao iniciar cron.service.'
        elif systemctl list-unit-files crond.service --no-legend 2>/dev/null | grep -q '^crond.service'; then
            systemctl enable --now crond || installer_fail 'Falha ao iniciar crond.service.'
        else
            installer_fail 'Nenhum serviço cron.service/crond.service encontrado.'
        fi
    elif command -v service >/dev/null; then
        service cron start || service crond start || installer_fail 'Falha ao iniciar serviço cron/crond.'
    else
        installer_fail 'Inicie o daemon cron; comando service indisponível.'
    fi
    printf '\nINSTALADO: %s\nConfiguração: %s\nCron: %s\nLog: /var/log/azuracast-hora-certa.log\n' "$INSTALLED_SCRIPT" "$CONFIG_FILE" "$CRON_FILE"
    if (( status )); then printf 'Estado: cron ativo; primeira playlist pendente. Execute "sudo bash %s run --next-day --api-sync" após indexação.\n' "$INSTALLED_SCRIPT"; fi
    printf 'Confira no painel do AzuraCast a playlist de amanhã e escute ao vivo antes de confiar na automação.\n'
}
case "${1:-}" in
    install) shift; (($# == 0)) || installer_fail 'install não recebe argumentos.'; install_main; exit 0 ;;
    disable)
        [[ $EUID == 0 ]] || installer_fail 'Use sudo para desativar o cron.'
        [[ -f "$CRON_FILE" ]] || installer_fail 'Arquivo cron não encontrado.'
        mv -- "$CRON_FILE" "$CRON_FILE.disabled"
        printf 'Cron desativado. Playlists já existentes devem ser desativadas no painel.\n'; exit 0 ;;
    status)
        printf 'Script instalado: '; [[ -f "$INSTALLED_SCRIPT" ]] && echo sim || echo não
        printf 'Cron ativo: '; [[ -f "$CRON_FILE" ]] && echo sim || echo não
        printf 'Configuração presente: '; [[ -f "$CONFIG_FILE" ]] && echo sim || echo não
        [[ -f "$CRON_FILE" ]] && cat -- "$CRON_FILE"
        exit 0 ;;
    run)
        shift
        [[ $EUID == 0 ]] || installer_fail 'Use sudo ... run para executar como dono da estação.'
        [[ "$SELF" == "$INSTALLED_SCRIPT" ]] || installer_fail 'Use a cópia instalada para executar run.'
        [[ -f "$STATION_PATH_FILE" && ! -L "$STATION_PATH_FILE" && "$(stat -c %u -- "$STATION_PATH_FILE")" == 0 && "$(stat -c %a -- "$STATION_PATH_FILE")" == 600 ]] || installer_fail 'Metadados da estação inválidos.'
        IFS= read -r station_run < "$STATION_PATH_FILE" || installer_fail 'Não foi possível ler a estação.'
        check_station_path "$station_run"
        exec setpriv --reuid="$(stat -c %u -- "$station_run")" --regid="$(stat -c %g -- "$station_run")" --clear-groups \
          /usr/bin/env HCP_CONFIG_FILE="$CONFIG_FILE" /bin/bash "$INSTALLED_SCRIPT" "$@" ;;
    --cron)
        [[ $EUID == 0 ]] || installer_fail 'Cron deve rodar como root.'
        [[ "$SELF" == "$INSTALLED_SCRIPT" ]] || installer_fail 'Use a cópia instalada para executar cron.'
        [[ -f "$STATION_PATH_FILE" && ! -L "$STATION_PATH_FILE" && "$(stat -c %u -- "$STATION_PATH_FILE")" == 0 && "$(stat -c %a -- "$STATION_PATH_FILE")" == 600 ]] || installer_fail 'Metadados da estação inválidos no cron.'
        IFS= read -r station_run < "$STATION_PATH_FILE" || installer_fail 'Não foi possível ler a estação.'
        check_station_path "$station_run"
        exec setpriv --reuid="$(stat -c %u -- "$station_run")" --regid="$(stat -c %g -- "$station_run")" --clear-groups \
          /usr/bin/env HCP_CONFIG_FILE="$CONFIG_FILE" /bin/bash "$INSTALLED_SCRIPT" --cron-worker ;;
esac
if [[ "$SELF" == "$INSTALLED_SCRIPT" && -f "${HCP_CONFIG_FILE:-$CONFIG_FILE}" ]]; then
    cfg=${HCP_CONFIG_FILE:-$CONFIG_FILE}
    [[ ! -L "$cfg" && "$(stat -c %u -- "$cfg")" == "$EUID" && "$(stat -c %a -- "$cfg")" == 600 ]] || installer_fail 'Configuração deve pertencer ao executor e ter modo 600.'
    # Arquivo criado por este instalador e pertencente ao mesmo UID da estação.
    source "$cfg"
fi
if [[ "${1:-}" == --cron-worker ]]; then
    shift
    [[ "${HCP_TIMEZONE:-Etc/UTC}" =~ ^[A-Za-z_]+(/[A-Za-z0-9_+-]+)+$ && -f "/usr/share/zoneinfo/${HCP_TIMEZONE:-Etc/UTC}" ]] || installer_fail 'Fuso inválido no cron.'
    [[ "$(TZ="${HCP_TIMEZONE:-Etc/UTC}" date +%H)" == 23 ]] || exit 0
    [[ "$(TZ="${HCP_TIMEZONE:-Etc/UTC}" date +%M)" =~ ^(10|20|30|40|50)$ ]] || exit 0
    set -- --next-day --api-sync
fi

STATION_DIR="${HCP_STATION_DIR:-}"
TIMEZONE="${HCP_TIMEZONE:-Etc/UTC}"
MEDIA_DIR="${HCP_MEDIA_DIR:-$STATION_DIR/media/${HCP_MEDIA_SUBDIR:-horacerta}}"
MIN_START="${HCP_MIN_START:-3}"
MIN_END="${HCP_MIN_END:-27}"
HOUR_START="${HCP_HOUR_START:-6}"
HOUR_END="${HCP_HOUR_END:-23}"
OUTPUT_DIR="$MEDIA_DIR/Gerados"
MODE=build
API_SYNC=false
DAY=
NEXT_DAY=false

die() { printf 'ERRO: %s\n' "$*" >&2; exit 2; }
usage() {
    cat <<'HELP'
Uso: hora-certa.sh [--plan | --check | --check-all | --api-sync] [--date AAAA-MM-DD | --next-day]

Sem opções, gera os áudios de hoje. --plan mostra minuto/voz sem gravar arquivos.
--check valida os MP3 do dia sem criar arquivos ou alterar a API.
--check-all valida todas as horas/minutos e as duas vozes do intervalo escolhido.
--next-day gera amanhã para preparar a estação com antecedência.
--api-sync cria/importa/agenda uma playlist do dia pela API (opt-in).

Para --plan antes da instalação, informe HCP_STATION_DIR, HCP_MEDIA_DIR e
HCP_TIMEZONE no ambiente. Após instalar use: sudo bash /opt/azuracast-hora-certa/hora-certa.sh run --next-day --api-sync
HELP
}

while (($#)); do
    case "$1" in
        --plan) MODE=plan ;;
        --check) MODE=check ;;
        --check-all) MODE=check_all ;;
        --api-sync) API_SYNC=true ;;
        --date) (($# >= 2)) || die '--date exige AAAA-MM-DD'; DAY=$2; shift ;;
        --next-day) NEXT_DAY=true ;;
        -h|--help) usage; exit 0 ;;
        *) die "Opção desconhecida: $1" ;;
    esac
    shift
done
[[ -z "$DAY" || "$NEXT_DAY" == false ]] || die 'Use --date OU --next-day.'
[[ "$MODE" == build || "$API_SYNC" == false ]] || die '--plan/--check/--check-all e --api-sync são incompatíveis.'
[[ "$TIMEZONE" =~ ^[A-Za-z_]+(/[A-Za-z0-9_+-]+)+$ && -f "/usr/share/zoneinfo/$TIMEZONE" ]] || die "Fuso IANA inválido: $TIMEZONE"
for number in "$MIN_START" "$MIN_END" "$HOUR_START" "$HOUR_END"; do
    [[ "$number" =~ ^(0|[1-9][0-9]?)$ ]] || die "Número inválido: $number"
done
((MIN_START >= 0 && MIN_START <= MIN_END && MIN_END <= 59)) || die 'Minutos devem estar entre 00 e 59, com início <= fim.'
((HOUR_START >= 0 && HOUR_START <= HOUR_END && HOUR_END <= 23)) || die 'Horas devem estar entre 00 e 23, com início <= fim.'

if [[ -z "$DAY" ]]; then
    if [[ "$NEXT_DAY" == true ]]; then
        DAY="$(TZ="$TIMEZONE" date -d 'tomorrow' '+%Y-%m-%d')"
    else
        DAY="$(TZ="$TIMEZONE" date '+%Y-%m-%d')"
    fi
fi
[[ "$DAY" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die 'Data deve ser AAAA-MM-DD.'
NORMALIZED="$(TZ=UTC date -d "$DAY 12:00:00" '+%Y-%m-%d' 2>/dev/null)" || die "Data inválida: $DAY"
[[ "$NORMALIZED" == "$DAY" ]] || die "Data impossível: $DAY"

# Âncora civil em UTC ao meio-dia: DST local não altera o ciclo diário.
EPOCH_DAYS=$(( $(TZ=UTC date -d "$DAY 12:00:00" +%s) / 86400 ))
ANCHOR_DAYS=$(( $(TZ=UTC date -d '2020-01-01 12:00:00' +%s) / 86400 ))
INDEX=$((EPOCH_DAYS - ANCHOR_DAYS))
RANGE=$((MIN_END - MIN_START + 1))
MINUTE=$((MIN_START + (INDEX % RANGE + RANGE) % RANGE))
HOURS_PER_DAY=$((HOUR_END - HOUR_START + 1))
printf -v MINUTE_TEXT '%02d' "$MINUTE"
printf 'data=%s minuto=:%s horas=%02d-%02d vozes=alternadas por anúncio\n' "$DAY" "$MINUTE_TEXT" "$HOUR_START" "$HOUR_END"
for ((hour=HOUR_START; hour<=HOUR_END; hour++)); do
    serial=$((INDEX * HOURS_PER_DAY + hour - HOUR_START))
    voice_index=$(((serial % 2 + 2) % 2))
    if ((voice_index == 0)); then voice=Feminino; else voice=Masculino; fi
    printf '  %02d:%s %s\n' "$hour" "$MINUTE_TEXT" "$voice"
done
[[ "$MODE" == plan ]] && exit 0

for tool in ffmpeg ffprobe flock sha256sum mktemp stat cut chmod mv date; do
    command -v "$tool" >/dev/null 2>&1 || die "Programa necessário ausente: $tool"
done
[[ -d "$STATION_DIR" && ! -L "$STATION_DIR" ]] || die "Estação inexistente ou simbólica: $STATION_DIR"
[[ -d "$STATION_DIR/media" && ! -L "$STATION_DIR/media" && -d "$MEDIA_DIR" && ! -L "$MEDIA_DIR" ]] || die 'Pastas de mídia ausentes ou simbólicas.'
STATION_DIR=$(realpath -e -- "$STATION_DIR") || die 'Caminho da estação inválido.'
MEDIA_DIR=$(realpath -e -- "$MEDIA_DIR") || die 'Caminho da pasta das vozes inválido.'
[[ "$MEDIA_DIR" == "$STATION_DIR/media/"* ]] || die 'A pasta das vozes deve estar dentro de station/media.'
MEDIA_RELATIVE="${MEDIA_DIR#"$STATION_DIR/media/"}"
[[ -n "$MEDIA_RELATIVE" && "$MEDIA_RELATIVE" != *$'\n'* && "$MEDIA_RELATIVE" != *$'\r'* ]] || die 'Nome de pasta de mídia inválido.'
OUTPUT_DIR="$MEDIA_DIR/Gerados"
[[ -d "$MEDIA_DIR/Feminino" && ! -L "$MEDIA_DIR/Feminino" ]] || die 'Pasta Feminino ausente/simbólica.'
[[ -d "$MEDIA_DIR/Masculino" && ! -L "$MEDIA_DIR/Masculino" ]] || die 'Pasta Masculino ausente/simbólica.'
if [[ "$(id -u)" != "$(stat -c %u -- "$STATION_DIR")" ]]; then
    [[ ( "$MODE" == check || "$MODE" == check_all ) && "$(id -u)" == 0 ]] || die 'Execute como o UID dono da estação.'
fi
[[ ! -L "$OUTPUT_DIR" ]] || die 'Pasta Gerados não pode ser um link simbólico.'
if [[ "$MODE" != check && "$MODE" != check_all ]]; then
    mkdir -p -- "$OUTPUT_DIR"
    exec 9>"$OUTPUT_DIR/.hora-certa.lock"
    if ! flock -n 9; then
        printf 'Execução anterior ainda ativa; ignorando esta chamada.\n'
        exit 0
    fi
fi

DAY_COMPACT=${DAY//-/}
CACHE_DIR="$OUTPUT_DIR/Cache"
[[ ! -L "$CACHE_DIR" ]] || die 'Pasta Cache não pode ser um link simbólico.'
[[ "$MODE" == check || "$MODE" == check_all ]] || mkdir -p -- "$CACHE_DIR"
validate_mp3() {
    local input=$1 codec
    [[ -f "$input" && ! -L "$input" && -s "$input" ]] || die "MP3 ausente ou inseguro: $input"
    if [[ ( "$MODE" == check || "$MODE" == check_all ) && "$(id -u)" == 0 && "$(stat -c %u -- "$STATION_DIR")" != 0 ]]; then
        setpriv --reuid="$(stat -c %u -- "$STATION_DIR")" --regid="$(stat -c %g -- "$STATION_DIR")" --clear-groups \
          test -r "$input" || die "Dono da estação não consegue ler MP3: $input"
    fi
    codec=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 -- "$input") || die "MP3 inválido: $input"
    [[ "$codec" == mp3 ]] || die "Codec não é MP3: $input"
    ffmpeg -nostdin -v error -xerror -i "$input" -f null - >/dev/null || die "MP3 truncado: $input"
}
if [[ "$MODE" == check_all ]]; then
    for voice in Feminino Masculino; do
        for ((hour=HOUR_START; hour<=HOUR_END; hour++)); do
            printf -v hh '%02d' "$hour"
            if (( MIN_START == 0 )); then validate_mp3 "$MEDIA_DIR/$voice/HRS${hh}_0.mp3"; fi
            if (( MIN_END > 0 )); then validate_mp3 "$MEDIA_DIR/$voice/HRS${hh}.mp3"; fi
        done
        for ((minute=MIN_START; minute<=MIN_END; minute++)); do
            (( minute > 0 )) || continue
            printf -v mm '%02d' "$minute"
            validate_mp3 "$MEDIA_DIR/$voice/MIN${mm}.mp3"
        done
    done
    printf 'VALIDADO: todas as horas e minutos do intervalo para as duas vozes; nenhum arquivo criado.\n'
    exit 0
fi

declare -a HOUR_FILES=()
declare -a MINUTE_FILES=()
declare -a VOICES=()
for ((hour=HOUR_START; hour<=HOUR_END; hour++)); do
    printf -v hh '%02d' "$hour"
    serial=$((INDEX * HOURS_PER_DAY + hour - HOUR_START))
    voice_index=$(((serial % 2 + 2) % 2))
    if ((voice_index == 0)); then voice=Feminino; else voice=Masculino; fi
    source_dir="$MEDIA_DIR/$voice"
    if ((MINUTE == 0)); then
        input="$source_dir/HRS${hh}_0.mp3"
        minute_file=
    else
        input="$source_dir/HRS${hh}.mp3"
        minute_file="$source_dir/MIN${MINUTE_TEXT}.mp3"
    fi
    validate_mp3 "$input"
    [[ -z "$minute_file" ]] || validate_mp3 "$minute_file"
    HOUR_FILES+=("$input")
    MINUTE_FILES+=("$minute_file")
    VOICES+=("$voice")
done
if [[ "$MODE" == check ]]; then
    printf 'VALIDADO: áudios originais do dia %s (%s anúncios); nenhum arquivo criado.\n' "$DAY" "$HOURS_PER_DAY"
    exit 0
fi

M3U_TMP="$(mktemp "$OUTPUT_DIR/.agenda-${DAY_COMPACT}.XXXXXX")"
cleanup() {
    [[ -z "${MP3_TMP:-}" ]] || rm -f -- "$MP3_TMP"
    [[ -z "${M3U_TMP:-}" ]] || rm -f -- "$M3U_TMP"
}
trap cleanup EXIT
printf '#EXTM3U\n' > "$M3U_TMP"

for ((hour=HOUR_START; hour<=HOUR_END; hour++)); do
    printf -v hh '%02d' "$hour"
    input="${HOUR_FILES[hour-HOUR_START]}"
    minute_file="${MINUTE_FILES[hour-HOUR_START]}"
    voice="${VOICES[hour-HOUR_START]}"
    if ((MINUTE == 0)); then
        # ZaraRadio já fornece a locução integral da hora exata em HRSxx_0.
        # Referencia o original diretamente, sem gravar outra cópia.
        printf '%s/%s/HRS%s_0.mp3\n' "$MEDIA_RELATIVE" "$voice" "$hh" >> "$M3U_TMP"
        continue
    fi
    # A chave contém hora, minuto, voz e hash dos dois arquivos de origem.
    # A data pertence apenas à agenda: o MP3 pode atender a muitos dias.
    hash="$(sha256sum -- "$input" "$minute_file" | sha256sum | cut -c1-16)"
    filename="HoraCerta_${hh}${MINUTE_TEXT}_${voice}_${hash}.mp3"
    final="$CACHE_DIR/$filename"
    relative="$MEDIA_RELATIVE/Gerados/Cache/$filename"
    if [[ -e "$final" || -L "$final" ]]; then
        validate_mp3 "$final"
    else
        MP3_TMP="$(mktemp "$CACHE_DIR/.audio-XXXXXXXX.mp3")"
        ffmpeg -nostdin -hide_banner -loglevel error -y -i "$input" -i "$minute_file" \
            -filter_complex '[0:a]aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo[a];[1:a]aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo[b];[a][b]concat=n=2:v=0:a=1,alimiter=limit=0.89125[out]' \
            -map '[out]' -codec:a libmp3lame -b:a 192k -ar 48000 -ac 2 "$MP3_TMP" || die "Falha FFmpeg: $hh:$MINUTE_TEXT"
        validate_mp3 "$MP3_TMP"
        chmod 0640 "$MP3_TMP"
        mv -- "$MP3_TMP" "$final"
        MP3_TMP=
    fi
    printf '%s\n' "$relative" >> "$M3U_TMP"
done

chmod 0640 "$M3U_TMP"
mv -- "$M3U_TMP" "$OUTPUT_DIR/agenda-${DAY_COMPACT}.m3u"
M3U_TMP=
printf 'GERADO: %s\n' "$OUTPUT_DIR/agenda-${DAY_COMPACT}.m3u"
if [[ "$API_SYNC" == false ]]; then
    printf 'ATENÇÃO: M3U no disco não ativa uma playlist no AutoDJ; use --api-sync.\n'
    exit 0
fi

for tool in curl jq awk; do
    command -v "$tool" >/dev/null 2>&1 || die "Para --api-sync é necessário: $tool"
done
API_BASE="${HCP_API_URL:-}"
API_HOST="${HCP_API_HOST:-}"
API_STATION="${HCP_STATION_ID:-}"
API_KEY_FILE="${HCP_API_KEY_FILE:-}"
[[ "$API_BASE" =~ ^https://[A-Za-z0-9._:-]+(/[^?\#[:space:]]*)?$ ||
   "$API_BASE" =~ ^http://(localhost|127\.0\.0\.1)(:[0-9]+)?(/[^?\#[:space:]]*)?$ ]] || die 'HCP_API_URL deve usar HTTPS (ou HTTP local).'
if [[ -n "$API_HOST" ]]; then
    [[ "$API_HOST" =~ ^[A-Za-z0-9.-]+$ && "$API_BASE" =~ ^http://(localhost|127\.0\.0\.1)(:[0-9]+)?$ ]] || die 'HCP_API_HOST só pode ser usado com API HTTP local.'
fi
[[ "$API_STATION" =~ ^[A-Za-z0-9_-]+$ ]] || die 'HCP_STATION_ID inválido.'
[[ -f "$API_KEY_FILE" && ! -L "$API_KEY_FILE" && "$(stat -c %u -- "$API_KEY_FILE")" == "$(id -u)" ]] || die 'Arquivo da chave ausente ou com dono incorreto.'
KEY_MODE="$(stat -c %a -- "$API_KEY_FILE")"
(( (8#$KEY_MODE & 077) == 0 )) || die 'Arquivo da chave deve ser privado (chmod 600).'
API_KEY="$(< "$API_KEY_FILE")"
[[ "$API_KEY" =~ ^[A-Za-z0-9._:-]{8,250}$ ]] || die 'Formato de chave inválido.'
API_CONFIG="$(mktemp "$CONFIG_DIR/.api-curl-XXXXXX")"
chmod 0600 "$API_CONFIG"
printf 'header = "Authorization: Bearer %s"\n' "$API_KEY" > "$API_CONFIG"
if [[ "$API_BASE" == http://* ]]; then
    printf 'noproxy = "*"\n' >> "$API_CONFIG"
    [[ -z "$API_HOST" ]] || printf 'header = "Host: %s"\n' "$API_HOST" >> "$API_CONFIG"
fi
unset API_KEY
trap 'cleanup; [[ -z "${API_CONFIG:-}" ]] || rm -f -- "$API_CONFIG"' EXIT
API_URL="${API_BASE%/}/api/station/$API_STATION"

api_get() {
    curl --config "$API_CONFIG" --fail --silent --show-error --connect-timeout 5 --max-time 30 \
        "$API_URL/$1"
}
api_json() {
    curl --config "$API_CONFIG" --fail --silent --show-error --connect-timeout 5 --max-time 30 \
        -X "$1" -H 'Content-Type: application/json' --data-binary "@$3" "$API_URL/$2"
}

# Apaga apenas agendas antigas criadas por este script e a playlist correspondente.
# MP3 de Cache permanecem: podem ser reutilizados ou estar em outras playlists.
prune_old_days() {
    local today cutoff file basename compact old_day normalized name marker list counts id details removed=0
    today="$(TZ="$TIMEZONE" date +%Y-%m-%d)" || return 1
    cutoff="$(TZ=UTC date -d "$today 12:00:00 UTC - $RETENTION_DAYS days" +%Y%m%d)" || return 1
    for file in "$OUTPUT_DIR"/agenda-????????.m3u; do
        [[ -f "$file" && ! -L "$file" ]] || continue
        basename=${file##*/}
        [[ "$basename" =~ ^agenda-([0-9]{8})\.m3u$ ]] || continue
        compact=${BASH_REMATCH[1]}
        [[ "$compact" < "$cutoff" ]] || continue
        old_day="${compact:0:4}-${compact:4:2}-${compact:6:2}"
        normalized="$(TZ=UTC date -d "$old_day 12:00:00" +%Y-%m-%d 2>/dev/null)" || continue
        [[ "$normalized" == "$old_day" ]] || continue
        # Nunca remover uma agenda com nome coincidente mas conteúdo de outro uso.
        [[ "$(head -n 1 -- "$file")" == '#EXTM3U' ]] || continue
        awk -v prefix="$MEDIA_RELATIVE/" 'NR==1 {next} index($0,prefix)!=1 {bad=1} END {exit (NR<2 || bad)}' "$file" || continue
        name="Hora Certa Auto $compact"
        marker="AZHC-v1 $old_day"
        if ! list="$(curl --config "$API_CONFIG" --fail --silent --show-error \
            --connect-timeout 5 --max-time 30 --get --data-urlencode "searchPhrase=$name" \
            "$API_URL/playlists")"; then
            printf 'AVISO: não consultei a playlist antiga %s; preservando a agenda.\n' "$old_day" >&2
            return 1
        fi
        if ! counts="$(jq -er --arg name "$name" --arg marker "$marker" \
            '[(if type=="array" then .[] else .rows[] end) | select(.name==$name)] |
             {ours: [.[] | select(.description==$marker) | .id], other: [.[] | select(.description!=$marker)] | length}' \
            <<< "$list")"; then
            printf 'AVISO: resposta inválida ao consultar %s; preservando a agenda.\n' "$old_day" >&2
            return 1
        fi
        if [[ "$(jq -r '.other' <<< "$counts")" != 0 ]]; then
            printf 'AVISO: outra playlist usa o nome %s; preservando a agenda.\n' "$name" >&2
            continue
        fi
        case "$(jq -r '.ours | length' <<< "$counts")" in
            0) ;; # A playlist pode ter sido removida manualmente.
            1)
                id="$(jq -r '.ours[0]' <<< "$counts")"
                [[ "$id" =~ ^[1-9][0-9]*$ ]] || { printf 'AVISO: ID inesperado em %s.\n' "$name" >&2; continue; }
                if ! details="$(api_get "playlist/$id")"; then
                    printf 'AVISO: não confirmei os detalhes de %s; preservando.\n' "$name" >&2
                    return 1
                fi
                if ! jq -e --arg name "$name" --arg marker "$marker" --arg day "$old_day" --argjson id "$id" \
                    '.id==$id and .name==$name and .description==$marker and .type=="once_per_hour" and
                     .source=="songs" and (.schedule_items|type)=="array" and
                     (.schedule_items|length)==1 and
                     .schedule_items[0].start_date==$day and .schedule_items[0].end_date==$day' \
                    >/dev/null <<< "$details"; then
                    printf 'AVISO: playlist %s mudou; preservando-a.\n' "$name" >&2
                    continue
                fi
                if ! curl --config "$API_CONFIG" --fail --silent --show-error \
                    --connect-timeout 5 --max-time 30 -X DELETE "$API_URL/playlist/$id" >/dev/null; then
                    printf 'AVISO: não removi a playlist %s; preservando a agenda.\n' "$name" >&2
                    return 1
                fi
                ;;
            *) printf 'AVISO: playlists duplicadas em %s; preservando.\n' "$name" >&2; continue ;;
        esac
        rm -- "$file" || return 1
        printf 'LIMPEZA: playlist antiga e agenda %s removidas (MP3 preservados).\n' "$old_day"
        removed=$((removed + 1))
        ((removed < 20)) || break
    done
}

PLAYLIST_NAME="Hora Certa Auto ${DAY_COMPACT}"
MARKER="AZHC-v1 $DAY"
LIST="$(curl --config "$API_CONFIG" --fail --silent --show-error --connect-timeout 5 --max-time 30 \
    --get --data-urlencode "searchPhrase=$PLAYLIST_NAME" "$API_URL/playlists")" || die 'Não foi possível listar playlists pela API.'
jq -e 'type=="array" or (type=="object" and (.rows|type)=="array")' >/dev/null <<< "$LIST" || die 'Formato da lista de playlists inesperado.'
COLLISIONS="$(jq --arg name "$PLAYLIST_NAME" --arg marker "$MARKER" \
    '[if type=="array" then .[] else .rows[] end | select(.name==$name and .description!=$marker)] | length' <<< "$LIST")"
(( COLLISIONS == 0 )) || die 'Playlist com mesmo nome e dono diferente; nenhuma alteração feita.'
IDS="$(jq -r --arg name "$PLAYLIST_NAME" --arg marker "$MARKER" \
    '[if type=="array" then .[] else .rows[] end | select(.name==$name and .description==$marker) | .id] | join(" ")' <<< "$LIST")"
[[ "$IDS" != *' '* ]] || die 'Playlists duplicadas encontradas; corrija manualmente.'

if [[ -z "$IDS" ]]; then
    START_TIME=$((HOUR_START * 100 + MINUTE))
    END_TIME=$((HOUR_END * 100 + 59))
    PAYLOAD="$(mktemp "$OUTPUT_DIR/.playlist-json-XXXXXX")"
    trap 'cleanup; [[ -z "${API_CONFIG:-}" ]] || rm -f -- "$API_CONFIG"; [[ -z "${PAYLOAD:-}" ]] || rm -f -- "$PAYLOAD"' EXIT
    playlist_json "$PLAYLIST_NAME" "$MARKER" "$DAY" "$MINUTE" "$START_TIME" "$END_TIME" > "$PAYLOAD" \
      || die 'Não consegui montar o JSON da playlist; nenhuma playlist foi criada.'
    CREATED="$(api_json POST playlists "$PAYLOAD")" || die 'Falha ao criar playlist desativada.'
    IDS="$(jq -r '.id // empty' <<< "$CREATED")"
    [[ "$IDS" =~ ^[1-9][0-9]*$ ]] || die 'Resposta de criação sem ID; verifique playlists antes de tentar novamente.'
fi
PLAYLIST_ID="$IDS"
DETAILS="$(api_get "playlist/$PLAYLIST_ID")" || die 'Não foi possível verificar a playlist.'
jq -e --arg marker "$MARKER" --argjson minute "$MINUTE" --arg day "$DAY" \
    '.description==$marker and .type=="once_per_hour" and .source=="songs" and
     .order=="sequential" and .play_per_hour_minute==$minute and
     ([.schedule_items[]? | select(.start_date==$day and .end_date==$day)] | length)>=1' \
    >/dev/null <<< "$DETAILS" || die 'Contrato/agenda da playlist não corresponde ao dia.'
if jq -e '.is_enabled==true' >/dev/null <<< "$DETAILS"; then
    printf 'Playlist do dia já ativa (id=%s); não importei outra vez.\n' "$PLAYLIST_ID"
    prune_old_days || printf 'AVISO: limpeza adiada; tentarei novamente na próxima sincronização.\n' >&2
    exit 0
fi

# Uma tentativa anterior pode ter importado somente parte. Limpe somente a
# playlist identificada pelo marcador e ainda desativada.
curl --config "$API_CONFIG" --fail --silent --show-error --connect-timeout 5 --max-time 30 \
    -X DELETE "$API_URL/playlist/$PLAYLIST_ID/empty" >/dev/null || die 'Falha ao esvaziar playlist desativada.'
IMPORTED="$(curl --config "$API_CONFIG" --fail --silent --show-error \
    --connect-timeout 5 --max-time 90 -F "playlist_file=@$OUTPUT_DIR/agenda-${DAY_COMPACT}.m3u;type=audio/x-mpegurl" \
    "$API_URL/playlist/$PLAYLIST_ID/import")" || die 'Falha na importação; playlist continua desativada.'
EXPECTED=$((HOUR_END - HOUR_START + 1))
jq -e --argjson expected "$EXPECTED" \
    '.success==true and (.import_results|length)==$expected and
     ([.import_results[] | select(.match!=null)] | length)==$expected' \
    >/dev/null <<< "$IMPORTED" || die 'Mídia ainda não indexada ou importação incompleta; playlist desativada. Tente novamente depois da sincronização.'
ENABLE_PAYLOAD="$(mktemp "$OUTPUT_DIR/.enable-json-XXXXXX")"
trap 'cleanup; [[ -z "${API_CONFIG:-}" ]] || rm -f -- "$API_CONFIG"; [[ -z "${PAYLOAD:-}" ]] || rm -f -- "$PAYLOAD"; [[ -z "${ENABLE_PAYLOAD:-}" ]] || rm -f -- "$ENABLE_PAYLOAD"' EXIT
printf '{"is_enabled":true}\n' > "$ENABLE_PAYLOAD"
api_json PUT "playlist/$PLAYLIST_ID" "$ENABLE_PAYLOAD" >/dev/null || die 'Falha ao ativar playlist importada.'
DETAILS="$(api_get "playlist/$PLAYLIST_ID")" || die 'Falha ao confirmar ativação.'
jq -e '.is_enabled==true' >/dev/null <<< "$DETAILS" || die 'Playlist não ficou ativa.'
printf 'API: playlist criada/importada/ativada, id=%s, data=%s, minuto=:%s.\n' "$PLAYLIST_ID" "$DAY" "$MINUTE_TEXT"
prune_old_days || printf 'AVISO: limpeza adiada; tentarei novamente na próxima sincronização.\n' >&2
