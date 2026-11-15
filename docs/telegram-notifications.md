# Telegram notifications

Faseela sends a short start notification, then one detailed Telegram report
after each standalone CI run and each complete Build ISO (CD) run.

## What Telegram receives

- Overall result, workflow, repository, branch, commit, run number, trigger,
  actor, attempt, optional PR number, and every relevant job result.
- The generated `run-report.md` file as a Telegram document. It contains job
  durations, failed jobs and steps, direct log links, build facts, artifact
  names, and extracted failure diagnostics.
- A compressed archive of available build logs, including core and per-flavor
  logs and QEMU boot logs. Common token, password, and authorization patterns
  are redacted before the archive is sent.
- Build outputs are not downloaded again by the notification job and are not
  uploaded to Telegram. When a GitHub Release is published, Telegram includes
  its URL so the original ISO/rootfs can be downloaded as a single file,
  regardless of Telegram's upload limit.
- When the run does not publish a Release, Telegram links to the Actions run
  page where its workflow artifacts are available.

A failed or cancelled build still sends the report and available diagnostic
logs, but never sends partial build outputs as successful deliverables.
Telegram delivery is best-effort and cannot change the workflow result.

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

## Delivery limits and tests

The notification job never downloads build outputs. It links to the published
GitHub Release, or to the Actions run page when no Release was created. GitHub Actions logs are also retained
there independently of Telegram delivery.

Run the offline tests with:

    python3 -I tests/test-telegram-notify.py

The tests do not require a Telegram account, token, or network access.
