# restaurar-portal-modelo

Script para restaurar um backup do **Portal Modelo (Interlegis)** em Docker,
subindo a versão atual da imagem oficial (`interlegis/portalmodelo:3.0-21`) e
devolvendo o portal funcional com os mesmos dados do backup.

Backups disponíveis em: `https://drive.interlegis.leg.br/backups-portais/<cidade>-mt.backup.tar.gz`

## Uso

```bash
./restaurar-portal-modelo.sh <URL_DO_BACKUP> [opções]
```

Exemplo:

```bash
./restaurar-portal-modelo.sh https://drive.interlegis.leg.br/backups-portais/novaguarita-mt.backup.tar.gz
```

### Opções

| Opção | Descrição | Padrão |
|---|---|---|
| `--porta <N>` | Porta pública do portal | `8080` |
| `--imagem <imagem>` | Imagem do Portal Modelo | `interlegis/portalmodelo:3.0-21` |
| `--cidade <nome>` | Nome da pasta (derivada do nome do arquivo) | — |
| `--dir <caminho>` | Pasta raiz do projeto | `./<cidade>` |
| `--backup-local <arq>` | Não baixa; usa um `.tar.gz` já baixado | — |
| `--forcar` | Reexecuta mesmo se `./data` já tiver um `Data.fs` | — |

## O que o script faz

1. Cria a pasta com o nome da cidade (ex.: `novaguarita-mt.backup.tar.gz` → `novaguarita`)
2. Baixa o backup para dentro da pasta (com retomada e conferência de tamanho)
3. Gera o `docker-compose.yml` (serviços `zeoserver` + `plone` da imagem atual;
   **sem** `plonecfg`, pois o backup já contém o site criado)
4. Extrai o backup em `./data` (filestorage + blobstorage) e ajusta o dono
   para o uid 500 (`plone`), como o container espera
5. Sobe o stack e aguarda o portal responder, detectando o id do site

## Estrutura do backup

O tar.gz contém, na raiz:

- `filestorage/Data.fs` — banco ZODB do site
- `blobstorage/` — anexos (layout `bushy`, com `.layout`)

## Observações

- A senha do usuário `admin` do portal restaurado é a **mesma do portal
  original** (não é `adminpw`). Para redefini-la, use o ZMI
  (`http://localhost:<porta>/portal/manage_main` → `acl_users` → `admin`).
- Se o portal original for de versão antiga, rode os upgrades do Portal
  Modelo após a restauração (ver `run-portal-upgrades` no container).
- Para derrubar: `docker compose down` dentro da pasta do projeto (os dados
  ficam em `./data` no host).

## Requisitos

- Docker com `docker compose` v2
- `curl` e `tar`