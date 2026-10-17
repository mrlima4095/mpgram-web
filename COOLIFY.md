# Deploy do MPGram Web no Coolify

O repositório original traz uma pasta `docker/` (nginx + php-fpm + `docker-compose` legado)
que depende de `volumes_from`, `links` e bind-mount do código do host — isso não se
comporta bem no Coolify. Por isso foi adicionado um **`Dockerfile` na raiz**, com um
container único (Apache + mod_php) que escuta na **porta 80**; o proxy do Coolify fica
responsável por HTTPS e domínio.

Arquivos adicionados:

| Arquivo | Função |
| --- | --- |
| `Dockerfile` | imagem única (Apache + PHP 8.4 + extensões + Composer + MadelineProto + patches) |
| `docker/coolify/php.ini` | `short_open_tag`, limites, `ffi.enable=1`, opcache, browscap |
| `docker/coolify/apache.conf` | `AllowOverride`, bloqueio de `/s/`, `/docker/`, `.git`, log; timeouts longos |
| `docker/coolify/entrypoint.sh` | gera a config e ajusta permissões de `s/` no boot |
| `docker/coolify/apply-env-config.php` | gera `config.php`/`api_values.php` a partir das envs |
| `.dockerignore` | não envia `.git`, `s/`, `vendor/`, segredos etc. para o build |

---

## 1. Antes de tudo: API ID/Hash do Telegram

Crie um app em <https://my.telegram.org/apps> e guarde o `api_id` e o `api_hash`.
Eles **não** vão no código — serão variáveis de ambiente no Coolify.

## 2. Publique este repositório no seu GitHub

O Coolify faz deploy a partir de um repositório Git. Faça um fork/push:

```bash
cd mpgram-web
git add Dockerfile .dockerignore docker/coolify COOLIFY.md
git commit -m "Add Coolify-ready Dockerfile"
git remote add myrepo git@github.com:SEU_USUARIO/mpgram-web.git
git push myrepo master
```

## 3. Crie o recurso no Coolify

1. **Projects → + New** → escolha o projeto/ambiente.
2. **+ New Resource → Public Repository** (ou *Private Repository* + deploy key).
3. Selecione o repositório e a branch (`master`).
4. **Build Pack: `Dockerfile`**
   - *Dockerfile Location*: `/Dockerfile`
   - *Base Directory*: `/`
5. **Network → Ports Exposes: `80`** (é o que o container escuta).
6. **Domains**: informe `https://seu-dominio.com` e deixe o Coolify emitir o certificado.

## 4. Variáveis de ambiente (Environment Variables)

Marque como *Build Variable* apenas se precisar; no geral são de runtime.

| Variável | Obrigatória | Exemplo | Descrição |
| --- | --- | --- | --- |
| `API_ID` | **sim** | `1234567` | `api_id` de my.telegram.org |
| `API_HASH` | **sim** | `abcdef0123456789...` | `api_hash` |
| `INSTANCE_PASSWORD` | recomendado | `minhasenha` | senha para acessar a instância (vazio/`null` = sem senha) |
| `LOGIN_CAPTCHA` | não | `true` | captcha no login |
| `ENABLE_API` | não | `false` | habilita `api.php` |
| `ENABLE_LOGIN_API` | não | `false` | habilita API de login |
| `ENABLE_PEER_DB` | não | `true` | `false` reduz o tamanho das sessões, mas para de carregar avatares |
| `FORCE_HTTPS` | não | `false` | deixe `false`; o proxy do Coolify já manda `X-Forwarded-Proto` |
| `CHROME_HTTPS` | não | `false` | idem |
| `SERVER_NAME` | não | `mp.exemplo.com` | força o host usado nos links gerados |
| `UPLOAD_SIZE_LIMIT` | não | `20971520` | limite de upload em bytes (padrão 20 MB) |
| `DOWNLOAD_SIZE_LIMIT` | não | `1073741824` | limite de download (padrão 1 GB) |

Qualquer constante do `config.php.example` (`LOGIN_REQUESTS_BY_IP`, `CONVERT_VOICE_MESSAGES`,
`FILE_REWRITE`, etc.) pode ser sobrescrita por uma variável de ambiente com o mesmo nome.

> Prefere versionar um `config.php` próprio? Também funciona: o entrypoint **não**
> sobrescreve arquivos que já existem.

## 5. Volume persistente (muito importante)

Em **Storages** (Persistent Storage) crie um **Volume**:

- **Name**: `mpgram-sessions`
- **Destination Path**: `/var/www/html/s`

É aqui que ficam as sessões do MadelineProto (`s/<usuario>.madeline`). Sem o volume,
**todo redeploy apaga as sessões** e os usuários precisam logar de novo.

## 6. Healthcheck

Em **Health Checks** use:

- **Path**: `/robots.txt` (arquivo estático; `/` redireciona para `login.php`, também serve)
- **Port**: `80`

## 7. Deploy

Clique em **Deploy**. O build instala as extensões PHP, roda `composer install` e aplica
os patches do MadelineProto — pode levar **vários minutos** e consumir bastante RAM/CPU
(o `vendor/` do MadelineProto é grande). Ao terminar, acesse o domínio e faça login com
seu número de telefone no próprio cliente.

---

## Observações importantes

- **Restart periódico do PHP**: o README do projeto recomenda reiniciar o serviço PHP pelo
  menos de hora em hora (os workers do MadelineProto são de longa duração e vazam memória).
  O entrypoint já faz isso sozinho: a cada 1 hora ele mata apenas os processos
  `MadelineProto worker` (o Apache os recria sob demanda). Para mudar o intervalo, defina
  `MP_WORKER_RESTART_INTERVAL` (em segundos; `0` desativa).

- **Sessões travadas ("carregando pra sempre")**: o MadelineProto guarda o PID do worker
  dentro da própria pasta da sessão (`ipcState.php` + sockets `ipc`). Como `s/` é volume
  persistente, um redeploy/restart deixaria PIDs mortos ali e as requisições ficariam
  ~60s esperando um worker inexistente. O entrypoint limpa esse estado no boot e um
  watchdog roda a cada minuto removendo estado órfão. Se uma sessão aparecer com
  `AUTH_KEY_UNREGISTERED`, a sessão foi invalidada no lado do Telegram (sessão encerrada
  em "Dispositivos conectados" ou código de login expirado): basta sair e entrar de novo
  no cliente.

- **Memória**: cada requisição pode usar centenas de MB. Ajuste `memory_limit`
  (hoje 2048M em `docker/coolify/php.ini`) e os recursos do servidor conforme o
  número de usuários. Se ficar pesado, reduza `MaxRequestWorkers` no `apache.conf`.

- **Mensagens de voz / stickers animados (opcional)**: instale `ffmpeg` (voz) e o
  lottie-converter (TGS) e ative `CONVERT_VOICE_MESSAGES` / `CONVERT_TGS_STICKERS`.
  Por padrão ficam desativados.

- **Segurança do `api_id`/`api_hash`**: ficam em variáveis de ambiente e só aparecem no
  container. O `apache.conf` bloqueia acesso HTTP a `api_values.php`, `/s/`, `/docker/`,
  `.git` e `MadelineProto.log`.

- **Alternativa (não recomendada)**: dá para usar a pasta `docker/` original como
  *Build Pack: Docker Compose*. Exigiria definir `UID`, `PROTO=http`,
  `INTERFACE=0.0.0.0`, `PORT_HTTP` (ex.: 8080) e apontar a porta do Coolify para esse
  valor; além disso os serviços `composer` (one-shot) e `volumes_from` são frágeis.
  O `Dockerfile` da raiz é bem mais previsível.
