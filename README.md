# Hora Certa para AzuraCast ⏰🎙️

Locuções de hora certa com vozes **feminina e masculina alternadas**, minuto diferente a cada dia, geração de MP3 sem duplicatas, agenda automática no AutoDJ e limpeza conservadora. Instalação no **host Linux ou Windows** com acesso aos arquivos da estação; não exige plugin do AzuraCast nem incorpora domínio, IP, usuário, pasta ou ID privados.

> **Compatibilidade:** Linux usa `hora-certa.sh`, Bash, cron e ferramentas GNU (instala dependências com `apt` em Debian/Ubuntu). Windows usa **os dois arquivos** `hora-certa.bat` + `hora-certa-windows.ps1`, PowerShell **7.2 ou superior**, FFmpeg/FFprobe e Agendador de Tarefas. A estação precisa ter a mídia acessível **no próprio host que gera os áudios**, dentro da pasta `media/` que o AzuraCast realmente indexa. Em uma VPS Linux, execute a versão Linux **na VPS**. Teste primeiro em estação de homologação.

## Como funciona

| Etapa | Resultado |
| --- | --- |
| Instalação | Pede caminho da estação **e caminho completo da pasta das vozes**, fuso IANA, horários, intervalo de minutos, URL da API, ID e chave. Confirma a ligação entre pasta e estação antes de gravar. |
| A cada dia, às 23h no fuso da estação | Cron (Linux) ou Agendador de Tarefas (Windows) tenta preparar **a agenda do dia seguinte** às 23:10, 23:20, 23:30, 23:40 e 23:50. A segunda tentativa não duplica uma playlist já ativa. |
| Hora + minuto | Para `12:21`, usa `HRS12.mp3` e `MIN21.mp3` da voz selecionada e gera um único MP3. Para `12:00`, aponta direto para `HRS12_0.mp3`. |
| Cache | Um MP3 gerado serve para outras datas com a mesma hora, minuto, voz e arquivos de origem. Se a origem mudar, cria versão com outro hash; versões antigas permanecem para proteger playlists que ainda as usam. |
| Agenda e API | Cria `agenda-AAAAMMDD.m3u` e, via API, importa sua mídia para uma playlist com programação limitada àquela data. O AutoDJ toca segundo as regras de prioridade da estação. |
| Retenção | Depois de uma sincronização bem-sucedida, remove agendas com mais de **14 dias** e suas playlists identificadas e verificadas; mantém o cache MP3 e preserva itens duvidosos. |

O minuto avança deterministicamente dentro do intervalo definido. Por exemplo, se você escolher `03` a `27`, cada dia usa um minuto do ciclo; todas as horas daquele dia usam esse mesmo minuto. A voz alterna **a cada anúncio**, inclusive na passagem entre dias. Não há promessa de reprodução no segundo exato: o AutoDJ é responsável pelo momento de entrada, sujeito à configuração e à programação da estação.

## 1. Organize os MP3 no host

Identifique o **diretório real da estação** e, separadamente, o **caminho completo da pasta das vozes**. Esta última deve ser descendente de `<estacao>/media/`, inclusive se estiver em uma subpasta mais profunda; seu nome pode ser personalizado. O diretório da estação pode estar em volume Docker ou bind mount e **não precisa coincidir com o identificador curto da estação na API**. Exemplo de estrutura, com nomes genéricos:

```text
<diretorio-da-estacao>/
└── media/
    └── <minha-pasta-de-voz>/      # nome e caminho completo pedidos na instalação
        ├── Feminino/
        │   ├── HRS06.mp3          # fala a hora, sem o minuto
        │   ├── HRS06_0.mp3        # frase completa da hora exata, para :00
        │   └── MIN21.mp3          # fala o minuto 21
        └── Masculino/
            ├── HRS06.mp3
            ├── HRS06_0.mp3
            └── MIN21.mp3
```

Prepare, para **as duas vozes**, `HRS00.mp3` a `HRS23.mp3`, `HRS00_0.mp3` a `HRS23_0.mp3` e `MIN01.mp3` a `MIN59.mp3`, conforme as horas e o intervalo de minutos escolhidos. Apenas arquivos efetivamente selecionados serão exigidos em cada execução. `MIN00.mp3` não é usado. A pasta `Gerados/` é criada dentro da pasta das vozes se ainda não existir. O script verifica o codec MP3 e decodifica os arquivos selecionados antes de publicar uma agenda. Não redistribuímos locuções: providencie áudios para os quais você tenha direitos de uso.

O diretório da estação deve pertencer a um **UID diferente de root** que consiga escrever na subpasta de mídia. O instalador executa as tarefas diárias sob esse UID. Confira o acesso no host antes de começar:

```bash
stat -c 'UID=%u GID=%g %n' /caminho/real/da/estacao
stat -c 'UID=%u GID=%g %n' /caminho/completo/da/pasta/das/vozes
```

## 2. Instale no Linux (host local ou VPS Linux)

Baixe o [arquivo `hora-certa.sh`](hora-certa.sh) deste repositório para o **servidor host** por meio do Git, de uma cópia SCP ou da interface do GitHub. Confira que ele realmente está presente e execute num terminal SSH interativo:

```bash
ls -l ./hora-certa.sh && bash -n ./hora-certa.sh && sudo bash ./hora-certa.sh install
```

Não execute uma cópia antiga instalada se o arquivo recém-baixado não existir. Durante a instalação:

1. Informe o caminho absoluto da estação no host e o **caminho absoluto completo** da pasta que contém `Feminino/` e `Masculino/`, dentro da pasta `media/` daquela estação.
2. Informe o **fuso IANA que a estação realmente usa** (por exemplo, `Europe/Lisbon`); escolha minuto mínimo/máximo e hora inicial/final (intervalos inclusivos, `00–59` e `00–23`).
3. Informe a URL **base** do seu AzuraCast, sem `/api`, normalmente `https://<seu-servidor>`. Quando o proxy público estiver indisponível, use `http://127.0.0.1:<porta-http-mapeada>` no próprio host; preencha o Host virtual apenas se o proxy local precisar dele. HTTP remoto é recusado para proteger a chave.
4. Confirme o ID numérico e a estação apresentados pela API; compare com o armazenamento no painel. **Nome da pasta e shortcode podem ser diferentes.**
5. Cole uma **chave de API** de usuário com permissão para gerenciar a mídia/playlists daquela estação. Nada aparece na tela ao colar; pressione Enter. Se o terminal não colar com `Ctrl+V`, tente `Ctrl+Shift+V` ou a opção **Colar** do terminal.
6. Revise a pergunta final. O instalador valida **todos os MP3 das duas vozes para o intervalo completo de horas e minutos antes de gravar a instalação**, confere o JSON de playlist, instala as dependências necessárias pelo `apt` com confirmação, salva a configuração e tenta preparar a playlist de amanhã antes de ativar o cron.

A chave vem das **Minhas chaves de API** no painel do AzuraCast. Ela fica em `/opt/azuracast-hora-certa/hora-certa-config/api-key` com permissões `600`; **não** salve a chave no Git nem cole em um comando de shell. O instalador verifica o documento OpenAPI servido pela própria instância; se estiver indisponível mas a API essencial funcionar, solicita confirmação explícita antes de continuar.

### Windows: `.bat` + PowerShell 7

Use Windows quando a pasta de mídia que o AzuraCast indexa for acessível **pelo próprio Windows em uma unidade local**, normalmente em uma instalação Docker com bind mount da unidade. Um computador Windows que acessa somente a **API de uma VPS remota** não tem acesso aos arquivos da rádio e não consegue instalar esta automação pela API sozinha: nesse caso execute `hora-certa.sh` na VPS Linux.

1. Instale **PowerShell 7 para todos os usuários** (o `.bat` oferece o instalador MSI pelo `winget` com confirmação, se disponível) e **FFmpeg com FFprobe em uma pasta acessível à conta SYSTEM**, fora do seu perfil de usuário; consulte o [instalador oficial do PowerShell](https://learn.microsoft.com/powershell/scripting/install/install-powershell-on-windows) e os [builds Windows indicados pelo FFmpeg](https://ffmpeg.org/download.html). Tenha os caminhos completos de `ffmpeg.exe` e `ffprobe.exe` ou adicione ambos ao `PATH` do sistema. Instalações desses executáveis em `%LOCALAPPDATA%` são recusadas porque a tarefa SYSTEM pode não alcançá-los.
2. Mantenha `hora-certa.bat` e `hora-certa-windows.ps1` na **mesma pasta**; abra o Prompt de Comando (`cmd.exe`) **como Administrador** e vá até a pasta do ZIP extraído. Se usar PowerShell como terminal, anteponha `./` (no Windows, `.\hora-certa.bat`).
3. Execute `hora-certa.bat install`. Informe, por exemplo, `C:\radio\estacao` como pasta da estação e `C:\radio\estacao\media\minha-pasta-de-voz` como pasta das vozes, se **essas pastas realmente existirem no seu PC**. O programa valida a relação entre elas, cada voz, MP3 necessários, fuso IANA, API, ID e chave antes de instalar. **Esses caminhos são exemplos, não padrões do instalador.**
4. Confirme que o armazenamento no painel AzuraCast corresponde **ao mesmo volume**. O instalador prepara a agenda inicial e cria a tarefa `AzuraCastHoraCerta` para rodar como **SYSTEM**, inclusive sem usuário conectado. A chave é protegida com DPAPI da máquina e a pasta em `%ProgramData%\AzuraCastHoraCerta` recebe acesso restrito a SYSTEM e Administradores. Não mova esse diretório para outra máquina sem reinstalar a chave.

```bat
hora-certa.bat install
hora-certa.bat status
hora-certa.bat run -Plan -NextDay
hora-certa.bat run -NextDay -ApiSync
hora-certa.bat disable
```

No Windows, `run -Date AAAA-MM-DD -ApiSync` sincroniza uma data específica. Consulte `%ProgramData%\AzuraCastHoraCerta\hora-certa.log` para as tentativas agendadas e o histórico da tarefa no Agendador de Tarefas. Uma pasta UNC (`\\servidor\share\...`) é recusada: a conta SYSTEM geralmente não possui acesso ao compartilhamento. O uso no Windows **exige uma unidade local compartilhada com o AzuraCast**; drives mapeados da sessão do usuário não ficam automaticamente disponíveis para SYSTEM.

Ative **somente um agendador por estação**. Se migrar entre Linux e Windows, desative o cron ou a tarefa anterior e confira as playlists já ativas antes de ativar a nova instalação.

> **Validação de plataforma:** a implementação Windows usa as mesmas regras de áudio, agenda, API, cache e retenção do Linux, mas deve ser exercitada em um Windows de teste com acesso ao volume real antes de entrar em produção. O ambiente de desenvolvimento deste pacote não executa Windows.

### Arquivos criados no Linux

| Local | Conteúdo |
| --- | --- |
| `/opt/azuracast-hora-certa/hora-certa.sh` | Script instalado no host. |
| `/opt/azuracast-hora-certa/hora-certa-config/` | Configuração e chave, acessíveis ao UID da estação. |
| `/etc/cron.d/azuracast-hora-certa` | Cron para **uma estação por instalação**. |
| `/var/log/azuracast-hora-certa.log` | Saída das execuções agendadas. |
| `<pasta-das-vozes>/Gerados/Cache/*.mp3` | MP3 combinados, reutilizáveis. |
| `<pasta-das-vozes>/Gerados/agenda-AAAAMMDD.m3u` | Agenda do dia, importada via API. |

## 3. Verifique no AzuraCast

```bash
sudo bash /opt/azuracast-hora-certa/hora-certa.sh status
sudo bash /opt/azuracast-hora-certa/hora-certa.sh run --plan --next-day
sudo bash /opt/azuracast-hora-certa/hora-certa.sh run --check --next-day
sudo bash /opt/azuracast-hora-certa/hora-certa.sh run --check-all --next-day
sudo bash /opt/azuracast-hora-certa/hora-certa.sh run --next-day --api-sync
sudo tail -n 80 /var/log/azuracast-hora-certa.log
```

No painel do AzuraCast, confira a **playlist da data de amanhã**, a programação e os arquivos importados. Aguarde a indexação de arquivos de mídia pelo AzuraCast se receber aviso de importação incompleta; a playlist permanece desativada e o cron poderá tentar novamente. Escute a transmissão de teste: a programação `once_per_hour` pode interagir com outras playlists, requisições, prioridades e locução ao vivo.

O comando `run --date AAAA-MM-DD --api-sync` permite sincronizar uma data específica. Para interromper **futuras execuções do cron**:

```bash
sudo bash /opt/azuracast-hora-certa/hora-certa.sh disable
```

Playlists já ativadas continuam no AzuraCast; desative-as no painel se precisar interromper anúncios imediatamente. Para atualizar o script, baixe uma versão nova, revise as mudanças, confirme que o arquivo existe e execute novamente `sudo bash ./hora-certa.sh install`. A reinstalação pede confirmação e salva cópias dos arquivos anteriores em `hora-certa-config/backup-*` (incluindo eventuais chaves). Gerencie essas cópias como segredos e remova-as quando não forem mais necessárias.

## Retenção e espaço em disco

O processo guarda **no máximo uma versão por combinação de áudios de origem** encontrada; repetições diárias reaproveitam o MP3 existente. A quantidade do cache é limitada pelas combinações utilizadas e pode crescer quando os arquivos originais forem alterados. O script **não apaga automaticamente nenhum MP3 do cache** porque uma playlist antiga, inclusive criada manualmente, pode referenciá-lo.

Agendas `.m3u` e playlists anteriores a 14 dias são removidas **somente após** confirmar o nome, marcador e data pela API; a limpeza pula itens alterados/ambíguos e processa no máximo 20 dias por execução. Não execute `rm -rf` no cache sem antes consultar quais arquivos permanecem em playlists. Se precisar reduzir mais o uso, faça uma auditoria das referências no AzuraCast e um backup, depois exclua manualmente apenas os MP3 comprovadamente sem uso.

## Problemas comuns

| Sintoma | Verificação |
| --- | --- |
| `HTTP 502` na URL pública | Teste `/api/status` no endereço local do host; confira o proxy/túnel e a rota até a porta HTTP do container. O script permite URL local de loopback. |
| `ID` e pasta com nomes distintos | Confira a correspondência em **Administração → Armazenamento** no AzuraCast; confirme somente se for a mesma estação. |
| Chave invisível | É intencional. Confira a quantidade de caracteres exibida depois de pressionar Enter; use uma sessão SSH interativa e uma chave com permissão **Manage Station Media**. |
| `MP3 ausente` / `MP3 inválido` | Confira hora, minuto e voz mostrados por `run --plan --next-day`; verifique a estrutura e o codec no host. |
| `Importação incompleta` | Aguarde o AzuraCast indexar os MP3 em `Gerados/Cache/` e execute de novo `run --next-day --api-sync`. |
| Cron ativo sem tocar o anúncio | Confira playlist habilitada, datas, fuso da estação, prioridade e funcionamento do AutoDJ; acompanhe `tail` do log. |
| `curl: (60)` | O HTTPS do servidor precisa de um certificado TLS válido para o host informado; corrija o certificado ou use a API local em `127.0.0.1`. |

## Desenvolvimento

```bash
bash -n hora-certa.sh
python3 -m unittest discover -s tests -v
```

No Windows com PowerShell 7 e FFmpeg instalados, execute `pwsh -NoProfile -File .\tests\test_windows.ps1`. O workflow `.github/workflows/testes.yml` executa os testes em runners Linux e Windows depois que você publicar o repositório.

O teste Linux usa **API simulada** e áudios temporários para conferir criação/ativação da playlist, reutilização do cache, a hora redonda e a remoção conservadora. O teste Windows confere sintaxe, geração e cache em pasta com espaços; a API Windows e a instalação como SYSTEM **ainda exigem validação em uma estação Windows real**. O teste opcional da instalação interativa Linux exige root **com UID não root mapeado**; ambientes isolados que não permitem a troca de UID mostram `skipped`. Os testes não substituem a validação em uma instância real, cuja API e estratégia de AutoDJ variam conforme a versão.

Documentação oficial: [API e autenticação](https://www.azuracast.com/docs/developers/apis/), [Playlists e prioridades](https://www.azuracast.com/docs/user-guide/playlists/), [Gerenciamento de mídia](https://www.azuracast.com/docs/user-guide/media-management/). Consulte também `/docs/api/` e `/api/openapi.yml` **na sua própria instalação**, que refletem a versão em execução.

## Licença

MIT. Consulte [LICENSE](LICENSE).
