defineProvider({
  id: "nanogpt",
  name: "NanoGPT",
  endpoints: ["https://nano-gpt.com"],
  auth: { type: "x-api-key", secret: "NANOGPT_API_KEY" },
  settings: [{ key: "NANOGPT_API_KEY", title: "NanoGPT API key", type: "secure" }],
  capabilities: ["http-status"],
  async fetchUsage(ctx) {
    const response = await ctx.http.post("https://nano-gpt.com/api/check-balance", { body: {} });
    const message = `NanoGPT returned HTTP ${response.status}.`;
    if (response.status === 401 || response.status === 403) {
      throw ctx.fail.authenticationExpired("NanoGPT rejected the API key. Check it in Settings or NANOGPT_API_KEY.");
    }
    if (response.status === 429) throw ctx.fail.rateLimited(message);
    if (response.status >= 500) throw ctx.fail.providerUnavailable(message);
    if (response.status !== 200) throw ctx.fail.apiFailure(message);
    const fail = () => {
      throw ctx.fail.parseFailure("NanoGPT returned an unrecognized balance response.");
    };
    const decimal = (value) => {
      if (typeof value === "string" && /^\s*[+-]?(\d+(\.\d*)?|\.\d+)\s*$/.test(value)) value = Number(value);
      return typeof value === "number" && Number.isFinite(value) ? value : undefined;
    };
    let data;
    try {
      data = JSON.parse(response.bodyText);
    } catch {
      return fail();
    }
    if (!data || typeof data !== "object" || Array.isArray(data)) return fail();
    const usd = decimal(data.usd_balance);
    if (usd === undefined) return fail();
    const rows = [{ label: "USD balance", value: ctx.format.usd(usd) }];
    const nano = decimal(data.nano_balance);
    if (nano !== undefined) {
      rows.push({ label: "Nano balance", value: `${ctx.format.number(nano, { maximumFractionDigits: 4 })} XNO` });
    }

    // The subscription endpoint is best-effort: pay-as-you-go accounts and endpoint failures keep the balance.
    let subscription;
    try {
      const sub = await ctx.http.get("https://nano-gpt.com/api/subscription/v1/usage");
      if (sub.status === 200) subscription = JSON.parse(sub.bodyText);
    } catch {
      subscription = undefined;
    }
    const active =
      subscription &&
      typeof subscription === "object" &&
      subscription.active === true &&
      (subscription.state === "active" || subscription.state === "grace");
    const windowFor = (quota, windowMinutes) => {
      if (!quota || typeof quota !== "object" || quota.degraded === true) return undefined;
      const used = Number(quota.used);
      const remaining = Number(quota.remaining);
      let percent;
      if (Number.isFinite(used) && Number.isFinite(remaining) && used >= 0 && remaining >= 0 && used + remaining > 0) {
        percent = (used / (used + remaining)) * 100;
      } else if (typeof quota.percentUsed === "number" && Number.isFinite(quota.percentUsed)) {
        percent = quota.percentUsed;
      }
      if (percent === undefined) return undefined;
      const result = { usedPercent: Math.min(100, Math.max(0, percent)), windowMinutes };
      if (typeof quota.resetAt === "number" && Number.isFinite(quota.resetAt) && quota.resetAt > 0) {
        result.resetsAt = ctx.date.unixMillis(quota.resetAt);
      }
      return result;
    };
    const primary = active ? windowFor(subscription.dailyInputTokens, 1440) : undefined;
    const secondary = active ? windowFor(subscription.weeklyInputTokens, 10080) : undefined;
    const loginMethod = active
      ? subscription.state === "grace"
        ? "Subscription (grace)"
        : "Subscription"
      : "Pay as you go";
    return {
      primary,
      secondary,
      details: [{ title: "Account balance", rows }],
      identity: { loginMethod },
      dataConfidence: "exact",
    };
  },
});
