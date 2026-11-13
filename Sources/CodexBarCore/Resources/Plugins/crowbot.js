defineProvider({
  id: "crowbot",
  name: "crowbot",
  endpoints: ["https://api.crowbot.sh"],
  auth: { type: "bearer", secret: "CROWBOT_API_KEY" },
  settings: [{ key: "CROWBOT_API_KEY", title: "crowbot API key", type: "secure" }],
  capabilities: ["http-status"],
  async fetchUsage(ctx) {
    // Free account endpoint; documented at https://crowbot.sh/docs/api.md. Bodies and keys are never logged.
    const response = await ctx.http.get("https://api.crowbot.sh/api/me");
    const message = `crowbot returned HTTP ${response.status}.`;
    if (response.status === 401) {
      throw ctx.fail.authenticationExpired("crowbot rejected the API key. Check it in Settings or CROWBOT_API_KEY.");
    }
    if (response.status === 403) throw ctx.fail.permissionDenied("crowbot reports this account is disabled.");
    if (response.status === 429) {
      const delay = Number(response.headers["retry-after"] ?? 1);
      throw ctx.fail.rateLimited(message, {
        retryAfterSeconds: Number.isFinite(delay) && delay >= 0 ? Math.min(delay, 10) : 1,
      });
    }
    if (response.status >= 500) throw ctx.fail.providerUnavailable(message);
    if (response.status !== 200) throw ctx.fail.apiFailure(message);
    const fail = () => {
      throw ctx.fail.parseFailure("crowbot returned an unrecognized account response.");
    };
    let data;
    try {
      data = JSON.parse(response.bodyText);
    } catch {
      return fail();
    }
    if (!data || typeof data !== "object" || Array.isArray(data)) return fail();

    const integer = (value) => {
      if (typeof value === "string" && /^\s*-?\d+\s*$/.test(value)) value = Number(value);
      return Number.isSafeInteger(value) ? value : undefined;
    };
    const decimal = (value) => {
      if (typeof value === "string" && /^\s*-?(\d+(\.\d*)?|\.\d+)\s*$/.test(value)) value = Number(value);
      return typeof value === "number" && Number.isFinite(value) ? value : undefined;
    };
    const first = (values, parse) => {
      for (const value of values) {
        const parsed = parse(value);
        if (parsed !== undefined) return parsed;
      }
      return undefined;
    };
    const text = (value) => (typeof value === "string" && value.trim() !== "" ? value.trim().slice(0, 120) : undefined);
    const date = (value) => {
      let millis;
      const numeric = decimal(value);
      if (numeric !== undefined && numeric >= 1e9) {
        // Plausible epochs only: values below 1e12 are seconds, larger values are milliseconds.
        millis = numeric < 1e12 ? numeric * 1000 : numeric;
      } else if (typeof value === "string" && /^\s*\d{4}-\d{2}-\d{2}/.test(value)) {
        millis = new Date(value.trim()).getTime();
      }
      return Number.isFinite(millis) && Math.abs(millis) <= 8640000000000000 ? new Date(millis) : undefined;
    };

    const balanceMicro = integer(data.balance_microdollars);
    if (balanceMicro === undefined) return fail();
    const rows = [{ label: "USD balance", value: ctx.format.usd(balanceMicro / 1000000) }];
    const spentMicro = first([data.spent_microdollars, data.total_spent_microdollars], integer);
    const spent =
      spentMicro !== undefined ? spentMicro / 1000000 : first([data.spent_usd, data.total_spent_usd], decimal);
    if (spent !== undefined) rows.push({ label: "Total spent", value: ctx.format.usd(spent) });
    const requests = first([data.requests, data.request_count], integer);
    if (requests !== undefined) rows.push({ label: "Requests", value: ctx.format.number(requests) });
    if (data.can_spend === false) rows.push({ label: "Status", value: "Spending blocked", severity: "warning" });
    const details = [{ title: "Account balance", rows }];

    const pass = data.pass && typeof data.pass === "object" && !Array.isArray(data.pass) ? data.pass : undefined;
    let primary;
    let loginMethod = "Pay as you go";
    if (pass) {
      const labels = { starter: "Starter", vibecoder: "Vibecoder", hyperscaler: "Hyperscaler", raven: "Raven" };
      const planID = text(pass.plan_id) ?? text(pass.plan);
      const plan = text(pass.label) ?? (planID && labels[planID.toLowerCase()]) ?? planID;
      loginMethod = plan ? `${plan} pass` : "Pass";
      const passRows = [];
      const allowance = decimal(pass.allowance_bp);
      const refills = pass.refills;
      const refillDate = date(refills);
      if (allowance !== undefined) {
        primary = { usedPercent: Math.min(100, Math.max(0, 100 - allowance / 100)) };
        if (refillDate) primary.resetsAt = refillDate;
      }
      if (!refillDate || allowance === undefined) {
        const refillText = refillDate ? refillDate.toISOString() : text(refills);
        if (refillText) passRows.push({ label: "Refills", value: refillText });
      }
      const endsAt = date(pass.ends_at);
      if (endsAt) passRows.push({ label: "Pass ends", value: ctx.format.monthDay(endsAt) });
      if (passRows.length > 0) details.push({ title: "Pass", rows: passRows });
    }

    return { primary, details, identity: { loginMethod }, dataConfidence: "exact" };
  },
});
