---
summary: "crowbot prepaid USD balance and optional pass allowance through its free account API."
provider_id: crowbot
provider_name: crowbot
provider_source: API key for prepaid USD balance and optional pass allowance through the free account endpoint.
plugin_scope: Bearer account GET on both engines; prepaid balance and optional pass allowance without paid probes.
---

# crowbot

Enable **crowbot** in Settings → Providers and enter an API key, or set `CROWBOT_API_KEY` for the CLI. CodexBar sends
one free `GET https://api.crowbot.sh/api/me` request; it never sends chat completions.

The required integer `balance_microdollars` is the USD balance headline. Recognized spend and request counts appear as
detail rows, and `can_spend: false` adds a **Spending blocked** warning. Without a `pass` the account is labeled
**Pay as you go**. An active pass labels the plan (for example **Starter pass**) and, when `allowance_bp` is present,
shows a **Pass allowance** window (`100 - allowance_bp / 100` percent used). `refills` is its reset when it is an ISO
timestamp or Unix epoch; otherwise it is shown as text. `ends_at` is shown as **Pass ends**.

401 means an invalid key, 403 a disabled account, 429 rate limiting, and 5xx an unavailable provider. Non-JSON or
missing balances fail parsing. Source: [crowbot API documentation](https://crowbot.sh/docs/api).
