#!/bin/bash
# ============================================================
# Minecraft Modpack Server - Script de Instalação
# Ubuntu/Debian | CurseForge | playit.gg (acesso remoto)
# ============================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

CF_API="https://api.curseforge.com/v1"
MINECRAFT_GAME_ID=432
MODPACK_CLASS_ID=4471
CONFIG_FILE="$HOME/.mc_server_config"
SERVER_BASE="$HOME/minecraft-servers"

SELECTED_MOD_ID=""
SELECTED_MOD_NAME=""
SELECTED_FILE_ID=""
SELECTED_FILE_NAME=""
SELECTED_MC_VERSION=""
SERVER_PACK_FILE_ID=""
HAS_SERVER_PACK=false
CF_API_KEY=""
SERVER_DIR=""

p_banner() {
  echo -e "${CYAN}${BOLD}"
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║     Minecraft Modpack Server  (v1.0)         ║"
  echo "  ║  CurseForge + playit.gg  |  Ubuntu/Debian    ║"
  echo "  ╚══════════════════════════════════════════════╝"
  echo -e "${NC}"
}

p_step()    { echo -e "\n${BLUE}${BOLD}==> $1${NC}"; }
p_ok()      { echo -e "${GREEN}✓ $1${NC}"; }
p_warn()    { echo -e "${YELLOW}⚠  $1${NC}"; }
p_error()   { echo -e "${RED}✗ $1${NC}"; }
p_info()    { echo -e "   $1"; }

ask() {
  local prompt="$1" default="${2:-}" var_name="$3"
  local result
  if [ -n "$default" ]; then
    read -rp "$(echo -e "${CYAN}?${NC} $prompt [$default]: ")" result
    result="${result:-$default}"
  else
    read -rp "$(echo -e "${CYAN}?${NC} $prompt: ")" result
  fi
  printf -v "$var_name" '%s' "$result"
}

# ─── Dependências ────────────────────────────────────────────────────────────

check_deps() {
  p_step "Verificando dependências..."
  local missing=()
  for cmd in curl jq unzip bc; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    p_warn "Instalando: ${missing[*]}"
    sudo apt-get update -qq
    sudo apt-get install -y "${missing[@]}" -qq
  fi
  p_ok "Dependências OK"
}

install_java() {
  local mc_minor="$1"
  local java_pkg

  if   [ "$mc_minor" -ge 21 ]; then java_pkg="openjdk-21-jre-headless"
  elif [ "$mc_minor" -ge 17 ]; then java_pkg="openjdk-17-jre-headless"
  elif [ "$mc_minor" -ge 16 ]; then java_pkg="openjdk-11-jre-headless"
  else                               java_pkg="openjdk-11-jre-headless"
  fi

  if java -version &>/dev/null 2>&1; then
    local cur=$(java -version 2>&1 | grep -oP '(?<=version ")(1\.)?\K\d+' | head -1)
    local need=$(echo "$java_pkg" | grep -oP '\d+')
    if [ "${cur:-0}" -ge "$need" ]; then
      p_ok "Java $cur já instalado (necessário: $need+)"
      return 0
    fi
  fi

  p_step "Instalando $java_pkg..."
  sudo apt-get install -y "$java_pkg" -qq
  p_ok "$java_pkg instalado"
}

# ─── API Key ─────────────────────────────────────────────────────────────────

load_config() {
  [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
}

setup_api_key() {
  load_config
  if [ -n "${CF_API_KEY:-}" ]; then
    local test
    test=$(curl -sf -H "x-api-key: $CF_API_KEY" "$CF_API/games/432" | jq -r '.data.name' 2>/dev/null || true)
    if [ "$test" = "Minecraft" ]; then
      p_ok "API key do CurseForge carregada"
      return 0
    else
      p_warn "API key salva inválida — vamos reconfigurar"
    fi
  fi

  p_step "Configurando API Key do CurseForge"
  echo ""
  echo "  Você precisa de uma chave gratuita da API do CurseForge."
  echo ""
  echo -e "  1. Acesse: ${CYAN}https://console.curseforge.com/#/api-keys${NC}"
  echo "  2. Faça login (pode usar conta Google/Twitch)"
  echo "  3. Crie uma API key gratuita e copie"
  echo ""

  local key=""
  while true; do
    ask "Cole sua API key do CurseForge" "" key
    if [ -z "$key" ]; then
      p_error "API key não pode ser vazia"; continue
    fi
    local test
    test=$(curl -sf -H "x-api-key: $key" "$CF_API/games/432" | jq -r '.data.name' 2>/dev/null || true)
    if [ "$test" = "Minecraft" ]; then
      break
    else
      p_error "API key inválida ou sem conexão. Tente novamente."
    fi
  done

  CF_API_KEY="$key"
  echo "CF_API_KEY=\"$key\"" > "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
  p_ok "API key salva em $CONFIG_FILE"
}

cf() {
  curl -sf -H "x-api-key: $CF_API_KEY" "$CF_API$1"
}

# ─── Busca de modpack ─────────────────────────────────────────────────────────

search_modpacks() {
  while true; do
    p_step "Buscar Modpack"
    echo ""
    local term=""
    ask "Nome do modpack (Enter = populares)" "" term

    local enc_term=""
    [ -n "$term" ] && enc_term=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$term" 2>/dev/null || echo "$term" | sed 's/ /+/g')

    local url="/mods/search?gameId=${MINECRAFT_GAME_ID}&classId=${MODPACK_CLASS_ID}&pageSize=12&sortField=5&sortOrder=desc"
    [ -n "$enc_term" ] && url+="&searchFilter=${enc_term}"

    local result
    result=$(cf "$url")

    local count
    count=$(echo "$result" | jq '.data | length')

    if [ "$count" -eq 0 ]; then
      p_warn "Nenhum modpack encontrado. Tente outro nome."
      continue
    fi

    echo ""
    echo -e "  ${BOLD}#   Nome                                  Downloads  ID${NC}"
    echo    "  ─────────────────────────────────────────────────────────────"

    for i in $(seq 0 $((count - 1))); do
      local name dl id
      name=$(echo "$result" | jq -r ".data[$i].name" | cut -c1-38)
      dl=$(echo "$result" | jq -r ".data[$i].downloadCount")
      id=$(echo "$result" | jq -r ".data[$i].id")
      printf "  ${CYAN}%-3s${NC} %-38s  %-9s  %s\n" "$((i+1))" "$name" "$dl" "$id"
    done

    echo ""
    local choice=""
    ask "Escolha um modpack (1-$count) ou 'b' para nova busca" "" choice

    if [ "$choice" = "b" ] || [ "$choice" = "B" ]; then continue; fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$count" ]; then
      p_error "Opção inválida"; continue
    fi

    local idx=$((choice - 1))
    SELECTED_MOD_ID=$(echo "$result" | jq -r ".data[$idx].id")
    SELECTED_MOD_NAME=$(echo "$result" | jq -r ".data[$idx].name")

    echo ""
    echo -e "  Resumo: $(echo "$result" | jq -r ".data[$idx].summary")"
    echo ""
    local confirm=""
    ask "Continuar com '$SELECTED_MOD_NAME'? (s/n)" "s" confirm
    [ "$confirm" = "s" ] || [ "$confirm" = "S" ] && break
  done

  p_ok "Selecionado: $SELECTED_MOD_NAME (ID: $SELECTED_MOD_ID)"
}

# ─── Seleção de versão ────────────────────────────────────────────────────────

select_version() {
  p_step "Versões disponíveis para '$SELECTED_MOD_NAME'"

  local files
  files=$(cf "/mods/$SELECTED_MOD_ID/files?pageSize=50&sortOrder=desc")

  # Prefer files that have a server pack
  local server_files
  server_files=$(echo "$files" | jq '[.data[] | select(.serverPackFileId != null and .serverPackFileId != 0)]')
  local sf_count
  sf_count=$(echo "$server_files" | jq 'length')

  local display_files
  local with_pack=true
  if [ "$sf_count" -gt 0 ]; then
    display_files="$server_files"
    echo -e "  ${GREEN}✓ Server packs disponíveis ($sf_count versões)${NC}"
  else
    p_warn "Sem server pack oficial — mostrando todas as versões (pode precisar de ajuste manual)"
    display_files=$(echo "$files" | jq '.data')
    sf_count=$(echo "$display_files" | jq 'length')
    with_pack=false
  fi

  echo ""
  echo -e "  ${BOLD}#   Arquivo                                  MC Versões         Data${NC}"
  echo    "  ──────────────────────────────────────────────────────────────────────"

  for i in $(seq 0 $((sf_count - 1))); do
    local fname mc_vers date
    fname=$(echo "$display_files" | jq -r ".[$i].fileName" | cut -c1-40)
    mc_vers=$(echo "$display_files" | jq -r '.[$i].gameVersions | join(", ")' | cut -c1-18)
    date=$(echo "$display_files" | jq -r ".[$i].fileDate" | cut -c1-10)
    printf "  ${CYAN}%-3s${NC} %-40s  %-18s  %s\n" "$((i+1))" "$fname" "$mc_vers" "$date"
  done

  echo ""
  local choice=""
  ask "Escolha a versão (1-$sf_count)" "1" choice

  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$sf_count" ]; then
    p_error "Opção inválida"; select_version; return
  fi

  local idx=$((choice - 1))
  SELECTED_FILE_ID=$(echo "$display_files" | jq -r ".[$idx].id")
  SELECTED_FILE_NAME=$(echo "$display_files" | jq -r ".[$idx].fileName")
  SELECTED_MC_VERSION=$(echo "$display_files" | jq -r '.[$idx].gameVersions[0]')
  HAS_SERVER_PACK="$with_pack"

  if [ "$with_pack" = true ]; then
    SERVER_PACK_FILE_ID=$(echo "$display_files" | jq -r ".[$idx].serverPackFileId")
    p_ok "Versão: $SELECTED_FILE_NAME | MC: $SELECTED_MC_VERSION | Server pack ID: $SERVER_PACK_FILE_ID"
  else
    p_ok "Versão: $SELECTED_FILE_NAME | MC: $SELECTED_MC_VERSION"
  fi
}

# ─── Download ────────────────────────────────────────────────────────────────

download_server_pack() {
  local mod_slug
  mod_slug=$(echo "$SELECTED_MOD_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -dc 'a-z0-9-')
  SERVER_DIR="$SERVER_BASE/$mod_slug"
  mkdir -p "$SERVER_DIR"

  p_step "Baixando server pack para $SERVER_DIR..."

  local file_id
  if [ "$HAS_SERVER_PACK" = true ] && [ -n "$SERVER_PACK_FILE_ID" ] && [ "$SERVER_PACK_FILE_ID" != "null" ]; then
    file_id="$SERVER_PACK_FILE_ID"
    p_info "Usando server pack dedicado (ID: $file_id)"
  else
    file_id="$SELECTED_FILE_ID"
    p_info "Usando arquivo principal do modpack (ID: $file_id)"
  fi

  local url_resp
  url_resp=$(cf "/mods/$SELECTED_MOD_ID/files/$file_id/download-url")
  local download_url
  download_url=$(echo "$url_resp" | jq -r '.data // empty')

  if [ -z "$download_url" ] || [ "$download_url" = "null" ]; then
    p_error "A API não forneceu URL de download direto para este arquivo."
    echo ""
    echo "  Opções:"
    echo "  1. Baixe o server pack manualmente em: https://www.curseforge.com/minecraft/search?page=1&pageSize=20&sortBy=relevancy&class=modpacks"
    echo "  2. Coloque o ZIP em $SERVER_DIR e reinicie o script com a opção de instalação manual"
    echo ""
    local manual_zip=""
    ask "Caminho completo para o ZIP baixado manualmente (ou Enter para sair)" "" manual_zip
    if [ -z "$manual_zip" ]; then exit 1; fi
    cp "$manual_zip" "$SERVER_DIR/"
    download_url=""
    DOWNLOADED_FILE="$SERVER_DIR/$(basename "$manual_zip")"
    return
  fi

  local filename
  filename=$(basename "$download_url" | cut -d'?' -f1)
  [ -z "$filename" ] && filename="server-pack.zip"
  DOWNLOADED_FILE="$SERVER_DIR/$filename"

  if [ -f "$DOWNLOADED_FILE" ]; then
    p_warn "Arquivo já existe: $filename"
    local redownload=""
    ask "Baixar novamente?" "n" redownload
    if [ "$redownload" != "s" ] && [ "$redownload" != "S" ]; then
      p_ok "Usando arquivo existente"
      return
    fi
  fi

  curl -L --progress-bar -o "$DOWNLOADED_FILE" "$download_url"
  p_ok "Download concluído: $filename"
}

# ─── Instalação ──────────────────────────────────────────────────────────────

install_server() {
  p_step "Instalando servidor em $SERVER_DIR..."

  cd "$SERVER_DIR"

  local ext="${DOWNLOADED_FILE##*.}"
  if [ "$ext" = "zip" ]; then
    p_info "Extraindo ZIP..."
    unzip -oq "$DOWNLOADED_FILE" -d "$SERVER_DIR"
    p_ok "Extração concluída"
  fi

  # Detect and run installer
  local forge_installer neoforge_installer fabric_installer

  forge_installer=$(find "$SERVER_DIR" -maxdepth 3 -name "forge-*installer*.jar" 2>/dev/null | head -1 || true)
  neoforge_installer=$(find "$SERVER_DIR" -maxdepth 3 -name "neoforge-*installer*.jar" 2>/dev/null | head -1 || true)
  fabric_installer=$(find "$SERVER_DIR" -maxdepth 3 -name "fabric-installer*.jar" 2>/dev/null | head -1 || true)

  if [ -n "$forge_installer" ]; then
    p_step "Instalando Forge..."
    java -jar "$forge_installer" --installServer 2>&1 | tail -5
    p_ok "Forge instalado"
  elif [ -n "$neoforge_installer" ]; then
    p_step "Instalando NeoForge..."
    java -jar "$neoforge_installer" --installServer 2>&1 | tail -5
    p_ok "NeoForge instalado"
  elif [ -n "$fabric_installer" ]; then
    p_step "Instalando Fabric..."
    java -jar "$fabric_installer" server -downloadMinecraft -dir "$SERVER_DIR" 2>&1 | tail -5
    p_ok "Fabric instalado"
  elif [ -f "$SERVER_DIR/install.sh" ]; then
    p_step "Executando install.sh do modpack..."
    chmod +x "$SERVER_DIR/install.sh"
    bash "$SERVER_DIR/install.sh" 2>&1 | tail -5
  else
    p_warn "Instalador automático não encontrado."
    p_info "Se o servidor não funcionar de primeira, verifique:"
    p_info "  - Se há um install.sh ou installer.jar na pasta $SERVER_DIR"
    p_info "  - A documentação do modpack no CurseForge"
  fi
}

# ─── Configuração ─────────────────────────────────────────────────────────────

configure_server() {
  p_step "Configurando servidor..."

  cd "$SERVER_DIR"

  # Aceitar EULA
  echo "eula=true" > eula.txt
  p_ok "EULA aceita automaticamente"

  # Calcular memória
  local total_mb
  total_mb=$(free -m | awk '/^Mem:/{print $2}')
  local alloc_mb=$(echo "scale=0; $total_mb * 75 / 100" | bc)
  [ "$alloc_mb" -gt 12288 ] && alloc_mb=12288
  local alloc_gb=$(echo "scale=0; $alloc_mb / 1024" | bc)
  [ "$alloc_gb" -lt 1 ] && alloc_gb=2

  p_ok "RAM disponível: ${total_mb}MB → alocando ${alloc_gb}GB para o servidor"

  echo ""
  echo -e "${BOLD}  Configurações básicas:${NC}"

  local max_players gamemode difficulty offline_mode whitelist_mode
  ask "Máximo de jogadores" "20" max_players
  ask "Modo de jogo (survival/creative/adventure)" "survival" gamemode
  ask "Dificuldade (peaceful/easy/normal/hard)" "normal" difficulty

  echo ""
  echo -e "  ${YELLOW}${BOLD}Minecraft original (conta paga)?${NC}"
  echo "  Responda 'n' se você e seus amigos usam conta gratuita/cracked."
  ask "Todos têm Minecraft original? (s/n)" "n" offline_mode

  local online_mode_val="true"
  if [ "$offline_mode" != "s" ] && [ "$offline_mode" != "S" ]; then
    online_mode_val="false"
    echo ""
    p_warn "Modo offline ativado (online-mode=false)"
    echo ""
    echo -e "  ${YELLOW}Atenção:${NC} sem autenticação, qualquer pessoa com o endereço pode entrar."
    echo "  Recomendado ativar whitelist para restringir apenas aos seus amigos."
    ask "Ativar whitelist? (s/n)" "s" whitelist_mode
  fi

  # server.properties
  if [ ! -f server.properties ]; then
    cat > server.properties << EOF
server-port=25565
online-mode=true
white-list=false
spawn-protection=16
view-distance=10
simulation-distance=8
max-tick-time=60000
EOF
  fi

  # Update values
  for kv in "max-players=$max_players" "gamemode=$gamemode" "difficulty=$difficulty" "online-mode=$online_mode_val"; do
    local k="${kv%%=*}" v="${kv#*=}"
    if grep -q "^${k}=" server.properties; then
      sed -i "s/^${k}=.*/${k}=${v}/" server.properties
    else
      echo "${k}=${v}" >> server.properties
    fi
  done

  # Whitelist
  if [ "${whitelist_mode:-n}" = "s" ] || [ "${whitelist_mode:-n}" = "S" ]; then
    sed -i "s/^white-list=.*/white-list=true/" server.properties 2>/dev/null || echo "white-list=true" >> server.properties
    p_ok "Whitelist ativada"

    echo ""
    echo -e "  ${BOLD}Adicionar jogadores à whitelist:${NC}"
    echo "  Digite um nome por linha. Enter em branco para terminar."

    local whitelist_entries="[]"
    while true; do
      local pname=""
      ask "  Nome do jogador (Enter para terminar)" "" pname
      [ -z "$pname" ] && break
      whitelist_entries=$(echo "$whitelist_entries" | jq --arg n "$pname" '. + [{"uuid":"00000000-0000-0000-0000-000000000000","name":$n}]')
      p_ok "  $pname adicionado"
    done

    echo "$whitelist_entries" | jq '.' > whitelist.json
    p_ok "whitelist.json criado ($(echo "$whitelist_entries" | jq 'length') jogadores)"
    echo ""
    p_info "Para adicionar mais jogadores depois, use o console do servidor:"
    p_info "  /whitelist add NomeDoJogador"
    p_info "  /whitelist reload"
  fi

  # JVM flags (Aikar's flags)
  local jvm_flags="-XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 \
-XX:+UnlockExperimentalVMOptions -XX:+DisableExplicitGC -XX:+AlwaysPreTouch \
-XX:G1NewSizePercent=30 -XX:G1MaxNewSizePercent=40 -XX:G1HeapRegionSize=8M \
-XX:G1ReservePercent=20 -XX:G1HeapWastePercent=5 -XX:G1MixedGCCountTarget=4 \
-XX:InitiatingHeapOccupancyPercent=15 -XX:G1MixedGCLiveThresholdPercent=90 \
-XX:G1RSetUpdatingPauseTimePercent=5 -XX:SurvivorRatio=32 \
-XX:+PerfDisableSharedMem -XX:MaxTenuringThreshold=1 -Dusing.aikars.flags=https://mcflags.emc.gs"

  # Find server jar / run script
  local server_jar=""
  local run_script=""

  if [ -f "run.sh" ]; then
    run_script="run.sh"
  elif [ -f "start.bat" ] && ls run*.sh 1>/dev/null 2>&1; then
    run_script=$(ls run*.sh | head -1)
  fi

  if [ -z "$run_script" ]; then
    # Find jar (exclude installer jars)
    server_jar=$(find "$SERVER_DIR" -maxdepth 2 -name "forge-*universal*.jar" 2>/dev/null | head -1 || true)
    [ -z "$server_jar" ] && server_jar=$(find "$SERVER_DIR" -maxdepth 2 -name "neoforge-*shim*.jar" 2>/dev/null | head -1 || true)
    [ -z "$server_jar" ] && server_jar=$(find "$SERVER_DIR" -maxdepth 1 -name "fabric-server-launch.jar" 2>/dev/null | head -1 || true)
    [ -z "$server_jar" ] && server_jar=$(find "$SERVER_DIR" -maxdepth 1 -name "*.jar" ! -name "*installer*" 2>/dev/null | head -1 || true)
  fi

  # Create start.sh
  cat > start.sh << SCRIPT
#!/bin/bash
# Gerado por mc-server-setup.sh
cd "\$(dirname "\$0")"

SCRIPT

  if [ -n "$run_script" ]; then
    # Patch run.sh to inject memory
    if grep -q '\$JAVA_OPTS\|-Xmx\|-Xms' "$run_script" 2>/dev/null; then
      # Already has memory flags, just wrap it
      cat >> start.sh << SCRIPT
export JAVA_TOOL_OPTIONS="-Xms${alloc_gb}G -Xmx${alloc_gb}G $jvm_flags"
bash "$run_script" nogui
SCRIPT
    else
      cat >> start.sh << SCRIPT
bash "$run_script" nogui
SCRIPT
    fi
  elif [ -n "$server_jar" ]; then
    local jar_rel="${server_jar#$SERVER_DIR/}"
    cat >> start.sh << SCRIPT
exec java -Xms${alloc_gb}G -Xmx${alloc_gb}G $jvm_flags \\
  -jar "$jar_rel" nogui
SCRIPT
  else
    cat >> start.sh << SCRIPT
echo "ATENÇÃO: Não foi possível detectar o jar do servidor automaticamente."
echo "Edite este arquivo e adicione o comando correto para iniciar o servidor."
echo "Pasta do servidor: $SERVER_DIR"
SCRIPT
    p_warn "start.sh criado mas requer edição manual — jar do servidor não detectado"
  fi

  chmod +x start.sh

  # stop.sh via RCON (or graceful kill)
  cat > stop.sh << 'SCRIPT'
#!/bin/bash
PID=$(pgrep -f "minecraft\|forge\|fabric\|neoforge" | head -1)
if [ -n "$PID" ]; then
  echo "Parando servidor (PID: $PID)..."
  kill -SIGTERM "$PID"
  timeout 30 tail --pid="$PID" -f /dev/null 2>/dev/null || true
  echo "Servidor parado."
else
  echo "Servidor não está rodando."
fi
SCRIPT
  chmod +x stop.sh

  p_ok "Scripts start.sh e stop.sh criados"
}

# ─── playit.gg ────────────────────────────────────────────────────────────────

setup_playit() {
  p_step "Configurando acesso remoto com playit.gg..."

  echo ""
  echo -e "  ${BOLD}playit.gg${NC} cria um endereço público para o servidor sem precisar"
  echo    "  configurar roteador ou ter IP fixo. É gratuito para uso básico."
  echo ""

  if command -v playit &>/dev/null; then
    p_ok "playit.gg já está instalado"
  else
    local arch
    arch=$(uname -m)
    local bin_url=""

    case "$arch" in
      x86_64)  bin_url="https://github.com/playit-cloud/playit-agent/releases/latest/download/playit-linux_amd64" ;;
      aarch64) bin_url="https://github.com/playit-cloud/playit-agent/releases/latest/download/playit-linux_arm64" ;;
      armv7l)  bin_url="https://github.com/playit-cloud/playit-agent/releases/latest/download/playit-linux_arm32" ;;
      *)
        p_warn "Arquitetura $arch não suportada automaticamente."
        echo "  Baixe manualmente em: https://playit.gg/download"
        return 1
        ;;
    esac

    p_info "Baixando playit.gg ($arch)..."
    local dest="$HOME/.local/bin/playit"
    mkdir -p "$HOME/.local/bin"
    curl -L --progress-bar -o "$dest" "$bin_url"
    chmod +x "$dest"

    # Add to PATH if needed
    if ! command -v playit &>/dev/null; then
      echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
      export PATH="$HOME/.local/bin:$PATH"
    fi

    p_ok "playit.gg instalado em $dest"
  fi

  # Create start-with-tunnel.sh
  cat > "$SERVER_DIR/start-with-tunnel.sh" << 'TUNNEL'
#!/bin/bash
cd "$(dirname "$0")"

cleanup() {
  echo "Parando tunnel e servidor..."
  [ -n "${PLAYIT_PID:-}" ] && kill "$PLAYIT_PID" 2>/dev/null || true
  exit 0
}
trap cleanup SIGINT SIGTERM

echo "=== Iniciando tunnel playit.gg ==="
playit &
PLAYIT_PID=$!

echo "=== Aguardando tunnel... ==="
sleep 8

echo "=== Iniciando servidor Minecraft ==="
bash start.sh

cleanup
TUNNEL
  chmod +x "$SERVER_DIR/start-with-tunnel.sh"
  p_ok "start-with-tunnel.sh criado"
}

# ─── systemd ─────────────────────────────────────────────────────────────────

setup_systemd() {
  echo ""
  local create=""
  ask "Criar serviço systemd para iniciar o servidor automaticamente com o sistema? (s/n)" "n" create
  [ "$create" != "s" ] && [ "$create" != "S" ] && return 0

  local user
  user=$(whoami)
  local service_name="mc-$(echo "$SELECTED_MOD_NAME" | tr '[:upper:] ' '[:lower:]-' | tr -dc 'a-z0-9-')"

  sudo tee "/etc/systemd/system/${service_name}.service" > /dev/null << EOF
[Unit]
Description=Minecraft Server - $SELECTED_MOD_NAME
After=network.target

[Service]
User=$user
WorkingDirectory=$SERVER_DIR
ExecStart=$SERVER_DIR/start-with-tunnel.sh
ExecStop=$SERVER_DIR/stop.sh
Restart=on-failure
RestartSec=30
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable "$service_name"
  p_ok "Serviço ${service_name} criado e habilitado"
  p_info "Comandos:"
  p_info "  sudo systemctl start $service_name"
  p_info "  sudo systemctl status $service_name"
  p_info "  journalctl -u $service_name -f   (ver logs ao vivo)"
}

# ─── Resumo ───────────────────────────────────────────────────────────────────

print_summary() {
  local mc_minor
  mc_minor=$(echo "$SELECTED_MC_VERSION" | grep -oP '1\.\K\d+' || echo "20")

  echo ""
  echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗"
  echo    "║           Instalação concluída com sucesso!          ║"
  echo -e "╚══════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${BOLD}Modpack:${NC}   $SELECTED_MOD_NAME"
  echo -e "  ${BOLD}Versão:${NC}    $SELECTED_FILE_NAME"
  echo -e "  ${BOLD}Minecraft:${NC} $SELECTED_MC_VERSION"
  echo -e "  ${BOLD}Pasta:${NC}     $SERVER_DIR"
  echo ""
  echo -e "${BOLD}  ── Como usar ───────────────────────────────────────────${NC}"
  echo ""
  echo -e "  ${CYAN}1. Primeira execução (configurar tunnel):${NC}"
  echo -e "     playit"
  echo -e "     → Acesse o link gerado, faça login e crie um túnel TCP na porta 25565"
  echo -e "     → Você receberá um endereço como:  ${GREEN}abc123.joinmc.link:12345${NC}"
  echo ""
  echo -e "  ${CYAN}2. Iniciar servidor com acesso remoto:${NC}"
  echo -e "     cd $SERVER_DIR && bash start-with-tunnel.sh"
  echo ""
  echo -e "  ${CYAN}3. Seus amigos se conectam com o endereço do playit.gg${NC}"
  echo ""
  echo -e "${BOLD}  ── Launcher para os amigos (sem Minecraft original) ────${NC}"
  echo ""
  echo -e "  Use o ${CYAN}PrismLauncher${NC} — gratuito, open source, suporta modpacks CurseForge."
  echo ""
  echo -e "  ${CYAN}1. Baixar PrismLauncher:${NC}  https://prismlauncher.org/download/"
  echo -e "  ${CYAN}2. Na tela de login:${NC}  clique em 'Offline' e escolha um nome de usuário"
  echo -e "  ${CYAN}3. Adicionar modpack:${NC}  'Add Instance' → 'CurseForge' → buscar '$SELECTED_MOD_NAME'"
  echo -e "     (precisa de API key gratuita do CurseForge — igual à usada no servidor)"
  echo -e "  ${CYAN}4. Conectar:${NC}  Multiplayer → Direct Connect → endereço do playit.gg"
  echo ""
  echo -e "  ${YELLOW}Atenção:${NC} todos devem usar o mesmo nome de usuário sempre,"
  echo -e "  caso contrário o inventário/progresso não é mantido."
  echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  p_banner
  check_deps
  setup_api_key
  search_modpacks
  select_version

  local mc_minor
  mc_minor=$(echo "$SELECTED_MC_VERSION" | grep -oP '1\.\K\d+' || echo "20")
  install_java "$mc_minor"

  download_server_pack
  install_server
  configure_server
  setup_playit
  setup_systemd
  print_summary
}

# Modo interativo: se passar --reinstall, pula busca e usa servidor existente
if [ "${1:-}" = "--reinstall" ] && [ -n "${2:-}" ]; then
  SERVER_DIR="$2"
  cd "$SERVER_DIR"
  load_config
  setup_api_key
  configure_server
  setup_playit
  echo "Reinstalação concluída."
else
  main
fi
