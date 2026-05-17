export const translations = {
  vi: {
    noActiveAccount: "Chưa có tài khoản đang dùng",
    selectionUnavailable: "không có policy",
    version: "phiên bản",
    best: "tốt nhất",
    refresh: "Làm mới",
    refreshing: "Đang tải...",
    currentState: "Trạng thái",
    thresholds: "ngưỡng",
    apiMode: "chế độ api",
    usageApiOn: "usage api bật",
    usageApiOff: "chỉ local",
    accountApiOn: "account api bật",
    accountApiOff: "account api tắt",
    quickActions: "Tác vụ nhanh",
    switchBest: "Dùng tốt nhất",
    warmAll: "Cập nhật",
    addAccount: "Thêm account",
    deviceLogin: "Thiết bị",
    autoSwitch: "Tự chuyển",
    on: "Bật",
    off: "Tắt",
    mode: "Chế độ",
    reactive: "Reactive",
    proactive: "Proactive",
    pinned: "Pin",
    failover: "Limit",
    accounts: "Tài khoản",
    showingAccounts: "Hiển thị {shown} / {total} tài khoản",
    all: "Tất cả",
    active: "Đang dùng",
    eligible: "Đủ điều kiện",
    fresh: "Mới",
    stale: "Cũ",
    unknown: "Không rõ",
    search: "Tìm kiếm",
    searchPlaceholder: "email, alias hoặc plan",
    sort: "Sắp xếp",
    sortSmart: "Mặc định",
    sortRemaining: "Quota cao nhất",
    sortRecentUsage: "Dùng gần đây",
    sortLabel: "Tên A-Z",
    status: "Trạng thái",
    runtime: "CLI",
    login: "Đăng nhập",
    output: "Kết quả",
    source: "nguồn",
    resolvedPath: "đường dẫn",
    overridePath: "đường dẫn override",
    savePath: "Lưu đường dẫn",
    clearOverride: "Xóa override",
    retryDetect: "Dò lại",
    switch: "Dùng",
    removeAccount: "Xóa account",
    warm: "Warm",
    record: "mã",
    alias: "bí danh",
    usage: "dùng",
    waitingLoginOutput: "Đang chờ output đăng nhập...",
    latestResult: "kết quả mới nhất",
    loadingRegistry: "Đang tải danh sách tài khoản...",
    noAccountsMatch: "Không có tài khoản khớp bộ lọc hiện tại.",
    summaryActive: "đang dùng",
    summaryService: "dịch vụ",
    summaryBestKnown: "quota tốt nhất",
    summaryPinnedAccount: "tài khoản pin",
    summaryPinState: "trạng thái pin",
    summaryBlockedAccount: "tài khoản chặn",
    summaryFailoverState: "trạng thái failover",
    summarySnapshots: "dữ liệu",
    none: "không có",
    snapshotsValue: "{fresh} mới · {eligible} đủ điều kiện",
    runtimeAvailable: "sẵn sàng",
    runtimeUnavailable: "không có",
    noBinaryResolved: "Chưa tìm thấy binary hoạt động",
    loginRunning: "đang chạy",
    loginDone: "xong",
    loginFinished: "hoàn tất",
    browserAuth: "trình duyệt",
    deviceAuth: "thiết bị",
    openLoginUrl: "Mở URL đăng nhập",
    copyLoginUrl: "Sao chép URL",
    dismiss: "Đóng",
    noticeSwitchBest: "Đã chuyển sang tài khoản có quota đã biết tốt nhất.",
    noticeWarmAll: "Đã cập nhật quota cho tất cả tài khoản.",
    noticeAutoEnable: "Đã bật tự động chuyển tài khoản.",
    noticeAutoDisable: "Đã tắt tự động chuyển tài khoản.",
    noticeModeReactive: "Đã chuyển mode auto-switch sang reactive.",
    noticeModeProactive: "Đã chuyển mode auto-switch sang proactive.",
    noticeModePinned: "Đã chuyển mode auto-switch sang pinned.",
    noticeModeFailover: "Đã chuyển mode auto-switch sang failover.",
    noticeSwitchedAccount: "Đã chuyển sang {label}.",
    noticeRemovedAccount: "Đã xóa {label} khỏi Codex Auth Studio.",
    noticeWarmedAccount: "Đã cập nhật quota cho {label}.",
    noticeSavedOverride: "Đã lưu đường dẫn override cho codex-auth.",
    noticeClearedOverride: "Đã xóa đường dẫn override của codex-auth.",
    noticeOpenedLoginUrl: "Đã mở URL đăng nhập trong trình duyệt.",
    noticeCopiedLoginUrl: "Đã sao chép URL đăng nhập vào clipboard.",
    noticeDeviceLoginStarted: "Đã bắt đầu đăng nhập thiết bị.",
    noticeBrowserLoginStarted: "Đã bắt đầu đăng nhập bằng trình duyệt.",
    noticeLoginFinished: "Đăng nhập xong. Danh sách tài khoản đã được làm mới.",
    clipboardUnavailable: "Clipboard không khả dụng trong môi trường hiện tại.",
    eligibleHintMissing: "Chưa có tài khoản nào có dữ liệu quota mới.",
    eligibleHintThreshold:
      "Đã có snapshot mới, nhưng chưa tài khoản nào vượt ngưỡng hiện tại (5h < {five}%, weekly < {weekly}%).",
    eligibleHintActiveAlreadyBest:
      "Tài khoản hiện tại đã là lựa chọn đủ điều kiện duy nhất.",
    pinStateNone: "chưa pin",
    pinStateReady: "sẵn sàng",
    pinStateMissingSnapshot: "thiếu snapshot",
    pinStateOutOfSync: "lệch auth hiện tại",
    pinStateLow: "quota thấp",
    pinStateExhausted: "hết quota",
    failoverStateIdle: "rảnh",
    failoverStateProcessing: "đang xử lý",
    failoverStateSwitched: "đã chuyển",
    failoverStateNoTarget: "không có tài khoản đích",
    failoverStateStaleEvent: "sự kiện cũ",
    failoverStateError: "lỗi",
    language: "Ngôn ngữ",
    langVi: "VI",
    langEn: "EN",
    addAccountIsolated: "Thêm TK (Ẩn danh)",
    isolatedLogin: "ẩn danh",
    noticeIsolatedLoginStarted: "Đã bắt đầu đăng nhập ẩn danh (trình duyệt riêng biệt).",
    noticeIsolatedBrowserOpened: "Đã mở trình duyệt ẩn danh.",
    isolatedBrowserFailed: "Không thể mở trình duyệt ẩn danh: {error}",
    noBrowserFound: "Không tìm thấy trình duyệt hỗ trợ (Chromium hoặc Firefox).",
    cancelLogin: "Hủy",
    noticeCancelledLogin: "Đã hủy đăng nhập.",
    refreshTokenReusedDetected:
      "Refresh token đã bị dùng trước đó. Có thể thử phục hồi từ snapshot local, không cần logout/login lại.",
    recoverSnapshot: "Phục hồi snapshot",
    recover: "Phục hồi",
    recoveryAvailable: "có backup",
    markUnusable: "Bỏ qua account này",
    confirmRemoveAccount:
      "Xóa {label} khỏi Codex Auth Studio?\n\nThao tác này sẽ xóa account khỏi registry và xóa snapshot auth local của account đó. Nếu cần dùng lại, bạn phải đăng nhập/import lại.",
    noticeRecoveredAuth: "Đã phục hồi snapshot auth cho {label}.",
    noticeMarkedUnusable: "Đã tạm loại {label} khỏi auto-switch.",
    accountHealthReady: "dùng được",
    accountHealthReadyTitle: "Có thể chuyển sang account này",
    accountHealthActive: "đang dùng",
    accountHealthActiveTitle: "Account đang hoạt động",
    accountHealthNoAuth: "thiếu token",
    accountHealthNoAuthTitle: "Thiếu file auth snapshot",
    accountHealthNoAuthDetail: "Không thể chuyển sang account này cho tới khi phục hồi hoặc đăng nhập lại.",
    accountHealthQuarantined: "cách ly",
    accountHealthQuarantinedTitle: "Token bị cô lập",
    accountHealthQuarantinedDetail: "Snapshot auth bị lỗi đã được cách ly để tránh lặp lỗi refresh token.",
    accountHealthBlocked: "đã chặn",
    accountHealthBlockedTitle: "Đang bị loại khỏi auto-switch",
    accountHealthBlockedDetail: "Account này bị tạm bỏ qua để tránh lặp lỗi.",
    accountHealthNeedsWarm: "thiếu quota",
    accountHealthNeedsWarmTitle: "Thiếu dữ liệu quota mới",
    accountHealthUnknownSnapshotDetail: "Chưa có snapshot quota mới cho account này.",
    accountHealthStaleSnapshotDetail: "Snapshot quota đã cũ.",
    accountHealthLowQuota: "quota thấp",
    accountHealthLowQuotaTitle: "Không đạt ngưỡng auto-switch",
    accountHealthUnknown: "không rõ",
    accountHealthUnknownTitle: "Chưa xác định được trạng thái dùng",
    accountHealthUnknownDetail: "Chưa đủ dữ liệu để đánh giá quota.",
    accountHealthRemainingDetail: "Quota khả dụng khoảng {percent}%.",
    accountColumnAccount: "Account",
    accountColumnQuota: "Quota",
    accountColumnHealth: "Khả dụng",
    accountColumnMeta: "Dữ liệu",
    accountColumnActions: "Tác vụ",
    loginPhase: "bước",
    loginPhaseIdle: "chưa chạy",
    loginPhaseLaunching: "đang khởi chạy",
    loginPhaseWaitingForUrl: "đang chờ URL OAuth",
    loginPhaseBrowserOpen: "đã mở trình duyệt",
    loginPhaseWaitingForCallback: "đang chờ callback",
    loginPhaseImporting: "đang import account",
    loginPhaseSuccess: "thành công",
    loginPhaseFailed: "lỗi",
    loginPhaseCancelled: "đã hủy",
  },
  en: {
    noActiveAccount: "No active account",
    selectionUnavailable: "selection unavailable",
    version: "version",
    best: "best",
    refresh: "Refresh",
    refreshing: "Refreshing...",
    currentState: "Current State",
    thresholds: "thresholds",
    apiMode: "api mode",
    usageApiOn: "usage api on",
    usageApiOff: "local only",
    accountApiOn: "account api on",
    accountApiOff: "account api off",
    quickActions: "Quick Actions",
    switchBest: "Use Best",
    warmAll: "Refresh",
    addAccount: "Add Account",
    deviceLogin: "Device",
    autoSwitch: "Auto-switch",
    on: "On",
    off: "Off",
    mode: "Mode",
    reactive: "Reactive",
    proactive: "Proactive",
    pinned: "Pinned",
    failover: "Failover",
    accounts: "Accounts",
    showingAccounts: "Showing {shown} / {total} accounts",
    all: "All",
    active: "Active",
    eligible: "Eligible",
    fresh: "Fresh",
    stale: "Stale",
    unknown: "Unknown",
    search: "Search",
    searchPlaceholder: "email, alias, or plan",
    sort: "Sort",
    sortSmart: "Smart",
    sortRemaining: "Highest remaining",
    sortRecentUsage: "Recent usage",
    sortLabel: "Label A-Z",
    status: "Status",
    runtime: "Runtime",
    login: "Login",
    output: "Output",
    source: "source",
    resolvedPath: "resolved path",
    overridePath: "override path",
    savePath: "Save Path",
    clearOverride: "Clear Override",
    retryDetect: "Retry Detect",
    switch: "Use",
    removeAccount: "Remove account",
    warm: "Warm",
    record: "record",
    alias: "alias",
    usage: "usage",
    waitingLoginOutput: "Waiting for login output...",
    latestResult: "latest result",
    loadingRegistry: "Loading account registry...",
    noAccountsMatch: "No accounts match the current filter.",
    summaryActive: "active",
    summaryService: "service",
    summaryBestKnown: "best known quota",
    summaryPinnedAccount: "pinned account",
    summaryPinState: "pin state",
    summaryBlockedAccount: "blocked account",
    summaryFailoverState: "failover state",
    summarySnapshots: "snapshots",
    none: "none",
    snapshotsValue: "{fresh} fresh · {eligible} eligible",
    runtimeAvailable: "available",
    runtimeUnavailable: "unavailable",
    noBinaryResolved: "No working binary resolved",
    loginRunning: "running",
    loginDone: "done",
    loginFinished: "finished",
    browserAuth: "browser-auth",
    deviceAuth: "device-auth",
    openLoginUrl: "Open Login URL",
    copyLoginUrl: "Copy Login URL",
    dismiss: "Dismiss",
    noticeSwitchBest: "Switched to the account with the best known quota.",
    noticeWarmAll: "Warm-up finished.",
    noticeAutoEnable: "Auto-switch enabled.",
    noticeAutoDisable: "Auto-switch disabled.",
    noticeModeReactive: "Auto-switch mode set to reactive.",
    noticeModeProactive: "Auto-switch mode set to proactive.",
    noticeModePinned: "Auto-switch mode set to pinned.",
    noticeModeFailover: "Auto-switch mode set to failover.",
    noticeSwitchedAccount: "Switched to {label}.",
    noticeRemovedAccount: "Removed {label} from Codex Auth Studio.",
    noticeWarmedAccount: "Warmed {label}.",
    noticeSavedOverride: "Saved the codex-auth override path.",
    noticeClearedOverride: "Cleared the codex-auth override path.",
    noticeOpenedLoginUrl: "Opened the login URL in a browser.",
    noticeCopiedLoginUrl: "Copied the login URL to the clipboard.",
    noticeDeviceLoginStarted: "Device login started.",
    noticeBrowserLoginStarted: "Browser login started.",
    noticeLoginFinished: "Login finished. Account list refreshed.",
    clipboardUnavailable: "Clipboard access is unavailable in this environment.",
    eligibleHintMissing: "No account has fresh quota data yet.",
    eligibleHintThreshold:
      "Fresh snapshots exist, but none are above the current thresholds (5h < {five}%, weekly < {weekly}%).",
    eligibleHintActiveAlreadyBest:
      "The active account is already the only eligible candidate.",
    pinStateNone: "not pinned",
    pinStateReady: "ready",
    pinStateMissingSnapshot: "missing snapshot",
    pinStateOutOfSync: "out of sync",
    pinStateLow: "low quota",
    pinStateExhausted: "exhausted",
    failoverStateIdle: "idle",
    failoverStateProcessing: "processing",
    failoverStateSwitched: "switched",
    failoverStateNoTarget: "no target",
    failoverStateStaleEvent: "stale event",
    failoverStateError: "error",
    language: "Language",
    langVi: "VI",
    langEn: "EN",
    addAccountIsolated: "Add Account (Isolated)",
    isolatedLogin: "isolated",
    noticeIsolatedLoginStarted: "Isolated login started (separate browser profile).",
    noticeIsolatedBrowserOpened: "Opened isolated browser.",
    isolatedBrowserFailed: "Failed to open isolated browser: {error}",
    noBrowserFound: "No supported browser found (Chromium or Firefox).",
    cancelLogin: "Cancel",
    noticeCancelledLogin: "Login cancelled.",
    refreshTokenReusedDetected:
      "The refresh token was already used. Try restoring a local snapshot instead of logging out and signing in again.",
    recoverSnapshot: "Recover Snapshot",
    recover: "Recover",
    recoveryAvailable: "backup",
    markUnusable: "Skip this account",
    confirmRemoveAccount:
      "Remove {label} from Codex Auth Studio?\n\nThis removes the account from the registry and deletes its local auth snapshot. To use it again, you must sign in or import it again.",
    noticeRecoveredAuth: "Recovered auth snapshot for {label}.",
    noticeMarkedUnusable: "Temporarily excluded {label} from auto-switch.",
    accountHealthReady: "ready",
    accountHealthReadyTitle: "Can switch to this account",
    accountHealthActive: "active",
    accountHealthActiveTitle: "Currently active account",
    accountHealthNoAuth: "no token",
    accountHealthNoAuthTitle: "Missing auth snapshot file",
    accountHealthNoAuthDetail: "This account cannot be activated until it is recovered or signed in again.",
    accountHealthQuarantined: "quarantined",
    accountHealthQuarantinedTitle: "Token isolated",
    accountHealthQuarantinedDetail: "The bad auth snapshot was isolated to avoid repeated refresh-token failures.",
    accountHealthBlocked: "blocked",
    accountHealthBlockedTitle: "Excluded from auto-switch",
    accountHealthBlockedDetail: "This account is temporarily skipped to avoid repeated failures.",
    accountHealthNeedsWarm: "quota missing",
    accountHealthNeedsWarmTitle: "Fresh quota data is missing",
    accountHealthUnknownSnapshotDetail: "No fresh quota snapshot exists for this account yet.",
    accountHealthStaleSnapshotDetail: "Quota snapshot is stale.",
    accountHealthLowQuota: "low quota",
    accountHealthLowQuotaTitle: "Below auto-switch thresholds",
    accountHealthUnknown: "unknown",
    accountHealthUnknownTitle: "Usability is unknown",
    accountHealthUnknownDetail: "There is not enough data to judge quota.",
    accountHealthRemainingDetail: "Available quota is about {percent}%.",
    accountColumnAccount: "Account",
    accountColumnQuota: "Quota",
    accountColumnHealth: "Usability",
    accountColumnMeta: "Data",
    accountColumnActions: "Actions",
    loginPhase: "phase",
    loginPhaseIdle: "idle",
    loginPhaseLaunching: "launching",
    loginPhaseWaitingForUrl: "waiting for OAuth URL",
    loginPhaseBrowserOpen: "browser opened",
    loginPhaseWaitingForCallback: "waiting for callback",
    loginPhaseImporting: "importing account",
    loginPhaseSuccess: "success",
    loginPhaseFailed: "failed",
    loginPhaseCancelled: "cancelled",
  },
} as const;

export type Language = keyof typeof translations;
export type TranslationKey = keyof (typeof translations)["vi"];
export type TranslationVars = Record<string, string | number | null | undefined>;
export type MessageDescriptor = {
  key: TranslationKey;
  vars?: TranslationVars;
};

export type SummaryLike = {
  bestKnownLabel: string | null;
  bestKnownRemaining: number | null;
  eligibleHint: string | null;
  eligibleHintCode: string | null;
  threshold5hPercent: number;
  thresholdWeeklyPercent: number;
  autoSwitchMode?: string | null;
  pinnedAccountLabel?: string | null;
  pinState?: string | null;
  failoverState?: string | null;
  blockedAccountLabel?: string | null;
  blockedUntil?: string | null;
};

export type AccountLike = {
  label: string;
  email: string;
  alias: string;
  plan: string;
  accountName: string | null;
  isActive: boolean;
  freshness: "fresh" | "stale" | "unknown";
  eligible: boolean;
  usable: boolean;
  effectiveRemaining: number | null;
  lastUsedAt: number | null;
  lastUsageAt: number | null;
};

export type FilterScope = "all" | "active" | "eligible" | "fresh" | "stale" | "unknown";
export type SortMode = "smart" | "remaining" | "recent-usage" | "label";

export function translate(language: Language, key: TranslationKey, vars?: TranslationVars) {
  let text: string = translations[language][key];
  if (!vars) {
    return text;
  }
  for (const [name, value] of Object.entries(vars)) {
    text = text.split(`{${name}}`).join(value == null ? "" : String(value));
  }
  return text;
}

export function resolveMessageText(
  language: Language,
  raw: string,
  descriptor: MessageDescriptor | null,
) {
  if (descriptor) {
    return translate(language, descriptor.key, descriptor.vars);
  }
  return raw;
}

export function summaryEligibleHint(language: Language, summary: SummaryLike | null | undefined) {
  if (!summary?.eligibleHintCode) {
    return summary?.eligibleHint ?? null;
  }
  switch (summary.eligibleHintCode) {
    case "missing-fresh-local-snapshot":
      return translate(language, "eligibleHintMissing");
    case "below-threshold":
      return translate(language, "eligibleHintThreshold", {
        five: summary.threshold5hPercent,
        weekly: summary.thresholdWeeklyPercent,
      });
    case "active-already-best":
      return translate(language, "eligibleHintActiveAlreadyBest");
    default:
      return summary.eligibleHint ?? null;
  }
}

export function freshnessLabel(
  language: Language,
  freshness: AccountLike["freshness"],
) {
  switch (freshness) {
    case "fresh":
      return translate(language, "fresh");
    case "stale":
      return translate(language, "stale");
    case "unknown":
      return translate(language, "unknown");
    default:
      return freshness;
  }
}

export function serviceLabel(language: Language, value: string | null) {
  if (!value) {
    return translate(language, "unknown");
  }
  if (value === "running") {
    return language === "vi" ? "đang chạy" : "running";
  }
  return value;
}

export function compactBestLabel(
  language: Language,
  summary: SummaryLike | null | undefined,
) {
  if (!summary?.bestKnownLabel || summary.bestKnownRemaining === null) {
    return translate(language, "none");
  }
  return `${summary.bestKnownLabel} · ${Math.round(summary.bestKnownRemaining)}%`;
}

export function pinStateLabel(language: Language, pinState: string | null | undefined) {
  switch (pinState) {
    case "none":
      return translate(language, "pinStateNone");
    case "ready":
      return translate(language, "pinStateReady");
    case "missing-snapshot":
      return translate(language, "pinStateMissingSnapshot");
    case "out-of-sync":
      return translate(language, "pinStateOutOfSync");
    case "low":
      return translate(language, "pinStateLow");
    case "exhausted":
      return translate(language, "pinStateExhausted");
    default:
      return pinState ?? translate(language, "none");
  }
}

export function failoverStateLabel(language: Language, state: string | null | undefined) {
  switch (state) {
    case "idle":
      return translate(language, "failoverStateIdle");
    case "processing":
      return translate(language, "failoverStateProcessing");
    case "switched":
      return translate(language, "failoverStateSwitched");
    case "no-target":
    case "no_target":
      return translate(language, "failoverStateNoTarget");
    case "stale-event":
    case "stale_event":
      return translate(language, "failoverStateStaleEvent");
    case "error":
      return translate(language, "failoverStateError");
    default:
      return state ?? translate(language, "none");
  }
}

export function filterAccountsByQuery<T extends AccountLike>(accounts: T[], filter: string) {
  const query = filter.trim().toLowerCase();
  if (!query) {
    return accounts;
  }
  return accounts.filter((account) =>
    [
      account.label,
      account.email,
      account.alias,
      account.plan,
      account.accountName ?? "",
    ]
      .join(" ")
      .toLowerCase()
      .includes(query),
  );
}

export function filterAccountsByScope<T extends AccountLike>(accounts: T[], scope: FilterScope) {
  switch (scope) {
    case "all":
      return accounts;
    case "active":
      return accounts.filter((account) => account.isActive);
    case "eligible":
      return accounts.filter((account) => account.eligible);
    case "fresh":
      return accounts.filter((account) => account.freshness === "fresh");
    case "stale":
      return accounts.filter((account) => account.freshness === "stale");
    case "unknown":
      return accounts.filter((account) => account.freshness === "unknown");
    default:
      return accounts;
  }
}

export function sortAccounts<T extends AccountLike>(accounts: T[], mode: SortMode) {
  if (mode === "smart") {
    return accounts;
  }

  const next = [...accounts];
  next.sort((left, right) => {
    switch (mode) {
      case "remaining":
        return (
          compareBoolean(right.usable, left.usable) ||
          compareOptionalNumber(right.effectiveRemaining, left.effectiveRemaining) ||
          left.label.localeCompare(right.label)
        );
      case "recent-usage":
        return (
          compareBoolean(right.usable, left.usable) ||
          compareOptionalNumber(right.lastUsageAt, left.lastUsageAt) ||
          compareOptionalNumber(right.lastUsedAt, left.lastUsedAt) ||
          left.label.localeCompare(right.label)
        );
      case "label":
        return left.label.localeCompare(right.label);
      default:
        return 0;
    }
  });
  return next;
}

function compareOptionalNumber(left: number | null, right: number | null) {
  if (left === right) {
    return 0;
  }
  if (left === null) {
    return -1;
  }
  if (right === null) {
    return 1;
  }
  return left - right;
}

function compareBoolean(left: boolean, right: boolean) {
  if (left === right) {
    return 0;
  }
  return left ? 1 : -1;
}
