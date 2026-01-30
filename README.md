# imsendmail

`sendmail` replacement that sends Telegram messages

## Usage

```bash
sendmail [recipient ...] < message.txt
```

Reads a message from stdin and sends it via Telegram. Recipients can be specified as command-line arguments or in the `To:` header.

**Recipient formats:**

- `123456789@telegram`: Telegram chat ID
- `alias@example.com`: resolved via config aliases

## Configuration

Config file locations (first found is used):

1. `./imsendmailrc.json` (current directory)
2. `$XDG_CONFIG_HOME/imsendmail/imsendmailrc.json`
3. `$HOME/.config/imsendmail/imsendmailrc.json`
4. `/etc/imsendmailrc.json`

```json
{
  "telegram_token": "123456:ABC-your-bot-token",
  "aliases": {
    "admin@localhost": "123456789@telegram",
    "*": "123456789@telegram" // catch all fallback
  }
}
```
