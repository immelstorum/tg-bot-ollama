Структура проекта

После выполнения установщика будет создана следующая структура:

text
/opt/telegram-bot-ollama/
├── .env                 # Конфигурация (токен, настройки)
├── docker-compose.yml   # Конфигурация Docker Compose
├── Dockerfile           # Образ для бота
├── bot.py              # Код бота
├── requirements.txt    # Python зависимости
└── manage.sh           # Скрипт управления

Использование

Установка:

bash
chmod +x install.sh
sudo ./install.sh

Настройка токена:

bash
nano /opt/telegram-bot-ollama/.env
# Замените YOUR_TELEGRAM_BOT_TOKEN на реальный токен

Запуск:

bash
cd /opt/telegram-bot-ollama
./manage.sh start

Просмотр логов:

bash
./manage.sh logs

Остановка:

bash
./manage.sh stop

Скрипт автоматически установит Docker, создаст все необходимые файлы и настроит окружение для работы бота с Ollama.