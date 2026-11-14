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

Enable **NanoGPT** in Settings → Providers and enter an API key, or set `NANOGPT_API_KEY` for the CLI
(`nano-gpt` also works as a provider alias). The key is sent only to `https://nano-gpt.com` as `x-api-key`.

- `POST /api/check-balance` supplies the USD balance headline and a Nano balance detail row. 401 and 403 mean an
  invalid key; 429 and 5xx are transient. Missing or malformed balances fail instead of showing zero.
- `GET /api/subscription/v1/usage` is best-effort. For an `active` or `grace` subscription, daily and weekly input
  tokens become the primary and secondary windows (`used / (used + remaining)`, falling back to `percentUsed`).
  Degraded or missing quotas are omitted, and any failure leaves just the balance.

Source: [NanoGPT API documentation](https://docs.nano-gpt.com). Tests use synthetic fixtures on both engines.
