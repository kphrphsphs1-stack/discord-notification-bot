# Discord Notification Bot

A custom Discord bot with automated notifications, moderation commands, and third-party API integrations.

## Features

- Real-time crypto price alerts in Discord channels
- Server moderation commands (kick, ban, mute, warn)
- Scheduled announcements and reminders
- Custom embed messages with rich formatting
- Role management and auto-role assignment
- Integration with external APIs (CoinGecko, OpenWeather)

  ## Tech Stack

  - Python 3.11+ with discord.py
  - SQLite for persistent storage
  - REST API integrations
  - Docker support for deployment

    ## Commands

    | Command | Description |
    |---------|-------------|
    | /price BTC | Get current Bitcoin price |
    | /alert BTC 70000 | Set price alert |
    | /remind 2h Meeting | Set a reminder |
    | /kick @user reason | Kick a user |
    | /stats | Show server statistics |

    ## Setup

    ```
    git clone https://github.com/kphrphsphs1-stack/discord-notification-bot.git
    cd discord-notification-bot
    pip install -r requirements.txt
    cp .env.example .env
    python bot.py
    ```

    ## License

    MIT License
    
