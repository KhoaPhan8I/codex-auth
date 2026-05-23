import { invoke } from "@tauri-apps/api/core";
import { openUrl } from "@tauri-apps/plugin-opener";
import {
  filterAccountsByQuery as filterAccountsByQueryHelper,
  filterAccountsByScope as filterAccountsByScopeHelper,
  resolveMessageText as resolveMessageTextForLanguage,
  serviceLabel as serviceLabelForLanguage,
  sortAccounts as sortAccountsHelper,
  translate,
  type TranslationKey,
} from "./ui_logic";

type DashboardPayload = {
  version: string | null;
  versionError: string | null;
  refreshIntervalSeconds: number;
  cliRuntime: CliRuntimeView;
  summary: SummaryView;
  status: StatusView;
  accounts: AccountView[];
  warnings: string[];
  login: LoginSnapshot;
  action: ActionSnapshot;
  quotaConfirm: QuotaConfirmSnapshot;
  authRecovery: AuthRecoverySnapshot;
};

type SummaryView = {
  activeLabel: string | null;
  totalAccounts: number;
  freshAccounts: number;
  staleAccounts: number;
  unknownAccounts: number;
  eligibleAccounts: number;
  bestKnownLabel: string | null;
  bestKnownRemaining: number | null;
  eligibleHint: string | null;
  eligibleHintCode: string | null;
  autoSwitchEnabled: boolean;
  autoSwitchMode: string;
  pinnedAccountLabel: string | null;
  pinState: string | null;
  failoverState: string | null;
  blockedAccountLabel: string | null;
  blockedUntil: string | null;
  threshold5hPercent: number;
  thresholdWeeklyPercent: number;
  usageApiEnabled: boolean;
  accountApiEnabled: boolean;
};

type StatusView = {
  pairs: StatusPair[];
  service: string | null;
  usage: string | null;
  accountApi: string | null;
  activeAuth: string | null;
  activeAccount: string | null;
  activeAccountKey: string | null;
  selection: string | null;
  pinnedAccount: string | null;
  pinState: string | null;
  failoverState: string | null;
  blockedAccount: string | null;
  blockedUntil: string | null;
  snapshotSource: string | null;
  knownSnapshots: string | null;
  eligibleCandidates: string | null;
  registryActive: string | null;
  commandError: string | null;
};

type StatusPair = {
  key: string;
  value: string;
};

type CliRuntimeView = {
  available: boolean;
  resolvedPath: string | null;
  resolutionSource: string | null;
  overridePath: string | null;
  error: string | null;
};

type AccountView = {
  key: string;
  label: string;
  email: string;
  alias: string;
  accountName: string | null;
  recordHint: string;
  recordTitle: string;
  plan: string;
  authMode: string;
  isActive: boolean;
  freshness: "fresh" | "stale" | "unknown";
  eligible: boolean;
  blocked: boolean;
  authAvailable: boolean;
  authHealth: string;
  usable: boolean;
  recoverable: boolean;
  quarantined: boolean;
  quarantineReason: string | null;
  lastAuthError: string | null;
  quotaSource: "api-confirmed" | "api-unavailable" | "local-snapshot" | "unknown";
  quotaConfirmedAt: number | null;
  quotaConfirmedRelative: string | null;
  quotaConfirmStatusCode: number | null;
  quotaConfirmError: string | null;
  effectiveRemaining: number | null;
  fiveHour: QuotaWindowView | null;
  weekly: QuotaWindowView | null;
  lastUsedAt: number | null;
  lastUsageAt: number | null;
  lastUsedRelative: string | null;
  lastUsageRelative: string | null;
};

type QuotaWindowView = {
  remainingPercent: number;
  resetsAtLabel: string | null;
};

type LoginSnapshot = {
  running: boolean;
  finished: boolean;
  success: boolean;
  deviceAuth: boolean;
  isolated: boolean;
  output: string;
  loginUrl: string | null;
  isolatedSessionId: string | null;
  startedAt: string | null;
  finishedAt: string | null;
  exitCode: number | null;
  error: string | null;
  cancelled: boolean;
  refreshTokenReused: boolean;
  phase: string;
  browserUrlOpened: boolean;
  importStarted: boolean;
  importFinished: boolean;
  diagnostic: string | null;
};

type ActionResult = {
  command: string;
  output: string;
};

type ActionSnapshot = {
  running: boolean;
  finished: boolean;
  success: boolean;
  command: string | null;
  output: string;
  startedAt: string | null;
  finishedAt: string | null;
  exitCode: number | null;
  error: string | null;
  refreshTokenReused: boolean;
};

type QuotaConfirmSnapshot = {
  running: boolean;
  finished: boolean;
  success: boolean;
  scope: string | null;
  output: string;
  startedAt: string | null;
  finishedAt: string | null;
  checkedAccounts: number;
  totalAccounts: number;
  error: string | null;
};

type AuthRecoverySnapshot = {
  refreshTokenReused: boolean;
  activeAccountKey: string | null;
  activeAccount: AuthRecoveryAccountView | null;
  accounts: AuthRecoveryAccountView[];
};

type AuthRecoveryAccountView = {
  accountKey: string;
  label: string;
  email: string;
  isActive: boolean;
  candidateCount: number;
  bestCandidateId: string | null;
  bestSource: string | null;
  bestLastRefresh: string | null;
  bestModifiedAt: number | null;
};

type MessageDescriptor = {
  key: TranslationKey;
  vars?: Record<string, string | number | null | undefined>;
};

type FilterScope = "all" | "active" | "eligible" | "fresh" | "stale" | "unknown";
type SortMode = "smart" | "remaining" | "recent-usage" | "label";
type Language = "vi" | "en";

const LOCAL_ACTIONS = new Set(["set-scope", "open-login-url", "copy-login-url", "cancel-login"]);
const LANGUAGE_STORAGE_KEY = "codex-auth-desktop-language";
const ACCOUNT_SCROLL_SELECTOR = ".account-grid-compact";

const state = {
  dashboard: null as DashboardPayload | null,
  loading: true,
  busy: false,
  error: "",
  errorDescriptor: null as MessageDescriptor | null,
  errorSource: null as "dashboard" | "general" | null,
  notice: "",
  noticeDescriptor: null as MessageDescriptor | null,
  consoleText: "",
  pendingActionNotice: null as MessageDescriptor | null,
  pendingActionRevision: 0,
  messageRevision: 0,
  filter: "",
  scope: "all" as FilterScope,
  sortMode: "smart" as SortMode,
  cliOverrideInput: "",
  cliOverrideDirty: false,
  language: loadLanguage(),
};

const INVOKE_TIMEOUT_MS = 30000;
const MAX_CASCADE_DEPTH = 3;

let loginPollTimer: number | null = null;
let actionPollTimer: number | null = null;
let quotaPollTimer: number | null = null;
let dashboardRefreshTimer: number | null = null;
let dashboardRequestInFlight = false;
let queuedDashboardSilent: boolean | null = null;
let dashboardRequestSeq = 0;
let dashboardAppliedSeq = 0;
let dashboardRequestCascadeDepth = 0;
let quotaPollInFlight = false;
let renderGuardHash: string | null = null;

type FocusSnapshot = {
  id: string;
  selectionStart: number | null;
  selectionEnd: number | null;
};

type ScrollSnapshot = {
  windowX: number;
  windowY: number;
  accountGridTop: number | null;
  accountGridLeft: number | null;
};

class LocalizedUiError extends Error {
  key: TranslationKey;
  vars?: Record<string, string | number | null | undefined>;

  constructor(key: TranslationKey, vars?: Record<string, string | number | null | undefined>) {
    super(key);
    this.name = "LocalizedUiError";
    Object.setPrototypeOf(this, LocalizedUiError.prototype);
    this.key = key;
    this.vars = vars;
  }
}

window.addEventListener("DOMContentLoaded", () => {
  applyLanguage();
  bindEvents();
  syncDashboardRefresh();
  void requestDashboard();
});

window.addEventListener("beforeunload", () => {
  if (loginPollTimer !== null) {
    window.clearInterval(loginPollTimer);
    loginPollTimer = null;
  }
  if (actionPollTimer !== null) {
    window.clearInterval(actionPollTimer);
    actionPollTimer = null;
  }
  if (quotaPollTimer !== null) {
    window.clearInterval(quotaPollTimer);
    quotaPollTimer = null;
  }
  if (dashboardRefreshTimer !== null) {
    window.clearInterval(dashboardRefreshTimer);
    dashboardRefreshTimer = null;
  }
});

function bindEvents() {
  document.addEventListener("click", (event) => {
    const target = (event.target as HTMLElement).closest("[data-action]") as
      | HTMLElement
      | null;
    if (!target) {
      return;
    }

    const action = target.dataset.action;
    if (!action) {
      return;
    }

    if (isUiLocked() && !LOCAL_ACTIONS.has(action)) {
      return;
    }
    void handleAction(action, target);
  });

  document.addEventListener("input", (event) => {
    const input = event.target as HTMLInputElement | null;
    if (!input) {
      return;
    }
    if (input.id === "account-filter") {
      state.filter = input.value;
      render();
      return;
    }
    if (input.id === "cli-override-path") {
      state.cliOverrideInput = input.value;
      state.cliOverrideDirty = true;
      render();
    }
  });

  document.addEventListener("change", (event) => {
    const select = event.target as HTMLSelectElement | null;
    if (!select) {
      return;
    }
    if (select.id === "account-sort") {
      state.sortMode = select.value as SortMode;
      render();
      return;
    }
    if (select.id === "app-language") {
      setLanguage(select.value as Language);
    }
  });

  document.addEventListener("visibilitychange", () => {
    syncDashboardRefresh();
  });

  window.addEventListener("focus", () => {
    if (!loginRunning() && !actionRunning() && !state.busy) {
      void requestDashboard(true);
    }
  });
}

function loadLanguage(): Language {
  try {
    const stored = window.localStorage.getItem(LANGUAGE_STORAGE_KEY);
    return stored === "en" ? "en" : "vi";
  } catch {
    return "vi";
  }
}

function setLanguage(language: Language) {
  state.language = language === "en" ? "en" : "vi";
  try {
    window.localStorage.setItem(LANGUAGE_STORAGE_KEY, state.language);
  } catch {
    // Ignore storage failures and continue with in-memory language state.
  }
  applyLanguage();
  render();
}

function applyLanguage() {
  document.documentElement.lang = state.language === "vi" ? "vi" : "en";
}

function t(key: TranslationKey, vars?: Record<string, string | number | null | undefined>) {
  return translate(state.language, key, vars);
}

function resolveMessageText(raw: string, descriptor: MessageDescriptor | null) {
  return resolveMessageTextForLanguage(state.language, raw, descriptor);
}

function setNoticeDescriptor(key: TranslationKey, vars?: Record<string, string | number | null | undefined>) {
  state.noticeDescriptor = { key, vars };
  state.notice = "";
}

function setErrorDescriptor(
  key: TranslationKey,
  vars?: Record<string, string | number | null | undefined>,
  source: "dashboard" | "general" = "general",
) {
  state.errorDescriptor = { key, vars };
  state.error = "";
  state.errorSource = source;
}

function setErrorRaw(message: string, source: "dashboard" | "general" = "general") {
  state.error = message;
  state.errorDescriptor = null;
  state.errorSource = message ? source : null;
}

function clearMessages() {
  state.notice = "";
  state.noticeDescriptor = null;
  state.error = "";
  state.errorDescriptor = null;
  state.errorSource = null;
}

function setErrorFromUnknown(error: unknown, source: "dashboard" | "general" = "general") {
  if (error instanceof LocalizedUiError) {
    setErrorDescriptor(error.key, error.vars, source);
    return;
  }
  setErrorRaw(asMessage(error), source);
}

function serviceLabel(value: string | null) {
  return serviceLabelForLanguage(state.language, value);
}

async function handleAction(action: string, target: HTMLElement) {
  switch (action) {
    case "refresh":
      await maybeStartQuotaConfirmationAll();
      await requestDashboard();
      return;
    case "switch-account":
      await performImmediateAction(
        "switch_account_now",
        { accountKey: target.dataset.accountKey ?? "" },
        { key: "noticeSwitchedAccount", vars: { label: target.dataset.label ?? t("none") } },
      );
      return;
    case "remove-account": {
      const label = target.dataset.label ?? t("none");
      if (!window.confirm(t("confirmRemoveAccount", { label }))) {
        return;
      }
      await performImmediateAction(
        "remove_account",
        { accountKey: target.dataset.accountKey ?? "" },
        { key: "noticeRemovedAccount", vars: { label } },
      );
      return;
    }
    case "recover-account-auth":
      if (await performImmediateAction(
        "recover_account_auth",
        {
          accountKey: target.dataset.accountKey ?? "",
          candidateId: target.dataset.candidateId ?? "",
        },
        { key: "noticeRecoveredAuth", vars: { label: target.dataset.label ?? t("none") } },
      )) {
        setErrorRaw("");
      }
      return;
    case "mark-account-unusable":
      await performImmediateAction(
        "mark_account_unusable",
        {
          accountKey: target.dataset.accountKey ?? "",
          reason: "refresh-token-reused",
        },
        { key: "noticeMarkedUnusable", vars: { label: target.dataset.label ?? t("none") } },
      );
      return;
    case "login-browser":
      await startLogin(false);
      return;
    case "cancel-login":
      cancelLogin();
      return;
    case "dismiss-login":
      await dismissLogin();
      return;
    case "set-scope":
      state.scope = (target.dataset.scope as FilterScope) ?? "all";
      render();
      return;
    case "save-cli-override":
      if (await performImmediateAction(
        "set_cli_override",
        { path: state.cliOverrideInput },
        { key: "noticeSavedOverride" },
      )) {
        state.cliOverrideDirty = false;
      }
      return;
    case "clear-cli-override":
      if (await performImmediateAction(
        "clear_cli_override",
        {},
        { key: "noticeClearedOverride" },
      )) {
        state.cliOverrideDirty = false;
        state.cliOverrideInput = "";
      }
      return;
    case "retry-cli-runtime":
      await requestDashboard();
      return;
    case "open-login-url":
      if (state.dashboard?.login.loginUrl) {
        try {
          if (state.dashboard.login.isolated && state.dashboard.login.isolatedSessionId) {
            await invoke("open_isolated_browser_for_session", {
              url: state.dashboard.login.loginUrl,
              sessionId: state.dashboard.login.isolatedSessionId,
            });
          } else {
            await openUrl(state.dashboard.login.loginUrl);
          }
          setNoticeDescriptor("noticeOpenedLoginUrl");
          setErrorRaw("");
          render();
        } catch (error) {
          setErrorFromUnknown(error);
          render();
        }
      }
      return;
    case "copy-login-url":
      if (state.dashboard?.login.loginUrl) {
        try {
          await copyText(state.dashboard.login.loginUrl);
          setNoticeDescriptor("noticeCopiedLoginUrl");
          setErrorRaw("");
          render();
        } catch (error) {
          setErrorFromUnknown(error);
          render();
        }
      }
      return;
    default:
      return;
  }
}

function invokeWithTimeout<T>(command: string, args?: Record<string, unknown>, ms = INVOKE_TIMEOUT_MS): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => {
      reject(new Error(`Invoke "${command}" timed out after ${ms}ms`));
    }, ms);
    invoke<T>(command, args)
      .then((result) => {
        clearTimeout(timer);
        resolve(result);
      })
      .catch((err) => {
        clearTimeout(timer);
        reject(err);
      });
  });
}

async function requestDashboard(silent = false) {
  if (dashboardRequestInFlight) {
    if (queuedDashboardSilent === null) {
      queuedDashboardSilent = silent;
      dashboardRequestCascadeDepth = 0;
    }
    return;
  }

  await runDashboardRequest(silent);
}

async function runDashboardRequest(silent = false) {
  if (dashboardRequestCascadeDepth >= MAX_CASCADE_DEPTH) {
    dashboardRequestCascadeDepth = 0;
    queuedDashboardSilent = null;
    dashboardRequestInFlight = false;
    return;
  }

  dashboardRequestInFlight = true;
  const requestSeq = ++dashboardRequestSeq;

  if (!silent) {
    state.loading = true;
    setErrorRaw("");
    render();
  }

  try {
    const dashboard = await invokeWithTimeout<DashboardPayload>("get_dashboard");
    if (requestSeq < dashboardAppliedSeq) {
      return;
    }
    dashboardAppliedSeq = requestSeq;
    if (state.errorSource === "dashboard") {
      setErrorRaw("");
    }
    applyDashboard(dashboard);
    syncActionPolling();
    syncQuotaPolling();
    if (!state.consoleText && dashboard.versionError) {
      state.consoleText = dashboard.versionError;
    }
  } catch (error) {
    if (!silent || !state.dashboard) {
      setErrorFromUnknown(error, "dashboard");
    }
  } finally {
    state.loading = false;
    syncLoginPolling();
    syncActionPolling();
    syncQuotaPolling();
    syncDashboardRefresh();
    render();
    dashboardRequestInFlight = false;
    if (queuedDashboardSilent !== null) {
      const nextSilent = queuedDashboardSilent;
      queuedDashboardSilent = null;
      dashboardRequestCascadeDepth++;
      void runDashboardRequest(nextSilent);
    } else {
      dashboardRequestCascadeDepth = 0;
    }
  }
}

function applyDashboard(dashboard: DashboardPayload) {
  state.dashboard = dashboard;
  if (!state.cliOverrideDirty) {
    state.cliOverrideInput = dashboard.cliRuntime.overridePath ?? "";
  }
}

async function maybeStartQuotaConfirmationAll() {
  if (!state.dashboard?.summary.usageApiEnabled || state.dashboard.quotaConfirm.running) {
    return;
  }

  try {
    const quotaConfirm = await invoke<QuotaConfirmSnapshot>("refresh_quota_confirmations");
    if (state.dashboard) {
      state.dashboard.quotaConfirm = quotaConfirm;
    }
    syncQuotaPolling();
    render();
  } catch (error) {
    setErrorFromUnknown(error);
    render();
  }
}

async function performImmediateAction(
  command: string,
  payload: Record<string, unknown>,
  notice: MessageDescriptor,
): Promise<boolean> {
  state.busy = true;
  state.messageRevision += 1;
  clearMessages();
  render();

  try {
    const result = await invoke<ActionResult>(command, payload);
    setNoticeDescriptor(notice.key, notice.vars);
    state.consoleText = `$ ${result.command}\n${result.output}`.trim();
    await requestDashboard(true);
    return true;
  } catch (error) {
    setErrorFromUnknown(error);
    state.consoleText = resolveMessageText(state.error, state.errorDescriptor);
    return false;
  } finally {
    state.busy = false;
    render();
  }
}

async function startLogin(deviceAuth: boolean, isolated: boolean = false) {
  state.busy = true;
  state.messageRevision += 1;
  clearMessages();
  render();

  try {
    const login = await invoke<LoginSnapshot>("start_login", { deviceAuth, isolated });
    if (state.dashboard) {
      state.dashboard.login = login;
    }
    if (isolated) {
      setNoticeDescriptor("noticeIsolatedLoginStarted");
    } else if (deviceAuth) {
      setNoticeDescriptor("noticeDeviceLoginStarted");
    } else {
      setNoticeDescriptor("noticeBrowserLoginStarted");
    }
    syncLoginPolling();
  } catch (error) {
    setErrorFromUnknown(error);
  } finally {
    state.busy = false;
    syncDashboardRefresh();
    syncActionPolling();
    render();
  }
}

async function dismissLogin() {
  state.busy = true;
  render();
  try {
    const sessionId = state.dashboard?.login.isolatedSessionId ?? null;
    // Retry clear_login_state until the backend acknowledges.
    // The background thread finishes within ~200ms of cancellation,
    // so a few retries (up to 3s) is more than sufficient.
    let cleared = false;
    for (let i = 0; i < 30; i++) {
      try {
        const login = await invoke<LoginSnapshot>("clear_login_state");
        if (state.dashboard) {
          state.dashboard.login = login;
        }
        cleared = true;
        break;
      } catch {
        await new Promise((r) => setTimeout(r, 100));
      }
    }
    if (!cleared && state.dashboard) {
      // Final fallback: clear frontend state optimistically.
      state.dashboard.login = {
        running: false, finished: false, success: false, deviceAuth: false,
        isolated: false, output: "", loginUrl: null, isolatedSessionId: null,
        startedAt: null, finishedAt: null, exitCode: null, error: null,
        cancelled: false, refreshTokenReused: false, phase: "",
        browserUrlOpened: false, importStarted: false, importFinished: false,
        diagnostic: null,
      };
    }
    if (sessionId) {
      try {
        await invoke("cleanup_isolated_session", { sessionId });
      } catch {
        // Best-effort cleanup; ignore errors.
      }
    }
  } catch (error) {
    setErrorFromUnknown(error);
  } finally {
    state.busy = false;
    syncLoginPolling();
    syncDashboardRefresh();
    render();
  }
}

async function cancelLogin() {
  state.busy = true;
  render();
  // Truly fire-and-forget: the Rust cancel_login spawns a watchdog thread
  // so the IPC channel stays responsive for dismiss/dashboard calls.
  invoke<LoginSnapshot>("cancel_login").catch(() => {});
  // Immediately update frontend state so the user sees instant feedback.
  if (state.dashboard) {
    state.dashboard.login = {
      ...state.dashboard.login,
      running: false,
      finished: true,
      cancelled: true,
      phase: "cancelled",
      output: (state.dashboard.login?.output ?? "") + "\nLogin cancelled.",
    };
  }
  syncLoginPolling();
  setNoticeDescriptor("noticeCancelledLogin");
  state.busy = false;
  syncDashboardRefresh();
  render();
}

function syncLoginPolling() {
  const running = state.dashboard?.login.running ?? false;
  if (running && loginPollTimer === null) {
    loginPollTimer = window.setInterval(() => {
      void refreshLoginState();
    }, 1500);
    return;
  }
  if (!running && loginPollTimer !== null) {
    window.clearInterval(loginPollTimer);
    loginPollTimer = null;
  }
}

function syncActionPolling() {
  const running = actionRunning();
  if (running && actionPollTimer === null) {
    actionPollTimer = window.setInterval(() => {
      void refreshActionState();
    }, 750);
    return;
  }
  if (!running && actionPollTimer !== null) {
    window.clearInterval(actionPollTimer);
    actionPollTimer = null;
  }
}

function syncQuotaPolling() {
  const running = state.dashboard?.quotaConfirm.running ?? false;
  if (running && quotaPollTimer === null) {
    quotaPollTimer = window.setInterval(() => {
      void refreshQuotaConfirmState();
    }, 1500);
    return;
  }
  if (!running && quotaPollTimer !== null) {
    window.clearInterval(quotaPollTimer);
    quotaPollTimer = null;
  }
}

async function refreshQuotaConfirmState() {
  if (!state.dashboard || quotaPollInFlight) {
    return;
  }

  quotaPollInFlight = true;
  const wasRunning = state.dashboard.quotaConfirm.running;
  try {
    const next = await invokeWithTimeout<QuotaConfirmSnapshot>("get_quota_confirm_state", undefined, 15000);
    if (!state.dashboard) {
      return;
    }
    state.dashboard.quotaConfirm = next;
    if (wasRunning && !next.running) {
      await requestDashboard(true);
    } else {
      render();
    }
  } catch (error) {
    setErrorFromUnknown(error);
    render();
  } finally {
    quotaPollInFlight = false;
    syncQuotaPolling();
    syncDashboardRefresh();
  }
}

function syncDashboardRefresh() {
  if (document.hidden || loginRunning() || actionRunning()) {
    if (dashboardRefreshTimer !== null) {
      window.clearInterval(dashboardRefreshTimer);
      dashboardRefreshTimer = null;
    }
    return;
  }

  const intervalMs = (state.dashboard?.refreshIntervalSeconds ?? 10) * 1000;
  if (dashboardRefreshTimer === null) {
    dashboardRefreshTimer = window.setInterval(() => {
      void refreshDashboardTick();
    }, intervalMs);
  }
}

async function refreshDashboardTick() {
  if (state.busy || state.loading || loginRunning() || actionRunning()) {
    return;
  }
  await requestDashboard(true);
}

async function refreshActionState() {
  if (!state.dashboard) {
    return;
  }

  const messageRevision = state.pendingActionRevision;
  try {
    const next = await invokeWithTimeout<ActionSnapshot>("get_action_state", undefined, 15000);
    state.dashboard.action = next;
    if (messageRevision === state.messageRevision) {
      state.consoleText = next.output.trim();
    }

    if (next.finished) {
      await completeActionFromSnapshot(next, messageRevision);
    } else {
      render();
    }
  } catch (error) {
    if (messageRevision === state.messageRevision) {
      setErrorFromUnknown(error);
      render();
    }
  } finally {
    syncActionPolling();
    syncDashboardRefresh();
  }
}

async function completeActionFromSnapshot(action: ActionSnapshot, messageRevision: number) {
  if (state.dashboard) {
    state.dashboard.action = action;
  }

  const ownsMessage = messageRevision === state.messageRevision;
  if (ownsMessage) {
    state.consoleText = action.output.trim();
    if (action.success && state.pendingActionNotice) {
      setNoticeDescriptor(state.pendingActionNotice.key, state.pendingActionNotice.vars);
    } else if (action.refreshTokenReused) {
      setErrorDescriptor("refreshTokenReusedDetected");
    } else if (!action.success) {
      setErrorRaw(action.error ?? "Command failed.");
    }
  }
  state.pendingActionNotice = null;
  state.pendingActionRevision = 0;
  await requestDashboard(true);
}

async function refreshLoginState() {
  if (!state.dashboard) {
    return;
  }

  const messageRevision = state.messageRevision;
  try {
    const next = await invokeWithTimeout<LoginSnapshot>("get_login_state", undefined, 15000);
    const wasRunning = state.dashboard.login.running;
    state.dashboard.login = next;

    if (wasRunning && !next.running) {
      if (messageRevision === state.messageRevision) {
        state.consoleText = next.output.trim();
        if (next.success) {
          setNoticeDescriptor("noticeLoginFinished");
        } else if (next.cancelled) {
          setNoticeDescriptor("noticeCancelledLogin");
        } else if (next.refreshTokenReused) {
          setErrorDescriptor("refreshTokenReusedDetected");
        } else if (next.error) {
          setErrorRaw(next.error);
        }
      }
      if (next.isolated && next.isolatedSessionId) {
        void invoke("cleanup_isolated_session", { sessionId: next.isolatedSessionId }).catch(() => {});
      }
      await requestDashboard(true);
    } else {
      render();
    }
  } catch (error) {
    if (messageRevision === state.messageRevision) {
      setErrorFromUnknown(error);
      render();
    }
  } finally {
    syncLoginPolling();
    syncDashboardRefresh();
  }
}

function render() {
  const root = document.querySelector("#app");
  if (!root) {
    return;
  }

  const guardParts = [
    JSON.stringify(state.dashboard?.accounts ?? null),
    state.dashboard?.summary.totalAccounts,
    state.dashboard?.version,
    state.filter,
    state.scope,
    state.sortMode,
    state.error,
    state.notice,
    state.loading,
    state.busy,
    state.language,
    state.dashboard?.status.service,
    state.dashboard?.status.activeAccount,
    state.dashboard?.summary.autoSwitchEnabled,
    state.dashboard?.summary.autoSwitchMode,
    state.dashboard?.login.running,
    state.dashboard?.login.finished,
    state.dashboard?.login.phase,
    state.dashboard?.login.loginUrl,
    state.dashboard?.login.output?.length,
    state.dashboard?.login.diagnostic,
  ];
  const guardHash = guardParts.join("|");
  if (guardHash === renderGuardHash) {
    return;
  }
  renderGuardHash = guardHash;

  const focusSnapshot = captureFocusSnapshot();
  const scrollSnapshot = captureScrollSnapshot();

  root.innerHTML = `
    <main class="shell shell-compact">
      <section class="topbar topbar-slim glass-panel">
        <div class="brand-lockup">
          <div class="brand-mark" aria-hidden="true">${icon("bolt")}</div>
          <div class="topbar-copy">
            <h1>Codex Auth Studio</h1>
            <p class="topbar-meta-line" title="${escapeAttribute(state.dashboard?.summary.activeLabel ?? t("noActiveAccount"))}">
              <span class="status-dot ${state.dashboard?.status.service === "running" ? "is-online" : ""}"></span>
              <strong class="topbar-active">${escapeHtml(state.dashboard?.summary.activeLabel ?? t("noActiveAccount"))}</strong>
              <span class="topbar-selection">${escapeHtml(state.dashboard?.summary.autoSwitchMode ?? state.dashboard?.status.selection ?? t("selectionUnavailable"))}</span>
            </p>
          </div>
        </div>
        <div class="topbar-actions">
          <label class="lang-select icon-select" title="${escapeAttribute(t("language"))}">
            ${icon("globe")}
            <select id="app-language" aria-label="${escapeAttribute(t("language"))}">
              <option value="vi" ${state.language === "vi" ? "selected" : ""}>${escapeHtml(t("langVi"))}</option>
              <option value="en" ${state.language === "en" ? "selected" : ""}>${escapeHtml(t("langEn"))}</option>
            </select>
          </label>
          <details class="version-popover">
            <summary class="icon-button ghost-button" title="${escapeAttribute(t("version"))}">
              ${icon("info")}
            </summary>
            <div class="mini-popover">
            <span>${escapeHtml(t("version"))}</span>
            <strong>${escapeHtml(state.dashboard?.version ?? t("unknown"))}</strong>
            </div>
          </details>
          <button class="icon-button ghost-button" data-action="refresh" title="${escapeAttribute(t("refresh"))}" ${
            isRefreshDisabled()
          }>
            ${icon("refresh")}
            <span>${state.loading ? escapeHtml(t("refreshing")) : escapeHtml(t("refresh"))}</span>
          </button>
        </div>
      </section>

      ${renderMessages()}

      <section class="panel control-panel hero-panel">
        <div class="hero-layout">
          <div class="hero-focus">
            <p class="panel-title">${escapeHtml(t("currentState"))}</p>
            <h2>${escapeHtml(state.dashboard?.summary.activeLabel ?? t("noActiveAccount"))}</h2>
            <p class="hero-subline">${escapeHtml(state.dashboard?.status.selection ?? t("selectionUnavailable"))}</p>
          </div>
          <div class="quick-toolbar">
            <button class="ghost-button" data-action="login-browser" ${isCliActionDisabled()}>
              ${icon("plus")}
              <span>${escapeHtml(t("addAccount"))}</span>
            </button>
          </div>
        </div>

        ${renderSummaryCards()}
      </section>

      <section class="panel account-panel">
        <div class="account-toolbar">
          <div class="toolbar-copy">
            <p class="panel-title">${icon("users")}${escapeHtml(t("accounts"))}</p>
            <p class="account-count">
              ${escapeHtml(
                t("showingAccounts", {
                  shown: renderedAccounts().length,
                  total: state.dashboard?.summary.totalAccounts ?? 0,
                }),
              )}
            </p>
          </div>
          <div class="toolbar-controls">
            <div class="chip-row scope-row">
              ${renderScopeChip("all", t("all"))}
              ${renderScopeChip("active", t("active"))}
              ${renderScopeChip("eligible", t("eligible"))}
            </div>
            <label class="search compact-field">
              ${icon("search")}
              <input id="account-filter" value="${escapeHtml(state.filter)}" placeholder="${escapeAttribute(t("searchPlaceholder"))}" />
            </label>
            <label class="sort compact-field">
              ${icon("sort")}
              <select id="account-sort">
                ${renderSortOption("smart", t("sortSmart"))}
                ${renderSortOption("remaining", t("sortRemaining"))}
                ${renderSortOption("recent-usage", t("sortRecentUsage"))}
                ${renderSortOption("label", t("sortLabel"))}
              </select>
            </label>
          </div>
        </div>
        <div class="account-grid account-grid-compact">
          ${renderAccounts()}
        </div>
      </section>

      ${renderUtilityPanels()}
    </main>
    ${renderLoginModal()}
  `;

  restoreFocusSnapshot(focusSnapshot);
  restoreScrollSnapshot(scrollSnapshot);
}

function renderMessages() {
  const warnings = state.dashboard?.warnings ?? [];
  const blocks = [];
  const errorText = resolveMessageText(state.error, state.errorDescriptor);
  const noticeText = resolveMessageText(state.notice, state.noticeDescriptor);

  if (errorText) {
    blocks.push(`<div class="message message-error">${escapeHtml(errorText)}</div>`);
  }
  if (noticeText) {
    blocks.push(`<div class="message message-ok">${escapeHtml(noticeText)}</div>`);
  }
  if (warnings.length > 0) {
    blocks.push(
      `<div class="message message-warn">${warnings
        .map((warning) => escapeHtml(warning))
        .join("<br />")}</div>`,
    );
  }
  const quota = state.dashboard?.quotaConfirm;
  if (quota?.running) {
    blocks.push(
      `<div class="message message-warn">API quota: ${escapeHtml(`${quota.checkedAccounts}/${quota.totalAccounts}`)} confirmed in background</div>`,
    );
  }
  if (quota?.finished && !quota.success && quota.error) {
    blocks.push(`<div class="message message-warn">${escapeHtml(quota.error)}</div>`);
  }
  const recovery = state.dashboard?.authRecovery;
  const needsRecovery =
    recovery?.refreshTokenReused ||
    state.dashboard?.login.refreshTokenReused ||
    state.dashboard?.action.refreshTokenReused;
  if (needsRecovery) {
    const active = recovery?.activeAccount;
    blocks.push(
      `<div class="message message-warn recovery-message">
        <span>${escapeHtml(t("refreshTokenReusedDetected"))}</span>
        ${
          active?.bestCandidateId
            ? `<button
                class="ghost-button"
                data-action="recover-account-auth"
                data-account-key="${escapeAttribute(active.accountKey)}"
                data-candidate-id="${escapeAttribute(active.bestCandidateId)}"
                data-label="${escapeAttribute(active.label)}"
                type="button"
                ${isUiLocked() ? "disabled" : ""}
              >${escapeHtml(t("recoverSnapshot"))}</button>`
            : active
              ? `<button
                  class="ghost-button"
                  data-action="mark-account-unusable"
                  data-account-key="${escapeAttribute(active.accountKey)}"
                  data-label="${escapeAttribute(active.label)}"
                  type="button"
                  ${isUiLocked() ? "disabled" : ""}
                >${escapeHtml(t("markUnusable"))}</button>`
              : ""
        }
      </div>`,
    );
  }

  return blocks.join("");
}

function renderSummaryCards() {
  const summary = state.dashboard?.summary;
  const cards = [
    {
      label: t("summaryActive"),
      value: summary?.activeLabel ?? t("none"),
      tone: "ink",
    },
    {
      label: t("summaryService"),
      value: serviceLabel(state.dashboard?.status.service ?? null),
      tone: state.dashboard?.status.service === "running" ? "good" : "warn",
    },
    {
      label: t("summaryBestKnown"),
      value:
        summary?.bestKnownLabel && summary.bestKnownRemaining !== null
          ? `${summary.bestKnownLabel} · ${Math.round(summary.bestKnownRemaining)}%`
          : t("none"),
      tone: "sun",
    },
    {
      label: t("summarySnapshots"),
      value:
        summary === undefined
          ? "0/0"
          : t("snapshotsValue", {
              fresh: summary.freshAccounts,
              eligible: summary.eligibleAccounts,
            }),
      tone: "muted",
    },
  ];

  return `
    <div class="summary-grid">
      ${cards
        .map(
          (card) => `
            <div class="summary-card summary-${card.tone}">
              <div class="summary-icon" aria-hidden="true">${summaryIcon(card.label)}</div>
              <span>${escapeHtml(card.label)}</span>
              <strong>${escapeHtml(card.value)}</strong>
            </div>
          `,
        )
        .join("")}
    </div>
  `;
}

function summaryIcon(label: string) {
  if (label === t("summaryService")) {
    return icon("pulse");
  }
  if (label === t("summaryActive")) {
    return icon("user");
  }
  if (label === t("summarySnapshots")) {
    return icon("layers");
  }
  return icon("target");
}

function renderUtilityPanels() {
  const blocks = [
    renderStatusPanel(),
    renderCliRuntimePanel(),
    renderLoginPanel(),
    renderCommandOutputPanel(),
  ].filter(Boolean);

  if (blocks.length === 0) {
    return "";
  }

  return `
    <section class="utility-strip">
      ${blocks.join("")}
    </section>
  `;
}

function renderStatusPanel() {
  const pairs = state.dashboard?.status.pairs ?? [];
  if (pairs.length === 0) {
    return "";
  }

  return `
    <details class="panel utility-panel">
      <summary class="utility-summary">
        <span>${escapeHtml(t("status"))}</span>
        <strong>${escapeHtml(serviceLabel(state.dashboard?.status.service ?? null))} · ${escapeHtml(state.dashboard?.status.activeAuth ?? t("unknown"))}</strong>
      </summary>
      <div class="detail-grid compact-detail-grid">
        ${pairs
          .map(
            (pair) => `
              <div class="detail-item">
                <span>${escapeHtml(pair.key)}</span>
                <strong>${escapeHtml(pair.value)}</strong>
              </div>
            `,
          )
          .join("")}
      </div>
    </details>
  `;
}

function renderCliRuntimePanel() {
  const runtime = state.dashboard?.cliRuntime;
  const available = runtime?.available ?? false;
  const source = runtime?.resolutionSource ?? t("none");
  const resolvedPath = runtime?.resolvedPath ?? t("noBinaryResolved");
  const overridePath = state.cliOverrideInput;
  const hasSavedOverride = Boolean(runtime?.overridePath);

  return `
    <details class="panel utility-panel runtime-panel">
      <summary class="utility-summary">
        <span>${escapeHtml(t("runtime"))}</span>
        <strong>${available ? escapeHtml(t("runtimeAvailable")) : escapeHtml(t("runtimeUnavailable"))} · ${escapeHtml(source)}</strong>
      </summary>
      <div class="detail-grid runtime-grid compact-detail-grid">
        <div class="detail-item">
          <span>${escapeHtml(t("source"))}</span>
          <strong>${escapeHtml(source)}</strong>
        </div>
        <div class="detail-item">
          <span>${escapeHtml(t("resolvedPath"))}</span>
          <strong class="runtime-path" title="${escapeAttribute(resolvedPath)}">${escapeHtml(resolvedPath)}</strong>
        </div>
      </div>
      <label class="search runtime-search">
        <span>${escapeHtml(t("overridePath"))}</span>
        <input
          id="cli-override-path"
          value="${escapeAttribute(overridePath)}"
          placeholder="/full/path/to/codex-auth"
          ${isRuntimeActionDisabled()}
        />
      </label>
      <div class="runtime-actions">
        <button data-action="save-cli-override" ${saveCliOverrideDisabled()}>
          ${escapeHtml(t("savePath"))}
        </button>
        <button class="ghost-button" data-action="clear-cli-override" ${
          !hasSavedOverride || isRuntimeActionDisabled() ? "disabled" : ""
        }>
          ${escapeHtml(t("clearOverride"))}
        </button>
        <button class="ghost-button" data-action="retry-cli-runtime" ${isRefreshDisabled()}>
          ${escapeHtml(t("retryDetect"))}
        </button>
      </div>
      ${
        runtime?.error
          ? `<p class="summary-hint runtime-error">${escapeHtml(runtime.error)}</p>`
          : ""
      }
    </details>
  `;
}

function renderScopeChip(scope: FilterScope, label: string) {
  return `
    <button
      class="filter-chip ${state.scope === scope ? "filter-chip-active" : ""}"
      data-action="set-scope"
      data-scope="${scope}"
      type="button"
    >
      ${escapeHtml(label)}
    </button>
  `;
}

function renderSortOption(value: SortMode, label: string) {
  return `<option value="${value}" ${state.sortMode === value ? "selected" : ""}>${escapeHtml(label)}</option>`;
}

function renderAccounts() {
  const accounts = renderedAccounts();
  if (state.loading && !state.dashboard) {
    return `<div class="empty-state">${escapeHtml(t("loadingRegistry"))}</div>`;
  }
  if (accounts.length === 0) {
    return `<div class="empty-state">${escapeHtml(t("noAccountsMatch"))}</div>`;
  }

  return `
    <div class="account-table" role="table" aria-label="${escapeAttribute(t("accounts"))}">
      <div class="account-table-head" role="row">
        <span>${escapeHtml(t("accountColumnAccount"))}</span>
        <span>${escapeHtml(t("accountColumnQuota"))}</span>
        <span>${escapeHtml(t("accountColumnHealth"))}</span>
        <span>${escapeHtml(t("accountColumnMeta"))}</span>
        <span>${escapeHtml(t("accountColumnActions"))}</span>
      </div>
      ${accounts.map(renderAccountRow).join("")}
    </div>
  `;
}

function renderAccountRow(account: AccountView) {
  const recovery = recoveryForAccount(account.key);
  const health = accountHealth(account);
  const switchDisabled = accountSwitchDisabled(account);
  const title = account.lastAuthError || health.detail;
  return `
    <article
      class="account-table-row ${account.isActive ? "is-active" : ""} account-health-${health.tone}"
      title="${escapeAttribute(title)}"
      role="row"
    >
      <div class="account-cell account-identity-cell" role="cell">
        <strong>${escapeHtml(account.label)}</strong>
        ${account.label === account.email ? "" : `<span>${escapeHtml(account.email)}</span>`}
      </div>
      <div class="account-cell account-quota-cell" role="cell">
        ${renderQuotaMeter("5h", account.fiveHour)}
        ${renderQuotaMeter("wk", account.weekly)}
      </div>
      <div class="account-cell account-health-cell" role="cell">
        <div class="badge-row badge-row-left">
          ${badge(health.label, `health-badge health-${health.tone}`)}
          ${account.isActive ? badge(t("active"), "active") : ""}
          ${account.eligible ? badge(t("eligible"), "eligible") : ""}
          ${renderQuotaSourceBadge(account)}
          ${recovery && recovery.candidateCount > 0 ? badge(t("recoveryAvailable"), "freshness freshness-stale") : ""}
        </div>
        <span>${escapeHtml(health.detail)}</span>
      </div>
      <div class="account-cell account-meta-cell" role="cell">
        <span><span class="meta-dot meta-dot-${account.freshness}"></span>${escapeHtml(account.plan)}</span>
        ${account.lastUsageRelative ? `<span>${escapeHtml(account.lastUsageRelative)}</span>` : ""}
        ${account.quotaConfirmedRelative ? `<span>API ${escapeHtml(account.quotaConfirmedRelative)}</span>` : ""}
        ${account.accountName ? `<span>${escapeHtml(account.accountName)}</span>` : ""}
        ${account.authMode !== "chatgpt" ? `<span>${escapeHtml(account.authMode)}</span>` : ""}
      </div>
      <div class="account-cell account-action-cell" role="cell">
        <button
          class="account-icon-action"
          data-action="switch-account"
          data-account-key="${escapeAttribute(account.key)}"
          data-label="${escapeAttribute(account.label)}"
          title="${escapeAttribute(t("switch"))}: ${escapeAttribute(account.label)}"
          aria-label="${escapeAttribute(t("switch"))}: ${escapeAttribute(account.label)}"
          ${switchDisabled}
        >
          ${icon("switch")}
          <span>${escapeHtml(t("switch"))}</span>
        </button>
        ${
          recovery?.bestCandidateId
            ? `<button
                class="ghost-button account-icon-action"
                data-action="recover-account-auth"
                data-account-key="${escapeAttribute(account.key)}"
                data-candidate-id="${escapeAttribute(recovery.bestCandidateId)}"
                data-label="${escapeAttribute(account.label)}"
                title="${escapeAttribute(t("recoverSnapshot"))}: ${escapeAttribute(account.label)}"
                aria-label="${escapeAttribute(t("recoverSnapshot"))}: ${escapeAttribute(account.label)}"
                ${isUiLocked() ? "disabled" : ""}
              >
                ${icon("shield")}
                <span>${escapeHtml(t("recover"))}</span>
              </button>`
            : `<span class="account-action-placeholder" aria-hidden="true"></span>`
        }
        <button
          class="ghost-button danger-button account-icon-action"
          data-action="remove-account"
          data-account-key="${escapeAttribute(account.key)}"
          data-label="${escapeAttribute(account.label)}"
          title="${escapeAttribute(t("removeAccount"))}: ${escapeAttribute(account.label)}"
          aria-label="${escapeAttribute(t("removeAccount"))}: ${escapeAttribute(account.label)}"
          ${isUiLocked() ? "disabled" : ""}
        >
          ${icon("trash")}
          <span>${escapeHtml(t("removeAccount"))}</span>
        </button>
      </div>
    </article>
  `;
}

function recoveryForAccount(accountKey: string) {
  return state.dashboard?.authRecovery.accounts.find((account) => account.accountKey === accountKey) ?? null;
}

function accountHealth(account: AccountView) {
  const remaining = account.effectiveRemaining === null ? null : Math.round(account.effectiveRemaining);
  if (account.quarantined || account.authHealth === "quarantined") {
    return {
      label: t("accountHealthQuarantined"),
      title: t("accountHealthQuarantinedTitle"),
      detail: account.lastAuthError ?? t("accountHealthQuarantinedDetail"),
      tone: "bad",
    };
  }
  if (!account.authAvailable) {
    return {
      label: t("accountHealthNoAuth"),
      title: t("accountHealthNoAuthTitle"),
      detail: t("accountHealthNoAuthDetail"),
      tone: "bad",
    };
  }
  if (account.authHealth === "active" || account.isActive) {
    return {
      label: t("accountHealthActive"),
      title: t("accountHealthActiveTitle"),
      detail: remaining === null ? t("accountHealthUnknownDetail") : t("accountHealthRemainingDetail", { percent: remaining }),
      tone: "good",
    };
  }
  if (account.authHealth === "ready" || account.eligible) {
    return {
      label: t("accountHealthReady"),
      title: t("accountHealthReadyTitle"),
      detail: remaining === null ? t("accountHealthUnknownDetail") : t("accountHealthRemainingDetail", { percent: remaining }),
      tone: "good",
    };
  }
  if (account.blocked) {
    return {
      label: t("accountHealthBlocked"),
      title: t("accountHealthBlockedTitle"),
      detail: t("accountHealthBlockedDetail"),
      tone: "bad",
    };
  }
  if (account.authHealth === "needsWarm" || account.freshness !== "fresh") {
    return {
      label: t("accountHealthNeedsWarm"),
      title: t("accountHealthNeedsWarmTitle"),
      detail: account.freshness === "unknown" ? t("accountHealthUnknownSnapshotDetail") : t("accountHealthStaleSnapshotDetail"),
      tone: "warn",
    };
  }
  if (remaining !== null) {
    return {
      label: t("accountHealthLowQuota"),
      title: t("accountHealthLowQuotaTitle"),
      detail: t("accountHealthRemainingDetail", { percent: remaining }),
      tone: remaining <= 5 ? "bad" : "warn",
    };
  }
  return {
    label: t("accountHealthUnknown"),
    title: t("accountHealthUnknownTitle"),
    detail: t("accountHealthUnknownDetail"),
    tone: "warn",
  };
}

function accountSwitchDisabled(account: AccountView) {
  if (isUiLocked()) {
    return "disabled";
  }
  if (!account.authAvailable || account.quarantined || account.blocked) {
    return "disabled";
  }
  if (account.authHealth === "noAuth" || account.authHealth === "quarantined" || account.authHealth === "blocked") {
    return "disabled";
  }
  return "";
}

function renderQuotaMeter(label: string, window: QuotaWindowView | null) {
  const percent = window ? Math.round(window.remainingPercent) : null;
  const width = percent === null ? 0 : Math.max(0, Math.min(100, percent));
  const remaining = percent === null ? t("unknown") : `${percent}%`;
  const tone = percent === null ? "unknown" : percent < 15 ? "low" : percent < 45 ? "mid" : "high";

  return `
    <div class="quota-meter quota-${tone}" title="${escapeAttribute(`${label} ${remaining}`)}">
      <div class="quota-meter-head">
        <span>${escapeHtml(label)}</span>
        <strong>${escapeHtml(remaining)}</strong>
      </div>
      <div class="quota-track">
        <div class="quota-fill" style="width: ${width}%"></div>
      </div>
    </div>
  `;
}

function renderQuotaSourceBadge(account: AccountView) {
  if (account.quotaSource === "api-confirmed") {
    return badge("API", "eligible");
  }
  if (account.quotaSource === "api-unavailable") {
    return badge("API?", "freshness freshness-stale");
  }
  return "";
}

function renderLoginPanel() {
  const login = state.dashboard?.login;
  if (!login || (!login.running && !login.finished && !login.output)) {
    return "";
  }
  // Modal overlay handles this state; skip redundant utility panel.
  return "";
}

function renderLoginModal() {
  const login = state.dashboard?.login;
  if (!login || (!login.running && !login.finished && !login.output)) {
    return "";
  }
  const phaseLabel = loginPhaseLabel(login.phase);

  return `
    <div class="login-modal-backdrop">
      <div class="login-modal" role="dialog" aria-label="${escapeAttribute(t("login"))}">
        <div class="login-modal-header">
          <div class="login-modal-icon ${login.running ? "spin" : login.success ? "is-success" : "is-failed"}">${login.running ? icon("refresh") : login.success ? `<svg class="ui-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M5 13l4 4L19 7"/></svg>` : `<svg class="ui-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M18 6 6 18"/><path d="M6 6 18 18"/></svg>`}</div>
          <div class="login-modal-info">
            <strong class="login-modal-title">${login.isolated ? escapeHtml(t("isolatedLogin")) : login.deviceAuth ? escapeHtml(t("deviceAuth")) : escapeHtml(t("browserAuth"))}</strong>
            <span class="login-modal-status">${login.running ? escapeHtml(t("loginRunning")) : login.success ? escapeHtml(t("loginDone")) : escapeHtml(t("loginFinished"))}</span>
          </div>
          ${!login.running ? `
            <button class="ghost-button login-modal-close" data-action="dismiss-login" aria-label="${escapeAttribute(t("dismiss"))}">
              <svg class="ui-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M18 6 6 18"/><path d="M6 6 18 18"/></svg>
            </button>
          ` : ""}
        </div>
        <div class="login-modal-body">
          <div class="login-modal-meta">
            <div class="login-meta-item login-phase-item">
              <span>${escapeHtml(t("loginPhase"))}</span>
              <strong>${escapeHtml(phaseLabel)}</strong>
            </div>
            <div class="login-meta-item">
              <span>${escapeHtml(t("startedAt"))}</span>
              <strong>${login.startedAt ?? "-"}</strong>
            </div>
          </div>
          <pre class="console login-modal-output">${escapeHtml(login.output || t("waitingLoginOutput"))}</pre>
          ${login.loginUrl ? `
            <details class="login-url-details" open>
              <summary>${escapeHtml(t("loginUrl"))}</summary>
              <div class="login-url-row">
                <input class="login-url-input" readonly value="${escapeAttribute(login.loginUrl)}" spellcheck="false" />
                <div class="login-url-actions">
                  <button class="ghost-button" data-action="open-login-url">${escapeHtml(t("openLoginUrl"))}</button>
                  <button class="ghost-button" data-action="copy-login-url">${escapeHtml(t("copyLoginUrl"))}</button>
                </div>
              </div>
            </details>
          ` : ""}
          ${login.diagnostic ? `<p class="login-diagnostic">${escapeHtml(login.diagnostic)}</p>` : ""}
        </div>
        <div class="login-modal-footer">
          ${login.running ? `
            <button class="ghost-button danger-button" data-action="cancel-login" ${state.busy ? "disabled" : ""}>
              ${escapeHtml(t("cancelLogin"))}
            </button>
          ` : `
            <button class="ghost-button" data-action="dismiss-login">
              ${escapeHtml(t("dismiss"))}
            </button>
          `}
        </div>
      </div>
    </div>
  `;
}

function loginPhaseLabel(phase: string) {
  switch (phase) {
    case "launching":
      return t("loginPhaseLaunching");
    case "waitingForUrl":
      return t("loginPhaseWaitingForUrl");
    case "browserOpen":
      return t("loginPhaseBrowserOpen");
    case "waitingForCallback":
      return t("loginPhaseWaitingForCallback");
    case "importing":
      return t("loginPhaseImporting");
    case "success":
      return t("loginPhaseSuccess");
    case "failed":
      return t("loginPhaseFailed");
    case "cancelled":
      return t("loginPhaseCancelled");
    default:
      return t("loginPhaseIdle");
  }
}

function renderCommandOutputPanel() {
  if (!state.consoleText) {
    return "";
  }

  return `
    <details class="panel utility-panel">
      <summary class="utility-summary">
        <span>${escapeHtml(t("output"))}</span>
        <strong>${escapeHtml(t("latestResult"))}</strong>
      </summary>
      <pre class="console">${escapeHtml(state.consoleText)}</pre>
    </details>
  `;
}

function renderedAccounts() {
  return sortAccounts(
    filterAccountsByScope(
      filterAccountsByQuery(state.dashboard?.accounts ?? [], state.filter),
      state.scope,
    ),
    state.sortMode,
  );
}

function filterAccountsByQuery(accounts: AccountView[], filter: string) {
  return filterAccountsByQueryHelper(accounts, filter);
}

function filterAccountsByScope(accounts: AccountView[], scope: FilterScope) {
  return filterAccountsByScopeHelper(accounts, scope);
}

function sortAccounts(accounts: AccountView[], mode: SortMode) {
  return sortAccountsHelper(accounts, mode);
}

function badge(text: string, cls: string) {
  return `<span class="badge ${cls}">${escapeHtml(text)}</span>`;
}

type IconName = keyof typeof ICON_PATHS;

const ICON_PATHS = {
  bolt: `<path d="M13 2 4 14h7l-1 8 9-12h-7l1-8Z"></path>`,
  device: `<rect x="7" y="2.75" width="10" height="18.5" rx="2"></rect><path d="M10.5 17.5h3"></path>`,
  globe: `<circle cx="12" cy="12" r="8.5"></circle><path d="M3.5 12h17"></path><path d="M12 3.5c2.1 2.3 3.1 5.1 3.1 8.5s-1 6.2-3.1 8.5c-2.1-2.3-3.1-5.1-3.1-8.5s1-6.2 3.1-8.5Z"></path>`,
  info: `<circle cx="12" cy="12" r="8.5"></circle><path d="M12 11v5"></path><path d="M12 7.5h.01"></path>`,
  layers: `<path d="m12 3 9 5-9 5-9-5 9-5Z"></path><path d="m3 12 9 5 9-5"></path><path d="m3 16 9 5 9-5"></path>`,
  plus: `<path d="M12 5v14"></path><path d="M5 12h14"></path>`,
  pulse: `<path d="M3 12h4l2-6 4 12 2-6h6"></path>`,
  refresh: `<path d="M20 6v5h-5"></path><path d="M4 18v-5h5"></path><path d="M18.4 9A7 7 0 0 0 6.1 6.4L4 8.5"></path><path d="M5.6 15A7 7 0 0 0 17.9 17.6L20 15.5"></path>`,
  search: `<circle cx="10.5" cy="10.5" r="6.5"></circle><path d="m16 16 4 4"></path>`,
  shield: `<path d="M12 3 5 6v5c0 4.2 2.8 8 7 10 4.2-2 7-5.8 7-10V6l-7-3Z"></path><path d="m9 12 2 2 4-5"></path>`,
  sort: `<path d="M7 5v14"></path><path d="m4 16 3 3 3-3"></path><path d="M17 19V5"></path><path d="m14 8 3-3 3 3"></path>`,
  switch: `<path d="M17 3l4 4-4 4"></path><path d="M21 7H9a5 5 0 0 0-5 5v1"></path><path d="M7 21l-4-4 4-4"></path><path d="M3 17h12a5 5 0 0 0 5-5v-1"></path>`,
  target: `<circle cx="12" cy="12" r="8.5"></circle><circle cx="12" cy="12" r="3.5"></circle><path d="M12 2v4"></path><path d="M12 18v4"></path><path d="M2 12h4"></path><path d="M18 12h4"></path>`,
  trash: `<path d="M4 7h16"></path><path d="M10 11v6"></path><path d="M14 11v6"></path><path d="M6 7l1 14h10l1-14"></path><path d="M9 7V4h6v3"></path>`,
  user: `<circle cx="12" cy="8" r="4"></circle><path d="M4.5 21a7.5 7.5 0 0 1 15 0"></path>`,
  users: `<path d="M15 19a6 6 0 0 0-12 0"></path><circle cx="9" cy="8" r="4"></circle><path d="M22 19a6 6 0 0 0-5-5.9"></path><path d="M16 4.2a4 4 0 0 1 0 7.6"></path>`,
} as const;

function icon(name: IconName) {
  return `<svg class="ui-icon" viewBox="0 0 24 24" aria-hidden="true">${ICON_PATHS[name]}</svg>`;
}

function isCliActionDisabled() {
  return isUiLocked() ? "disabled" : "";
}

function isRefreshDisabled() {
  return state.loading || isUiLocked() ? "disabled" : "";
}

function isRuntimeActionDisabled() {
  return isUiLocked() ? "disabled" : "";
}

function loginRunning() {
  return state.dashboard?.login.running ?? false;
}

function actionRunning() {
  return state.dashboard?.action.running ?? false;
}

function isUiLocked() {
  return state.busy || loginRunning() || actionRunning();
}

function saveCliOverrideDisabled() {
  return !state.cliOverrideInput.trim() || isUiLocked() ? "disabled" : "";
}

function captureFocusSnapshot(): FocusSnapshot | null {
  const active = document.activeElement as HTMLInputElement | HTMLSelectElement | null;
  if (!active || !("id" in active) || !active.id) {
    return null;
  }
  return {
    id: active.id,
    selectionStart: "selectionStart" in active ? active.selectionStart : null,
    selectionEnd: "selectionEnd" in active ? active.selectionEnd : null,
  };
}

function captureScrollSnapshot(): ScrollSnapshot {
  const accountGrid = document.querySelector(ACCOUNT_SCROLL_SELECTOR) as HTMLElement | null;
  return {
    windowX: window.scrollX,
    windowY: window.scrollY,
    accountGridTop: accountGrid?.scrollTop ?? null,
    accountGridLeft: accountGrid?.scrollLeft ?? null,
  };
}

function restoreFocusSnapshot(snapshot: FocusSnapshot | null) {
  if (!snapshot) {
    return;
  }
  const next = document.getElementById(snapshot.id) as
    | HTMLInputElement
    | HTMLSelectElement
    | null;
  if (!next) {
    return;
  }
  next.focus();
  if (
    "setSelectionRange" in next &&
    typeof snapshot.selectionStart === "number" &&
    typeof snapshot.selectionEnd === "number"
  ) {
    next.setSelectionRange(snapshot.selectionStart, snapshot.selectionEnd);
  }
}

function restoreScrollSnapshot(snapshot: ScrollSnapshot) {
  const accountGrid = document.querySelector(ACCOUNT_SCROLL_SELECTOR) as HTMLElement | null;
  if (accountGrid && snapshot.accountGridTop !== null) {
    accountGrid.scrollTop = snapshot.accountGridTop;
    accountGrid.scrollLeft = snapshot.accountGridLeft ?? 0;
  }
  window.scrollTo(snapshot.windowX, snapshot.windowY);
}

async function copyText(text: string) {
  if (navigator.clipboard?.writeText) {
    await navigator.clipboard.writeText(text);
    return;
  }

  const textarea = document.createElement("textarea");
  textarea.value = text;
  textarea.setAttribute("readonly", "");
  textarea.style.position = "absolute";
  textarea.style.left = "-9999px";
  document.body.appendChild(textarea);
  textarea.select();
  const ok = document.execCommand("copy");
  document.body.removeChild(textarea);
  if (!ok) {
    throw new LocalizedUiError("clipboardUnavailable");
  }
}

function asMessage(error: unknown) {
  if (typeof error === "string") {
    return error;
  }
  if (error instanceof Error) {
    return error.message;
  }
  return String(error);
}

function escapeHtml(value: string) {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function escapeAttribute(value: string) {
  return escapeHtml(value);
}
