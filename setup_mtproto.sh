#!/bin/bash
# ==============================================================================
# MTProto FakeTLS proxy setup (nineseconds/mtg:2) with Prometheus stats
#
# КАК ЗАПУСТИТЬ:
#   sudo bash setup_mtproto.sh <домен_или_ip> [порт] [порт_статистики]
#
# ПРИМЕРЫ:
#   sudo bash setup_mtproto.sh mydomain.com          # порты по умолчанию
#   sudo bash setup_mtproto.sh mydomain.com 2083     # свой порт
#   sudo bash setup_mtproto.sh 1.2.3.4               # без домена, только по IP
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Аргументы
# ------------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
  echo "Использование: sudo bash $0 <домен_или_ip> [порт] [порт_статистики]"
  echo "Пример:            sudo bash $0 mydomain.com 2083 3129"
  echo "Пример без домена: sudo bash $0 1.2.3.4 2083 3129"
  exit 1
fi

DOMAIN="$1"
PORT="${2:-2083}"
STATS_PORT="${3:-3129}"
CONFIG_DIR="/opt/mtg"
CONFIG_FILE="$CONFIG_DIR/config.toml"
SECRET_FILE="$CONFIG_DIR/secret.txt"

# ------------------------------------------------------------------------------
# Определяем: домен или IP
# Если передан IP — FakeTLS маскируется под google.com
# ------------------------------------------------------------------------------
if [[ "$DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  IS_IP=true
  TLS_DOMAIN="google.com"
  echo ">>> Обнаружен IP-адрес. FakeTLS будет маскироваться под: $TLS_DOMAIN"
else
  IS_IP=false
  TLS_DOMAIN="$DOMAIN"
fi

echo ""
echo "=============================="
echo "  MTProto Setup"
echo "=============================="
echo "  Домен/IP    : $DOMAIN"
echo "  TLS-маска   : $TLS_DOMAIN"
echo "  Порт        : $PORT"
echo "  Статистика  : 127.0.0.1:$STATS_PORT (только локально)"
echo "=============================="
echo ""

# ------------------------------------------------------------------------------
# Шаг 1/7 — Docker
# ------------------------------------------------------------------------------
echo "[1/7] Проверка Docker..."
if ! command -v docker &>/dev/null; then
  echo "      Docker не найден — устанавливаем..."
  apt-get update -q
  apt-get install -y -q ca-certificates curl gnupg lsb-release
  curl -fsSL https://get.docker.com | sh
  systemctl enable docker --now
  echo "      Docker установлен ✓"
else
  echo "      Docker уже установлен ✓"
fi

# ------------------------------------------------------------------------------
# Шаг 2/7 — Получение образа
# ------------------------------------------------------------------------------
echo "[2/7] Загрузка образа nineseconds/mtg:2..."
if ! docker pull nineseconds/mtg:2; then
  echo "      ОШИБКА: не удалось загрузить образ. Проверь интернет-соединение."
  exit 1
fi
echo "      Образ загружен ✓"

# ------------------------------------------------------------------------------
# Шаг 3/7 — Генерация секрета
# ------------------------------------------------------------------------------
echo "[3/7] Генерация FakeTLS-секрета для домена: $TLS_DOMAIN..."
SECRET=$(docker run --rm nineseconds/mtg:2 generate-secret --hex "$TLS_DOMAIN")
if [[ -z "$SECRET" ]]; then
  echo "      ОШИБКА: секрет не сгенерирован."
  exit 1
fi
echo "      Секрет: $SECRET"

mkdir -p "$CONFIG_DIR"
echo "$SECRET" > "$SECRET_FILE"
chmod 600 "$SECRET_FILE"
echo "      Секрет сохранён в $SECRET_FILE"

# ------------------------------------------------------------------------------
# Шаг 4/7 — Конфигурация
# stats bind-to = 0.0.0.0 внутри контейнера (не 127.0.0.1 — иначе недоступно)
# снаружи доступ ограничен через -p 127.0.0.1:STATS_PORT
# ------------------------------------------------------------------------------
echo "[4/7] Запись конфига в $CONFIG_FILE..."
cat > "$CONFIG_FILE" <<EOF
secret = "$SECRET"
bind-to = "0.0.0.0:$PORT"

[stats.prometheus]
enabled = true
bind-to = "0.0.0.0:$STATS_PORT"
http-path = "/"
EOF
echo "      Конфиг записан ✓"

# ------------------------------------------------------------------------------
# Шаг 5/7 — Запуск контейнера
# ------------------------------------------------------------------------------
echo "[5/7] Запуск контейнера mtg..."
docker stop mtg 2>/dev/null && docker rm mtg 2>/dev/null || true

docker run -d \
  --name mtg \
  --restart=always \
  -p "$PORT:$PORT" \
  -p "127.0.0.1:$STATS_PORT:$STATS_PORT" \
  -v "$CONFIG_FILE:/config.toml:ro" \
  nineseconds/mtg:2 \
  run /config.toml

echo "      Ожидаем запуска контейнера..."
STARTED=false
for i in {1..15}; do
  if docker ps --filter "name=^mtg$" --filter "status=running" | grep -q mtg; then
    STARTED=true
    break
  fi
  sleep 1
done

if [[ "$STARTED" == true ]]; then
  echo "      Контейнер запущен ✓"
else
  echo "      ОШИБКА: контейнер не запустился. Логи:"
  docker logs mtg
  exit 1
fi

# ------------------------------------------------------------------------------
# Шаг 6/7 — Статистика
# ------------------------------------------------------------------------------
echo "[6/7] Проверка endpoint статистики..."
sleep 3
if curl -s --max-time 5 "http://127.0.0.1:$STATS_PORT/" | grep -q "mtg"; then
  echo "      Статистика работает ✓"
else
  echo "      Статистика пока недоступна (попробуй через минуту):"
  echo "      curl http://127.0.0.1:$STATS_PORT/"
fi

# ------------------------------------------------------------------------------
# Шаг 7/7 — Firewall и безопасность
# ------------------------------------------------------------------------------
echo ""
echo "[7/7] Проверка безопасности и firewall..."
echo ""

# --- UFW ---
echo "  ▶ UFW Firewall:"
UFW_ACTIVE=false
if ! command -v ufw &>/dev/null; then
  echo "    ✗ UFW не установлен"
else
  UFW_STATUS=$(ufw status | head -1)
  if echo "$UFW_STATUS" | grep -q "inactive"; then
    echo "    ⚠ UFW установлен, но ВЫКЛЮЧЕН"
  else
    echo "    ✓ UFW активен"
    UFW_ACTIVE=true
  fi
fi

# --- SSH порт ---
SSH_PORT=$(ss -tlnp | grep sshd | awk '{print $4}' | awk -F: '{print $NF}' | head -1)
SSH_PORT="${SSH_PORT:-22}"

# --- 3x-ui ---
echo ""
echo "  ▶ 3x-ui:"
XUI_FOUND=false
XUI_PORTS=()

if systemctl is-active --quiet x-ui 2>/dev/null; then
  XUI_FOUND=true
  echo "    ✓ 3x-ui запущен (systemd)"
fi

if docker ps --format '{{.Names}}' 2>/dev/null | grep -qiE "x-ui|3x-ui|xui"; then
  XUI_FOUND=true
  echo "    ✓ 3x-ui запущен (Docker)"
fi

if [[ "$XUI_FOUND" == true ]]; then
  mapfile -t XUI_PORTS < <(
    ss -tlnp | grep -E "x-ui|xui" | awk '{print $4}' | awk -F: '{print $NF}' | sort -un
  )
  if [[ -f /usr/local/x-ui/bin/config.json ]]; then
    mapfile -t CFG_PORTS < <(grep -oP '"port"\s*:\s*\K[0-9]+' /usr/local/x-ui/bin/config.json | sort -un)
    XUI_PORTS+=("${CFG_PORTS[@]+"${CFG_PORTS[@]}"}")
  fi
  mapfile -t XUI_PORTS < <(printf '%s\n' "${XUI_PORTS[@]+"${XUI_PORTS[@]}"}" | sort -un)

  if [[ ${#XUI_PORTS[@]} -gt 0 ]]; then
    echo "    → Обнаруженные порты 3x-ui: ${XUI_PORTS[*]}"
  else
    echo "    ⚠ Порты 3x-ui не определены автоматически"
    echo "    → Проверь вручную: ss -tlnp | grep x-ui"
  fi
else
  echo "    – 3x-ui не обнаружен"
fi

# --- Применяем / выводим правила UFW ---
echo ""
echo "  ▶ Правила UFW:"

if [[ "$UFW_ACTIVE" == false ]]; then
  echo ""
  echo "    UFW неактивен. Готовые команды — скопируй и выполни блоком:"
  echo ""
  echo "    ┌────────────────────────────────────────────────────────────"
  echo "    ufw default deny incoming"
  echo "    ufw default allow outgoing"
  echo "    ufw allow $SSH_PORT/tcp comment 'SSH'"
  echo "    ufw allow $PORT/tcp comment 'MTProto Telegram'"
  for xport in "${XUI_PORTS[@]+"${XUI_PORTS[@]}"}"; do
    echo "    ufw allow $xport/tcp comment '3x-ui'"
  done
  echo "    ufw --force enable"
  echo "    ufw status verbose"
  echo "    └────────────────────────────────────────────────────────────"
  echo ""
  echo "    ⚠  ВНИМАНИЕ: перед включением UFW убедись, что SSH порт"
  echo "       $SSH_PORT открыт — иначе потеряешь доступ к серверу!"
else
  ufw allow "$SSH_PORT/tcp" comment 'SSH' 2>/dev/null || true
  echo "    ✓ SSH порт $SSH_PORT — добавлен"

  ufw allow "$PORT/tcp" comment 'MTProto Telegram' 2>/dev/null || true
  echo "    ✓ MTProto порт $PORT — добавлен"

  for xport in "${XUI_PORTS[@]+"${XUI_PORTS[@]}"}"; do
    ufw allow "$xport/tcp" comment '3x-ui' 2>/dev/null || true
    echo "    ✓ 3x-ui порт $xport — добавлен"
  done

  ufw reload
  echo ""
  echo "    Текущие правила UFW:"
  ufw status numbered | grep -v "^$" | head -30
fi

# ------------------------------------------------------------------------------
# Получаем внешний IP сервера
# ------------------------------------------------------------------------------
SERVER_IP=$(curl -s --max-time 5 ifconfig.me | tr -d '[:space:]' || echo "unknown")

# ------------------------------------------------------------------------------
# Итог
# ------------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  MTProto прокси готов!"
echo "============================================================"
echo ""
if [[ "$IS_IP" == true ]]; then
  echo "  Подключение по IP:"
  echo "  tg://proxy?server=$DOMAIN&port=$PORT&secret=$SECRET"
else
  echo "  Подключение по домену:"
  echo "  tg://proxy?server=$DOMAIN&port=$PORT&secret=$SECRET"
  echo ""
  echo "  Подключение по IP (резерв):"
  echo "  tg://proxy?server=$SERVER_IP&port=$PORT&secret=$SECRET"
fi
echo ""
echo "  Секрет сохранён: $SECRET_FILE"
echo ""
echo "  Статистика (только с сервера):"
echo "  curl http://127.0.0.1:$STATS_PORT/"
echo ""
echo "  Мониторинг в реальном времени:"
echo "  watch -n 2 'curl -s http://127.0.0.1:$STATS_PORT/ | grep -E \"connections|traffic\"'"
echo ""
echo "  Перезапуск прокси:  docker restart mtg"
echo "  Логи:               docker logs -f mtg"
echo ""
echo "  ⚠  Если коннекта нет — проверь внешний firewall у провайдера VDS:"
echo "     порт $PORT/tcp должен быть открыт в панели управления сервером."
echo "============================================================"
