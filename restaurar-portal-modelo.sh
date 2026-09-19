#!/usr/bin/env bash
# =============================================================================
# restaurar-portal-modelo.sh
# -----------------------------------------------------------------------------
# Restaura um backup do Portal Modelo (Interlegis) em Docker, subindo a versão
# atual da imagem oficial (interlegis/portalmodelo) e devolvendo o portal
# funcional, com os mesmos dados do backup.
#
# Fluxo:
#   1. Define a pasta da cidade (a partir do nome do arquivo, ex.: o link
#      .../novaguarita-mt.backup.tar.gz  ->  pasta "novaguarita")
#   2. Baixa o backup para dentro dessa pasta (com retomada de download)
#   3. Gera o docker-compose.yml (zeoserver + plone da imagem atual)
#   4. Extrai o backup em ./data (filestorage + blobstorage) e ajusta o dono
#      para o uid 500 (plone), como o container espera
#   5. Sobe o stack e aguarda o portal responder
#
# Uso:
#   ./restaurar-portal-modelo.sh <URL_DO_BACKUP> [opções]
#
# Opções:
#   --porta <N>          Porta pública do portal (padrão: 8080)
#   --imagem <imagem>    Imagem do Portal Modelo (padrão: interlegis/portalmodelo:3.0-21)
#   --cidade <nome>      Nome da pasta (padrão: derivado do nome do arquivo)
#   --dir <caminho>      Pasta raiz do projeto (padrão: ./<cidade>)
#   --backup-local <arq> Não baixa: usa um arquivo .tar.gz já baixado
#   --forcar             Reexecuta mesmo se ./data já tiver um Data.fs
#
# Exemplos:
#   ./restaurar-portal-modelo.sh https://drive.interlegis.leg.br/backups-portais/novaguarita-mt.backup.tar.gz
#   ./restaurar-portal-modelo.sh <url> --porta 9081 --backup-local ~/novaguarita-mt.backup.tar.gz
# =============================================================================

set -euo pipefail

BACKUP_URL="${1:-}"
PORTA="${PORTA:-8080}"
IMAGEM="interlegis/portalmodelo:3.0-21"
CIDADE=""
DIR=""
BACKUP_LOCAL=""
FORCAR=0

# ----------------------------------------------------------------------------
# Parsing de argumentos
# ----------------------------------------------------------------------------
for arg in "$@"; do
  [[ "$arg" == "--forcar" ]] && FORCAR=1
done
while [[ $# -gt 0 ]]; do
  case "$1" in
    --porta)        PORTA="$2";        shift 2 ;;
    --imagem)       IMAGEM="$2";       shift 2 ;;
    --cidade)       CIDADE="$2";       shift 2 ;;
    --dir)          DIR="$2";          shift 2 ;;
    --backup-local) BACKUP_LOCAL="$2"; shift 2 ;;
    --forcar)       shift ;;
    -h|--help)      grep '^#' "$0" | sed 's/^# \{0,1\}//' | sed -n '10,36p'; exit 0 ;;
    *)              shift ;;
  esac
done

# ----------------------------------------------------------------------------
# Pré-requisitos
# ----------------------------------------------------------------------------
for cmd in curl docker tar; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERRO: '$cmd' não encontrado."; exit 1; }
done
docker compose version >/dev/null 2>&1 || { echo "ERRO: docker compose v2 não disponível."; exit 1; }

# ----------------------------------------------------------------------------
# Deriva o nome da cidade a partir da URL/nome do arquivo
#   novaguarita-mt.backup.tar.gz  ->  novaguarita
#   caceres.mt.backup.tar.gz      ->  caceres
# ----------------------------------------------------------------------------
if [[ -z "$CIDADE" ]]; then
  NOME_ARQ="$(basename "${BACKUP_LOCAL:-$BACKUP_URL}")" || true
  [[ "$NOME_ARQ" == *".backup.tar.gz" ]] && NOME_ARQ="${NOME_ARQ%.backup.tar.gz}"
  [[ "$NOME_ARQ" == *".tar.gz" ]]      && NOME_ARQ="${NOME_ARQ%.tar.gz}"
  # remove sufixo de estado tipo "-mt", ".mt", "_mt"
  NOME_ARQ="$(echo "$NOME_ARQ" | sed -E 's/[-_.](ac|al|am|ap|ba|ce|df|es|go|ma|mg|ms|mt|pa|pb|pe|pi|pr|rj|rn|ro|rr|rs|sc|se|sp|to)$//I')"
  CIDADE="$(echo "$NOME_ARQ" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed -E 's/^-+|-+$//g')"
fi
[[ -z "$CIDADE" ]] && { echo "ERRO: não consegui derivar o nome da cidade. Use --cidade <nome>."; exit 1; }

DIR="${DIR:-$CIDADE}"
BACKUP_DIR="$DIR"
BACKUP_ARQ="$BACKUP_DIR/$(basename "${BACKUP_LOCAL:-$BACKUP_URL}")"
SITE="/portal"   # id de site padrão criado pela imagem; será conferido no final

echo "==> Cidade          : $CIDADE"
echo "==> Pasta           : $DIR"
echo "==> Porta pública   : $PORTA"
echo "==> Imagem          : $IMAGEM"
echo "==> Backup          : $BACKUP_ARQ"
echo

mkdir -p "$DIR"

# ----------------------------------------------------------------------------
# 1. Download do backup (pula se já estiver completo; retoma se parcial)
# ----------------------------------------------------------------------------
if [[ -n "$BACKUP_LOCAL" ]]; then
  echo "==> [1/5] Usando backup local: $BACKUP_LOCAL"
  if [[ ! -f "$BACKUP_ARQ" ]]; then
    cp "$BACKUP_LOCAL" "$BACKUP_ARQ"
  else
    echo "      Backup local já copiado."
  fi
else
  echo "==> [1/5] Baixando backup (com retomada se interrompido)..."
  TAM_ESPERADO=$(curl -sIL --max-time 60 "$BACKUP_URL" | awk 'tolower($1)=="content-length:"{n=$2} END{print n+0}')
  if [[ -f "$BACKUP_ARQ" ]] && [[ "$TAM_ESPERADO" -gt 0 ]] && \
     [[ "$(stat -c%s "$BACKUP_ARQ")" -eq "$TAM_ESPERADO" ]]; then
    echo "      Backup já está completo localmente, pulando download."
  else
    curl -L --fail --retry 3 -C - -o "$BACKUP_ARQ" "$BACKUP_URL"
  fi
fi

if [[ ! -f "$BACKUP_ARQ" ]]; then
  echo "ERRO: arquivo de backup não encontrado em $BACKUP_ARQ"; exit 1
fi

# conferência do tamanho (só quando a HEAD funcionou)
if [[ -z "$BACKUP_LOCAL" ]] && [[ "$TAM_ESPERADO" -gt 0 ]]; then
  REAL="$(stat -c%s "$BACKUP_ARQ")"
  if [[ "$REAL" -ne "$TAM_ESPERADO" ]]; then
    echo "ERRO: download incompleto ($REAL de $TAM_ESPERADO bytes). Reexecute para retomar."
    exit 1
  fi
  echo "      Download OK ($REAL bytes)."
fi

# ----------------------------------------------------------------------------
# 2. docker-compose.yml (zeoserver + plone da imagem atual; sem plonecfg,
#    pois o backup já contém o site — criação de site novo não é desejada)
# ----------------------------------------------------------------------------
echo "==> [2/5] Gerando docker-compose.yml..."
if [[ -f "$DIR/docker-compose.yml" ]]; then
  echo "      docker-compose.yml já existe; mantendo. (Apague-o p/ regenerar.)"
else
  cat > "$DIR/docker-compose.yml" <<EOF
# Portal Modelo (Interlegis) — restauração do backup de $CIDADE
# Site: http://localhost:$PORTA$SITE/
# Imagem atual do Portal Modelo, configurada via env vars (ZEO client).
#
# Comandos úteis:
#   docker compose logs -f plone    # acompanhar o boot
#   docker compose down             # derrubar (dados ficam em ./data)
services:
  zeoserver:
    image: $IMAGEM
    container_name: pm-${CIDADE}-zeoserver
    restart: unless-stopped
    command: zeoserver
    environment:
      ZEO_SHARED_BLOB_DIR: "on"
    volumes:
      - ./data:/data

  plone:
    image: $IMAGEM
    container_name: pm-${CIDADE}-plone
    restart: unless-stopped
    environment:
      ZEO_ADDRESS: zeoserver:8100
      ZEO_SHARED_BLOB_DIR: "on"
    ports:
      - "${PORTA}:8080"
    volumes:
      - ./data:/data
    healthcheck:
      # saudável quando o Zope responde (raiz "/"), independente do id do site
      test: ["CMD", "python", "-c", "import urllib2;urllib2.urlopen('http://localhost:8080/',timeout=10)"]
      interval: 10s
      timeout: 10s
      retries: 40
      start_period: 60s
EOF
  echo "      $DIR/docker-compose.yml criado."
fi

# ----------------------------------------------------------------------------
# 3. Extração do backup em ./data
# ----------------------------------------------------------------------------
echo "==> [3/5] Preparando ./data e extraindo o backup..."
mkdir -p "$DIR/data"/{filestorage,blobstorage,zeoserver,log,instance}

if [[ -s "$DIR/data/filestorage/Data.fs" ]] && [[ "$FORCAR" -eq 0 ]]; then
  echo "      ./data/filestorage/Data.fs já existe; pulando extração."
  echo "      (Use --forcar para extrair por cima — cuidado!)"
else
  tar -xzf "$BACKUP_ARQ" -C "$DIR/data" --no-same-owner
  # Defesa: se o tar tiver o conteúdo dentro de uma subpasta, sobe o conteúdo
  if [[ ! -f "$DIR/data/filestorage/Data.fs" ]]; then
    FOUND="$(find "$DIR/data" -name Data.fs -path '*/filestorage/*' | head -1)"
    if [[ -z "$FOUND" ]]; then
      echo "ERRO: backup não contém filestorage/Data.fs. Estrutura do arquivo:"
      tar -tzf "$BACKUP_ARQ" | head -20
      exit 1
    fi
    CARA="$(dirname "$(dirname "$FOUND")")"
    echo "      Backup está dentro de '$CARA'; ajustando layout..."
    mv "$CARA"/filestorage "$CARA"/blobstorage "$DIR/data/" 2>/dev/null || true
  fi
fi

# dono 500:500 (plone) em TODO o data dir — obrigatório para o ZODB
docker run --rm -v "$PWD/$DIR/data:/data" alpine:3 chown -R 500:500 /data

if [[ ! -d "$DIR/data/blobstorage" ]] || [[ -z "$(ls -A "$DIR/data/blobstorage" 2>/dev/null)" ]]; then
  echo "      ATENÇÃO: backup sem blobstorage (anexos). O portal sobe, mas as"
  echo "      imagens/documentos armazenados como blobs podem faltar."
fi

# ----------------------------------------------------------------------------
# 4. Subir o stack e aguardar o portal
# ----------------------------------------------------------------------------
echo "==> [4/5] Subindo containers (1º boot de um Data.fs grande pode demorar)..."
(
  cd "$DIR" && docker compose up -d
)
echo "      Aguardando o portal responder em http://localhost:$PORTA/ ..."
OK=0
for i in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://localhost:$PORTA/" 2>/dev/null || true)
  if [[ "$code" == "200" || "$code" == "302" ]]; then
    echo "      Portal respondendo (HTTP $code) após ~$((i * 10))s."
    OK=1
    break
  fi
  sleep 10
done
if [[ "$OK" -eq 0 ]]; then
  echo "ERRO: o portal não respondeu em 10 min. Veja os logs:"
  ( cd "$DIR" && docker compose logs --tail 50 plone )
  exit 1
fi

# ----------------------------------------------------------------------------
# 5. Detecção do id do site (o backup pode ter site "portal" ou outro)
# ----------------------------------------------------------------------------
echo "==> [5/5] Detectando o id do site..."
SITE_DETECTADO=""
for cand in "portal" "$CIDADE" "${CIDADE}mt" "novo"; do
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://localhost:$PORTA/$cand/" 2>/dev/null || true)
  if [[ "$code" == "200" ]]; then SITE_DETECTADO="$cand"; break; fi
done

if [[ -n "$SITE_DETECTADO" ]]; then
  echo "      Site encontrado: /$SITE_DETECTADO/"
  URL_FINAL="http://localhost:$PORTA/$SITE_DETECTADO/"
else
  URL_FINAL="http://localhost:$PORTA/"
  echo "      Não encontrei um id padrão; confira a lista de sites na página inicial."
fi

echo
echo "======================================================================"
echo " PORTAL RESTAURADO!"
echo "   Pasta      : $PWD/$DIR"
echo "   Site       : $URL_FINAL"
echo "   Containers : pm-${CIDADE}-zeoserver / pm-${CIDADE}-plone"
echo "   Backup     : $BACKUP_ARQ"
echo
echo " Observações:"
echo "  - A senha do usuário 'admin' é a MESMA do portal original do backup"
echo "    (não é 'adminpw'). Para redefini-la, abra o ZMI:"
echo "      ${URL_FINAL}manage_main  ->  acl_users -> admin"
echo "  - Se o portal original for de versão antiga, rode os upgrades do"
echo "    Portal Modelo após a restauração (ver 'run-portal-upgrades')."
echo "  - Para derrubar: (cd $PWD/$DIR && docker compose down)"
echo "======================================================================"