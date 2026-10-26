---
summary: "NanoGPT prepaid balance and optional subscription token windows through its API."
provider_id: nanogpt
provider_name: NanoGPT
provider_source: API key for the prepaid USD balance, with daily and weekly input-token windows for active subscriptions.
plugin_scope: x-api-key balance POST plus best-effort subscription usage GET on both engines; subscription failures keep the balance.
read_when:
  - Configuring NanoGPT
  - Debugging NanoGPT balance or subscription fetching
---

# NanoGPT

Enable **NanoGPT** in Settings → Providers and enter a NanoGPT API key, or set `NANOGPT_API_KEY` for the CLI.
The provider is off by default. CodexBar sends the key only to `https://nano-gpt.com` as `x-api-key` and does not
import browser cookies or start a login flow.

The bundled JavaScript plugin makes two requests:

- `POST /api/check-balance` always runs. Its `usd_balance` string is the headline (for example `$129.47`) and
  `nano_balance` is shown as a detail row. The deposit address is never read into the snapshot or displayed.
  A 401 or 403 is reported as an invalid key; 429 and 5xx are transient errors.
- `GET /api/subscription/v1/usage` is best-effort. When `active` is true and `state` is `active` or `grace`, daily input
  tokens become the primary window and weekly input tokens the secondary window, with the reported `resetAt`. The
  percentage is computed from `used / (used + remaining)`, falling back to `percentUsed`. Quotas that are `null` or
  `degraded` are omitted rather than shown as full. Inactive accounts, missing quotas, or any request failure leave
  just the balance, which is the normal pay-as-you-go view.

Balances are decimal strings; zero and negative values are preserved, and malformed values fail parsing instead of
becoming zero. The key and response bodies are never logged.

```sh
codexbar usage --provider nanogpt --source api --json
```

`nano-gpt` also works as a provider alias.

Sources: [NanoGPT API documentation](https://docs.nano-gpt.com). Tests use synthetic fixtures on QuickJS and
JavaScriptCore; no authenticated account was probed during implementation.
