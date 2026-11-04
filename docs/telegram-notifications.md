# Telegram notifications

Faseela sends a Telegram message when its GitHub Actions workflows finish.

Notifications are enabled for:
- CI: script and recipe checks.
- Build ISO (CD): recipe selection, core build, flavor builds, QEMU boot tests,
  container image and release publication.

The message includes the overall result, workflow, repository, branch, short
commit ID, triggering event and actor, run attempt, each relevant job result,
and a link to the GitHub Actions run. Messages use Telegram HTML formatting.

## Configure the bot

1. Create a Telegram bot with @BotFather and copy its API token.
2. Open a private chat with the bot and send /start. For a group, add the bot
   and send a message in the group.
3. Obtain the destination chat ID from message.chat.id in the Telegram Bot API
   getUpdates response.
4. In this GitHub repository, open Settings → Secrets and variables → Actions,
   then add these repository secrets:

   | Secret | Value |
   | --- | --- |
   | TELEGRAM_BOT_TOKEN | The token issued by @BotFather |
   | TELEGRAM_CHAT_ID | The destination user or group chat ID |

Never commit the token or chat ID to the repository. The notifier skips safely
when either secret is absent, which also allows fork pull-request CI to run
without secrets.

## Delivery and tests

Notifications are best-effort. Telegram/network failures create a GitHub Actions
warning but never change the build, CI, or release result. Optional skipped jobs
(such as image publishing on a manual artifact-only build) do not turn a
successful workflow into a failure.

Run the offline tests with:

    python3 -I tests/test-telegram-notify.py

The tests do not require a Telegram account, token, or network access.
