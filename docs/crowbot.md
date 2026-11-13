---
summary: "crowbot prepaid USD balance and optional pass allowance through its free account API."
provider_id: crowbot
provider_name: crowbot
provider_source: API key for prepaid USD balance and optional pass allowance through the free account endpoint.
plugin_scope: Bearer account GET on both engines; prepaid balance and optional pass allowance without paid probes.
---

# crowbot

crowbot is off by default. Enable it in Settings and enter an API key, or set
`CROWBOT_API_KEY`. The API-key field uses the shared config-file credential storage.
The dashboard opens <https://crowbot.sh>.

## Account source

CodexBar sends `GET https://api.crowbot.sh/api/me` with bearer authentication.
This is a free account request, not a chat completion. Normal polling does not incur model charges,
and no paid probe, persistent balance cache, or special 30-minute cooldown is needed.

The required integer `balance_microdollars` is divided by 1,000,000 and displayed as the USD balance
headline. Optional cumulative spend and request count appear as detail rows when recognized.
`can_spend: false` adds a **Spending blocked** notice without hiding the account balance.

## Pass allowance

Without an active `pass`, the account is labeled **Pay as you go** and only balance details are shown.
An active pass can supply a primary **Pass allowance** window. `allowance_bp` is allowance remaining
in basis points (10,000 means full), so used percentage is `100 - allowance_bp / 100`, clamped to 0–100.
Missing allowance is not fabricated as zero usage.

`refills` is interpreted as a reset only when it is a recognized ISO timestamp or Unix epoch in seconds
or milliseconds. Otherwise a textual refill description is shown as a detail row. The API describes this
as roughly when the pass is full again, not a guaranteed reset. `ends_at` is shown as **Pass ends**.
The plan name appears in the login-method label, such as **Starter pass**. Known public plan IDs map to
Starter, Vibecoder, Hyperscaler, and Raven.

Some optional field names and shapes are not fully documented. The parser accepts common spend,
request-count, and plan-name aliases, and omits missing or malformed optional values instead of failing
an otherwise valid balance. It does not interpret per-model chat quota windows or infer limits from spend.

## Errors and privacy

401 means an invalid API key; 403 reports an account-disabled/access-denied response. 429 is rate limiting,
and 5xx means the provider is unavailable. Non-JSON responses or a missing/malformed required balance
fail parsing with a clear message. API keys and response bodies are never logged, and key hints are not
rendered. Tests use synthetic fixtures on both JavaScript engines, not real accounts.

Source: [crowbot API documentation](https://crowbot.sh/docs/api).
