#!/bin/bash

set -e

echo "======================================"
echo "Установщик Telegram бота с Ollama"
echo "======================================"
echo ""

# Проверка прав root
if [ "$EUID" -ne 0 ]; then 
    echo "Пожалуйста, запустите скрипт с правами root (sudo)"
    exit 1
fi

# Обновление системы
echo "[1/6] Обновление системы..."
apt update -y
apt upgrade -y
apt install -y curl wget git

# Установка Docker
echo "[2/6] Установка Docker..."
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    rm get-docker.sh
    systemctl start docker
    systemctl enable docker
    echo "Docker установлен успешно"
else
    echo "Docker уже установлен"
fi

# Установка Docker Compose
echo "[3/6] Проверка Docker Compose..."
if ! docker compose version &> /dev/null; then
    echo "Установка Docker Compose..."
    apt-get install -y docker-compose-plugin
fi

# Добавление текущего пользователя в группу docker
echo "[4/6] Настройка прав пользователя..."
REAL_USER=${SUDO_USER:-$USER}
usermod -aG docker $REAL_USER
echo "Пользователь $REAL_USER добавлен в группу docker"

# Создание директории проекта
echo "[5/6] Создание структуры проекта..."
PROJECT_DIR="/opt/telegram-bot-ollama"
mkdir -p $PROJECT_DIR
cd $PROJECT_DIR

# Создание .env файла
echo "[6/6] Создание конфигурационных файлов..."
cat > .env << 'EOF'
# Токен Telegram бота (получить у @BotFather)
TELEGRAM_BOT_TOKEN=YOUR_TELEGRAM_BOT_TOKEN

# Настройки Ollama
OLLAMA_HOST=ollama
OLLAMA_PORT=11434
OLLAMA_MODEL=gpt-oss:20b

# Настройки памяти контекста
CONTEXT_MEMORY_SIZE=8
EOF

# Создание docker-compose.yml
cat > docker-compose.yml << 'EOF'
version: '3.8'

services:
  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    ports:
      - "11434:11434"
    volumes:
      - ollama_data:/root/.ollama
    environment:
      - OLLAMA_HOST=0.0.0.0:11434
      - OLLAMA_ORIGINS=*
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "ollama", "list"]
      interval: 30s
      timeout: 10s
      retries: 3
    networks:
      - bot_network

  telegram-bot:
    build: .
    container_name: telegram-bot
    depends_on:
      ollama:
        condition: service_healthy
    env_file:
      - .env
    restart: unless-stopped
    networks:
      - bot_network

volumes:
  ollama_data:

networks:
  bot_network:
    driver: bridge
EOF

# Создание Dockerfile
cat > Dockerfile << 'EOF'
FROM python:3.12-slim

WORKDIR /app

# Копирование requirements.txt
COPY requirements.txt .

# Установка зависимостей
RUN pip install --no-cache-dir -r requirements.txt

# Копирование кода бота
COPY bot.py .

# Запуск бота
CMD ["python", "-u", "bot.py"]
EOF

# Создание requirements.txt
cat > requirements.txt << 'EOF'
python-telegram-bot==20.7
ollama==0.3.3
nest-asyncio==1.6.0
EOF

# Создание bot.py
cat > bot.py << 'EOF'
import logging
import os
from telegram import Update
from telegram.ext import ApplicationBuilder, CommandHandler, MessageHandler, filters, ContextTypes
import ollama
import nest_asyncio
import asyncio

# Применяем nest_asyncio для совместимости
nest_asyncio.apply()

# Настройка логирования
logging.basicConfig(
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    level=logging.INFO
)
logger = logging.getLogger(__name__)

# Загрузка конфигурации из переменных окружения
TOKEN = os.getenv('TELEGRAM_BOT_TOKEN')
OLLAMA_HOST = os.getenv('OLLAMA_HOST', 'ollama')
OLLAMA_PORT = os.getenv('OLLAMA_PORT', '11434')
OLLAMA_MODEL = os.getenv('OLLAMA_MODEL', 'gpt-oss:20b')
CONTEXT_SIZE = int(os.getenv('CONTEXT_MEMORY_SIZE', '8'))

# Настройка клиента Ollama
ollama_client = ollama.Client(host=f'http://{OLLAMA_HOST}:{OLLAMA_PORT}')

# Хранилище контекста для каждого пользователя
context_memory = {}

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Обработчик команды /start"""
    user_name = update.effective_user.first_name
    await update.message.reply_text(
        f'Привет, {user_name}! 👋\n\n'
        f'Я локальный ИИ-бот на базе {OLLAMA_MODEL}.\n'
        f'Задавайте вопросы, и я постараюсь помочь!\n\n'
        f'Используйте /clear для очистки контекста разговора.'
    )

async def clear_context(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Очистка контекста разговора"""
    user_id = update.effective_user.id
    if user_id in context_memory:
        context_memory[user_id] = []
    await update.message.reply_text('Контекст разговора очищен! 🧹')

async def handle_message(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Обработчик текстовых сообщений"""
    user_id = update.effective_user.id
    message_text = update.message.text
    
    # Инициализация контекста для нового пользователя
    if user_id not in context_memory:
        context_memory[user_id] = []
    
    # Добавляем сообщение пользователя в контекст
    context_memory[user_id].append({'role': 'user', 'content': message_text})
    
    # Ограничиваем контекст последними N сообщениями
    context_memory[user_id] = context_memory[user_id][-CONTEXT_SIZE:]
    
    # Отправляем индикатор "печатает"
    await update.message.chat.send_action(action="typing")
    
    try:
        # Запрос к локальной модели через Ollama
        response = ollama_client.chat(
            model=OLLAMA_MODEL,
            messages=context_memory[user_id]
        )
        
        response_text = response['message']['content']
        
        # Добавляем ответ модели в контекст
        context_memory[user_id].append({'role': 'assistant', 'content': response_text})
        
        # Отправляем ответ пользователю
        await update.message.reply_text(response_text)
        
        logger.info(f"User {user_id}: successful response")
        
    except Exception as e:
        logger.error(f"Ошибка при обращении к Ollama: {e}")
        await update.message.reply_text(
            '⚠️ Произошла ошибка при обработке запроса.\n'
            'Попробуйте позже или используйте /clear для сброса контекста.'
        )

async def error_handler(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Обработчик ошибок"""
    logger.error(f"Update {update} caused error {context.error}")

async def main() -> None:
    """Главная функция"""
    if not TOKEN:
        logger.error("TELEGRAM_BOT_TOKEN не установлен!")
        return
    
    logger.info(f"Запуск бота с моделью {OLLAMA_MODEL}")
    
    # Создаём приложение
    application = ApplicationBuilder().token(TOKEN).build()
    
    # Добавляем обработчики
    application.add_handler(CommandHandler('start', start))
    application.add_handler(CommandHandler('clear', clear_context))
    application.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_message))
    application.add_error_handler(error_handler)
    
    # Запускаем бота
    logger.info("Бот успешно запущен!")
    await application.run_polling(allowed_updates=Update.ALL_TYPES)

if __name__ == '__main__':
    asyncio.run(main())
EOF

# Создание скрипта управления
cat > manage.sh << 'EOF'
#!/bin/bash

case "$1" in
    start)
        echo "Запуск сервисов..."
        docker compose up -d
        echo "Ожидание запуска Ollama..."
        sleep 10
        echo "Загрузка модели gpt-oss:20b..."
        docker exec ollama ollama pull gpt-oss:20b
        echo "Сервисы запущены!"
        ;;
    stop)
        echo "Остановка сервисов..."
        docker compose down
        echo "Сервисы остановлены!"
        ;;
    restart)
        echo "Перезапуск сервисов..."
        docker compose restart
        ;;
    logs)
        docker compose logs -f telegram-bot
        ;;
    logs-ollama)
        docker compose logs -f ollama
        ;;
    status)
        docker compose ps
        ;;
    pull-model)
        if [ -z "$2" ]; then
            echo "Использование: ./manage.sh pull-model <model-name>"
            echo "Пример: ./manage.sh pull-model llama3:latest"
        else
            docker exec ollama ollama pull "$2"
        fi
        ;;
    list-models)
        docker exec ollama ollama list
        ;;
    *)
        echo "Использование: ./manage.sh {start|stop|restart|logs|logs-ollama|status|pull-model|list-models}"
        exit 1
        ;;
esac
EOF

chmod +x manage.sh

# Установка прав на директорию
chown -R $REAL_USER:$REAL_USER $PROJECT_DIR

echo ""
echo "======================================"
echo "Установка завершена!"
echo "======================================"
echo ""
echo "Следующие шаги:"
echo "1. Отредактируйте файл $PROJECT_DIR/.env"
echo "   Укажите токен бота: nano $PROJECT_DIR/.env"
echo ""
echo "2. Перезайдите в систему для применения прав Docker"
echo "   или выполните: newgrp docker"
echo ""
echo "3. Запустите бота:"
echo "   cd $PROJECT_DIR"
echo "   ./manage.sh start"
echo ""
echo "Дополнительные команды:"
echo "  ./manage.sh stop          - остановить бота"
echo "  ./manage.sh restart       - перезапустить бота"
echo "  ./manage.sh logs          - просмотр логов бота"
echo "  ./manage.sh logs-ollama   - просмотр логов Ollama"
echo "  ./manage.sh status        - статус контейнеров"
echo "  ./manage.sh list-models   - список моделей"
echo "  ./manage.sh pull-model <model> - загрузить другую модель"
echo ""
