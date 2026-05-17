import test from "node:test";
import assert from "node:assert/strict";

import {
  compactBestLabel,
  filterAccountsByQuery,
  filterAccountsByScope,
  freshnessLabel,
  pinStateLabel,
  resolveMessageText,
  serviceLabel,
  sortAccounts,
  summaryEligibleHint,
  translate,
  type AccountLike,
  type MessageDescriptor,
  type SummaryLike,
} from "./ui_logic.js";

function makeAccount(overrides: Partial<AccountLike> = {}): AccountLike {
  return {
    label: "sage",
    email: "sage@example.com",
    alias: "sage",
    plan: "free",
    accountName: null,
    isActive: false,
    freshness: "fresh",
    eligible: true,
    usable: true,
    effectiveRemaining: 50,
    lastUsedAt: 100,
    lastUsageAt: 100,
    ...overrides,
  };
}

function makeSummary(overrides: Partial<SummaryLike> = {}): SummaryLike {
  return {
    bestKnownLabel: "sage",
    bestKnownRemaining: 42,
    eligibleHint: null,
    eligibleHintCode: null,
    threshold5hPercent: 10,
    thresholdWeeklyPercent: 5,
    autoSwitchMode: "reactive",
    ...overrides,
  };
}

test("resolveMessageText retranslates descriptors by language", () => {
  const descriptor: MessageDescriptor = {
    key: "noticeSwitchedAccount",
    vars: { label: "sage" },
  };

  assert.equal(resolveMessageText("vi", "", descriptor), "Đã chuyển sang sage.");
  assert.equal(resolveMessageText("en", "", descriptor), "Switched to sage.");
  assert.equal(resolveMessageText("vi", "raw error", null), "raw error");
});

test("summaryEligibleHint uses stable hint codes instead of raw backend text", () => {
  assert.equal(
    summaryEligibleHint(
      "vi",
      makeSummary({ eligibleHintCode: "missing-fresh-local-snapshot" }),
    ),
    "Chưa có tài khoản nào có dữ liệu quota mới.",
  );
  assert.equal(
    summaryEligibleHint(
      "en",
      makeSummary({ eligibleHintCode: "below-threshold", threshold5hPercent: 12, thresholdWeeklyPercent: 8 }),
    ),
    "Fresh snapshots exist, but none are above the current thresholds (5h < 12%, weekly < 8%).",
  );
  assert.equal(
    summaryEligibleHint(
      "vi",
      makeSummary({ eligibleHintCode: "active-already-best" }),
    ),
    "Tài khoản hiện tại đã là lựa chọn đủ điều kiện duy nhất.",
  );
  assert.equal(
    summaryEligibleHint(
      "vi",
      makeSummary({ eligibleHintCode: "unknown-code", eligibleHint: "raw backend hint" }),
    ),
    "raw backend hint",
  );
});

test("filterAccountsByQuery and filterAccountsByScope keep account discovery predictable", () => {
  const accounts = [
    makeAccount({ label: "sage", email: "sage@example.com", freshness: "fresh", eligible: true }),
    makeAccount({ label: "amber", email: "amber@example.com", alias: "alt", freshness: "stale", eligible: false }),
    makeAccount({ label: "ghost", email: "ghost@example.com", plan: "team", freshness: "unknown", isActive: true }),
  ];

  assert.deepEqual(
    filterAccountsByQuery(accounts, "ALT").map((account) => account.label),
    ["amber"],
  );
  assert.deepEqual(
    filterAccountsByScope(accounts, "active").map((account) => account.label),
    ["ghost"],
  );
  assert.deepEqual(
    filterAccountsByScope(accounts, "unknown").map((account) => account.label),
    ["ghost"],
  );
});

test("sortAccounts keeps remaining and recency ordering stable", () => {
  const accounts = [
    makeAccount({ label: "beta", effectiveRemaining: 30, isActive: true, lastUsageAt: 10 }),
    makeAccount({ label: "alpha", effectiveRemaining: 90, isActive: false, lastUsageAt: 5 }),
    makeAccount({ label: "gamma", effectiveRemaining: 90, isActive: true, lastUsageAt: 20 }),
  ];

  assert.deepEqual(
    sortAccounts(accounts, "remaining").map((account) => account.label),
    ["alpha", "gamma", "beta"],
  );
  assert.deepEqual(
    sortAccounts(accounts, "recent-usage").map((account) => account.label),
    ["gamma", "beta", "alpha"],
  );
  assert.deepEqual(
    sortAccounts(accounts, "label").map((account) => account.label),
    ["alpha", "beta", "gamma"],
  );
});

test("service, freshness, pin state, and compact best labels localize cleanly", () => {
  assert.equal(serviceLabel("vi", "running"), "đang chạy");
  assert.equal(serviceLabel("en", "running"), "running");
  assert.equal(freshnessLabel("vi", "unknown"), "Không rõ");
  assert.equal(freshnessLabel("en", "fresh"), "Fresh");
  assert.equal(compactBestLabel("vi", makeSummary()), "sage · 42%");
  assert.equal(compactBestLabel("en", makeSummary({ bestKnownLabel: null })), "none");
  assert.equal(pinStateLabel("vi", "out-of-sync"), "lệch auth hiện tại");
  assert.equal(pinStateLabel("en", "ready"), "ready");
  assert.equal(translate("vi", "showingAccounts", { shown: 2, total: 5 }), "Hiển thị 2 / 5 tài khoản");
});
