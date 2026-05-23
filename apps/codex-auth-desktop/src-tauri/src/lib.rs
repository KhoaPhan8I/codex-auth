use chrono::{Local, TimeZone, Utc};
use serde::{Deserialize, Serialize};
use std::cmp::Ordering;
use std::collections::HashMap;
use std::env;
use std::fs;
use std::io::{BufRead, BufReader, Read};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering as AtomicOrdering};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::time::{Duration, Instant};
use tauri::Manager;

const LOCAL_SNAPSHOT_MAX_AGE_SECONDS: i64 = 24 * 60 * 60;
const DASHBOARD_REFRESH_INTERVAL_SECONDS: u64 = 10;
const DESKTOP_SETTINGS_DIR_NAME: &str = "io.loongphy.codexauthstudio";
const DESKTOP_SETTINGS_FILE_NAME: &str = "settings.json";
const BUNDLED_CLI_RESOURCE_DIR: &str = "bin";
const FREE_PLAN_REALTIME_GUARD_5H_PERCENT: f64 = 35.0;
const API_QUOTA_CONFIRM_TTL_SECONDS: i64 = 10 * 60;
const API_QUOTA_CONFIRM_DASHBOARD_TTL_SECONDS: i64 = 2 * 60;
const API_QUOTA_CONFIRM_PARALLELISM: usize = 3;
const CLI_PROBE_TIMEOUT_SECONDS: u64 = 8;
const CLI_IMPORT_TIMEOUT_SECONDS: u64 = 20;
const USAGE_API_ENDPOINT: &str = "https://chatgpt.com/backend-api/wham/usage";
const ELIGIBLE_HINT_MISSING_FRESH_LOCAL_SNAPSHOT: &str = "missing-fresh-local-snapshot";
const ELIGIBLE_HINT_BELOW_THRESHOLD: &str = "below-threshold";
const ELIGIBLE_HINT_ACTIVE_ALREADY_BEST: &str = "active-already-best";
const REFRESH_TOKEN_REUSED_HINT: &str = "refresh-token-reused";
const LOGIN_PHASE_IDLE: &str = "idle";
const LOGIN_PHASE_LAUNCHING: &str = "launching";
const LOGIN_PHASE_WAITING_FOR_URL: &str = "waitingForUrl";
const LOGIN_PHASE_BROWSER_OPEN: &str = "browserOpen";
const LOGIN_PHASE_WAITING_FOR_CALLBACK: &str = "waitingForCallback";
const LOGIN_PHASE_IMPORTING: &str = "importing";
const LOGIN_PHASE_SUCCESS: &str = "success";
const LOGIN_PHASE_FAILED: &str = "failed";
const LOGIN_PHASE_CANCELLED: &str = "cancelled";
const ACCOUNT_HEALTH_READY: &str = "ready";
const ACCOUNT_HEALTH_ACTIVE: &str = "active";
const ACCOUNT_HEALTH_NO_AUTH: &str = "noAuth";
const ACCOUNT_HEALTH_QUARANTINED: &str = "quarantined";
const ACCOUNT_HEALTH_BLOCKED: &str = "blocked";
const ACCOUNT_HEALTH_NEEDS_WARM: &str = "needsWarm";
const ACCOUNT_HEALTH_LOW_QUOTA: &str = "lowQuota";
const ACCOUNT_HEALTH_UNKNOWN: &str = "unknown";

static BUNDLED_CLI_CANDIDATES: OnceLock<Vec<PathBuf>> = OnceLock::new();

struct LoginState {
    inner: Arc<Mutex<LoginJobState>>,
    url_ready: Arc<(Mutex<bool>, Condvar)>,
    cancel_requested: Arc<AtomicBool>,
}

impl Default for LoginState {
    fn default() -> Self {
        Self {
            inner: Arc::new(Mutex::new(LoginJobState::default())),
            url_ready: Arc::new((Mutex::new(false), Condvar::new())),
            cancel_requested: Arc::new(AtomicBool::new(false)),
        }
    }
}

#[derive(Default)]
struct ActionState {
    inner: Arc<Mutex<ActionJobState>>,
}

#[derive(Default)]
struct QuotaConfirmState {
    inner: Arc<Mutex<QuotaConfirmJobState>>,
}

struct IsolatedBrowserSession {
    session_id: String,
    profile_dir: PathBuf,
    noop_dir: Option<PathBuf>,
    codex_home_dir: Option<PathBuf>,
    child: Option<Child>,
}

#[derive(Default)]
struct IsolatedBrowserState {
    sessions: Arc<Mutex<Vec<IsolatedBrowserSession>>>,
}

#[derive(Default)]
struct LoginJobState {
    running: bool,
    finished: bool,
    success: bool,
    device_auth: bool,
    isolated: bool,
    output: String,
    login_url: Option<String>,
    isolated_session_id: Option<String>,
    started_at: Option<String>,
    finished_at: Option<String>,
    exit_code: Option<i32>,
    error: Option<String>,
    cancelled: bool,
    refresh_token_reused: bool,
    phase: String,
    browser_url_opened: bool,
    import_started: bool,
    import_finished: bool,
    diagnostic: Option<String>,
}

#[derive(Default)]
struct ActionJobState {
    running: bool,
    finished: bool,
    success: bool,
    command: Option<String>,
    account_key_hint: Option<String>,
    output: String,
    started_at: Option<String>,
    finished_at: Option<String>,
    exit_code: Option<i32>,
    error: Option<String>,
    refresh_token_reused: bool,
}

#[derive(Default)]
struct QuotaConfirmJobState {
    running: bool,
    finished: bool,
    success: bool,
    scope: Option<String>,
    output: String,
    started_at: Option<String>,
    finished_at: Option<String>,
    checked_accounts: usize,
    total_accounts: usize,
    error: Option<String>,
    cache: HashMap<String, ConfirmedQuotaRecord>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct LoginSnapshot {
    running: bool,
    finished: bool,
    success: bool,
    device_auth: bool,
    isolated: bool,
    output: String,
    login_url: Option<String>,
    isolated_session_id: Option<String>,
    started_at: Option<String>,
    finished_at: Option<String>,
    exit_code: Option<i32>,
    error: Option<String>,
    cancelled: bool,
    refresh_token_reused: bool,
    phase: String,
    browser_url_opened: bool,
    import_started: bool,
    import_finished: bool,
    diagnostic: Option<String>,
}

#[derive(Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
struct ActionSnapshot {
    running: bool,
    finished: bool,
    success: bool,
    command: Option<String>,
    output: String,
    started_at: Option<String>,
    finished_at: Option<String>,
    exit_code: Option<i32>,
    error: Option<String>,
    refresh_token_reused: bool,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct QuotaConfirmSnapshot {
    running: bool,
    finished: bool,
    success: bool,
    scope: Option<String>,
    output: String,
    started_at: Option<String>,
    finished_at: Option<String>,
    checked_accounts: usize,
    total_accounts: usize,
    error: Option<String>,
}

#[derive(Clone)]
struct ConfirmedQuotaRecord {
    snapshot: Option<RateLimitSnapshot>,
    checked_at: i64,
    status_code: Option<u16>,
    error: Option<String>,
}

impl LoginState {
    fn snapshot(&self) -> LoginSnapshot {
        let state = self.inner.lock().expect("login state poisoned");
        LoginSnapshot {
            running: state.running,
            finished: state.finished,
            success: state.success,
            device_auth: state.device_auth,
            isolated: state.isolated,
            output: state.output.clone(),
            login_url: state.login_url.clone(),
            isolated_session_id: state.isolated_session_id.clone(),
            started_at: state.started_at.clone(),
            finished_at: state.finished_at.clone(),
            exit_code: state.exit_code,
            error: state.error.clone(),
            cancelled: state.cancelled,
            refresh_token_reused: state.refresh_token_reused,
            phase: if state.phase.is_empty() {
                LOGIN_PHASE_IDLE.to_string()
            } else {
                state.phase.clone()
            },
            browser_url_opened: state.browser_url_opened,
            import_started: state.import_started,
            import_finished: state.import_finished,
            diagnostic: state.diagnostic.clone(),
        }
    }
}

impl ActionState {
    fn snapshot(&self) -> ActionSnapshot {
        let state = self.inner.lock().expect("action state poisoned");
        ActionSnapshot {
            running: state.running,
            finished: state.finished,
            success: state.success,
            command: state.command.clone(),
            output: state.output.clone(),
            started_at: state.started_at.clone(),
            finished_at: state.finished_at.clone(),
            exit_code: state.exit_code,
            error: state.error.clone(),
            refresh_token_reused: state.refresh_token_reused,
        }
    }
}

impl QuotaConfirmState {
    fn snapshot(&self) -> QuotaConfirmSnapshot {
        let state = self.inner.lock().expect("quota confirm state poisoned");
        QuotaConfirmSnapshot {
            running: state.running,
            finished: state.finished,
            success: state.success,
            scope: state.scope.clone(),
            output: state.output.clone(),
            started_at: state.started_at.clone(),
            finished_at: state.finished_at.clone(),
            checked_accounts: state.checked_accounts,
            total_accounts: state.total_accounts,
            error: state.error.clone(),
        }
    }

    fn cache_snapshot(&self) -> HashMap<String, ConfirmedQuotaRecord> {
        let state = self.inner.lock().expect("quota confirm state poisoned");
        state.cache.clone()
    }
}

#[derive(Clone, Default, Serialize, Deserialize)]
struct RegistryFile {
    #[serde(default)]
    active_account_key: Option<String>,
    #[serde(default)]
    auto_switch: AutoSwitchConfig,
    #[serde(default)]
    api: ApiConfig,
    #[serde(default)]
    accounts: Vec<AccountRecord>,
}

#[derive(Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DesktopSettings {
    #[serde(default)]
    codex_auth_bin_override: Option<String>,
}

#[derive(Clone, Serialize, Deserialize)]
struct AutoSwitchConfig {
    #[serde(default)]
    enabled: bool,
    #[serde(default = "default_auto_mode")]
    mode: String,
    #[serde(default)]
    pinned_account_key: Option<String>,
    #[serde(default)]
    blocked_account_key: Option<String>,
    #[serde(default)]
    blocked_until_ms: Option<i64>,
    #[serde(default = "default_threshold_5h")]
    threshold_5h_percent: u8,
    #[serde(default = "default_threshold_weekly")]
    threshold_weekly_percent: u8,
}

impl Default for AutoSwitchConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            mode: default_auto_mode(),
            pinned_account_key: None,
            blocked_account_key: None,
            blocked_until_ms: None,
            threshold_5h_percent: default_threshold_5h(),
            threshold_weekly_percent: default_threshold_weekly(),
        }
    }
}

#[derive(Clone, Default, Serialize, Deserialize)]
struct ApiConfig {
    #[serde(default)]
    usage: bool,
    #[serde(default)]
    account: bool,
}

#[derive(Clone, Default, Serialize, Deserialize)]
struct AccountRecord {
    account_key: String,
    #[serde(default)]
    chatgpt_account_id: Option<String>,
    #[serde(default)]
    chatgpt_user_id: Option<String>,
    email: String,
    #[serde(default)]
    alias: String,
    #[serde(default)]
    account_name: Option<String>,
    #[serde(default)]
    plan: Option<String>,
    #[serde(default)]
    auth_mode: Option<String>,
    #[serde(default)]
    last_used_at: Option<i64>,
    #[serde(default)]
    last_usage: Option<RateLimitSnapshot>,
    #[serde(default)]
    last_usage_at: Option<i64>,
    #[serde(default)]
    auth_health: Option<String>,
    #[serde(default)]
    auth_checked_at: Option<i64>,
    #[serde(default)]
    auth_verified_at: Option<i64>,
    #[serde(default)]
    auth_error: Option<String>,
    #[serde(default)]
    auth_quarantined_at: Option<i64>,
}

#[derive(Clone, Default, Serialize, Deserialize)]
struct RateLimitSnapshot {
    #[serde(default)]
    primary: Option<RateLimitWindow>,
    #[serde(default)]
    secondary: Option<RateLimitWindow>,
    #[serde(default)]
    plan_type: Option<String>,
}

#[derive(Clone, Default, Serialize, Deserialize)]
struct RateLimitWindow {
    used_percent: f64,
    #[serde(default)]
    window_minutes: Option<i64>,
    #[serde(default)]
    resets_at: Option<i64>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum SnapshotFreshness {
    Unknown,
    Stale,
    Fresh,
}

impl SnapshotFreshness {
    fn as_str(self) -> &'static str {
        match self {
            Self::Unknown => "unknown",
            Self::Stale => "stale",
            Self::Fresh => "fresh",
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct DashboardPayload {
    version: Option<String>,
    version_error: Option<String>,
    refresh_interval_seconds: u64,
    cli_runtime: CliRuntimeView,
    summary: SummaryView,
    status: StatusView,
    accounts: Vec<AccountView>,
    warnings: Vec<String>,
    login: LoginSnapshot,
    action: ActionSnapshot,
    quota_confirm: QuotaConfirmSnapshot,
    auth_recovery: AuthRecoverySnapshot,
}

#[derive(Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
struct AuthRecoverySnapshot {
    refresh_token_reused: bool,
    active_account_key: Option<String>,
    active_account: Option<AuthRecoveryAccountView>,
    accounts: Vec<AuthRecoveryAccountView>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct AuthRecoveryAccountView {
    account_key: String,
    label: String,
    email: String,
    is_active: bool,
    candidate_count: usize,
    best_candidate_id: Option<String>,
    best_source: Option<String>,
    best_last_refresh: Option<String>,
    best_modified_at: Option<i64>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SummaryView {
    active_label: Option<String>,
    total_accounts: usize,
    fresh_accounts: usize,
    stale_accounts: usize,
    unknown_accounts: usize,
    eligible_accounts: usize,
    best_known_label: Option<String>,
    best_known_remaining: Option<f64>,
    eligible_hint: Option<String>,
    eligible_hint_code: Option<String>,
    auto_switch_enabled: bool,
    auto_switch_mode: String,
    pinned_account_label: Option<String>,
    pin_state: Option<String>,
    failover_state: Option<String>,
    blocked_account_label: Option<String>,
    blocked_until: Option<String>,
    threshold_5h_percent: u8,
    threshold_weekly_percent: u8,
    usage_api_enabled: bool,
    account_api_enabled: bool,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct CliRuntimeView {
    available: bool,
    resolved_path: Option<String>,
    resolution_source: Option<String>,
    override_path: Option<String>,
    error: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct StatusView {
    pairs: Vec<StatusPair>,
    service: Option<String>,
    usage: Option<String>,
    account_api: Option<String>,
    active_auth: Option<String>,
    active_account: Option<String>,
    active_account_key: Option<String>,
    selection: Option<String>,
    pinned_account: Option<String>,
    pin_state: Option<String>,
    failover_state: Option<String>,
    blocked_account: Option<String>,
    blocked_until: Option<String>,
    snapshot_source: Option<String>,
    known_snapshots: Option<String>,
    eligible_candidates: Option<String>,
    registry_active: Option<String>,
    has_active_account_key_line: bool,
    command_error: Option<String>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct StatusPair {
    key: String,
    value: String,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct AccountView {
    key: String,
    label: String,
    email: String,
    alias: String,
    account_name: Option<String>,
    record_hint: String,
    record_title: String,
    plan: String,
    auth_mode: String,
    is_active: bool,
    freshness: String,
    eligible: bool,
    blocked: bool,
    auth_available: bool,
    auth_health: String,
    usable: bool,
    recoverable: bool,
    quarantined: bool,
    quarantine_reason: Option<String>,
    last_auth_error: Option<String>,
    quota_source: String,
    quota_confirmed_at: Option<i64>,
    quota_confirmed_relative: Option<String>,
    quota_confirm_status_code: Option<u16>,
    quota_confirm_error: Option<String>,
    effective_remaining: Option<f64>,
    five_hour: Option<QuotaWindowView>,
    weekly: Option<QuotaWindowView>,
    last_used_at: Option<i64>,
    last_usage_at: Option<i64>,
    last_used_relative: Option<String>,
    last_usage_relative: Option<String>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct QuotaWindowView {
    remaining_percent: f64,
    resets_at_label: Option<String>,
    resets_at: Option<i64>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ActionResult {
    command: String,
    output: String,
}

struct CommandOutput {
    stdout: String,
    stderr: String,
}

struct ResolvedCliRuntime {
    view: CliRuntimeView,
    binary_path: Option<PathBuf>,
    warnings: Vec<String>,
}

#[derive(Clone, Copy)]
enum CliResolutionSource {
    SavedOverride,
    Bundled,
    Env,
    Path,
    StandardPath,
}

impl CliResolutionSource {
    fn as_str(self) -> &'static str {
        match self {
            Self::SavedOverride => "saved-override",
            Self::Bundled => "bundled",
            Self::Env => "env",
            Self::Path => "path",
            Self::StandardPath => "standard-path",
        }
    }
}

fn default_auto_mode() -> String {
    "reactive".to_string()
}

fn default_threshold_5h() -> u8 {
    10
}

fn default_threshold_weekly() -> u8 {
    5
}

#[tauri::command]
fn get_dashboard(
    login_state: tauri::State<'_, LoginState>,
    action_state: tauri::State<'_, ActionState>,
    quota_confirm_state: tauri::State<'_, QuotaConfirmState>,
) -> Result<DashboardPayload, String> {
    let mut warnings = Vec::new();
    let (mut registry, registry_warning) = load_registry();
    if let Some(warning) = registry_warning {
        push_unique_warning(&mut warnings, warning);
    }

    let runtime = resolve_cli_runtime();
    for warning in &runtime.warnings {
        push_unique_warning(&mut warnings, warning.clone());
    }
    if let Some(error) = &runtime.view.error {
        push_unique_warning(&mut warnings, error.clone());
    }

    let (version, version_error) = match runtime.binary_path.as_deref() {
        Some(binary_path) => match run_codex_auth_with_binary(binary_path, ["--version"]) {
            Ok(output) => (Some(output.stdout.trim().to_string()), None),
            Err(err) => {
                push_unique_warning(&mut warnings, err.clone());
                (None, Some(err))
            }
        },
        None => (None, runtime.view.error.clone()),
    };

    let status = load_status_view(
        runtime.binary_path.as_deref(),
        runtime.view.error.as_deref(),
    );
    if let Some(err) = &status.command_error {
        push_unique_warning(&mut warnings, err.clone());
        if is_refresh_token_reused_message(err) {
            match handle_refresh_token_incident(None, "status") {
                Ok(Some(outcome)) => {
                    push_unique_warning(&mut warnings, outcome.output);
                    let (next_registry, next_warning) = load_registry();
                    registry = next_registry;
                    if let Some(warning) = next_warning {
                        push_unique_warning(&mut warnings, warning);
                    }
                }
                Ok(None) => push_unique_warning(
                    &mut warnings,
                    "Refresh token reuse was detected, but no tracked account could be resolved for recovery."
                        .to_string(),
                ),
                Err(err) => push_unique_warning(
                    &mut warnings,
                    format!("Refresh-token recovery failed: {err}"),
                ),
            }
        }
    }
    if !status.has_active_account_key_line && status.active_account.is_some() {
        push_unique_warning(
            &mut warnings,
            "`codex-auth status` did not report `active account key`; desktop fallback matching may be ambiguous until the CLI is updated."
                .to_string(),
        );
    }

    maybe_start_dashboard_quota_confirm(&registry, &quota_confirm_state);
    let quota_confirm = quota_confirm_state.snapshot();
    let quota_cache = quota_confirm_state.cache_snapshot();
    let effective_registry = registry_with_confirmed_quota(&registry, &quota_cache);
    let accounts = build_account_views(&effective_registry, &status, &quota_cache);
    let summary = build_summary(&effective_registry, &status, &accounts);
    let auth_recovery = build_auth_recovery_snapshot(&effective_registry, &status, None);

    Ok(DashboardPayload {
        version,
        version_error,
        refresh_interval_seconds: DASHBOARD_REFRESH_INTERVAL_SECONDS,
        cli_runtime: runtime.view,
        summary,
        status,
        accounts,
        warnings,
        login: login_state.snapshot(),
        action: action_state.snapshot(),
        quota_confirm,
        auth_recovery,
    })
}

#[tauri::command]
fn set_cli_override(
    path: String,
    login_state: tauri::State<'_, LoginState>,
    action_state: tauri::State<'_, ActionState>,
) -> Result<ActionResult, String> {
    ensure_mutations_unlocked(&login_state, &action_state)?;
    let trimmed = path.trim();
    if trimmed.is_empty() {
        return Err("Override path cannot be empty.".to_string());
    }
    let candidate = canonical_override_path(trimmed)?;
    validate_codex_auth_binary(&candidate)?;

    let version_output = run_codex_auth_with_binary(&candidate, ["--version"])?;
    let mut settings = load_desktop_settings().0;
    settings.codex_auth_bin_override = Some(candidate.to_string_lossy().to_string());
    save_desktop_settings(&settings)?;

    Ok(ActionResult {
        command: "desktop set-cli-override".to_string(),
        output: format!(
            "Saved codex-auth override to {}\n{}",
            candidate.display(),
            render_command_output(&version_output).trim()
        )
        .trim()
        .to_string(),
    })
}

#[tauri::command]
fn clear_cli_override(
    login_state: tauri::State<'_, LoginState>,
    action_state: tauri::State<'_, ActionState>,
) -> Result<ActionResult, String> {
    ensure_mutations_unlocked(&login_state, &action_state)?;
    let mut settings = load_desktop_settings().0;
    settings.codex_auth_bin_override = None;
    save_desktop_settings(&settings)?;
    Ok(ActionResult {
        command: "desktop clear-cli-override".to_string(),
        output: "Cleared the saved codex-auth override. The app will auto-detect the CLI again."
            .to_string(),
    })
}

#[tauri::command]
fn switch_best(
    login_state: tauri::State<'_, LoginState>,
    action_state: tauri::State<'_, ActionState>,
) -> Result<ActionSnapshot, String> {
    ensure_mutations_unlocked(&login_state, &action_state)?;
    start_action(["switch", "--best"], &action_state)
}

#[tauri::command]
fn switch_account(
    account_key: String,
    login_state: tauri::State<'_, LoginState>,
    action_state: tauri::State<'_, ActionState>,
) -> Result<ActionSnapshot, String> {
    ensure_mutations_unlocked(&login_state, &action_state)?;
    start_action(
        ["switch", "--account-key", account_key.as_str()],
        &action_state,
    )
}

#[tauri::command]
fn switch_account_now(
    account_key: String,
    login_state: tauri::State<'_, LoginState>,
    action_state: tauri::State<'_, ActionState>,
) -> Result<ActionResult, String> {
    ensure_mutations_unlocked(&login_state, &action_state)?;
    let account_key = account_key.trim();
    if account_key.is_empty() {
        return Err("Account key cannot be empty.".to_string());
    }
    validate_switch_account_target(account_key)?;

    let runtime = resolve_cli_runtime();
    let binary_path = runtime.binary_path.ok_or_else(|| {
        runtime
            .view
            .error
            .unwrap_or_else(|| "codex-auth is unavailable.".to_string())
    })?;
    let args = ["switch", "--account-key", account_key];
    let output = run_switch_account_now(&binary_path, account_key, &args)?;
    Ok(ActionResult {
        command: format_command(&args),
        output,
    })
}

#[tauri::command]
fn remove_account(
    account_key: String,
    login_state: tauri::State<'_, LoginState>,
    action_state: tauri::State<'_, ActionState>,
) -> Result<ActionResult, String> {
    ensure_mutations_unlocked(&login_state, &action_state)?;
    let account_key = account_key.trim();
    if account_key.is_empty() {
        return Err("Account key cannot be empty.".to_string());
    }

    let runtime = resolve_cli_runtime();
    let binary_path = runtime.binary_path.ok_or_else(|| {
        runtime
            .view
            .error
            .unwrap_or_else(|| "codex-auth is unavailable.".to_string())
    })?;
    let args = ["remove", "--account-key", account_key];
    let output = run_codex_auth_with_binary(&binary_path, args)?;
    Ok(ActionResult {
        command: format_command(&args),
        output: render_command_output(&output),
    })
}

#[tauri::command]
fn warm_all(
    login_state: tauri::State<'_, LoginState>,
    action_state: tauri::State<'_, ActionState>,
) -> Result<ActionSnapshot, String> {
    ensure_mutations_unlocked(&login_state, &action_state)?;
    start_action(["warm", "--all"], &action_state)
}

#[tauri::command]
fn warm_account(
    account_key: String,
    login_state: tauri::State<'_, LoginState>,
    action_state: tauri::State<'_, ActionState>,
) -> Result<ActionSnapshot, String> {
    ensure_mutations_unlocked(&login_state, &action_state)?;
    start_action(
        ["warm", "--account-key", account_key.as_str()],
        &action_state,
    )
}

#[tauri::command]
fn set_auto_enabled(
    enabled: bool,
    login_state: tauri::State<'_, LoginState>,
    action_state: tauri::State<'_, ActionState>,
) -> Result<ActionSnapshot, String> {
    ensure_mutations_unlocked(&login_state, &action_state)?;
    if enabled {
        start_action(["config", "auto", "enable"], &action_state)
    } else {
        start_action(["config", "auto", "disable"], &action_state)
    }
}

#[tauri::command]
fn set_auto_mode(
    mode: String,
    login_state: tauri::State<'_, LoginState>,
    action_state: tauri::State<'_, ActionState>,
) -> Result<ActionSnapshot, String> {
    ensure_mutations_unlocked(&login_state, &action_state)?;
    if mode != "reactive" && mode != "proactive" && mode != "pinned" && mode != "failover" {
        return Err("Mode must be `reactive`, `proactive`, `pinned`, or `failover`.".to_string());
    }
    start_action(["config", "auto", "mode", mode.as_str()], &action_state)
}

#[tauri::command]
fn start_login(
    device_auth: bool,
    isolated: Option<bool>,
    state: tauri::State<'_, LoginState>,
    action_state: tauri::State<'_, ActionState>,
    browser_state: tauri::State<'_, IsolatedBrowserState>,
) -> Result<LoginSnapshot, String> {
    let isolated = isolated.unwrap_or(false);
    ensure_mutations_unlocked_action_state(&action_state)?;

    let session_id = if isolated {
        Some(generate_session_id())
    } else {
        None
    };

    {
        let mut url_flag = state.url_ready.0.lock().expect("url_ready poisoned");
        *url_flag = false;
    }
    state.cancel_requested.store(false, AtomicOrdering::SeqCst);

    {
        let mut job = state.inner.lock().expect("login state poisoned");
        if job.running {
            return Err("A login flow is already running.".to_string());
        }
        let mode_label = if isolated { " (isolated)" } else { "" };
        *job = LoginJobState {
            running: true,
            finished: false,
            success: false,
            device_auth,
            isolated,
            output: format!(
                "Launching `codex-auth login{}`{}...\n",
                if device_auth { " --device-auth" } else { "" },
                mode_label,
            ),
            login_url: None,
            isolated_session_id: session_id.clone(),
            started_at: Some(now_label()),
            finished_at: None,
            exit_code: None,
            error: None,
            cancelled: false,
            refresh_token_reused: false,
            phase: LOGIN_PHASE_LAUNCHING.to_string(),
            browser_url_opened: false,
            import_started: false,
            import_finished: false,
            diagnostic: None,
        };
    }

    let shared = Arc::clone(&state.inner);
    let url_ready = Arc::clone(&state.url_ready);
    let cancel_requested = Arc::clone(&state.cancel_requested);
    let browser_sessions = Arc::clone(&browser_state.sessions);
    std::thread::spawn(move || {
        let result = run_login_process(
            device_auth,
            isolated,
            &shared,
            &url_ready,
            &cancel_requested,
            &browser_sessions,
        );
        if let Err(err) = result {
            let mut job = shared.lock().expect("login state poisoned");
            job.running = false;
            job.finished = true;
            job.success = false;
            job.finished_at = Some(now_label());
            job.error = Some(err.clone());
            job.phase = LOGIN_PHASE_FAILED.to_string();
            append_line(&mut job.output, &format!("Login failed: {err}"));
            job.login_url = extract_login_url(&job.output);
            job.refresh_token_reused = is_refresh_token_reused_message(&job.output);
        }
    });

    Ok(state.snapshot())
}

fn cancel_login_watchdog(inner: Arc<std::sync::Mutex<LoginJobState>>) {
    for _ in 0..50 {
        if !inner.lock().map(|job| job.running).unwrap_or(false) {
            return;
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    // Timeout fallback: force final state so the frontend is never stuck.
    let mut job = inner.lock().expect("login state poisoned");
    job.running = false;
    job.finished = true;
    job.cancelled = true;
    job.success = false;
    job.finished_at = Some(now_label());
    job.phase = LOGIN_PHASE_CANCELLED.to_string();
    job.error = Some("Login cancelled (timeout).".to_string());
    append_line(&mut job.output, "Login cancelled (timeout).");
}

#[tauri::command]
fn cancel_login(state: tauri::State<'_, LoginState>) -> Result<LoginSnapshot, String> {
    let is_running = {
        let job = state
            .inner
            .lock()
            .map_err(|_| "Login state is unavailable.".to_string())?;
        job.running
    };
    if !is_running {
        return Ok(state.snapshot());
    }
    state.cancel_requested.store(true, AtomicOrdering::SeqCst);
    {
        let mut job = state
            .inner
            .lock()
            .map_err(|_| "Login state is unavailable.".to_string())?;
        if !job.cancelled {
            append_line(
                &mut job.output,
                "Cancellation requested. Stopping login process...",
            );
        }
        job.cancelled = true;
    }
    // Spawn watchdog on a separate thread so the IPC thread is not blocked.
    // The watchdog waits for the background thread to detect the flag
    // (checking running every 100ms, up to 5s), then force-sets final state
    // on timeout. This keeps clear_login_state and other IPC commands
    // responsive during cancellation.
    std::thread::spawn({
        let inner = Arc::clone(&state.inner);
        move || cancel_login_watchdog(inner)
    });
    Ok(state.snapshot())
}

#[tauri::command]
fn get_login_state(state: tauri::State<'_, LoginState>) -> LoginSnapshot {
    state.snapshot()
}

#[tauri::command]
fn get_action_state(state: tauri::State<'_, ActionState>) -> ActionSnapshot {
    state.snapshot()
}

#[tauri::command]
fn refresh_quota_confirmations(
    state: tauri::State<'_, QuotaConfirmState>,
) -> Result<QuotaConfirmSnapshot, String> {
    let (registry, registry_warning) = load_registry();
    if let Some(warning) = registry_warning {
        return Err(warning);
    }
    if !registry.api.usage {
        return Err("Usage API is disabled. Enable it with `codex-auth config api enable` before API quota confirmation.".to_string());
    }
    let targets = quota_confirm_targets(&registry, QuotaConfirmScope::All, true, &state);
    if targets.is_empty() {
        return Ok(state.snapshot());
    }
    start_quota_confirm(targets, "all".to_string(), true, &state)
}

#[tauri::command]
fn get_quota_confirm_state(state: tauri::State<'_, QuotaConfirmState>) -> QuotaConfirmSnapshot {
    state.snapshot()
}

#[tauri::command]
fn scan_auth_recovery() -> Result<AuthRecoverySnapshot, String> {
    let (registry, registry_warning) = load_registry();
    if let Some(warning) = registry_warning {
        return Err(warning);
    }
    let runtime = resolve_cli_runtime();
    let status = load_status_view(
        runtime.binary_path.as_deref(),
        runtime.view.error.as_deref(),
    );
    Ok(build_auth_recovery_snapshot(&registry, &status, None))
}

#[tauri::command]
fn recover_account_auth(
    account_key: String,
    candidate_id: String,
    login_state: tauri::State<'_, LoginState>,
    action_state: tauri::State<'_, ActionState>,
) -> Result<ActionResult, String> {
    ensure_mutations_unlocked(&login_state, &action_state)?;
    recover_account_auth_from_candidate(&account_key, &candidate_id)
}

#[tauri::command]
fn mark_account_unusable(
    account_key: String,
    reason: Option<String>,
    login_state: tauri::State<'_, LoginState>,
    action_state: tauri::State<'_, ActionState>,
) -> Result<ActionResult, String> {
    ensure_mutations_unlocked(&login_state, &action_state)?;
    mark_account_blocked_for_recovery(
        &account_key,
        reason.as_deref().unwrap_or(REFRESH_TOKEN_REUSED_HINT),
    )
}

#[tauri::command]
fn clear_login_state(state: tauri::State<'_, LoginState>) -> Result<LoginSnapshot, String> {
    let mut job = state
        .inner
        .lock()
        .map_err(|_| "Login state is unavailable.".to_string())?;
    if job.running {
        return Err("Cannot clear the login panel while a login flow is running.".to_string());
    }
    *job = LoginJobState::default();
    Ok(state.snapshot())
}

#[tauri::command]
fn open_isolated_browser_for_session(
    url: String,
    session_id: String,
    state: tauri::State<'_, IsolatedBrowserState>,
) -> Result<(), String> {
    open_isolated_browser(&url, &session_id, &state.sessions).map(|_| ())
}

#[tauri::command]
fn cleanup_isolated_session(
    session_id: String,
    state: tauri::State<'_, IsolatedBrowserState>,
) -> Result<(), String> {
    let mut sessions = state
        .sessions
        .lock()
        .map_err(|_| "Browser state is unavailable.".to_string())?;
    if let Some(idx) = sessions.iter().position(|s| s.session_id == session_id) {
        let mut session = sessions.remove(idx);
        if let Some(ref mut child) = session.child {
            let _ = child.kill();
            let _ = child.wait();
        }
        cleanup_session_dirs(&session);
        Ok(())
    } else {
        Err(format!("Session '{session_id}' not found."))
    }
}

fn start_action<const N: usize>(
    args: [&str; N],
    state: &tauri::State<'_, ActionState>,
) -> Result<ActionSnapshot, String> {
    let command = format_command(&args);
    let account_key_hint = account_key_arg_hint(&args);
    {
        let mut job = state
            .inner
            .lock()
            .map_err(|_| "Action state is unavailable.".to_string())?;
        if job.running {
            return Err("Another desktop action is already running.".to_string());
        }
        *job = ActionJobState {
            running: true,
            finished: false,
            success: false,
            command: Some(command.clone()),
            account_key_hint,
            output: format!("Launching `{command}`...\n"),
            started_at: Some(now_label()),
            finished_at: None,
            exit_code: None,
            error: None,
            refresh_token_reused: false,
        };
    }

    let shared = Arc::clone(&state.inner);
    let args_owned: Vec<String> = args.iter().map(|arg| (*arg).to_string()).collect();
    std::thread::spawn(move || {
        if let Err(err) = run_action_process(args_owned, &shared) {
            let mut job = shared.lock().expect("action state poisoned");
            job.running = false;
            job.finished = true;
            job.success = false;
            job.finished_at = Some(now_label());
            job.error = Some(err.clone());
            append_line(&mut job.output, &format!("Action failed: {err}"));
            job.refresh_token_reused = is_refresh_token_reused_message(&job.output);
        }
    });

    Ok(state.snapshot())
}

fn account_key_arg_hint(args: &[&str]) -> Option<String> {
    args.windows(2).find_map(|pair| {
        if pair[0] == "--account-key" {
            Some(pair[1].to_string())
        } else {
            None
        }
    })
}

fn validate_switch_account_target(account_key: &str) -> Result<(), String> {
    let (registry, registry_warning) = load_registry();
    if let Some(warning) = registry_warning {
        return Err(warning);
    }
    let account = registry
        .accounts
        .iter()
        .find(|account| account.account_key == account_key)
        .ok_or_else(|| format!("Account {} is not tracked.", short_account_key(account_key)))?;
    let registry_auth_health = account.auth_health.as_deref().unwrap_or("unknown");
    if account_auth_path(account_key).is_err() {
        return Err(format!(
            "Cannot switch to {} because its auth snapshot is missing.",
            preferred_label(account)
        ));
    }
    if account_auth_is_quarantined(account_key)
        || account.auth_quarantined_at.is_some()
        || registry_auth_health == "quarantined"
    {
        return Err(format!(
            "Cannot switch to {} because its auth snapshot is quarantined.",
            preferred_label(account)
        ));
    }
    if matches!(
        registry_auth_health,
        "missing_auth" | "malformed_auth" | "account_mismatch" | "api_failed"
    ) {
        return Err(format!(
            "Cannot switch to {} because auth health is {registry_auth_health}.",
            preferred_label(account)
        ));
    }
    if is_refresh_token_reused_message(account.auth_error.as_deref().unwrap_or_default()) {
        return Err(format!(
            "Cannot switch to {} because refresh-token reuse was detected.",
            preferred_label(account)
        ));
    }
    if account_is_blocked(&registry, account, Utc::now().timestamp()) {
        return Err(format!(
            "Cannot switch to {} because it is temporarily blocked.",
            preferred_label(account)
        ));
    }
    Ok(())
}

fn run_switch_account_now(
    binary_path: &Path,
    account_key: &str,
    args: &[&str],
) -> Result<String, String> {
    let output = match run_codex_auth_dynamic(
        binary_path,
        args,
        Duration::from_secs(CLI_IMPORT_TIMEOUT_SECONDS),
    ) {
        Ok(output) => output,
        Err(err) if is_refresh_token_reused_message(&err) => {
            let mut parts = vec![
                err,
                "Detected reused refresh token. Attempting local auth recovery before retrying switch."
                    .to_string(),
            ];
            match handle_refresh_token_incident(Some(account_key), "switch") {
                Ok(Some(outcome)) => {
                    parts.push(outcome.output);
                    parts.push("Retrying switch after local recovery.".to_string());
                }
                Ok(None) => {
                    parts.push(
                        "No tracked account could be resolved for refresh-token recovery."
                            .to_string(),
                    );
                    return Err(join_command_texts(parts));
                }
                Err(recovery_err) => {
                    parts.push(format!("Refresh-token recovery failed: {recovery_err}"));
                    return Err(join_command_texts(parts));
                }
            }

            match run_codex_auth_dynamic(
                binary_path,
                args,
                Duration::from_secs(CLI_IMPORT_TIMEOUT_SECONDS),
            ) {
                Ok(retry_output) => {
                    let rendered = render_command_output(&retry_output);
                    if !rendered.trim().is_empty() {
                        parts.push(rendered);
                    }
                    parts.push(verify_switch_activation(account_key)?);
                    if let Some(warning) = running_codex_cli_warning() {
                        parts.push(warning);
                    }
                    return Ok(join_command_texts(parts));
                }
                Err(retry_err) => {
                    parts.push(format!("Retry failed: {retry_err}"));
                    return Err(join_command_texts(parts));
                }
            }
        }
        Err(err) => return Err(err),
    };

    let mut parts = Vec::new();
    let rendered = render_command_output(&output);
    if !rendered.trim().is_empty() {
        parts.push(rendered);
    }
    parts.push(verify_switch_activation(account_key)?);
    if let Some(warning) = running_codex_cli_warning() {
        parts.push(warning);
    }
    Ok(join_command_texts(parts))
}

fn join_command_texts(parts: Vec<String>) -> String {
    parts
        .into_iter()
        .map(|part| part.trim().to_string())
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join("\n")
}

fn verify_switch_activation(account_key: &str) -> Result<String, String> {
    let (registry, registry_warning) = load_registry();
    if let Some(warning) = registry_warning {
        return Err(format!("Switch verification failed: {warning}"));
    }

    verify_registry_active_account(&registry, account_key)?;

    let auth_path = resolve_codex_home()?.join("auth.json");
    if !auth_path.exists() {
        return Err(format!(
            "Switch verification failed: active auth was not written at {}.",
            auth_path.display()
        ));
    }
    let active_auth_key = account_key_from_auth_path(&auth_path)
        .map_err(|err| format!("Switch verification failed: {err}"))?;
    if active_auth_key != account_key {
        return Err(format!(
            "Switch verification failed: auth.json belongs to {}, expected {}.",
            short_account_key(&active_auth_key),
            short_account_key(account_key)
        ));
    }

    let label = registry
        .accounts
        .iter()
        .find(|account| account.account_key == account_key)
        .map(preferred_label)
        .unwrap_or_else(|| short_account_key(account_key));
    Ok(format!(
        "Verified switch: Codex CLI auth is now {} ({}).",
        label,
        short_account_key(account_key)
    ))
}

fn verify_registry_active_account(
    registry: &RegistryFile,
    expected_account_key: &str,
) -> Result<(), String> {
    match registry.active_account_key.as_deref() {
        Some(active_key) if active_key == expected_account_key => Ok(()),
        Some(active_key) => Err(format!(
            "Switch verification failed: registry active account is {}, expected {}.",
            short_account_key(active_key),
            short_account_key(expected_account_key)
        )),
        None => Err(format!(
            "Switch verification failed: registry has no active account, expected {}.",
            short_account_key(expected_account_key)
        )),
    }
}

fn running_codex_cli_warning() -> Option<String> {
    match find_running_codex_cli_processes() {
        Ok(processes) if !processes.is_empty() => Some(format!(
            "Warning: detected {} running Codex/Codext CLI process{}. Existing sessions keep their cached auth; close and reopen them to use the switched account.",
            processes.len(),
            if processes.len() == 1 { "" } else { "es" }
        )),
        _ => None,
    }
}

#[cfg(unix)]
fn find_running_codex_cli_processes() -> Result<Vec<u32>, String> {
    let output = Command::new("ps")
        .args(["-eo", "pid=,comm=,args="])
        .output()
        .map_err(|err| format!("Failed to inspect running Codex processes: {err}"))?;
    if !output.status.success() {
        return Err("Failed to inspect running Codex processes.".to_string());
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut pids = Vec::new();
    for line in stdout.lines() {
        let mut fields = line.split_whitespace();
        let Some(pid_text) = fields.next() else {
            continue;
        };
        let Some(command_name) = fields.next() else {
            continue;
        };
        let Ok(pid) = pid_text.parse::<u32>() else {
            continue;
        };
        if pid == std::process::id() {
            continue;
        }
        let args = fields.collect::<Vec<_>>().join(" ");
        if is_codex_cli_process(command_name, &args) {
            pids.push(pid);
        }
    }
    Ok(pids)
}

#[cfg(not(unix))]
fn find_running_codex_cli_processes() -> Result<Vec<u32>, String> {
    Ok(Vec::new())
}

fn is_codex_cli_process(command_name: &str, args: &str) -> bool {
    let command_name = command_name.to_ascii_lowercase();
    let args = args.to_ascii_lowercase();
    if args.contains("codex-auth")
        || args.contains("codex-auth-studio")
        || args.contains("codex-auth-desktop")
    {
        return false;
    }

    command_name == "codex"
        || command_name == "codext"
        || args.contains("/bin/codex")
        || args.contains("/bin/codext")
        || args.contains("\\bin\\codex")
        || args.contains("\\bin\\codext")
}

#[derive(Clone, Copy)]
enum QuotaConfirmScope {
    Dashboard,
    All,
}

#[derive(Clone)]
struct QuotaConfirmTask {
    account_key: String,
    label: String,
    auth_path: PathBuf,
}

struct QuotaConfirmTaskResult {
    account_key: String,
    label: String,
    record: ConfirmedQuotaRecord,
}

fn maybe_start_dashboard_quota_confirm(
    registry: &RegistryFile,
    state: &tauri::State<'_, QuotaConfirmState>,
) {
    if !registry.api.usage {
        return;
    }
    let targets = quota_confirm_targets(registry, QuotaConfirmScope::Dashboard, false, state);
    if targets.is_empty() {
        return;
    }
    let _ = start_quota_confirm(targets, "dashboard".to_string(), false, state);
}

fn quota_confirm_targets(
    registry: &RegistryFile,
    scope: QuotaConfirmScope,
    force: bool,
    state: &QuotaConfirmState,
) -> Vec<QuotaConfirmTask> {
    quota_confirm_targets_with_auth_resolver(registry, scope, force, state, |account_key| {
        account_auth_path(account_key).ok()
    })
}

fn quota_confirm_targets_with_auth_resolver<F>(
    registry: &RegistryFile,
    scope: QuotaConfirmScope,
    force: bool,
    state: &QuotaConfirmState,
    resolve_auth_path: F,
) -> Vec<QuotaConfirmTask>
where
    F: Fn(&str) -> Option<PathBuf>,
{
    let now = Utc::now().timestamp();
    let ttl = match scope {
        QuotaConfirmScope::Dashboard => API_QUOTA_CONFIRM_DASHBOARD_TTL_SECONDS,
        QuotaConfirmScope::All => API_QUOTA_CONFIRM_TTL_SECONDS,
    };
    let cache = state.cache_snapshot();
    let mut keys = Vec::<String>::new();
    match scope {
        QuotaConfirmScope::Dashboard => {
            if let Some(active_key) = registry.active_account_key.as_ref() {
                push_unique_key(&mut keys, active_key);
            }
            if let Some(best_key) = best_known_account_key(registry) {
                push_unique_key(&mut keys, best_key);
            }
            for account in &registry.accounts {
                if !account_is_chatgpt(account) {
                    continue;
                }
                let freshness =
                    snapshot_freshness_at(now, account.last_usage.is_some(), account.last_usage_at);
                if freshness != SnapshotFreshness::Fresh {
                    push_unique_key(&mut keys, &account.account_key);
                }
            }
        }
        QuotaConfirmScope::All => {
            keys.extend(
                registry
                    .accounts
                    .iter()
                    .filter(|account| account_is_chatgpt(account))
                    .map(|account| account.account_key.clone()),
            );
        }
    }

    let mut targets = Vec::new();
    for key in keys {
        let Some(account) = registry
            .accounts
            .iter()
            .find(|account| account.account_key == key)
        else {
            continue;
        };
        if !account_is_chatgpt(account) {
            continue;
        }
        if !force && confirmed_quota_is_fresh(cache.get(account.account_key.as_str()), now, ttl) {
            continue;
        }
        let Some(auth_path) = resolve_auth_path(&account.account_key) else {
            continue;
        };
        targets.push(QuotaConfirmTask {
            account_key: account.account_key.clone(),
            label: preferred_label(account),
            auth_path,
        });
    }
    targets
}

fn push_unique_key(keys: &mut Vec<String>, key: &str) {
    if !keys.iter().any(|existing| existing == key) {
        keys.push(key.to_string());
    }
}

fn confirmed_quota_is_fresh(
    record: Option<&ConfirmedQuotaRecord>,
    now: i64,
    ttl_seconds: i64,
) -> bool {
    record
        .map(|record| now.saturating_sub(record.checked_at) < ttl_seconds)
        .unwrap_or(false)
}

fn start_quota_confirm(
    targets: Vec<QuotaConfirmTask>,
    scope: String,
    force: bool,
    state: &tauri::State<'_, QuotaConfirmState>,
) -> Result<QuotaConfirmSnapshot, String> {
    {
        let mut job = state
            .inner
            .lock()
            .map_err(|_| "Quota confirmation state is unavailable.".to_string())?;
        if job.running {
            return Ok(QuotaConfirmSnapshot {
                running: job.running,
                finished: job.finished,
                success: job.success,
                scope: job.scope.clone(),
                output: job.output.clone(),
                started_at: job.started_at.clone(),
                finished_at: job.finished_at.clone(),
                checked_accounts: job.checked_accounts,
                total_accounts: job.total_accounts,
                error: job.error.clone(),
            });
        }
        if force {
            for task in &targets {
                job.cache.remove(task.account_key.as_str());
            }
        }
        job.running = true;
        job.finished = false;
        job.success = false;
        job.scope = Some(scope.clone());
        job.output = format!(
            "Confirming API quota for {} account{} ({scope})...\n",
            targets.len(),
            if targets.len() == 1 { "" } else { "s" }
        );
        job.started_at = Some(now_label());
        job.finished_at = None;
        job.checked_accounts = 0;
        job.total_accounts = targets.len();
        job.error = None;
    }

    let shared = Arc::clone(&state.inner);
    std::thread::spawn(move || run_quota_confirm_process(targets, shared));
    Ok(state.snapshot())
}

fn run_quota_confirm_process(
    targets: Vec<QuotaConfirmTask>,
    shared: Arc<Mutex<QuotaConfirmJobState>>,
) {
    let mut any_success = false;
    let mut any_persist_error = false;
    for chunk in targets.chunks(API_QUOTA_CONFIRM_PARALLELISM.max(1)) {
        let mut handles = Vec::new();
        for task in chunk.iter().cloned() {
            handles.push(std::thread::spawn(move || run_quota_confirm_task(task)));
        }

        for handle in handles {
            match handle.join() {
                Ok(result) => {
                    any_success |= result.record.snapshot.is_some();
                    let (outcome, persist_error) = quota_confirm_outcome_text(&result);
                    any_persist_error |= persist_error.is_some();
                    let mut job = shared.lock().expect("quota confirm state poisoned");
                    job.checked_accounts += 1;
                    append_line(&mut job.output, &outcome);
                    if let Some(err) = persist_error {
                        job.error = Some(err);
                    }
                    job.cache.insert(result.account_key, result.record);
                }
                Err(_) => {
                    let mut job = shared.lock().expect("quota confirm state poisoned");
                    job.checked_accounts += 1;
                    append_line(&mut job.output, "quota confirmation worker panicked");
                }
            }
        }
    }

    let mut job = shared.lock().expect("quota confirm state poisoned");
    job.running = false;
    job.finished = true;
    job.success = (any_success && !any_persist_error) || job.total_accounts == 0;
    job.finished_at = Some(now_label());
    if !job.success {
        if job.error.is_none() {
            job.error = Some("No account quota could be confirmed via API.".to_string());
        }
    }
}

fn quota_confirm_outcome_text(result: &QuotaConfirmTaskResult) -> (String, Option<String>) {
    if result.record.snapshot.is_none() {
        return (format!("unconfirmed {}", result.label), None);
    }

    match persist_confirmed_quota_record(&result.account_key, &result.record) {
        Ok(true) => (format!("confirmed {} (saved)", result.label), None),
        Ok(false) => (format!("confirmed {}", result.label), None),
        Err(err) => {
            let message = format!("Failed to save confirmed quota for {}: {err}", result.label);
            (
                format!("confirmed {} (save failed)", result.label),
                Some(message),
            )
        }
    }
}

fn run_quota_confirm_task(task: QuotaConfirmTask) -> QuotaConfirmTaskResult {
    let record = match fetch_usage_for_auth_path(&task.auth_path) {
        Ok(record) => record,
        Err(err) => ConfirmedQuotaRecord {
            snapshot: None,
            checked_at: Utc::now().timestamp(),
            status_code: None,
            error: Some(err),
        },
    };
    QuotaConfirmTaskResult {
        account_key: task.account_key,
        label: task.label,
        record,
    }
}

fn ensure_mutations_unlocked(
    login_state: &tauri::State<'_, LoginState>,
    action_state: &tauri::State<'_, ActionState>,
) -> Result<(), String> {
    ensure_mutations_unlocked_login_state(login_state)?;
    ensure_mutations_unlocked_action_state(action_state)
}

fn ensure_mutations_unlocked_login_state(state: &LoginState) -> Result<(), String> {
    let job = state
        .inner
        .lock()
        .map_err(|_| "Login state is unavailable.".to_string())?;
    if job.running {
        return Err("Cannot run account mutations while a login flow is running.".to_string());
    }
    Ok(())
}

fn ensure_mutations_unlocked_action_state(state: &ActionState) -> Result<(), String> {
    let job = state
        .inner
        .lock()
        .map_err(|_| "Action state is unavailable.".to_string())?;
    if job.running {
        return Err(
            "Cannot run another desktop action while a command is already running.".to_string(),
        );
    }
    Ok(())
}

fn run_action_process(
    args: Vec<String>,
    shared: &Arc<Mutex<ActionJobState>>,
) -> Result<(), String> {
    let binary = require_cli_runtime_binary()?;
    let command_text = format_owned_command(&args);
    let mut command = Command::new(&binary);
    command.args(args.iter().map(String::as_str));
    command.stdin(Stdio::null());
    command.stdout(Stdio::piped());
    command.stderr(Stdio::piped());

    let mut child = command
        .spawn()
        .map_err(|err| format!("Failed to launch `{}`: {err}", binary.display()))?;

    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| "Failed to capture action stdout.".to_string())?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| "Failed to capture action stderr.".to_string())?;

    let out_state = Arc::clone(shared);
    let out_reader = std::thread::spawn(move || stream_action_pipe(stdout, None, out_state));
    let err_state = Arc::clone(shared);
    let err_reader =
        std::thread::spawn(move || stream_action_pipe(stderr, Some("stderr"), err_state));

    let status = child
        .wait()
        .map_err(|err| format!("Action process failed while waiting: {err}"))?;
    let _ = out_reader.join();
    let _ = err_reader.join();

    let mut job = shared.lock().expect("action state poisoned");
    job.running = false;
    job.finished = true;
    job.finished_at = Some(now_label());
    job.exit_code = status.code();

    if status.success() {
        job.success = true;
        if job.output.trim() == format!("Launching `{command_text}`...") {
            append_line(&mut job.output, "Command completed.");
        }
        return Ok(());
    }

    job.success = false;
    job.refresh_token_reused = is_refresh_token_reused_message(&job.output);
    let failure = format!(
        "`{command_text}` exited with {}.",
        status
            .code()
            .map(|code| code.to_string())
            .unwrap_or_else(|| "a signal".to_string())
    );
    job.error = Some(failure.clone());
    if !job.output.contains(&failure) {
        append_line(&mut job.output, &failure);
    }
    if job.refresh_token_reused {
        append_line(
            &mut job.output,
            "Detected reused refresh token. Attempting local auth recovery before asking for another login.",
        );
    }
    let should_recover_auth = job.refresh_token_reused;
    let account_key_hint = job.account_key_hint.clone();
    drop(job);

    if should_recover_auth {
        let message = match handle_refresh_token_incident(account_key_hint.as_deref(), "action") {
            Ok(Some(outcome)) => outcome.output,
            Ok(None) => {
                "No tracked account could be resolved for refresh-token recovery.".to_string()
            }
            Err(err) => format!("Refresh-token recovery failed: {err}"),
        };
        let mut job = shared.lock().expect("action state poisoned");
        append_line(&mut job.output, &message);
    }
    Ok(())
}

fn run_login_process(
    device_auth: bool,
    isolated: bool,
    shared: &Arc<Mutex<LoginJobState>>,
    url_ready: &Arc<(Mutex<bool>, Condvar)>,
    cancel_requested: &Arc<AtomicBool>,
    browser_sessions: &Arc<Mutex<Vec<IsolatedBrowserSession>>>,
) -> Result<(), String> {
    let binary = require_cli_runtime_binary()?;
    let login_binary = if isolated {
        require_codex_binary()?
    } else {
        binary.clone()
    };
    let command_label = if isolated { "codex" } else { "codex-auth" };
    let mut command = Command::new(&login_binary);
    command.arg("login");
    if device_auth {
        command.arg("--device-auth");
    }

    let mut noop_dir_path: Option<PathBuf> = None;
    let mut isolated_codex_home_path: Option<PathBuf> = None;
    if isolated {
        let session_id = {
            let job = shared.lock().expect("login state poisoned");
            job.isolated_session_id.clone().unwrap_or_default()
        };
        let noop_dir = setup_noop_xdg_open(&session_id)?;
        let isolated_codex_home = setup_isolated_codex_home(&session_id)?;
        let current_path = env::var("PATH").unwrap_or_default();
        command.env("PATH", format!("{}:{current_path}", noop_dir.display()));
        command.env("BROWSER", noop_dir.join("codex-auth-noop-browser"));
        command.env("CODEX_HOME", &isolated_codex_home);
        noop_dir_path = Some(noop_dir);
        isolated_codex_home_path = Some(isolated_codex_home.clone());

        let mut job = shared.lock().expect("login state poisoned");
        job.phase = LOGIN_PHASE_WAITING_FOR_URL.to_string();
        job.diagnostic = Some(format!(
            "isolated CODEX_HOME={}, login binary={}",
            isolated_codex_home.as_path().display(),
            login_binary.display()
        ));
        append_line(
            &mut job.output,
            "Isolated mode: using a temporary Codex home so broken active auth cannot block login.",
        );
    } else {
        let mut job = shared.lock().expect("login state poisoned");
        job.phase = LOGIN_PHASE_WAITING_FOR_CALLBACK.to_string();
    }

    command.stdin(Stdio::null());
    command.stdout(Stdio::piped());
    command.stderr(Stdio::piped());

    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(err) => {
            if let Some(ref dir) = noop_dir_path {
                let _ = fs::remove_dir_all(dir);
            }
            if let Some(ref dir) = isolated_codex_home_path {
                let _ = fs::remove_dir_all(dir);
            }
            return Err(format!("Failed to launch `{command_label}`: {err}"));
        }
    };

    let stdout = match child.stdout.take() {
        Some(stdout) => stdout,
        None => {
            let _ = child.kill();
            let _ = child.wait();
            if let Some(ref dir) = noop_dir_path {
                let _ = fs::remove_dir_all(dir);
            }
            if let Some(ref dir) = isolated_codex_home_path {
                let _ = fs::remove_dir_all(dir);
            }
            return Err("Failed to capture login stdout.".to_string());
        }
    };
    let stderr = match child.stderr.take() {
        Some(stderr) => stderr,
        None => {
            let _ = child.kill();
            let _ = child.wait();
            if let Some(ref dir) = noop_dir_path {
                let _ = fs::remove_dir_all(dir);
            }
            if let Some(ref dir) = isolated_codex_home_path {
                let _ = fs::remove_dir_all(dir);
            }
            return Err("Failed to capture login stderr.".to_string());
        }
    };

    let out_state = Arc::clone(shared);
    let out_url_ready = Arc::clone(url_ready);
    let out_reader = std::thread::spawn(move || {
        stream_pipe_with_url_notify(stdout, None, out_state, out_url_ready);
    });
    let err_state = Arc::clone(shared);
    let err_url_ready = Arc::clone(url_ready);
    let err_reader = std::thread::spawn(move || {
        stream_pipe_with_url_notify(stderr, Some("stderr"), err_state, err_url_ready);
    });

    if isolated {
        let browser_sessions_clone = Arc::clone(browser_sessions);
        let shared_clone = Arc::clone(shared);
        let url_ready_clone = Arc::clone(url_ready);
        std::thread::spawn(move || {
            let url_ready = {
                let (lock, cvar) = &*url_ready_clone;
                let guard = lock.lock().expect("url_ready poisoned");
                let result = cvar
                    .wait_timeout(guard, std::time::Duration::from_secs(60))
                    .expect("url_ready poisoned");
                let ready = *result.0;
                drop(result);
                ready
            };
            if !url_ready {
                let url_from_output = {
                    let job = shared_clone.lock().expect("login state poisoned");
                    job.login_url.clone()
                };
                if url_from_output.is_none() {
                    let mut job = shared_clone.lock().expect("login state poisoned");
                    job.diagnostic =
                        Some("Timed out waiting for a valid OpenAI/ChatGPT OAuth URL.".to_string());
                    append_line(&mut job.output, "Warning: timed out waiting for login URL.");
                    return;
                }
            }
            let (url, session_id) = {
                let job = shared_clone.lock().expect("login state poisoned");
                (
                    job.login_url.clone(),
                    job.isolated_session_id.clone().unwrap_or_default(),
                )
            };
            if let Some(url) = url {
                match open_isolated_browser(&url, &session_id, &browser_sessions_clone) {
                    Ok(_) => {
                        let mut job = shared_clone.lock().expect("login state poisoned");
                        job.phase = LOGIN_PHASE_BROWSER_OPEN.to_string();
                        job.browser_url_opened = true;
                        append_line(
                            &mut job.output,
                            &format!("Opened isolated browser for: {url}"),
                        );
                    }
                    Err(err) => {
                        let mut job = shared_clone.lock().expect("login state poisoned");
                        job.diagnostic = Some(err.clone());
                        append_line(
                            &mut job.output,
                            &format!("Failed to open isolated browser: {err}"),
                        );
                    }
                }
            }
        });
    }

    let mut cancelled = false;
    let status = loop {
        if cancel_requested.load(AtomicOrdering::SeqCst) {
            cancelled = true;
            let _ = child.kill();
            break child.wait().map_err(|err| {
                format!("Login process failed while waiting after cancel: {err}")
            })?;
        }
        match child
            .try_wait()
            .map_err(|err| format!("Login process failed while polling: {err}"))?
        {
            Some(status) => break status,
            None => std::thread::sleep(Duration::from_millis(200)),
        }
    };
    let _ = out_reader.join();
    let _ = err_reader.join();

    if let Some(noop_dir) = noop_dir_path {
        let _ = fs::remove_dir_all(&noop_dir);
    }

    if cancelled {
        let mut job = shared.lock().expect("login state poisoned");
        job.running = false;
        job.finished = true;
        job.finished_at = Some(now_label());
        job.exit_code = status.code();
        job.success = false;
        job.cancelled = true;
        job.phase = LOGIN_PHASE_CANCELLED.to_string();
        job.error = Some("Login cancelled.".to_string());
        append_line(&mut job.output, "Login cancelled.");
        job.login_url = extract_login_url(&job.output);
        if let Some(ref dir) = isolated_codex_home_path {
            let _ = fs::remove_dir_all(dir);
        }
        return Ok(());
    }

    if status.success() {
        if let Some(ref isolated_codex_home) = isolated_codex_home_path {
            {
                let mut job = shared.lock().expect("login state poisoned");
                job.phase = LOGIN_PHASE_IMPORTING.to_string();
                job.import_started = true;
                append_line(
                    &mut job.output,
                    "Importing isolated login result into the main account registry...",
                );
            }
            let output = match import_isolated_login_auth(&binary, isolated_codex_home) {
                Ok(output) => output,
                Err(err) => {
                    let _ = fs::remove_dir_all(isolated_codex_home);
                    return Err(err);
                }
            };
            let rendered = render_command_output(&output);
            if !rendered.trim().is_empty() {
                let mut job = shared.lock().expect("login state poisoned");
                append_line(&mut job.output, rendered.trim());
            }
            {
                let mut job = shared.lock().expect("login state poisoned");
                job.import_finished = true;
            }
            let _ = fs::remove_dir_all(isolated_codex_home);
        }
        let mut job = shared.lock().expect("login state poisoned");
        job.running = false;
        job.finished = true;
        job.finished_at = Some(now_label());
        job.exit_code = status.code();
        job.success = true;
        job.phase = LOGIN_PHASE_SUCCESS.to_string();
        append_line(
            &mut job.output,
            "Login completed. Refreshing account state is safe now.",
        );
        job.login_url = extract_login_url(&job.output);
        return Ok(());
    }

    let mut job = shared.lock().expect("login state poisoned");
    job.running = false;
    job.finished = true;
    job.finished_at = Some(now_label());
    job.exit_code = status.code();
    job.success = false;
    job.phase = LOGIN_PHASE_FAILED.to_string();
    let failure = format!(
        "Login exited with {}.",
        status
            .code()
            .map(|code| code.to_string())
            .unwrap_or_else(|| "a signal".to_string())
    );
    job.error = Some(failure.clone());
    append_line(&mut job.output, &failure);
    job.login_url = extract_login_url(&job.output);
    job.refresh_token_reused = is_refresh_token_reused_message(&job.output);
    if job.refresh_token_reused {
        append_line(
            &mut job.output,
            "Detected reused refresh token. Attempting local auth recovery before asking for another login.",
        );
    }
    let should_recover_auth = job.refresh_token_reused;
    drop(job);
    if should_recover_auth {
        let message = match handle_refresh_token_incident(None, "login") {
            Ok(Some(outcome)) => outcome.output,
            Ok(None) => {
                "No tracked account could be resolved for refresh-token recovery.".to_string()
            }
            Err(err) => format!("Refresh-token recovery failed: {err}"),
        };
        let mut job = shared.lock().expect("login state poisoned");
        append_line(&mut job.output, &message);
    }
    if let Some(ref dir) = isolated_codex_home_path {
        let _ = fs::remove_dir_all(dir);
    }
    Ok(())
}

fn setup_isolated_codex_home(session_id: &str) -> Result<PathBuf, String> {
    let dir = isolated_cache_root()?
        .join("isolated-homes")
        .join(session_id);
    create_private_dir(&dir).map_err(|err| {
        format!(
            "Failed to create isolated Codex home at {}: {err}",
            dir.display()
        )
    })?;
    Ok(dir)
}

fn isolated_cache_root() -> Result<PathBuf, String> {
    let cache_dir = dirs::cache_dir()
        .or_else(dirs::home_dir)
        .ok_or_else(|| "Cache directory is unavailable.".to_string())?;
    Ok(cache_dir.join("codex-auth-studio"))
}

fn create_private_dir(path: &Path) -> Result<(), std::io::Error> {
    fs::create_dir_all(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

fn import_isolated_login_auth(
    codex_auth_binary: &Path,
    isolated_codex_home: &Path,
) -> Result<CommandOutput, String> {
    let auth_path = isolated_codex_home.join("auth.json");
    if !auth_path.exists() {
        return Err(format!(
            "Isolated login completed, but no auth.json was created at {}.",
            auth_path.display()
        ));
    }
    let account_key = account_key_from_auth_path(&auth_path)?;
    let auth_arg = auth_path.to_string_lossy().to_string();
    let import_output = run_codex_auth_dynamic(
        codex_auth_binary,
        &["import", auth_arg.as_str()],
        Duration::from_secs(CLI_IMPORT_TIMEOUT_SECONDS),
    )?;
    let switch_output = run_codex_auth_dynamic(
        codex_auth_binary,
        &["switch", "--account-key", account_key.as_str()],
        Duration::from_secs(CLI_IMPORT_TIMEOUT_SECONDS),
    )?;
    Ok(CommandOutput {
        stdout: join_command_streams(&[
            import_output.stdout.as_str(),
            switch_output.stdout.as_str(),
            &format!("Activated isolated login account {account_key}."),
        ]),
        stderr: join_command_streams(&[
            import_output.stderr.as_str(),
            switch_output.stderr.as_str(),
        ]),
    })
}

#[derive(Deserialize)]
struct AccountAuthJson {
    #[serde(default)]
    auth_mode: Option<String>,
    tokens: Option<AccountAuthTokensJson>,
}

#[derive(Deserialize)]
struct AccountAuthTokensJson {
    access_token: String,
    account_id: String,
    #[serde(default)]
    id_token: Option<String>,
}

fn join_command_streams(parts: &[&str]) -> String {
    parts
        .iter()
        .map(|part| part.trim())
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join("\n")
}

fn account_key_from_auth_path(auth_path: &Path) -> Result<String, String> {
    let auth = load_account_auth(auth_path)?;
    let tokens = auth
        .tokens
        .ok_or_else(|| format!("Auth snapshot is missing tokens: {}", auth_path.display()))?;
    let id_token = tokens
        .id_token
        .ok_or_else(|| format!("Auth snapshot is missing id_token: {}", auth_path.display()))?;
    let payload = id_token
        .split('.')
        .nth(1)
        .ok_or_else(|| "Auth id_token is not a JWT.".to_string())?;
    let payload_bytes = base64_url_decode_no_pad(payload)?;
    let claims: serde_json::Value = serde_json::from_slice(&payload_bytes)
        .map_err(|err| format!("Auth id_token payload is malformed JSON: {err}"))?;
    let auth_claims = claims
        .get("https://api.openai.com/auth")
        .and_then(|value| value.as_object())
        .ok_or_else(|| "Auth id_token is missing OpenAI account claims.".to_string())?;
    let user_id = auth_claims
        .get("chatgpt_user_id")
        .or_else(|| auth_claims.get("user_id"))
        .and_then(|value| value.as_str())
        .filter(|value| !value.is_empty())
        .ok_or_else(|| "Auth id_token is missing chatgpt_user_id.".to_string())?;
    if let Some(jwt_account_id) = auth_claims
        .get("chatgpt_account_id")
        .and_then(|value| value.as_str())
        .filter(|value| !value.is_empty())
    {
        if jwt_account_id != tokens.account_id {
            return Err("Auth id_token account_id does not match tokens.account_id.".to_string());
        }
    }
    Ok(format!("{user_id}::{}", tokens.account_id))
}

#[derive(Deserialize)]
struct UsageApiResponse {
    #[serde(default)]
    plan_type: Option<String>,
    #[serde(default)]
    rate_limit: Option<UsageApiRateLimit>,
}

#[derive(Deserialize)]
struct UsageApiRateLimit {
    #[serde(default)]
    primary_window: Option<UsageApiWindow>,
    #[serde(default)]
    secondary_window: Option<UsageApiWindow>,
}

#[derive(Deserialize)]
struct UsageApiWindow {
    used_percent: f64,
    #[serde(default)]
    limit_window_seconds: Option<i64>,
    #[serde(default)]
    reset_at: Option<i64>,
}

fn fetch_usage_for_auth_path(auth_path: &Path) -> Result<ConfirmedQuotaRecord, String> {
    let auth = load_account_auth(auth_path)?;
    if auth
        .auth_mode
        .as_deref()
        .map(|mode| mode != "chatgpt")
        .unwrap_or(false)
    {
        return Ok(ConfirmedQuotaRecord {
            snapshot: None,
            checked_at: Utc::now().timestamp(),
            status_code: None,
            error: Some("Auth mode is not ChatGPT.".to_string()),
        });
    }
    let tokens = auth
        .tokens
        .ok_or_else(|| format!("Auth snapshot is missing tokens: {}", auth_path.display()))?;
    let output = run_usage_api_curl(&tokens.access_token, &tokens.account_id)?;
    let (body, status_code) = parse_curl_json_status_output(&output)?;
    let snapshot = if body.trim().is_empty() {
        None
    } else {
        parse_usage_api_response(body)?
    };
    Ok(ConfirmedQuotaRecord {
        snapshot,
        checked_at: Utc::now().timestamp(),
        status_code,
        error: status_code
            .filter(|status| *status != 200)
            .map(|status| format!("Usage API returned HTTP {status}.")),
    })
}

fn persist_confirmed_quota_record(
    account_key: &str,
    record: &ConfirmedQuotaRecord,
) -> Result<bool, String> {
    let Some(snapshot) = record.snapshot.clone() else {
        return Ok(false);
    };

    let registry_path = resolve_codex_home()?.join("accounts").join("registry.json");
    let data = fs::read_to_string(&registry_path).map_err(|err| {
        format!(
            "Could not read registry at {}: {err}",
            registry_path.display()
        )
    })?;
    let mut registry_json: serde_json::Value = serde_json::from_str(&data).map_err(|err| {
        format!(
            "Registry is malformed at {}: {err}",
            registry_path.display()
        )
    })?;
    let Some(accounts) = registry_json
        .get_mut("accounts")
        .and_then(|accounts| accounts.as_array_mut())
    else {
        return Err(format!(
            "Registry has no accounts array at {}.",
            registry_path.display()
        ));
    };
    let Some(account) = accounts.iter_mut().find(|account| {
        account
            .get("account_key")
            .and_then(|value| value.as_str())
            .map(|key| key == account_key)
            .unwrap_or(false)
    }) else {
        return Ok(false);
    };

    let has_snapshot = account
        .get("last_usage")
        .map(|value| !value.is_null())
        .unwrap_or(false);
    let last_usage_at = account
        .get("last_usage_at")
        .and_then(|value| value.as_i64());
    if snapshot_freshness_at(record.checked_at, has_snapshot, last_usage_at)
        == SnapshotFreshness::Fresh
    {
        return Ok(false);
    }

    let Some(account_object) = account.as_object_mut() else {
        return Err(format!(
            "Registry account entry is malformed for {}.",
            short_account_key(account_key)
        ));
    };
    let snapshot_value = serde_json::to_value(snapshot)
        .map_err(|err| format!("Failed to serialize quota snapshot: {err}"))?;
    account_object.insert("last_usage".to_string(), snapshot_value);
    account_object.insert(
        "last_usage_at".to_string(),
        serde_json::Value::from(record.checked_at),
    );
    if record.status_code == Some(200) {
        account_object.insert(
            "auth_health".to_string(),
            serde_json::Value::from("verified"),
        );
        account_object.insert(
            "auth_checked_at".to_string(),
            serde_json::Value::from(record.checked_at),
        );
        account_object.insert(
            "auth_verified_at".to_string(),
            serde_json::Value::from(record.checked_at),
        );
        account_object.insert("auth_error".to_string(), serde_json::Value::Null);
        account_object.insert("auth_quarantined_at".to_string(), serde_json::Value::Null);
    }
    backup_file_if_exists(&registry_path)?;
    let rendered = serde_json::to_vec_pretty(&registry_json)
        .map_err(|err| format!("Failed to serialize registry: {err}"))?;
    write_private_file(&registry_path, &rendered)?;
    Ok(true)
}

fn load_account_auth(auth_path: &Path) -> Result<AccountAuthJson, String> {
    let data = fs::read_to_string(auth_path).map_err(|err| {
        format!(
            "Could not read auth snapshot at {}: {err}",
            auth_path.display()
        )
    })?;
    serde_json::from_str::<AccountAuthJson>(&data).map_err(|err| {
        format!(
            "Auth snapshot is malformed at {}: {err}",
            auth_path.display()
        )
    })
}

fn run_usage_api_curl(access_token: &str, account_id: &str) -> Result<String, String> {
    let output = Command::new("curl")
        .args([
            "--silent",
            "--show-error",
            "--location",
            "--connect-timeout",
            "5",
            "--max-time",
            "5",
            "--write-out",
            "\n%{http_code}",
            "-H",
            &format!("Authorization: Bearer {access_token}"),
            "-H",
            &format!("ChatGPT-Account-Id: {account_id}"),
            "-H",
            "User-Agent: codex-auth",
            USAGE_API_ENDPOINT,
        ])
        .output()
        .map_err(|err| format!("Failed to run curl for usage API: {err}"))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!(
            "Usage API transport failed with curl exit {}: {}",
            output
                .status
                .code()
                .map(|code| code.to_string())
                .unwrap_or_else(|| "signal".to_string()),
            stderr.trim()
        ));
    }
    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

fn parse_curl_json_status_output(output: &str) -> Result<(&str, Option<u16>), String> {
    let trimmed = output.trim_end_matches(['\r', '\n']);
    let Some((body, status_text)) = trimmed.rsplit_once('\n') else {
        return Err("Usage API response is missing HTTP status.".to_string());
    };
    let status = status_text
        .trim()
        .parse::<u16>()
        .map_err(|_| format!("Usage API returned a malformed HTTP status: {status_text}"))?;
    Ok((
        body.trim_end_matches('\r'),
        if status == 0 { None } else { Some(status) },
    ))
}

fn parse_usage_api_response(body: &str) -> Result<Option<RateLimitSnapshot>, String> {
    let response = serde_json::from_str::<UsageApiResponse>(body)
        .map_err(|err| format!("Usage API JSON is malformed: {err}"))?;
    let primary = response
        .rate_limit
        .as_ref()
        .and_then(|rate_limit| rate_limit.primary_window.as_ref())
        .map(usage_api_window_to_rate_limit_window);
    let secondary = response
        .rate_limit
        .as_ref()
        .and_then(|rate_limit| rate_limit.secondary_window.as_ref())
        .map(usage_api_window_to_rate_limit_window);
    if primary.is_none() && secondary.is_none() {
        return Ok(None);
    }
    Ok(Some(RateLimitSnapshot {
        primary,
        secondary,
        plan_type: response.plan_type,
    }))
}

fn usage_api_window_to_rate_limit_window(window: &UsageApiWindow) -> RateLimitWindow {
    RateLimitWindow {
        used_percent: window.used_percent,
        window_minutes: window.limit_window_seconds.and_then(ceil_minutes),
        resets_at: window.reset_at,
    }
}

fn ceil_minutes(seconds: i64) -> Option<i64> {
    if seconds <= 0 {
        None
    } else {
        Some((seconds + 59) / 60)
    }
}

fn push_unique_warning(warnings: &mut Vec<String>, warning: String) {
    if !warnings.iter().any(|existing| existing == &warning) {
        warnings.push(warning);
    }
}

fn resolve_cli_runtime() -> ResolvedCliRuntime {
    let (settings, settings_warning) = load_desktop_settings();
    let saved_override = settings
        .codex_auth_bin_override
        .as_deref()
        .map(canonical_override_path);
    let bundled_candidates = bundled_cli_candidates();
    let env_override = env::var_os("CODEX_AUTH_BIN").map(PathBuf::from).map(Ok);
    let path_candidates = path_env_candidates();
    let standard_candidates = standard_install_candidates();

    let mut warnings = Vec::new();
    if let Some(warning) = settings_warning {
        warnings.push(warning);
    }

    let mut resolution = resolve_cli_runtime_from_sources(
        saved_override,
        bundled_candidates,
        env_override,
        path_candidates,
        standard_candidates,
        validate_codex_auth_binary,
        settings.codex_auth_bin_override.clone(),
    );
    warnings.append(&mut resolution.warnings);

    resolution.warnings = warnings;
    resolution
}

fn require_cli_runtime_binary() -> Result<PathBuf, String> {
    let runtime = resolve_cli_runtime();
    runtime.binary_path.ok_or_else(|| {
        runtime
            .view
            .error
            .unwrap_or_else(|| "codex-auth is unavailable.".to_string())
    })
}

fn require_codex_binary() -> Result<PathBuf, String> {
    if let Some(path) = env::var_os("CODEX_BIN").map(PathBuf::from) {
        if path.exists() && path.is_file() {
            return Ok(path);
        }
        return Err(format!(
            "`CODEX_BIN` points to `{}`, but that file is not available.",
            path.display()
        ));
    }

    for candidate in codex_binary_candidates() {
        if candidate.exists() && candidate.is_file() {
            return Ok(candidate);
        }
    }

    Err(
        "Could not find a working `codex` binary for isolated login. Install Codex CLI or set CODEX_BIN."
            .to_string(),
    )
}

fn resolve_cli_runtime_from_sources<F>(
    saved_override: Option<Result<PathBuf, String>>,
    bundled_candidates: Vec<PathBuf>,
    env_override: Option<Result<PathBuf, String>>,
    path_candidates: Vec<PathBuf>,
    standard_candidates: Vec<PathBuf>,
    mut validator: F,
    override_path: Option<String>,
) -> ResolvedCliRuntime
where
    F: FnMut(&Path) -> Result<(), String>,
{
    if let Some(candidate_result) = saved_override {
        let (view, binary_path) = resolve_cli_runtime_candidate(
            candidate_result,
            CliResolutionSource::SavedOverride,
            &mut validator,
            override_path,
        );
        return ResolvedCliRuntime {
            view,
            binary_path,
            warnings: Vec::new(),
        };
    }

    let mut warnings = Vec::new();
    if let Some(candidate) =
        first_valid_optional_candidate(&bundled_candidates, &mut validator, &mut warnings)
    {
        return ResolvedCliRuntime {
            view: CliRuntimeView {
                available: true,
                resolved_path: Some(candidate.to_string_lossy().to_string()),
                resolution_source: Some(CliResolutionSource::Bundled.as_str().to_string()),
                override_path,
                error: None,
            },
            binary_path: Some(candidate),
            warnings,
        };
    }

    if let Some(candidate_result) = env_override {
        let (view, binary_path) = resolve_cli_runtime_candidate(
            candidate_result,
            CliResolutionSource::Env,
            &mut validator,
            override_path,
        );
        return ResolvedCliRuntime {
            view,
            binary_path,
            warnings,
        };
    }

    for candidate in path_candidates {
        if validator(&candidate).is_ok() {
            return ResolvedCliRuntime {
                view: CliRuntimeView {
                    available: true,
                    resolved_path: Some(candidate.to_string_lossy().to_string()),
                    resolution_source: Some(CliResolutionSource::Path.as_str().to_string()),
                    override_path,
                    error: None,
                },
                binary_path: Some(candidate),
                warnings,
            };
        }
    }

    for candidate in standard_candidates {
        if validator(&candidate).is_ok() {
            return ResolvedCliRuntime {
                view: CliRuntimeView {
                    available: true,
                    resolved_path: Some(candidate.to_string_lossy().to_string()),
                    resolution_source: Some(CliResolutionSource::StandardPath.as_str().to_string()),
                    override_path,
                    error: None,
                },
                binary_path: Some(candidate),
                warnings,
            };
        }
    }

    ResolvedCliRuntime {
        view: CliRuntimeView {
            available: false,
            resolved_path: None,
            resolution_source: None,
            override_path,
            error: Some(
                "Could not find a working `codex-auth` binary. Save an override path, set `CODEX_AUTH_BIN`, or install it in a standard location."
                    .to_string(),
            ),
        },
        binary_path: None,
        warnings,
    }
}

fn resolve_cli_runtime_candidate<F>(
    candidate_result: Result<PathBuf, String>,
    source: CliResolutionSource,
    validator: &mut F,
    override_path: Option<String>,
) -> (CliRuntimeView, Option<PathBuf>)
where
    F: FnMut(&Path) -> Result<(), String>,
{
    match candidate_result {
        Ok(candidate) => match validator(&candidate) {
            Ok(()) => (
                CliRuntimeView {
                    available: true,
                    resolved_path: Some(candidate.to_string_lossy().to_string()),
                    resolution_source: Some(source.as_str().to_string()),
                    override_path,
                    error: None,
                },
                Some(candidate),
            ),
            Err(err) => (
                CliRuntimeView {
                    available: false,
                    resolved_path: Some(candidate.to_string_lossy().to_string()),
                    resolution_source: Some(source.as_str().to_string()),
                    override_path,
                    error: Some(err),
                },
                None,
            ),
        },
        Err(err) => (
            CliRuntimeView {
                available: false,
                resolved_path: None,
                resolution_source: Some(source.as_str().to_string()),
                override_path,
                error: Some(err),
            },
            None,
        ),
    }
}

fn bundled_cli_candidates() -> Vec<PathBuf> {
    BUNDLED_CLI_CANDIDATES.get().cloned().unwrap_or_default()
}

fn first_valid_optional_candidate<F>(
    candidates: &[PathBuf],
    validator: &mut F,
    warnings: &mut Vec<String>,
) -> Option<PathBuf>
where
    F: FnMut(&Path) -> Result<(), String>,
{
    for candidate in candidates {
        if !candidate.exists() {
            continue;
        }
        match validator(candidate) {
            Ok(()) => return Some(candidate.clone()),
            Err(err) => warnings.push(format!(
                "Bundled codex-auth at {} is unavailable: {}",
                candidate.display(),
                err
            )),
        }
    }
    None
}

fn detect_bundled_cli_candidates<R: tauri::Runtime>(app: &tauri::AppHandle<R>) -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    if let Ok(resource_dir) = app.path().resource_dir() {
        for name in binary_names() {
            push_candidate(
                &mut candidates,
                resource_dir.join(BUNDLED_CLI_RESOURCE_DIR).join(name),
            );
            push_candidate(
                &mut candidates,
                resource_dir
                    .join("resources")
                    .join(BUNDLED_CLI_RESOURCE_DIR)
                    .join(name),
            );
        }
    }
    candidates
}

fn load_desktop_settings() -> (DesktopSettings, Option<String>) {
    let settings_path = match desktop_settings_path() {
        Ok(path) => path,
        Err(err) => return (DesktopSettings::default(), Some(err)),
    };

    let data = match fs::read_to_string(&settings_path) {
        Ok(data) => data,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
            return (DesktopSettings::default(), None)
        }
        Err(err) => {
            return (
                DesktopSettings::default(),
                Some(format!(
                    "Desktop settings are unavailable at {}: {err}",
                    settings_path.display()
                )),
            )
        }
    };

    match serde_json::from_str::<DesktopSettings>(&data) {
        Ok(settings) => (settings, None),
        Err(err) => (
            DesktopSettings::default(),
            Some(format!(
                "Desktop settings are malformed at {}: {err}",
                settings_path.display()
            )),
        ),
    }
}

fn save_desktop_settings(settings: &DesktopSettings) -> Result<(), String> {
    let settings_path = desktop_settings_path()?;
    let parent = settings_path
        .parent()
        .ok_or_else(|| "Desktop settings directory is unavailable.".to_string())?;
    fs::create_dir_all(parent).map_err(|err| {
        format!(
            "Failed to create desktop settings directory at {}: {err}",
            parent.display()
        )
    })?;

    if settings.codex_auth_bin_override.is_none() {
        match fs::remove_file(&settings_path) {
            Ok(()) => return Ok(()),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(()),
            Err(err) => {
                return Err(format!(
                    "Failed to clear desktop settings at {}: {err}",
                    settings_path.display()
                ))
            }
        }
    }

    let data = serde_json::to_string_pretty(settings)
        .map_err(|err| format!("Failed to serialize desktop settings: {err}"))?;
    fs::write(&settings_path, data).map_err(|err| {
        format!(
            "Failed to write desktop settings to {}: {err}",
            settings_path.display()
        )
    })
}

fn desktop_settings_path() -> Result<PathBuf, String> {
    let config_dir =
        dirs::config_dir().ok_or_else(|| "Desktop config directory is unavailable.".to_string())?;
    Ok(config_dir
        .join(DESKTOP_SETTINGS_DIR_NAME)
        .join(DESKTOP_SETTINGS_FILE_NAME))
}

fn canonical_override_path(raw: &str) -> Result<PathBuf, String> {
    let expanded = expand_user_path(raw)?;
    match fs::canonicalize(&expanded) {
        Ok(path) => Ok(path),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(expanded),
        Err(err) => Err(format!(
            "Failed to resolve `{}` into a filesystem path: {err}",
            expanded.display()
        )),
    }
}

fn expand_user_path(raw: &str) -> Result<PathBuf, String> {
    if raw == "~" {
        return dirs::home_dir().ok_or_else(|| "Home directory is unavailable.".to_string());
    }

    if let Some(rest) = raw.strip_prefix("~/").or_else(|| raw.strip_prefix("~\\")) {
        let home = dirs::home_dir().ok_or_else(|| "Home directory is unavailable.".to_string())?;
        return Ok(home.join(rest));
    }

    Ok(PathBuf::from(raw))
}

fn validate_codex_auth_binary(path: &Path) -> Result<(), String> {
    if !path.exists() {
        return Err(format!("`{}` does not exist.", path.display()));
    }
    if !path.is_file() {
        return Err(format!("`{}` is not a file.", path.display()));
    }
    run_codex_auth_with_binary(path, ["--version"]).map(|_| ())
}

fn path_env_candidates() -> Vec<PathBuf> {
    let Some(path_var) = env::var_os("PATH") else {
        return Vec::new();
    };

    let mut candidates = Vec::new();
    for directory in env::split_paths(&path_var) {
        for name in binary_names() {
            push_candidate(&mut candidates, directory.join(name));
        }
    }
    candidates
}

fn standard_install_candidates() -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    if let Some(home) = dirs::home_dir() {
        for name in binary_names() {
            push_candidate(
                &mut candidates,
                home.join(".npm-global").join("bin").join(name),
            );
            push_candidate(&mut candidates, home.join(".local").join("bin").join(name));
        }
        #[cfg(target_os = "windows")]
        {
            for name in binary_names() {
                push_candidate(
                    &mut candidates,
                    home.join("AppData").join("Roaming").join("npm").join(name),
                );
            }
        }
    }

    #[cfg(target_os = "macos")]
    {
        for name in binary_names() {
            push_candidate(
                &mut candidates,
                PathBuf::from("/opt/homebrew/bin").join(name),
            );
            push_candidate(&mut candidates, PathBuf::from("/usr/local/bin").join(name));
        }
    }

    #[cfg(any(target_os = "linux", target_os = "macos"))]
    {
        for name in binary_names() {
            push_candidate(&mut candidates, PathBuf::from("/usr/local/bin").join(name));
            push_candidate(&mut candidates, PathBuf::from("/usr/bin").join(name));
        }
    }

    candidates
}

fn codex_binary_candidates() -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    if let Some(path_var) = env::var_os("PATH") {
        for directory in env::split_paths(&path_var) {
            for name in codex_binary_names() {
                push_candidate(&mut candidates, directory.join(name));
            }
        }
    }
    if let Some(home) = dirs::home_dir() {
        for name in codex_binary_names() {
            push_candidate(
                &mut candidates,
                home.join(".npm-global").join("bin").join(name),
            );
            push_candidate(&mut candidates, home.join(".local").join("bin").join(name));
        }
    }
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    {
        for name in codex_binary_names() {
            push_candidate(&mut candidates, PathBuf::from("/usr/local/bin").join(name));
            push_candidate(&mut candidates, PathBuf::from("/usr/bin").join(name));
        }
    }
    candidates
}

fn push_candidate(candidates: &mut Vec<PathBuf>, candidate: PathBuf) {
    if !candidates.iter().any(|existing| existing == &candidate) {
        candidates.push(candidate);
    }
}

fn binary_names() -> &'static [&'static str] {
    #[cfg(target_os = "windows")]
    {
        &["codex-auth.cmd", "codex-auth.exe"]
    }
    #[cfg(not(target_os = "windows"))]
    {
        &["codex-auth"]
    }
}

fn codex_binary_names() -> &'static [&'static str] {
    #[cfg(target_os = "windows")]
    {
        &["codex.cmd", "codex.exe"]
    }
    #[cfg(not(target_os = "windows"))]
    {
        &["codex"]
    }
}

fn stream_pipe_with_url_notify<R: Read + Send + 'static>(
    reader: R,
    label: Option<&str>,
    shared: Arc<Mutex<LoginJobState>>,
    url_ready: Arc<(Mutex<bool>, Condvar)>,
) {
    let buffered = BufReader::new(reader);
    let mut notified = false;
    for line in buffered.lines() {
        match line {
            Ok(line) => {
                let mut job = shared.lock().expect("login state poisoned");
                if let Some(prefix) = label {
                    append_line(&mut job.output, &format!("[{prefix}] {line}"));
                } else {
                    append_line(&mut job.output, &line);
                }
                let had_url = job.login_url.is_some();
                job.login_url = extract_login_url(&job.output);
                let should_notify = !notified && !had_url && job.login_url.is_some();
                drop(job);
                if should_notify {
                    notified = true;
                    let (lock, cvar) = &*url_ready;
                    let mut ready = lock.lock().expect("url_ready poisoned");
                    *ready = true;
                    cvar.notify_all();
                }
            }
            Err(err) => {
                let mut job = shared.lock().expect("login state poisoned");
                append_line(&mut job.output, &format!("[reader] {err}"));
                break;
            }
        }
    }
}

fn stream_action_pipe<R: Read + Send + 'static>(
    reader: R,
    label: Option<&str>,
    shared: Arc<Mutex<ActionJobState>>,
) {
    let buffered = BufReader::new(reader);
    for line in buffered.lines() {
        match line {
            Ok(line) => {
                let mut job = shared.lock().expect("action state poisoned");
                if let Some(prefix) = label {
                    append_line(&mut job.output, &format!("[{prefix}] {line}"));
                } else {
                    append_line(&mut job.output, &line);
                }
            }
            Err(err) => {
                let mut job = shared.lock().expect("action state poisoned");
                append_line(&mut job.output, &format!("[reader] {err}"));
                break;
            }
        }
    }
}

fn append_line(target: &mut String, line: &str) {
    target.push_str(line);
    if !line.ends_with('\n') {
        target.push('\n');
    }
}

fn format_owned_command(args: &[String]) -> String {
    let mut rendered = String::from("codex-auth");
    for arg in args {
        rendered.push(' ');
        rendered.push_str(arg);
    }
    rendered
}

struct EligibleHintInfo {
    code: Option<&'static str>,
    text: Option<String>,
}

fn build_summary(
    registry: &RegistryFile,
    status: &StatusView,
    accounts: &[AccountView],
) -> SummaryView {
    let fresh_accounts = accounts
        .iter()
        .filter(|account| account.freshness == "fresh")
        .count();
    let stale_accounts = accounts
        .iter()
        .filter(|account| account.freshness == "stale")
        .count();
    let unknown_accounts = accounts
        .iter()
        .filter(|account| account.freshness == "unknown")
        .count();
    let eligible_accounts = accounts.iter().filter(|account| account.eligible).count();
    let best_known = best_known_account_key(registry)
        .and_then(|key| accounts.iter().find(|account| account.key == key));
    let best_eligible = best_eligible_account_key(registry)
        .and_then(|key| accounts.iter().find(|account| account.key == key));
    let active_account = accounts.iter().find(|account| account.is_active);
    let eligible_hint =
        if registry.auto_switch.mode == "pinned" || registry.auto_switch.mode == "failover" {
            EligibleHintInfo {
                code: None,
                text: None,
            }
        } else {
            build_eligible_hint(
                registry,
                fresh_accounts,
                eligible_accounts,
                active_account,
                best_eligible,
            )
        };

    SummaryView {
        active_label: active_account
            .map(|account| account.label.clone())
            .or_else(|| status.active_account.clone()),
        total_accounts: accounts.len(),
        fresh_accounts,
        stale_accounts,
        unknown_accounts,
        eligible_accounts,
        best_known_label: best_known.map(|account| account.label.clone()),
        best_known_remaining: best_known.and_then(|account| account.effective_remaining),
        eligible_hint: eligible_hint.text,
        eligible_hint_code: eligible_hint.code.map(str::to_string),
        auto_switch_enabled: registry.auto_switch.enabled,
        auto_switch_mode: registry.auto_switch.mode.clone(),
        pinned_account_label: status.pinned_account.clone().or_else(|| {
            registry
                .auto_switch
                .pinned_account_key
                .as_deref()
                .and_then(|key| accounts.iter().find(|account| account.key == key))
                .map(|account| account.label.clone())
        }),
        pin_state: status.pin_state.clone(),
        failover_state: status.failover_state.clone(),
        blocked_account_label: status.blocked_account.clone().or_else(|| {
            registry
                .auto_switch
                .blocked_account_key
                .as_deref()
                .and_then(|key| accounts.iter().find(|account| account.key == key))
                .map(|account| account.label.clone())
        }),
        blocked_until: status.blocked_until.clone(),
        threshold_5h_percent: registry.auto_switch.threshold_5h_percent,
        threshold_weekly_percent: registry.auto_switch.threshold_weekly_percent,
        usage_api_enabled: registry.api.usage,
        account_api_enabled: registry.api.account,
    }
}

fn build_eligible_hint(
    registry: &RegistryFile,
    fresh_accounts: usize,
    eligible_accounts: usize,
    active_account: Option<&AccountView>,
    best_eligible: Option<&AccountView>,
) -> EligibleHintInfo {
    if eligible_accounts == 0 {
        if fresh_accounts == 0 {
            return EligibleHintInfo {
                code: Some(ELIGIBLE_HINT_MISSING_FRESH_LOCAL_SNAPSHOT),
                text: Some("No account has fresh quota data yet.".to_string()),
            };
        }
        return EligibleHintInfo {
            code: Some(ELIGIBLE_HINT_BELOW_THRESHOLD),
            text: Some(format!(
                "Fresh snapshots exist, but none are above the current thresholds (5h < {}%, weekly < {}%).",
                registry.auto_switch.threshold_5h_percent, registry.auto_switch.threshold_weekly_percent
            )),
        };
    }

    if eligible_accounts == 1
        && active_account
            .map(|account| account.eligible)
            .unwrap_or(false)
        && active_account.map(|account| account.key.as_str())
            == best_eligible.map(|account| account.key.as_str())
    {
        return EligibleHintInfo {
            code: Some(ELIGIBLE_HINT_ACTIVE_ALREADY_BEST),
            text: Some("The active account is already the only eligible candidate, so there is nothing better to switch to.".to_string()),
        };
    }

    EligibleHintInfo {
        code: None,
        text: None,
    }
}

fn build_account_views(
    registry: &RegistryFile,
    status: &StatusView,
    quota_cache: &HashMap<String, ConfirmedQuotaRecord>,
) -> Vec<AccountView> {
    let status_active_key = resolve_status_active_key(registry, status);
    let display_labels = build_display_labels(registry);
    let recovery_candidates =
        scan_auth_recovery_candidates_for_registry(registry).unwrap_or_default();
    let now = Utc::now().timestamp();

    let mut accounts = registry
        .accounts
        .iter()
        .map(|account| {
            let freshness =
                snapshot_freshness_at(now, account.last_usage.is_some(), account.last_usage_at);
            let (five_hour, weekly) = extract_windows_at(account.last_usage.as_ref(), now);
            let confirmed = quota_cache.get(account.account_key.as_str());
            let effective_remaining = five_hour
                .as_ref()
                .map(|window| window.remaining_percent)
                .or_else(|| weekly.as_ref().map(|window| window.remaining_percent));
            let blocked = account_is_blocked(registry, account, now);
            let eligible = is_account_eligible(account, registry, now);
            let auth_path = account_auth_path(&account.account_key).ok();
            let auth_available = auth_path.is_some();
            let has_quarantine_marker = account_auth_is_quarantined(&account.account_key);
            let registry_auth_health = account.auth_health.as_deref().unwrap_or("unknown");
            let quarantined = has_quarantine_marker
                || account.auth_quarantined_at.is_some()
                || registry_auth_health == "quarantined";
            let recoverable = recovery_candidates.iter().any(|candidate| {
                candidate.account_key == account.account_key
                    && auth_path
                        .as_ref()
                        .map(|path| path != &candidate.path)
                        .unwrap_or(true)
            });
            let last_auth_error = account
                .auth_error
                .clone()
                .or_else(|| confirmed.and_then(|record| record.error.clone()));
            let (auth_health, usable, quarantine_reason) = account_auth_health_for_view(
                is_refresh_token_reused_message(last_auth_error.as_deref().unwrap_or_default()),
                is_active_hint(account, status_active_key, registry),
                eligible,
                blocked,
                auth_available,
                registry_auth_health,
                quarantined,
                freshness,
                effective_remaining,
                last_auth_error.as_deref(),
            );
            let label = display_labels
                .get(account.account_key.as_str())
                .cloned()
                .unwrap_or_else(|| preferred_label(account));
            let is_active = if let Some(active_key) = status_active_key {
                account.account_key == active_key
            } else {
                registry
                    .active_account_key
                    .as_deref()
                    .map(|key| key == account.account_key)
                    .unwrap_or(false)
            };

            AccountView {
                key: account.account_key.clone(),
                label,
                email: account.email.clone(),
                alias: account.alias.clone(),
                account_name: account.account_name.clone(),
                record_hint: short_account_key(&account.account_key),
                record_title: account.account_key.clone(),
                plan: account_plan_label(account).unwrap_or("unknown").to_string(),
                auth_mode: account
                    .auth_mode
                    .clone()
                    .unwrap_or_else(|| "chatgpt".to_string()),
                is_active,
                freshness: freshness.as_str().to_string(),
                eligible,
                blocked,
                auth_available,
                auth_health,
                usable,
                recoverable,
                quarantined,
                quarantine_reason,
                last_auth_error,
                quota_source: quota_source(account, confirmed).to_string(),
                quota_confirmed_at: confirmed.map(|record| record.checked_at),
                quota_confirmed_relative: confirmed
                    .map(|record| format_relative_at(now, record.checked_at)),
                quota_confirm_status_code: confirmed.and_then(|record| record.status_code),
                quota_confirm_error: confirmed.and_then(|record| record.error.clone()),
                effective_remaining,
                five_hour,
                weekly,
                last_used_at: account.last_used_at,
                last_usage_at: account.last_usage_at,
                last_used_relative: account.last_used_at.map(format_relative),
                last_usage_relative: account.last_usage_at.map(format_relative),
            }
        })
        .collect::<Vec<_>>();

    accounts.sort_by(compare_accounts_for_sort);
    accounts
}

fn is_active_hint(
    account: &AccountRecord,
    status_active_key: Option<&str>,
    registry: &RegistryFile,
) -> bool {
    if let Some(active_key) = status_active_key {
        account.account_key == active_key
    } else {
        registry
            .active_account_key
            .as_deref()
            .map(|key| key == account.account_key)
            .unwrap_or(false)
    }
}

fn account_auth_health_for_view(
    reused_token_error: bool,
    is_active: bool,
    eligible: bool,
    blocked: bool,
    auth_available: bool,
    registry_auth_health: &str,
    quarantined: bool,
    freshness: SnapshotFreshness,
    effective_remaining: Option<f64>,
    last_auth_error: Option<&str>,
) -> (String, bool, Option<String>) {
    if quarantined {
        return (
            ACCOUNT_HEALTH_QUARANTINED.to_string(),
            false,
            Some(
                last_auth_error
                    .unwrap_or("refresh-token-reused-quarantine")
                    .to_string(),
            ),
        );
    }
    if reused_token_error {
        return (
            ACCOUNT_HEALTH_QUARANTINED.to_string(),
            false,
            Some(REFRESH_TOKEN_REUSED_HINT.to_string()),
        );
    }
    if !auth_available {
        return (ACCOUNT_HEALTH_NO_AUTH.to_string(), false, None);
    }
    if matches!(
        registry_auth_health,
        "missing_auth" | "malformed_auth" | "account_mismatch" | "api_failed"
    ) {
        return (
            ACCOUNT_HEALTH_QUARANTINED.to_string(),
            false,
            last_auth_error.map(|error| error.to_string()),
        );
    }
    if blocked {
        return (
            ACCOUNT_HEALTH_BLOCKED.to_string(),
            false,
            Some(REFRESH_TOKEN_REUSED_HINT.to_string()),
        );
    }
    if is_active {
        return (ACCOUNT_HEALTH_ACTIVE.to_string(), true, None);
    }
    let verified = registry_auth_health == "verified";
    if eligible {
        return (ACCOUNT_HEALTH_READY.to_string(), verified, None);
    }
    if freshness != SnapshotFreshness::Fresh {
        return (ACCOUNT_HEALTH_NEEDS_WARM.to_string(), false, None);
    }
    if effective_remaining.is_some() {
        return (ACCOUNT_HEALTH_LOW_QUOTA.to_string(), verified, None);
    }
    (ACCOUNT_HEALTH_UNKNOWN.to_string(), false, None)
}

fn build_display_labels(registry: &RegistryFile) -> HashMap<&str, String> {
    let mut base_label_counts = HashMap::<String, usize>::new();
    for account in &registry.accounts {
        *base_label_counts
            .entry(preferred_label(account))
            .or_insert(0) += 1;
    }

    let mut labels = HashMap::new();
    for account in &registry.accounts {
        let base = preferred_label(account);
        let label = if base_label_counts.get(&base).copied().unwrap_or(0) > 1 {
            format!("{base} · {}", short_account_key(&account.account_key))
        } else {
            base
        };
        labels.insert(account.account_key.as_str(), label);
    }
    labels
}

fn quota_source(account: &AccountRecord, confirmed: Option<&ConfirmedQuotaRecord>) -> &'static str {
    if let Some(confirmed) = confirmed {
        if confirmed.snapshot.is_some() {
            return "api-confirmed";
        }
        if confirmed.error.is_some() || confirmed.status_code.is_some() {
            return "api-unavailable";
        }
    }
    if account.last_usage.is_some() {
        "local-snapshot"
    } else {
        "unknown"
    }
}

fn resolve_status_active_key<'a>(
    registry: &'a RegistryFile,
    status: &StatusView,
) -> Option<&'a str> {
    if let Some(active_key) = status.active_account_key.as_deref() {
        return registry
            .accounts
            .iter()
            .find(|account| account.account_key == active_key)
            .map(|account| account.account_key.as_str());
    }

    if status.has_active_account_key_line {
        return None;
    }

    let active_label = status.active_account.as_deref()?.trim();
    if active_label.eq_ignore_ascii_case("none") {
        return None;
    }

    registry
        .accounts
        .iter()
        .find(|account| {
            account.email == active_label
                || (!account.alias.trim().is_empty() && account.alias == active_label)
                || preferred_label(account) == active_label
        })
        .map(|account| account.account_key.as_str())
}

fn compare_accounts_for_sort(left: &AccountView, right: &AccountView) -> Ordering {
    right
        .usable
        .cmp(&left.usable)
        .then_with(|| right.eligible.cmp(&left.eligible))
        .then_with(|| compare_optional_f64(right.effective_remaining, left.effective_remaining))
        .then_with(|| compare_optional_i64(right.last_usage_at, left.last_usage_at))
        .then_with(|| compare_optional_i64(right.last_used_at, left.last_used_at))
        .then_with(|| left.label.to_lowercase().cmp(&right.label.to_lowercase()))
}

fn compare_optional_f64(left: Option<f64>, right: Option<f64>) -> Ordering {
    match (left, right) {
        (Some(a), Some(b)) => a.partial_cmp(&b).unwrap_or(Ordering::Equal),
        (Some(_), None) => Ordering::Greater,
        (None, Some(_)) => Ordering::Less,
        (None, None) => Ordering::Equal,
    }
}

fn compare_optional_i64(left: Option<i64>, right: Option<i64>) -> Ordering {
    match (left, right) {
        (Some(a), Some(b)) => a.cmp(&b),
        (Some(_), None) => Ordering::Greater,
        (None, Some(_)) => Ordering::Less,
        (None, None) => Ordering::Equal,
    }
}

fn preferred_label(account: &AccountRecord) -> String {
    if !account.alias.trim().is_empty() {
        account.alias.clone()
    } else {
        account.email.clone()
    }
}

fn short_account_key(account_key: &str) -> String {
    let tail = account_key.split("::").last().unwrap_or(account_key);
    let short_tail = if tail.len() > 8 {
        &tail[tail.len() - 8..]
    } else {
        tail
    };
    format!("…{short_tail}")
}

fn snapshot_freshness_at(
    now_secs: i64,
    has_snapshot: bool,
    last_usage_at: Option<i64>,
) -> SnapshotFreshness {
    if !has_snapshot || last_usage_at.is_none() {
        return SnapshotFreshness::Unknown;
    }
    if last_usage_at.unwrap_or_default() > now_secs {
        return SnapshotFreshness::Fresh;
    }
    let age = now_secs - last_usage_at.unwrap_or_default();
    if age > LOCAL_SNAPSHOT_MAX_AGE_SECONDS {
        SnapshotFreshness::Stale
    } else {
        SnapshotFreshness::Fresh
    }
}

#[derive(Clone, Copy)]
struct RankedCandidateScore {
    effective_remaining: f64,
    weekly_remaining: f64,
    effective_resets_at: i64,
    last_usage_at: i64,
    last_used_at: i64,
}

#[derive(Clone)]
struct ResolvedCandidate5hWindow {
    window: Option<RateLimitWindow>,
    allow_free_guard: bool,
}

fn is_account_eligible(account: &AccountRecord, registry: &RegistryFile, now: i64) -> bool {
    if account_is_blocked(registry, account, now) {
        return false;
    }
    eligible_candidate_score(account, &registry.auto_switch, now).is_some()
}

fn account_is_chatgpt(account: &AccountRecord) -> bool {
    account
        .auth_mode
        .as_deref()
        .map(|mode| mode == "chatgpt")
        .unwrap_or(true)
}

fn account_plan_label(account: &AccountRecord) -> Option<&str> {
    account.plan.as_deref().or_else(|| {
        account
            .last_usage
            .as_ref()
            .and_then(|snapshot| snapshot.plan_type.as_deref())
    })
}

fn account_is_free_plan(account: &AccountRecord) -> bool {
    account_plan_label(account)
        .map(|plan| plan.eq_ignore_ascii_case("free"))
        .unwrap_or(false)
}

fn effective_5h_threshold_percent(
    auto_switch: &AutoSwitchConfig,
    account: &AccountRecord,
    allow_free_guard: bool,
) -> f64 {
    let mut threshold = f64::from(auto_switch.threshold_5h_percent);
    if allow_free_guard && account_is_free_plan(account) {
        threshold = threshold.max(FREE_PLAN_REALTIME_GUARD_5H_PERCENT);
    }
    threshold
}

fn account_is_blocked(registry: &RegistryFile, account: &AccountRecord, now: i64) -> bool {
    active_blocked_account_key(registry, now)
        .map(|key| key == account.account_key)
        .unwrap_or(false)
}

fn active_blocked_account_key(registry: &RegistryFile, now: i64) -> Option<&str> {
    let blocked_key = registry.auto_switch.blocked_account_key.as_deref()?;
    let blocked = registry
        .accounts
        .iter()
        .find(|account| account.account_key == blocked_key)?;
    if blocked_account_still_applies(registry, blocked, now) {
        Some(blocked.account_key.as_str())
    } else {
        None
    }
}

fn blocked_account_still_applies(
    registry: &RegistryFile,
    account: &AccountRecord,
    now: i64,
) -> bool {
    if let Some(blocked_until_ms) = registry.auto_switch.blocked_until_ms {
        return Utc::now().timestamp_millis() < blocked_until_ms;
    }
    if let Some(score) = known_candidate_score(account, now) {
        return score.effective_remaining <= 0.0;
    }
    true
}

fn extract_windows_at(
    snapshot: Option<&RateLimitSnapshot>,
    now: i64,
) -> (Option<QuotaWindowView>, Option<QuotaWindowView>) {
    let resolved_5h = resolve_5h_candidate_window(snapshot);
    let weekly = resolve_weekly_window(snapshot);
    (
        quota_window_view(resolved_5h.window.as_ref(), now),
        quota_window_view(weekly.as_ref(), now),
    )
}

fn resolve_5h_candidate_window(snapshot: Option<&RateLimitSnapshot>) -> ResolvedCandidate5hWindow {
    let Some(snapshot) = snapshot else {
        return ResolvedCandidate5hWindow {
            window: None,
            allow_free_guard: false,
        };
    };

    if let Some(primary) = snapshot.primary.as_ref() {
        if primary.window_minutes.is_none() || primary.window_minutes == Some(300) {
            return ResolvedCandidate5hWindow {
                window: Some(primary.clone()),
                allow_free_guard: true,
            };
        }
    }
    if let Some(secondary) = snapshot.secondary.as_ref() {
        if secondary.window_minutes == Some(300) {
            return ResolvedCandidate5hWindow {
                window: Some(secondary.clone()),
                allow_free_guard: true,
            };
        }
    }

    ResolvedCandidate5hWindow {
        window: None,
        allow_free_guard: false,
    }
}

fn resolve_weekly_window(snapshot: Option<&RateLimitSnapshot>) -> Option<RateLimitWindow> {
    let snapshot = snapshot?;
    if snapshot
        .primary
        .as_ref()
        .and_then(|window| window.window_minutes)
        == Some(10080)
    {
        return snapshot.primary.clone();
    }
    if snapshot
        .secondary
        .as_ref()
        .and_then(|window| window.window_minutes)
        == Some(10080)
    {
        return snapshot.secondary.clone();
    }
    snapshot.secondary.clone()
}

fn quota_window_view(window: Option<&RateLimitWindow>, now: i64) -> Option<QuotaWindowView> {
    let window = window?;
    Some(QuotaWindowView {
        remaining_percent: remaining_percent_at(Some(window), now)?,
        resets_at_label: window.resets_at.map(format_reset),
        resets_at: window.resets_at,
    })
}

fn remaining_percent_at(window: Option<&RateLimitWindow>, now: i64) -> Option<f64> {
    let window = window?;
    if window
        .resets_at
        .map(|resets_at| resets_at <= now)
        .unwrap_or(false)
    {
        return Some(100.0);
    }
    Some((100.0 - window.used_percent).clamp(0.0, 100.0))
}

fn reset_at_or_max(window: Option<&RateLimitWindow>) -> i64 {
    window
        .and_then(|window| window.resets_at)
        .unwrap_or(i64::MAX)
}

fn load_status_view(binary_path: Option<&Path>, runtime_error: Option<&str>) -> StatusView {
    let Some(binary_path) = binary_path else {
        return StatusView {
            pairs: Vec::new(),
            service: None,
            usage: None,
            account_api: None,
            active_auth: None,
            active_account: None,
            active_account_key: None,
            selection: None,
            pinned_account: None,
            pin_state: None,
            failover_state: None,
            blocked_account: None,
            blocked_until: None,
            snapshot_source: None,
            known_snapshots: None,
            eligible_candidates: None,
            registry_active: None,
            has_active_account_key_line: false,
            command_error: runtime_error.map(ToOwned::to_owned),
        };
    };

    match run_codex_auth_with_binary(binary_path, ["status"]) {
        Ok(output) => parse_status_output(&output.stdout),
        Err(err) => StatusView {
            pairs: Vec::new(),
            service: None,
            usage: None,
            account_api: None,
            active_auth: None,
            active_account: None,
            active_account_key: None,
            selection: None,
            pinned_account: None,
            pin_state: None,
            failover_state: None,
            blocked_account: None,
            blocked_until: None,
            snapshot_source: None,
            known_snapshots: None,
            eligible_candidates: None,
            registry_active: None,
            has_active_account_key_line: false,
            command_error: Some(err),
        },
    }
}

fn parse_status_output(stdout: &str) -> StatusView {
    let mut pairs = Vec::new();
    for line in stdout.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        if let Some((key, value)) = trimmed.split_once(':') {
            pairs.push(StatusPair {
                key: key.trim().to_string(),
                value: value.trim().to_string(),
            });
        }
    }

    let lookup = |needle: &str| -> Option<String> {
        pairs
            .iter()
            .find(|pair| pair.key.eq_ignore_ascii_case(needle))
            .map(|pair| pair.value.clone())
    };
    let normalize = |value: Option<String>| -> Option<String> {
        value.and_then(|value| {
            let trimmed = value.trim();
            if trimmed.is_empty() || trimmed.eq_ignore_ascii_case("none") {
                None
            } else {
                Some(trimmed.to_string())
            }
        })
    };
    let has_active_account_key_line = pairs
        .iter()
        .any(|pair| pair.key.eq_ignore_ascii_case("active account key"));

    StatusView {
        service: lookup("service"),
        usage: lookup("usage"),
        account_api: lookup("account API"),
        active_auth: lookup("active auth"),
        active_account: normalize(lookup("active account")),
        active_account_key: normalize(lookup("active account key")),
        selection: lookup("selection"),
        pinned_account: normalize(lookup("pinned account")),
        pin_state: lookup("pin state"),
        failover_state: lookup("failover state"),
        blocked_account: normalize(lookup("blocked account")),
        blocked_until: normalize(lookup("blocked until")),
        snapshot_source: lookup("usage source mode").or_else(|| lookup("snapshot source")),
        known_snapshots: lookup("known snapshots"),
        eligible_candidates: lookup("eligible candidates"),
        registry_active: normalize(lookup("registry active")),
        has_active_account_key_line,
        pairs,
        command_error: None,
    }
}

fn best_known_account_key(registry: &RegistryFile) -> Option<&str> {
    let now = Utc::now().timestamp();
    let mut best: Option<(usize, RankedCandidateScore)> = None;
    for (idx, account) in registry.accounts.iter().enumerate() {
        if account_is_blocked(registry, account, now) {
            continue;
        }
        let Some(score) = known_candidate_score(account, now) else {
            continue;
        };
        if best
            .map(|(best_idx, best_score)| {
                candidate_score_better(account, score, &registry.accounts[best_idx], best_score)
            })
            .unwrap_or(true)
        {
            best = Some((idx, score));
        }
    }
    best.map(|(idx, _)| registry.accounts[idx].account_key.as_str())
}

fn best_eligible_account_key(registry: &RegistryFile) -> Option<&str> {
    let now = Utc::now().timestamp();
    let mut best: Option<(usize, RankedCandidateScore)> = None;
    for (idx, account) in registry.accounts.iter().enumerate() {
        if account_is_blocked(registry, account, now) {
            continue;
        }
        let Some(score) = eligible_candidate_score(account, &registry.auto_switch, now) else {
            continue;
        };
        if best
            .map(|(best_idx, best_score)| {
                candidate_score_better(account, score, &registry.accounts[best_idx], best_score)
            })
            .unwrap_or(true)
        {
            best = Some((idx, score));
        }
    }
    best.map(|(idx, _)| registry.accounts[idx].account_key.as_str())
}

fn known_candidate_score(account: &AccountRecord, now: i64) -> Option<RankedCandidateScore> {
    if !account_is_chatgpt(account) {
        return None;
    }
    let freshness = snapshot_freshness_at(now, account.last_usage.is_some(), account.last_usage_at);
    if freshness != SnapshotFreshness::Fresh {
        return None;
    }

    let resolved_5h = resolve_5h_candidate_window(account.last_usage.as_ref());
    let weekly = resolve_weekly_window(account.last_usage.as_ref());
    let five_hour_remaining = remaining_percent_at(resolved_5h.window.as_ref(), now);
    let weekly_remaining = remaining_percent_at(weekly.as_ref(), now);
    let effective_remaining = five_hour_remaining.or(weekly_remaining)?;
    let effective_resets_at = if five_hour_remaining.is_some() {
        reset_at_or_max(resolved_5h.window.as_ref())
    } else {
        reset_at_or_max(weekly.as_ref())
    };

    Some(RankedCandidateScore {
        effective_remaining,
        weekly_remaining: weekly_remaining.unwrap_or(effective_remaining),
        effective_resets_at,
        last_usage_at: account.last_usage_at.unwrap_or(-1),
        last_used_at: account.last_used_at.unwrap_or(-1),
    })
}

fn eligible_candidate_score(
    account: &AccountRecord,
    auto_switch: &AutoSwitchConfig,
    now: i64,
) -> Option<RankedCandidateScore> {
    let known = known_candidate_score(account, now)?;
    let resolved_5h = resolve_5h_candidate_window(account.last_usage.as_ref());
    let weekly = resolve_weekly_window(account.last_usage.as_ref());
    let threshold_5h =
        effective_5h_threshold_percent(auto_switch, account, resolved_5h.allow_free_guard);
    let rem_5h = remaining_percent_at(resolved_5h.window.as_ref(), now);
    let rem_week = remaining_percent_at(weekly.as_ref(), now);

    if rem_5h
        .map(|remaining| remaining < threshold_5h)
        .unwrap_or(false)
    {
        return None;
    }
    if rem_week
        .as_ref()
        .map(|remaining| *remaining < f64::from(auto_switch.threshold_weekly_percent))
        .unwrap_or(false)
    {
        return None;
    }
    Some(known)
}

fn candidate_score_better(
    left_account: &AccountRecord,
    left: RankedCandidateScore,
    right_account: &AccountRecord,
    right: RankedCandidateScore,
) -> bool {
    if left.effective_remaining != right.effective_remaining {
        return left.effective_remaining > right.effective_remaining;
    }
    if left.weekly_remaining != right.weekly_remaining {
        return left.weekly_remaining > right.weekly_remaining;
    }
    if left.effective_resets_at != right.effective_resets_at {
        return left.effective_resets_at < right.effective_resets_at;
    }
    if left.last_usage_at != right.last_usage_at {
        return left.last_usage_at > right.last_usage_at;
    }
    if left.last_used_at != right.last_used_at {
        return left.last_used_at > right.last_used_at;
    }

    let left_primary = if left_account.alias.trim().is_empty() {
        left_account.email.as_str()
    } else {
        left_account.alias.as_str()
    };
    let right_primary = if right_account.alias.trim().is_empty() {
        right_account.email.as_str()
    } else {
        right_account.alias.as_str()
    };
    let primary_cmp = left_primary.cmp(right_primary);
    if primary_cmp != Ordering::Equal {
        return primary_cmp == Ordering::Less;
    }

    let email_cmp = left_account.email.cmp(&right_account.email);
    if email_cmp != Ordering::Equal {
        return email_cmp == Ordering::Less;
    }

    left_account.account_key < right_account.account_key
}

fn generate_session_id() -> String {
    let mut buf = [0u8; 16];
    if let Ok(mut f) = std::fs::File::open("/dev/urandom") {
        use std::io::Read;
        let _ = f.read_exact(&mut buf);
    } else {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default();
        let bytes = now.as_nanos().to_le_bytes();
        buf[..8].copy_from_slice(&bytes[..8]);
        buf[8..].copy_from_slice(&(std::process::id() as u128).to_le_bytes()[..8]);
    }
    base64_url_no_pad(&buf)
}

fn detect_browser() -> Result<(PathBuf, String), String> {
    for (cmd, kind) in [
        ("chromium", "chromium"),
        ("chromium-browser", "chromium"),
        ("google-chrome-stable", "chromium"),
        ("google-chrome", "chromium"),
        ("firefox", "firefox"),
    ] {
        if let Ok(output) = Command::new("which").arg(cmd).output() {
            if output.status.success() {
                let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
                if !path.is_empty() {
                    return Ok((PathBuf::from(path), kind.to_string()));
                }
            }
        }
    }
    Err(
        "No supported browser found (chromium or firefox). Install one to use isolated login."
            .to_string(),
    )
}

fn open_isolated_browser(
    url: &str,
    session_id: &str,
    browser_sessions: &Arc<Mutex<Vec<IsolatedBrowserSession>>>,
) -> Result<String, String> {
    validate_login_url(url)?;
    {
        let sessions = browser_sessions.lock().expect("browser state poisoned");
        if sessions.iter().any(|s| s.session_id == session_id) {
            return Ok(session_id.to_string());
        }
    }

    let (browser_path, browser_kind) = detect_browser()?;
    let profile_dir = std::env::temp_dir().join(format!("codex-auth-session-{session_id}"));
    create_private_dir(&profile_dir)
        .map_err(|err| format!("Failed to create profile dir: {err}"))?;

    let mut cmd = Command::new(&browser_path);
    if browser_kind == "chromium" {
        cmd.args([
            &format!("--user-data-dir={}", profile_dir.display()),
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-sync",
            "--disable-background-networking",
            url,
        ]);
    } else {
        cmd.args([
            "-profile",
            &profile_dir.display().to_string(),
            "-no-remote",
            "-private-window",
            url,
        ]);
    }

    let child = cmd
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|err| format!("Failed to launch isolated browser: {err}"))?;

    let mut sessions = browser_sessions.lock().expect("browser state poisoned");
    sessions.push(IsolatedBrowserSession {
        session_id: session_id.to_string(),
        profile_dir,
        noop_dir: None,
        codex_home_dir: None,
        child: Some(child),
    });

    Ok(session_id.to_string())
}

fn setup_noop_xdg_open(session_id: &str) -> Result<PathBuf, String> {
    let noop_dir = std::env::temp_dir().join(format!("codex-noop-{session_id}"));
    create_private_dir(&noop_dir).map_err(|err| format!("Failed to create noop dir: {err}"))?;
    for name in [
        "xdg-open",
        "gio",
        "gnome-open",
        "kde-open",
        "kioclient",
        "sensible-browser",
        "x-www-browser",
        "www-browser",
        "codex-auth-noop-browser",
    ] {
        let script_path = noop_dir.join(name);
        fs::write(&script_path, "#!/bin/sh\nexit 0\n").map_err(|err| {
            format!(
                "Failed to write noop opener {}: {err}",
                script_path.display()
            )
        })?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&script_path, fs::Permissions::from_mode(0o755)).map_err(
                |err| {
                    format!(
                        "Failed to chmod noop script {}: {err}",
                        script_path.display()
                    )
                },
            )?;
        }
    }
    Ok(noop_dir)
}

fn cleanup_session_dirs(session: &IsolatedBrowserSession) {
    let _ = fs::remove_dir_all(&session.profile_dir);
    if let Some(ref noop_dir) = session.noop_dir {
        let _ = fs::remove_dir_all(noop_dir);
    }
    if let Some(ref codex_home_dir) = session.codex_home_dir {
        let _ = fs::remove_dir_all(codex_home_dir);
    }
}

fn extract_login_url(output: &str) -> Option<String> {
    output.split_whitespace().find_map(trim_url_candidate)
}

fn trim_url_candidate(token: &str) -> Option<String> {
    let trimmed = token
        .trim_matches(|ch: char| {
            matches!(
                ch,
                '"' | '\'' | '`' | '(' | ')' | '[' | ']' | '{' | '}' | '<' | '>'
            )
        })
        .trim_end_matches(|ch: char| matches!(ch, '.' | ',' | ';'));

    if validate_login_url(trimmed).is_ok() {
        Some(trimmed.to_string())
    } else {
        None
    }
}

fn validate_login_url(url: &str) -> Result<(), String> {
    let Some((scheme, host)) = split_url_scheme_host(url) else {
        return Err("Login URL is malformed.".to_string());
    };
    if scheme != "https" {
        return Err("Login URL must use HTTPS.".to_string());
    }
    if host == "chatgpt.com"
        || host.ends_with(".chatgpt.com")
        || host == "openai.com"
        || host.ends_with(".openai.com")
    {
        Ok(())
    } else {
        Err(format!("Refusing to open unexpected login host `{host}`."))
    }
}

fn split_url_scheme_host(url: &str) -> Option<(String, String)> {
    let (scheme, rest) = url.split_once("://")?;
    if scheme.is_empty() || rest.is_empty() {
        return None;
    }
    let authority = rest
        .split(|ch| matches!(ch, '/' | '?' | '#'))
        .next()
        .unwrap_or_default();
    if authority.is_empty() || authority.contains('@') {
        return None;
    }
    let host = if let Some(after_bracket) = authority.strip_prefix('[') {
        let (host, _) = after_bracket.split_once(']')?;
        host
    } else {
        authority.split(':').next().unwrap_or_default()
    };
    let host = host.trim_end_matches('.').to_lowercase();
    if host.is_empty() {
        None
    } else {
        Some((scheme.to_lowercase(), host))
    }
}

fn load_registry() -> (RegistryFile, Option<String>) {
    let codex_home = match resolve_codex_home() {
        Ok(path) => path,
        Err(err) => {
            return (
                RegistryFile::default(),
                Some(format!("Could not resolve CODEX_HOME: {err}")),
            )
        }
    };
    let registry_path = codex_home.join("accounts").join("registry.json");
    let data = match fs::read_to_string(&registry_path) {
        Ok(data) => data,
        Err(err) => {
            return (
                RegistryFile::default(),
                Some(format!(
                    "Registry is not available at {}: {err}",
                    registry_path.display()
                )),
            )
        }
    };
    match serde_json::from_str::<RegistryFile>(&data) {
        Ok(registry) => (registry, None),
        Err(err) => (
            RegistryFile::default(),
            Some(format!(
                "Registry is malformed at {}: {err}",
                registry_path.display()
            )),
        ),
    }
}

fn registry_with_confirmed_quota(
    registry: &RegistryFile,
    quota_cache: &HashMap<String, ConfirmedQuotaRecord>,
) -> RegistryFile {
    let mut effective = registry.clone();
    for account in &mut effective.accounts {
        let Some(confirmed) = quota_cache.get(account.account_key.as_str()) else {
            continue;
        };
        let Some(snapshot) = confirmed.snapshot.clone() else {
            continue;
        };
        account.last_usage = Some(snapshot);
        account.last_usage_at = Some(confirmed.checked_at);
    }
    effective
}

#[derive(Clone)]
struct AuthRecoveryCandidate {
    id: String,
    account_key: String,
    path: PathBuf,
    source: String,
    last_refresh: Option<String>,
    modified_at: Option<i64>,
}

struct AuthIncidentOutcome {
    output: String,
}

struct AuthCandidateMetadata {
    account_id: String,
    last_refresh: Option<String>,
}

fn build_auth_recovery_snapshot(
    registry: &RegistryFile,
    status: &StatusView,
    force_refresh_reused: Option<bool>,
) -> AuthRecoverySnapshot {
    let active_key = resolve_status_active_key(registry, status)
        .or(registry.active_account_key.as_deref())
        .map(ToOwned::to_owned);
    let candidates = scan_auth_recovery_candidates_for_registry(registry).unwrap_or_default();
    let display_labels = build_display_labels(registry);
    let refresh_token_reused = force_refresh_reused.unwrap_or_else(|| {
        status
            .command_error
            .as_deref()
            .map(is_refresh_token_reused_message)
            .unwrap_or(false)
    });

    let mut accounts = registry
        .accounts
        .iter()
        .filter_map(|account| {
            let current_auth = account_auth_path(&account.account_key).ok();
            let mut account_candidates = candidates
                .iter()
                .filter(|candidate| {
                    candidate.account_key == account.account_key
                        && current_auth
                            .as_ref()
                            .map(|path| path != &candidate.path)
                            .unwrap_or(true)
                })
                .cloned()
                .collect::<Vec<_>>();
            account_candidates.sort_by(compare_auth_recovery_candidates);
            let best = account_candidates.first();
            if best.is_none() && active_key.as_deref() != Some(account.account_key.as_str()) {
                return None;
            }
            Some(AuthRecoveryAccountView {
                account_key: account.account_key.clone(),
                label: display_labels
                    .get(account.account_key.as_str())
                    .cloned()
                    .unwrap_or_else(|| preferred_label(account)),
                email: account.email.clone(),
                is_active: active_key.as_deref() == Some(account.account_key.as_str()),
                candidate_count: account_candidates.len(),
                best_candidate_id: best.map(|candidate| candidate.id.clone()),
                best_source: best.map(|candidate| candidate.source.clone()),
                best_last_refresh: best.and_then(|candidate| candidate.last_refresh.clone()),
                best_modified_at: best.and_then(|candidate| candidate.modified_at),
            })
        })
        .collect::<Vec<_>>();
    accounts.sort_by(|left, right| {
        right
            .is_active
            .cmp(&left.is_active)
            .then_with(|| right.candidate_count.cmp(&left.candidate_count))
            .then_with(|| left.label.to_lowercase().cmp(&right.label.to_lowercase()))
    });
    let active_account = active_key.as_deref().and_then(|key| {
        accounts
            .iter()
            .find(|account| account.account_key == key)
            .cloned()
    });

    AuthRecoverySnapshot {
        refresh_token_reused,
        active_account_key: active_key,
        active_account,
        accounts,
    }
}

fn scan_auth_recovery_candidates_for_registry(
    registry: &RegistryFile,
) -> Result<Vec<AuthRecoveryCandidate>, String> {
    let codex_home = resolve_codex_home()?;
    let mut paths = Vec::<PathBuf>::new();
    let accounts_dir = codex_home.join("accounts");
    if let Ok(read_dir) = fs::read_dir(&accounts_dir) {
        for entry in read_dir.flatten() {
            let path = entry.path();
            let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
                continue;
            };
            if name.contains(".bad.") {
                continue;
            }
            if name.ends_with(".auth.json")
                || name.contains(".auth.json.bak.")
                || name.starts_with("auth.json.bak.")
            {
                push_candidate_path(&mut paths, path);
            }
        }
    }

    let mut candidates = Vec::new();
    for path in paths {
        let Ok(metadata) = load_auth_candidate_metadata(&path) else {
            continue;
        };
        for account in &registry.accounts {
            if auth_candidate_matches_account(&metadata, account) {
                candidates.push(AuthRecoveryCandidate {
                    id: base64_url_no_pad(path.to_string_lossy().as_bytes()),
                    account_key: account.account_key.clone(),
                    source: auth_candidate_source(&path),
                    modified_at: file_modified_unix(&path),
                    path: path.clone(),
                    last_refresh: metadata.last_refresh.clone(),
                });
                break;
            }
        }
    }
    Ok(candidates)
}

fn push_candidate_path(paths: &mut Vec<PathBuf>, path: PathBuf) {
    if !paths.iter().any(|existing| existing == &path) {
        paths.push(path);
    }
}

fn load_auth_candidate_metadata(path: &Path) -> Result<AuthCandidateMetadata, String> {
    let data = fs::read_to_string(path)
        .map_err(|err| format!("Could not read auth candidate at {}: {err}", path.display()))?;
    let value = serde_json::from_str::<serde_json::Value>(&data)
        .map_err(|err| format!("Auth candidate is malformed at {}: {err}", path.display()))?;
    let tokens = value
        .get("tokens")
        .and_then(|tokens| tokens.as_object())
        .ok_or_else(|| "Auth candidate is missing tokens.".to_string())?;
    let refresh_token = tokens
        .get("refresh_token")
        .and_then(|value| value.as_str())
        .unwrap_or("")
        .trim();
    if refresh_token.is_empty() {
        return Err("Auth candidate is missing a refresh token.".to_string());
    }
    let account_id = tokens
        .get("account_id")
        .and_then(|value| value.as_str())
        .unwrap_or("")
        .trim();
    if account_id.is_empty() {
        return Err("Auth candidate is missing an account id.".to_string());
    }
    Ok(AuthCandidateMetadata {
        account_id: account_id.to_string(),
        last_refresh: value
            .get("last_refresh")
            .and_then(|value| value.as_str())
            .map(ToOwned::to_owned),
    })
}

fn auth_candidate_matches_account(
    candidate: &AuthCandidateMetadata,
    account: &AccountRecord,
) -> bool {
    if account
        .chatgpt_account_id
        .as_deref()
        .map(|id| id == candidate.account_id)
        .unwrap_or(false)
    {
        return true;
    }
    account
        .account_key
        .split_once("::")
        .map(|(_, account_id)| account_id == candidate.account_id)
        .unwrap_or(false)
}

fn auth_candidate_source(path: &Path) -> String {
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or_default();
    if name == "auth.json" {
        "current-auth".to_string()
    } else if name.starts_with("auth.json.bak.") {
        "backup".to_string()
    } else if name.contains(".auth.json.bak.") {
        "backup".to_string()
    } else {
        "account-snapshot".to_string()
    }
}

fn file_modified_unix(path: &Path) -> Option<i64> {
    path.metadata()
        .ok()
        .and_then(|metadata| metadata.modified().ok())
        .and_then(|modified| modified.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|duration| duration.as_secs() as i64)
}

fn compare_auth_recovery_candidates(
    left: &AuthRecoveryCandidate,
    right: &AuthRecoveryCandidate,
) -> Ordering {
    compare_iso_like_refresh(right.last_refresh.as_deref(), left.last_refresh.as_deref())
        .then_with(|| compare_optional_i64(right.modified_at, left.modified_at))
        .then_with(|| recovery_source_rank(&left.source).cmp(&recovery_source_rank(&right.source)))
        .then_with(|| left.path.cmp(&right.path))
}

fn compare_iso_like_refresh(left: Option<&str>, right: Option<&str>) -> Ordering {
    match (left, right) {
        (Some(a), Some(b)) => a.cmp(b),
        (Some(_), None) => Ordering::Greater,
        (None, Some(_)) => Ordering::Less,
        (None, None) => Ordering::Equal,
    }
}

fn recovery_source_rank(source: &str) -> u8 {
    match source {
        "current-auth" => 0,
        "backup" => 1,
        "account-snapshot" => 2,
        _ => 3,
    }
}

fn recover_account_auth_from_candidate(
    account_key: &str,
    candidate_id: &str,
) -> Result<ActionResult, String> {
    let (registry, registry_warning) = load_registry();
    if let Some(warning) = registry_warning {
        return Err(warning);
    }
    if !registry
        .accounts
        .iter()
        .any(|account| account.account_key == account_key)
    {
        return Err(format!(
            "Account {} is not tracked.",
            short_account_key(account_key)
        ));
    }
    let candidates = scan_auth_recovery_candidates_for_registry(&registry)?;
    let candidate = candidates
        .into_iter()
        .find(|candidate| candidate.account_key == account_key && candidate.id == candidate_id)
        .ok_or_else(|| "Selected auth recovery snapshot is no longer available.".to_string())?;
    if account_auth_path(account_key)
        .ok()
        .as_ref()
        .map(|path| path == &candidate.path)
        .unwrap_or(false)
    {
        return Err(
            "Selected auth recovery snapshot is already the current auth file.".to_string(),
        );
    }
    let output = restore_account_auth_from_candidate(&registry, account_key, &candidate, false)?;
    clear_account_block_for_recovery(account_key)?;
    Ok(ActionResult {
        command: "desktop recover-account-auth".to_string(),
        output,
    })
}

fn restore_account_auth_from_candidate(
    registry: &RegistryFile,
    account_key: &str,
    candidate: &AuthRecoveryCandidate,
    quarantine_current: bool,
) -> Result<String, String> {
    let source_data = fs::read(&candidate.path).map_err(|err| {
        format!(
            "Could not read recovery snapshot at {}: {err}",
            candidate.path.display()
        )
    })?;
    let dest = account_auth_path(account_key).unwrap_or_else(|_| {
        resolve_codex_home()
            .unwrap_or_else(|_| PathBuf::from("."))
            .join("accounts")
            .join(format!(
                "{}.auth.json",
                base64_url_no_pad(account_key.as_bytes())
            ))
    });
    if quarantine_current {
        let _ = quarantine_file_if_exists(&dest)?;
    } else {
        backup_file_if_exists(&dest)?;
    }
    write_private_file(&dest, &source_data)?;

    let mut restored = vec![format!("account snapshot {}", dest.display())];
    if registry.active_account_key.as_deref() == Some(account_key) {
        let current_auth = resolve_codex_home()?.join("auth.json");
        if quarantine_current {
            let _ = quarantine_file_if_exists(&current_auth)?;
        } else {
            backup_file_if_exists(&current_auth)?;
        }
        write_private_file(&current_auth, &source_data)?;
        restored.push(format!("active auth {}", current_auth.display()));
    }

    Ok(format!(
        "Restored {} from {} (last_refresh: {}).",
        restored.join(" and "),
        candidate.source,
        candidate
            .last_refresh
            .clone()
            .unwrap_or_else(|| "unknown".to_string())
    ))
}

fn handle_refresh_token_incident(
    account_key_hint: Option<&str>,
    context: &str,
) -> Result<Option<AuthIncidentOutcome>, String> {
    let (registry, registry_warning) = load_registry();
    if let Some(warning) = registry_warning {
        return Err(warning);
    }
    let Some(account_key) = resolve_incident_account_key(&registry, account_key_hint) else {
        return Ok(None);
    };

    let had_quarantine_marker = account_auth_is_quarantined(&account_key);
    if !had_quarantine_marker {
        let current_auth = account_auth_path(&account_key).ok();
        let mut candidates = scan_auth_recovery_candidates_for_registry(&registry)?
            .into_iter()
            .filter(|candidate| {
                candidate.account_key == account_key
                    && current_auth
                        .as_ref()
                        .map(|path| path != &candidate.path)
                        .unwrap_or(true)
            })
            .collect::<Vec<_>>();
        candidates.sort_by(compare_auth_recovery_candidates);
        if let Some(candidate) = candidates.into_iter().next() {
            let restored =
                restore_account_auth_from_candidate(&registry, &account_key, &candidate, true)?;
            clear_account_block_for_recovery(&account_key)?;
            return Ok(Some(AuthIncidentOutcome {
                output: format!(
                    "Refresh token reuse detected during {context}. Auto-restored {} from local snapshot; no logout/login was required. {restored}",
                    short_account_key(&account_key)
                ),
            }));
        }
    }

    let quarantined = quarantine_account_auth_for_reused_token(&registry, &account_key)?;
    let blocked = mark_account_blocked_for_recovery(&account_key, REFRESH_TOKEN_REUSED_HINT)?;
    Ok(Some(AuthIncidentOutcome {
        output: format!(
            "Refresh token reuse detected during {context}. No safe unused backup remained, so {} was quarantined and excluded from auto-switch. {} {}",
            short_account_key(&account_key),
            quarantined,
            blocked.output
        ),
    }))
}

fn resolve_incident_account_key(
    registry: &RegistryFile,
    account_key_hint: Option<&str>,
) -> Option<String> {
    if let Some(key) = account_key_hint.and_then(|key| {
        let trimmed = key.trim();
        if trimmed.is_empty() {
            None
        } else {
            Some(trimmed)
        }
    }) {
        if registry
            .accounts
            .iter()
            .any(|account| account.account_key == key)
        {
            return Some(key.to_string());
        }
    }
    registry
        .active_account_key
        .as_ref()
        .filter(|key| {
            registry
                .accounts
                .iter()
                .any(|account| &account.account_key == *key)
        })
        .cloned()
}

fn quarantine_account_auth_for_reused_token(
    registry: &RegistryFile,
    account_key: &str,
) -> Result<String, String> {
    let mut moved = Vec::new();
    if let Ok(path) = account_auth_path(account_key) {
        if let Some(path) = quarantine_file_if_exists(&path)? {
            moved.push(path.display().to_string());
        }
    }
    if registry.active_account_key.as_deref() == Some(account_key) {
        let current_auth = resolve_codex_home()?.join("auth.json");
        if let Some(path) = quarantine_file_if_exists(&current_auth)? {
            moved.push(path.display().to_string());
        }
    }
    if moved.is_empty() {
        Ok("No auth file was present to quarantine.".to_string())
    } else {
        Ok(format!("Moved bad auth file(s) to: {}.", moved.join(", ")))
    }
}

fn quarantine_file_if_exists(path: &Path) -> Result<Option<PathBuf>, String> {
    if !path.exists() {
        return Ok(None);
    }
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| {
            format!(
                "Could not determine quarantine name for {}.",
                path.display()
            )
        })?;
    let quarantine_name = format!(
        "{}.bad.desktop-{}",
        name,
        Local::now().format("%Y%m%d-%H%M%S")
    );
    let mut quarantine_path = path.with_file_name(&quarantine_name);
    if quarantine_path.exists() {
        quarantine_path = path.with_file_name(format!("{quarantine_name}-{}", std::process::id()));
    }
    match fs::rename(path, &quarantine_path) {
        Ok(()) => Ok(Some(quarantine_path)),
        Err(rename_err) => {
            fs::copy(path, &quarantine_path).map_err(|copy_err| {
                format!(
                    "Failed to quarantine {} to {}: rename failed ({rename_err}); copy failed ({copy_err})",
                    path.display(),
                    quarantine_path.display()
                )
            })?;
            fs::remove_file(path).map_err(|remove_err| {
                format!(
                    "Copied bad auth to {}, but failed to remove {}: {remove_err}",
                    quarantine_path.display(),
                    path.display()
                )
            })?;
            Ok(Some(quarantine_path))
        }
    }
}

fn backup_file_if_exists(path: &Path) -> Result<(), String> {
    if !path.exists() {
        return Ok(());
    }
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| format!("Could not determine backup name for {}.", path.display()))?;
    let backup_name = format!(
        "{}.bak.desktop-{}",
        name,
        Local::now().format("%Y%m%d-%H%M%S")
    );
    let backup_path = path.with_file_name(backup_name);
    fs::copy(path, &backup_path).map_err(|err| {
        format!(
            "Failed to back up {} to {}: {err}",
            path.display(),
            backup_path.display()
        )
    })?;
    Ok(())
}

fn write_private_file(path: &Path, data: &[u8]) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .map_err(|err| format!("Failed to create {}: {err}", parent.display()))?;
    }
    fs::write(path, data).map_err(|err| format!("Failed to write {}: {err}", path.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600)).map_err(|err| {
            format!(
                "Failed to restrict permissions on {}: {err}",
                path.display()
            )
        })?;
    }
    Ok(())
}

fn mark_account_blocked_for_recovery(
    account_key: &str,
    reason: &str,
) -> Result<ActionResult, String> {
    let registry_path = resolve_codex_home()?.join("accounts").join("registry.json");
    let data = fs::read_to_string(&registry_path).map_err(|err| {
        format!(
            "Could not read registry at {}: {err}",
            registry_path.display()
        )
    })?;
    let mut value = serde_json::from_str::<serde_json::Value>(&data).map_err(|err| {
        format!(
            "Registry is malformed at {}: {err}",
            registry_path.display()
        )
    })?;
    let accounts = value
        .get("accounts")
        .and_then(|accounts| accounts.as_array())
        .ok_or_else(|| "Registry accounts list is missing.".to_string())?;
    if !accounts.iter().any(|account| {
        account
            .get("account_key")
            .and_then(|key| key.as_str())
            .map(|key| key == account_key)
            .unwrap_or(false)
    }) {
        return Err(format!(
            "Account {} is not tracked.",
            short_account_key(account_key)
        ));
    }
    let blocked_until = Utc::now().timestamp_millis() + 30 * 24 * 60 * 60 * 1000;
    if !value
        .get("auto_switch")
        .map(|v| v.is_object())
        .unwrap_or(false)
    {
        value["auto_switch"] = serde_json::json!({});
    }
    value["auto_switch"]["blocked_account_key"] =
        serde_json::Value::String(account_key.to_string());
    value["auto_switch"]["blocked_until_ms"] = serde_json::Value::Number(blocked_until.into());
    backup_file_if_exists(&registry_path)?;
    let rendered = serde_json::to_vec_pretty(&value)
        .map_err(|err| format!("Failed to serialize registry: {err}"))?;
    write_private_file(&registry_path, &rendered)?;
    Ok(ActionResult {
        command: "desktop mark-account-unusable".to_string(),
        output: format!(
            "Marked {} as temporarily unusable for auto-switch ({reason}).",
            short_account_key(account_key)
        ),
    })
}

fn clear_account_block_for_recovery(account_key: &str) -> Result<(), String> {
    let registry_path = resolve_codex_home()?.join("accounts").join("registry.json");
    let data = fs::read_to_string(&registry_path).map_err(|err| {
        format!(
            "Could not read registry at {}: {err}",
            registry_path.display()
        )
    })?;
    let mut value = serde_json::from_str::<serde_json::Value>(&data).map_err(|err| {
        format!(
            "Registry is malformed at {}: {err}",
            registry_path.display()
        )
    })?;
    let is_blocked_account = value
        .get("auto_switch")
        .and_then(|auto_switch| auto_switch.get("blocked_account_key"))
        .and_then(|key| key.as_str())
        .map(|key| key == account_key)
        .unwrap_or(false);
    if !is_blocked_account {
        return Ok(());
    }
    if let Some(auto_switch) = value
        .get_mut("auto_switch")
        .and_then(|value| value.as_object_mut())
    {
        auto_switch.remove("blocked_account_key");
        auto_switch.remove("blocked_until_ms");
    }
    backup_file_if_exists(&registry_path)?;
    let rendered = serde_json::to_vec_pretty(&value)
        .map_err(|err| format!("Failed to serialize registry: {err}"))?;
    write_private_file(&registry_path, &rendered)
}

fn is_refresh_token_reused_message(message: &str) -> bool {
    let lower = message.to_lowercase();
    lower.contains("refresh token was already used")
        || lower.contains("access token could not be refreshed")
        || lower.contains("please log out and sign in again")
}

fn resolve_codex_home() -> Result<PathBuf, String> {
    if let Some(path) = env::var_os("CODEX_HOME") {
        return Ok(PathBuf::from(path));
    }
    let home = dirs::home_dir().ok_or_else(|| "Home directory is unavailable.".to_string())?;
    Ok(home.join(".codex"))
}

fn account_auth_path(account_key: &str) -> Result<PathBuf, String> {
    let accounts_dir = resolve_codex_home()?.join("accounts");
    let direct = accounts_dir.join(format!("{account_key}.auth.json"));
    if direct.exists() {
        return Ok(direct);
    }
    let encoded = accounts_dir.join(format!(
        "{}.auth.json",
        base64_url_no_pad(account_key.as_bytes())
    ));
    if encoded.exists() {
        return Ok(encoded);
    }
    Err(format!(
        "Auth snapshot for {} is not available.",
        short_account_key(account_key)
    ))
}

fn account_auth_is_quarantined(account_key: &str) -> bool {
    let Ok(accounts_dir) = resolve_codex_home().map(|home| home.join("accounts")) else {
        return false;
    };
    let Ok(read_dir) = fs::read_dir(accounts_dir) else {
        return false;
    };
    let names = account_auth_file_names(account_key);
    read_dir.flatten().any(|entry| {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        names
            .iter()
            .any(|candidate| name.starts_with(&format!("{candidate}.bad.")))
    })
}

fn account_auth_file_names(account_key: &str) -> [String; 2] {
    [
        format!("{account_key}.auth.json"),
        format!("{}.auth.json", base64_url_no_pad(account_key.as_bytes())),
    ]
}

fn base64_url_no_pad(input: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut output = String::with_capacity((input.len() * 4).div_ceil(3));
    for chunk in input.chunks(3) {
        let b0 = chunk[0];
        let b1 = chunk.get(1).copied().unwrap_or(0);
        let b2 = chunk.get(2).copied().unwrap_or(0);
        output.push(TABLE[(b0 >> 2) as usize] as char);
        output.push(TABLE[(((b0 & 0b0000_0011) << 4) | (b1 >> 4)) as usize] as char);
        if chunk.len() >= 2 {
            output.push(TABLE[(((b1 & 0b0000_1111) << 2) | (b2 >> 6)) as usize] as char);
        }
        if chunk.len() == 3 {
            output.push(TABLE[(b2 & 0b0011_1111) as usize] as char);
        }
    }
    output
}

fn base64_url_decode_no_pad(input: &str) -> Result<Vec<u8>, String> {
    let mut output = Vec::with_capacity(input.len() * 3 / 4);
    let mut buffer: u32 = 0;
    let mut bits: u8 = 0;
    for byte in input.bytes() {
        if byte == b'=' {
            break;
        }
        let value = match byte {
            b'A'..=b'Z' => byte - b'A',
            b'a'..=b'z' => byte - b'a' + 26,
            b'0'..=b'9' => byte - b'0' + 52,
            b'-' => 62,
            b'_' => 63,
            _ => return Err("Invalid base64url character in auth id_token.".to_string()),
        } as u32;
        buffer = (buffer << 6) | value;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            output.push(((buffer >> bits) & 0xff) as u8);
            if bits > 0 {
                buffer &= (1 << bits) - 1;
            } else {
                buffer = 0;
            }
        }
    }
    Ok(output)
}

fn run_codex_auth_with_binary<const N: usize>(
    binary: &Path,
    args: [&str; N],
) -> Result<CommandOutput, String> {
    run_codex_auth_dynamic(
        binary,
        &args,
        Duration::from_secs(CLI_PROBE_TIMEOUT_SECONDS),
    )
}

fn run_codex_auth_dynamic(
    binary: &Path,
    args: &[&str],
    timeout: Duration,
) -> Result<CommandOutput, String> {
    let mut child = Command::new(binary)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|err| format!("Failed to run `{}`: {err}", binary.display()))?;

    let started = Instant::now();
    loop {
        match child
            .try_wait()
            .map_err(|err| format!("Failed to poll `{}`: {err}", binary.display()))?
        {
            Some(_) => break,
            None if started.elapsed() > timeout => {
                let _ = child.kill();
                let output = child.wait_with_output().map_err(|err| {
                    format!(
                        "Failed to collect timed-out `{}` output: {err}",
                        binary.display()
                    )
                })?;
                let rendered = render_command_output(&CommandOutput {
                    stdout: String::from_utf8_lossy(&output.stdout).to_string(),
                    stderr: String::from_utf8_lossy(&output.stderr).to_string(),
                });
                return Err(format!(
                    "`{}` timed out after {}s.{}{}",
                    format_command(args),
                    timeout.as_secs(),
                    if rendered.trim().is_empty() {
                        ""
                    } else {
                        "\n\n"
                    },
                    rendered.trim()
                ));
            }
            None => std::thread::sleep(Duration::from_millis(100)),
        }
    }

    let output = child
        .wait_with_output()
        .map_err(|err| format!("Failed to collect `{}` output: {err}", binary.display()))?;

    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();
    if output.status.success() {
        Ok(CommandOutput { stdout, stderr })
    } else {
        let rendered = render_command_output(&CommandOutput { stdout, stderr });
        if rendered.trim().is_empty() {
            Err(format!(
                "`{}` exited with {}.",
                format_command(args),
                output
                    .status
                    .code()
                    .map(|code| code.to_string())
                    .unwrap_or_else(|| "a signal".to_string())
            ))
        } else {
            Err(rendered)
        }
    }
}

fn render_command_output(output: &CommandOutput) -> String {
    let mut combined = String::new();
    if !output.stdout.trim().is_empty() {
        combined.push_str(output.stdout.trim_end());
    }
    if !output.stderr.trim().is_empty() {
        if !combined.is_empty() {
            combined.push_str("\n\n");
        }
        combined.push_str(output.stderr.trim_end());
    }
    combined
}

fn format_command(args: &[&str]) -> String {
    let mut rendered = String::from("codex-auth");
    for arg in args {
        rendered.push(' ');
        rendered.push_str(arg);
    }
    rendered
}

fn format_relative(timestamp: i64) -> String {
    format_relative_at(Utc::now().timestamp(), timestamp)
}

fn format_relative_at(now_secs: i64, timestamp: i64) -> String {
    let delta = (now_secs - timestamp).max(0);
    if delta < 60 {
        "just now".to_string()
    } else if delta < 3600 {
        format!("{}m ago", delta / 60)
    } else if delta < 86_400 {
        format!("{}h ago", delta / 3600)
    } else if delta < 604_800 {
        format!("{}d ago", delta / 86_400)
    } else {
        let dt = Local
            .timestamp_opt(timestamp, 0)
            .single()
            .unwrap_or_else(|| Local::now());
        dt.format("%d %b").to_string()
    }
}

fn format_reset(timestamp: i64) -> String {
    Local
        .timestamp_opt(timestamp, 0)
        .single()
        .map(|dt| dt.format("%H:%M on %-d %b").to_string())
        .unwrap_or_else(|| "unknown".to_string())
}

fn now_label() -> String {
    Local::now().format("%H:%M:%S").to_string()
}

fn preferred_linux_gdk_backend(
    session_type: Option<&str>,
    wayland_display: Option<&str>,
    x_display: Option<&str>,
    current_gdk_backend: Option<&str>,
) -> Option<&'static str> {
    #[cfg(not(target_os = "linux"))]
    {
        let _ = (
            session_type,
            wayland_display,
            x_display,
            current_gdk_backend,
        );
        None
    }

    #[cfg(target_os = "linux")]
    {
        if current_gdk_backend
            .map(|value| !value.trim().is_empty())
            .unwrap_or(false)
        {
            return None;
        }

        let is_wayland_session = session_type
            .map(|value| value.eq_ignore_ascii_case("wayland"))
            .unwrap_or(false)
            || wayland_display
                .map(|value| !value.trim().is_empty())
                .unwrap_or(false);
        let has_x_display = x_display
            .map(|value| !value.trim().is_empty())
            .unwrap_or(false);

        if is_wayland_session && has_x_display {
            Some("x11")
        } else {
            None
        }
    }
}

fn apply_linux_wayland_compat_env() {
    let backend = preferred_linux_gdk_backend(
        env::var("XDG_SESSION_TYPE").ok().as_deref(),
        env::var("WAYLAND_DISPLAY").ok().as_deref(),
        env::var("DISPLAY").ok().as_deref(),
        env::var("GDK_BACKEND").ok().as_deref(),
    );

    if backend == Some("x11") {
        env::set_var("GDK_BACKEND", "x11");
    }
}

fn should_apply_linux_webkit_safety_env() -> bool {
    #[cfg(not(target_os = "linux"))]
    {
        false
    }

    #[cfg(target_os = "linux")]
    {
        fs::metadata("/proc/driver/nvidia/version").is_ok()
    }
}

fn apply_linux_webkit_safety_env() {
    if !should_apply_linux_webkit_safety_env() {
        return;
    }

    if env::var_os("WEBKIT_DISABLE_COMPOSITING_MODE").is_none() {
        env::set_var("WEBKIT_DISABLE_COMPOSITING_MODE", "1");
    }
    if env::var_os("WEBKIT_DISABLE_DMABUF_RENDERER").is_none() {
        env::set_var("WEBKIT_DISABLE_DMABUF_RENDERER", "1");
    }
}

fn cleanup_stale_temp_dirs() {
    let temp = std::env::temp_dir();
    let stale_threshold = std::time::Duration::from_secs(2 * 60 * 60);
    cleanup_stale_dirs_in(
        &temp,
        &["codex-auth-session-", "codex-auth-home-", "codex-noop-"],
        stale_threshold,
    );
    if let Ok(root) = isolated_cache_root() {
        cleanup_stale_dirs_in(&root.join("isolated-homes"), &[""], stale_threshold);
    }
}

fn cleanup_stale_dirs_in(path: &Path, prefixes: &[&str], stale_threshold: std::time::Duration) {
    if let Ok(read_dir) = std::fs::read_dir(path) {
        for entry in read_dir.flatten() {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if !prefixes.iter().any(|prefix| name.starts_with(prefix)) {
                continue;
            }
            let is_stale = entry
                .metadata()
                .and_then(|m| m.modified())
                .and_then(|mtime| mtime.elapsed().map_err(|e| std::io::Error::other(e)))
                .map(|age| age > stale_threshold)
                .unwrap_or(true);
            if is_stale {
                let _ = fs::remove_dir_all(entry.path());
            }
        }
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    apply_linux_wayland_compat_env();
    apply_linux_webkit_safety_env();
    cleanup_stale_temp_dirs();
    tauri::Builder::default()
        .setup(|app| {
            let _ = BUNDLED_CLI_CANDIDATES.set(detect_bundled_cli_candidates(app.handle()));
            Ok(())
        })
        .manage(LoginState::default())
        .manage(ActionState::default())
        .manage(QuotaConfirmState::default())
        .manage(IsolatedBrowserState::default())
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::Destroyed = event {
                if let Some(browser_state) = window.try_state::<IsolatedBrowserState>() {
                    let sessions_arc = Arc::clone(&browser_state.sessions);
                    std::thread::spawn(move || {
                        let mut sessions = sessions_arc.lock().expect("browser state poisoned");
                        for session in sessions.iter_mut() {
                            if let Some(ref mut child) = session.child {
                                let _ = child.kill();
                                let _ = child.wait();
                            }
                            cleanup_session_dirs(session);
                        }
                        sessions.clear();
                    });
                }
            }
        })
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![
            get_dashboard,
            set_cli_override,
            clear_cli_override,
            switch_best,
            switch_account,
            switch_account_now,
            remove_account,
            warm_all,
            warm_account,
            set_auto_enabled,
            set_auto_mode,
            start_login,
            cancel_login,
            get_login_state,
            get_action_state,
            get_quota_confirm_state,
            refresh_quota_confirmations,
            scan_auth_recovery,
            recover_account_auth,
            mark_account_unusable,
            clear_login_state,
            cleanup_isolated_session,
            open_isolated_browser_for_session
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::OsString;

    static CODEX_HOME_ENV_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

    struct CodexHomeEnvRestore {
        previous: Option<OsString>,
    }

    impl Drop for CodexHomeEnvRestore {
        fn drop(&mut self) {
            if let Some(previous) = self.previous.as_ref() {
                env::set_var("CODEX_HOME", previous);
            } else {
                env::remove_var("CODEX_HOME");
            }
        }
    }

    fn with_temp_codex_home<T>(name: &str, run: impl FnOnce(&Path) -> T) -> T {
        let _lock = CODEX_HOME_ENV_LOCK
            .get_or_init(|| Mutex::new(()))
            .lock()
            .expect("CODEX_HOME test lock poisoned");
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("system clock before epoch")
            .as_nanos();
        let dir = std::env::temp_dir().join(format!(
            "codex-auth-desktop-{name}-{}-{unique}",
            std::process::id()
        ));
        fs::create_dir_all(dir.join("accounts")).expect("create temp CODEX_HOME accounts dir");
        let _restore = CodexHomeEnvRestore {
            previous: env::var_os("CODEX_HOME"),
        };
        env::set_var("CODEX_HOME", &dir);
        let result = run(&dir);
        let _ = fs::remove_dir_all(&dir);
        result
    }

    fn sample_auto_switch() -> AutoSwitchConfig {
        AutoSwitchConfig {
            enabled: true,
            mode: "reactive".to_string(),
            pinned_account_key: None,
            blocked_account_key: None,
            blocked_until_ms: None,
            threshold_5h_percent: 10,
            threshold_weekly_percent: 5,
        }
    }

    fn account_view(
        label: &str,
        active: bool,
        eligible: bool,
        freshness: &str,
        remaining: Option<f64>,
        last_usage_at: Option<i64>,
    ) -> AccountView {
        AccountView {
            key: format!("{label}-key"),
            label: label.to_string(),
            email: format!("{label}@example.com"),
            alias: String::new(),
            account_name: None,
            record_hint: format!("…{label}"),
            record_title: format!("{label}-full-key"),
            plan: "free".to_string(),
            auth_mode: "chatgpt".to_string(),
            is_active: active,
            freshness: freshness.to_string(),
            eligible,
            blocked: false,
            auth_available: true,
            auth_health: if active {
                ACCOUNT_HEALTH_ACTIVE.to_string()
            } else if eligible {
                ACCOUNT_HEALTH_READY.to_string()
            } else {
                ACCOUNT_HEALTH_UNKNOWN.to_string()
            },
            usable: true,
            recoverable: false,
            quarantined: false,
            quarantine_reason: None,
            last_auth_error: None,
            quota_source: "local-snapshot".to_string(),
            quota_confirmed_at: None,
            quota_confirmed_relative: None,
            quota_confirm_status_code: None,
            quota_confirm_error: None,
            effective_remaining: remaining,
            five_hour: None,
            weekly: None,
            last_used_at: last_usage_at,
            last_usage_at,
            last_used_relative: None,
            last_usage_relative: None,
        }
    }

    fn sample_status_with_active_key(
        active_account: Option<&str>,
        active_account_key: Option<&str>,
    ) -> StatusView {
        StatusView {
            pairs: Vec::new(),
            service: Some("running".to_string()),
            usage: Some("local".to_string()),
            account_api: Some("disabled".to_string()),
            active_auth: Some("ready".to_string()),
            active_account: active_account.map(ToOwned::to_owned),
            active_account_key: active_account_key.map(ToOwned::to_owned),
            selection: Some("reactive-best-snapshot".to_string()),
            pinned_account: None,
            pin_state: None,
            failover_state: None,
            blocked_account: None,
            blocked_until: None,
            snapshot_source: Some("local".to_string()),
            known_snapshots: Some("0/0".to_string()),
            eligible_candidates: Some("0".to_string()),
            registry_active: None,
            has_active_account_key_line: active_account_key.is_some(),
            command_error: None,
        }
    }

    fn usage_snapshot(
        five_hour_remaining: Option<f64>,
        weekly_remaining: Option<f64>,
        five_hour_reset: Option<i64>,
        weekly_reset: Option<i64>,
    ) -> RateLimitSnapshot {
        RateLimitSnapshot {
            primary: five_hour_remaining.map(|remaining| RateLimitWindow {
                used_percent: 100.0 - remaining,
                window_minutes: Some(300),
                resets_at: five_hour_reset,
            }),
            secondary: weekly_remaining.map(|remaining| RateLimitWindow {
                used_percent: 100.0 - remaining,
                window_minutes: Some(10080),
                resets_at: weekly_reset,
            }),
            plan_type: Some("free".to_string()),
        }
    }

    fn account_record(
        key: &str,
        email: &str,
        alias: &str,
        snapshot: Option<RateLimitSnapshot>,
        last_usage_at: Option<i64>,
        last_used_at: Option<i64>,
    ) -> AccountRecord {
        AccountRecord {
            account_key: key.to_string(),
            chatgpt_account_id: key
                .split_once("::")
                .map(|(_, account_id)| account_id.to_string()),
            chatgpt_user_id: key.split_once("::").map(|(user_id, _)| user_id.to_string()),
            email: email.to_string(),
            alias: alias.to_string(),
            account_name: None,
            plan: Some("free".to_string()),
            auth_mode: Some("chatgpt".to_string()),
            last_used_at,
            last_usage: snapshot,
            last_usage_at,
            auth_health: Some("verified".to_string()),
            auth_checked_at: Some(Utc::now().timestamp()),
            auth_verified_at: Some(Utc::now().timestamp()),
            auth_error: None,
            auth_quarantined_at: None,
        }
    }

    #[test]
    fn switch_verification_requires_registry_active_key_to_match() {
        let registry = RegistryFile {
            active_account_key: Some("target-key".to_string()),
            auto_switch: sample_auto_switch(),
            api: ApiConfig::default(),
            accounts: vec![account_record(
                "target-key",
                "target@example.com",
                "",
                None,
                None,
                None,
            )],
        };

        assert!(verify_registry_active_account(&registry, "target-key").is_ok());
        let err = verify_registry_active_account(&registry, "other-key").unwrap_err();
        assert!(err.contains("registry active account"));
    }

    #[test]
    fn codex_process_detection_skips_auth_tools() {
        assert!(is_codex_cli_process(
            "codex",
            "/home/demo/.npm-global/lib/node_modules/@openai/codex/vendor/codex exec"
        ));
        assert!(is_codex_cli_process(
            "node",
            "node /home/demo/.npm-global/bin/codext"
        ));
        assert!(!is_codex_cli_process(
            "codex-auth",
            "/home/demo/.local/opt/codex-auth-studio/lib/Codex Auth Studio/bin/codex-auth switch"
        ));
        assert!(!is_codex_cli_process(
            "codex-auth-desk",
            "/home/demo/.local/opt/codex-auth-studio/bin/codex-auth-desktop"
        ));
    }

    #[test]
    fn parses_status_output_pairs() {
        let status = parse_status_output(
            "service: running\nusage: local\naccount API: disabled\nactive auth: ready\nactive account: sage@example.com\nactive account key: user-sage::acct-sage\nselection: pinned-best-known\npinned account: sage@example.com\npin state: ready\neligible candidates: 0\n",
        );
        assert_eq!(status.service.as_deref(), Some("running"));
        assert_eq!(status.usage.as_deref(), Some("local"));
        assert_eq!(status.account_api.as_deref(), Some("disabled"));
        assert_eq!(status.active_account.as_deref(), Some("sage@example.com"));
        assert_eq!(
            status.active_account_key.as_deref(),
            Some("user-sage::acct-sage")
        );
        assert_eq!(status.selection.as_deref(), Some("pinned-best-known"));
        assert_eq!(status.pinned_account.as_deref(), Some("sage@example.com"));
        assert_eq!(status.pin_state.as_deref(), Some("ready"));
        assert_eq!(status.eligible_candidates.as_deref(), Some("0"));
    }

    #[test]
    fn parses_failover_status_output_pairs() {
        let status = parse_status_output(
            "service: running\nusage source mode: local-only\nactive auth: ready\nactive account: sage@example.com\nactive account key: user-sage::acct-sage\nselection: failover-on-rate-limit\nfailover state: switched\nblocked account: old@example.com\nblocked until: 2026-04-08 14:30:00\neligible candidates: 1\n",
        );
        assert_eq!(status.selection.as_deref(), Some("failover-on-rate-limit"));
        assert_eq!(status.failover_state.as_deref(), Some("switched"));
        assert_eq!(status.blocked_account.as_deref(), Some("old@example.com"));
        assert_eq!(status.blocked_until.as_deref(), Some("2026-04-08 14:30:00"));
        assert_eq!(status.snapshot_source.as_deref(), Some("local-only"));
    }

    #[test]
    fn snapshot_freshness_uses_age_threshold() {
        let now = 1_775_000_000i64;
        assert_eq!(
            snapshot_freshness_at(now, true, Some(now - 60)),
            SnapshotFreshness::Fresh
        );
        assert_eq!(
            snapshot_freshness_at(now, true, Some(now - LOCAL_SNAPSHOT_MAX_AGE_SECONDS - 1)),
            SnapshotFreshness::Stale
        );
        assert_eq!(
            snapshot_freshness_at(now, false, None),
            SnapshotFreshness::Unknown
        );
    }

    #[test]
    fn account_eligibility_requires_fresh_snapshot_and_thresholds() {
        let now = Utc::now().timestamp();
        let registry = RegistryFile {
            active_account_key: None,
            auto_switch: sample_auto_switch(),
            api: ApiConfig::default(),
            accounts: Vec::new(),
        };

        let healthy = account_record(
            "healthy-key",
            "healthy@example.com",
            "healthy",
            Some(usage_snapshot(Some(42.0), Some(12.0), None, None)),
            Some(now - 60),
            None,
        );
        assert!(is_account_eligible(&healthy, &registry, now));

        let low_weekly = account_record(
            "low-weekly-key",
            "low-weekly@example.com",
            "low-weekly",
            Some(usage_snapshot(Some(42.0), Some(4.0), None, None)),
            Some(now - 60),
            None,
        );
        assert!(!is_account_eligible(&low_weekly, &registry, now));

        let unknown = account_record(
            "unknown-key",
            "unknown@example.com",
            "unknown",
            Some(usage_snapshot(Some(42.0), Some(12.0), None, None)),
            None,
            None,
        );
        assert!(!is_account_eligible(&unknown, &registry, now));
    }

    #[test]
    fn quota_resolution_matches_cli_primary_implicit_5h_window() {
        let now = Utc::now().timestamp();
        let snapshot = RateLimitSnapshot {
            primary: Some(RateLimitWindow {
                used_percent: 60.0,
                window_minutes: None,
                resets_at: Some(now + 600),
            }),
            secondary: Some(RateLimitWindow {
                used_percent: 70.0,
                window_minutes: Some(10080),
                resets_at: Some(now + 3600),
            }),
            plan_type: Some("free".to_string()),
        };
        let account = account_record(
            "primary-implicit-key",
            "primary-implicit@example.com",
            "primary-implicit",
            Some(snapshot),
            Some(now - 30),
            None,
        );

        let (five_hour, weekly) = extract_windows_at(account.last_usage.as_ref(), now);
        assert_eq!(five_hour.map(|window| window.remaining_percent), Some(40.0));
        assert_eq!(weekly.map(|window| window.remaining_percent), Some(30.0));
        assert_eq!(
            known_candidate_score(&account, now).map(|score| score.effective_remaining),
            Some(40.0)
        );
        assert!(eligible_candidate_score(&account, &sample_auto_switch(), now).is_some());
    }

    #[test]
    fn expired_quota_window_is_rendered_as_full_remaining() {
        let now = Utc::now().timestamp();
        let snapshot = usage_snapshot(Some(0.0), None, Some(now - 1), None);
        let (five_hour, weekly) = extract_windows_at(Some(&snapshot), now);

        assert!(weekly.is_none());
        assert_eq!(
            five_hour.map(|window| window.remaining_percent),
            Some(100.0)
        );
    }

    #[test]
    fn blocked_account_is_not_best_or_eligible_until_block_expires() {
        let now = Utc::now().timestamp();
        let mut auto = sample_auto_switch();
        auto.blocked_account_key = Some("blocked-key".to_string());
        auto.blocked_until_ms = Some(Utc::now().timestamp_millis() + 60_000);
        let registry = RegistryFile {
            active_account_key: None,
            auto_switch: auto,
            api: ApiConfig::default(),
            accounts: vec![
                account_record(
                    "blocked-key",
                    "blocked@example.com",
                    "blocked",
                    Some(usage_snapshot(
                        Some(95.0),
                        Some(95.0),
                        Some(now + 600),
                        Some(now + 3600),
                    )),
                    Some(now - 20),
                    Some(now - 20),
                ),
                account_record(
                    "available-key",
                    "available@example.com",
                    "available",
                    Some(usage_snapshot(
                        Some(55.0),
                        Some(55.0),
                        Some(now + 900),
                        Some(now + 3900),
                    )),
                    Some(now - 30),
                    Some(now - 30),
                ),
            ],
        };

        assert_eq!(best_known_account_key(&registry), Some("available-key"));
        assert_eq!(best_eligible_account_key(&registry), Some("available-key"));

        let status = sample_status_with_active_key(None, None);
        let accounts = build_account_views(&registry, &status, &HashMap::new());
        let blocked = accounts
            .iter()
            .find(|account| account.key == "blocked-key")
            .expect("missing blocked view");
        assert!(!blocked.eligible);
    }

    #[test]
    fn default_sort_keeps_usable_eligible_then_remaining_without_active_jump() {
        let mut accounts = vec![
            account_view("beta", false, true, "fresh", Some(61.0), Some(10)),
            account_view("gamma", false, false, "fresh", Some(99.0), Some(100)),
            account_view("alpha", true, true, "fresh", Some(18.0), Some(1)),
        ];
        accounts.sort_by(compare_accounts_for_sort);
        let labels = accounts
            .into_iter()
            .map(|account| account.label)
            .collect::<Vec<_>>();
        assert_eq!(labels, vec!["beta", "alpha", "gamma"]);
    }

    #[test]
    fn extracts_login_url_from_log_output() {
        let output = "Open this URL in your browser:\nhttps://auth.openai.com/oauth/authorize?x=1&y=2\nWaiting for callback...";
        assert_eq!(
            extract_login_url(output).as_deref(),
            Some("https://auth.openai.com/oauth/authorize?x=1&y=2")
        );
    }

    #[test]
    fn extracts_oauth_url_instead_of_local_callback_server_url() {
        let output = "Starting local login server on http://localhost:1455.\nIf your browser did not open, navigate to this URL to authenticate:\n\nhttps://auth.openai.com/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&state=abc\n";
        assert_eq!(
            extract_login_url(output).as_deref(),
            Some("https://auth.openai.com/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&state=abc")
        );
    }

    #[test]
    fn login_url_validation_rejects_unexpected_hosts() {
        assert!(validate_login_url("https://auth.openai.com/oauth/authorize?x=1").is_ok());
        assert!(validate_login_url("https://chatgpt.com/auth/login").is_ok());
        assert!(validate_login_url("http://127.0.0.1:1455/callback").is_err());
        assert!(validate_login_url("http://localhost:1455/callback").is_err());
        assert!(validate_login_url("http://example.com/callback").is_err());
        assert!(validate_login_url("https://example.com/oauth").is_err());
        assert!(extract_login_url("go to https://example.com/oauth").is_none());
    }

    #[test]
    fn refresh_token_reuse_errors_are_classified() {
        assert!(is_refresh_token_reused_message(
            "Your access token could not be refreshed because your refresh token was already used. Please log out and sign in again."
        ));
        assert!(!is_refresh_token_reused_message(
            "network timeout while checking status"
        ));
    }

    #[test]
    fn auth_recovery_candidate_requires_refresh_token_and_matches_account_id() {
        let dir = std::env::temp_dir().join(format!(
            "codex-auth-recovery-test-{}",
            generate_session_id()
        ));
        fs::create_dir_all(&dir).expect("create temp dir");
        let auth_path = dir.join("candidate.auth.json");
        fs::write(
            &auth_path,
            r#"{"auth_mode":"chatgpt","tokens":{"access_token":"access","refresh_token":"refresh","account_id":"acct-1"},"last_refresh":"2026-05-06T00:00:00Z"}"#,
        )
        .expect("write auth candidate");
        let metadata = load_auth_candidate_metadata(&auth_path).expect("metadata should parse");
        let account = account_record("user-1::acct-1", "one@example.com", "one", None, None, None);
        assert!(auth_candidate_matches_account(&metadata, &account));

        fs::write(
            &auth_path,
            r#"{"auth_mode":"chatgpt","tokens":{"access_token":"access","account_id":"acct-1"}}"#,
        )
        .expect("write missing refresh token candidate");
        assert!(load_auth_candidate_metadata(&auth_path).is_err());
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn auth_recovery_snapshot_excludes_current_auth_file() {
        with_temp_codex_home("recovery-excludes-current", |codex_home| {
            let account_key = "user-1::acct-1";
            let accounts_dir = codex_home.join("accounts");
            let current = accounts_dir.join(format!("{account_key}.auth.json"));
            let backup = accounts_dir.join(format!("{account_key}.auth.json.bak.1"));
            let current_auth = r#"{"auth_mode":"chatgpt","tokens":{"access_token":"current","refresh_token":"current-refresh","account_id":"acct-1"},"last_refresh":"2026-05-06T00:00:00Z"}"#;
            let backup_auth = r#"{"auth_mode":"chatgpt","tokens":{"access_token":"backup","refresh_token":"backup-refresh","account_id":"acct-1"},"last_refresh":"2026-05-07T00:00:00Z"}"#;
            fs::write(&current, current_auth).expect("write current auth");
            fs::write(&backup, backup_auth).expect("write backup auth");

            let registry = RegistryFile {
                active_account_key: Some(account_key.to_string()),
                auto_switch: sample_auto_switch(),
                api: ApiConfig::default(),
                accounts: vec![account_record(
                    account_key,
                    "one@example.com",
                    "one",
                    None,
                    None,
                    None,
                )],
            };
            let status = sample_status_with_active_key(Some("one@example.com"), Some(account_key));

            let snapshot = build_auth_recovery_snapshot(&registry, &status, None);
            let account = snapshot
                .accounts
                .iter()
                .find(|account| account.account_key == account_key)
                .expect("missing recovery account");

            assert_eq!(account.candidate_count, 1);
            assert_eq!(account.best_source.as_deref(), Some("backup"));
        });
    }

    #[test]
    fn base64_url_no_pad_matches_auth_snapshot_filename_encoding() {
        assert_eq!(
            base64_url_no_pad(b"user-abc::workspace-id"),
            "dXNlci1hYmM6OndvcmtzcGFjZS1pZA"
        );
    }

    #[test]
    fn parses_usage_api_response_into_rate_limit_snapshot() {
        let body = r#"{
            "plan_type": "free",
            "rate_limit": {
                "primary_window": {
                    "used_percent": 12.5,
                    "limit_window_seconds": 18000,
                    "reset_at": 1775739000
                },
                "secondary_window": {
                    "used_percent": 34,
                    "limit_window_seconds": 604800,
                    "reset_at": 1776339000
                }
            }
        }"#;

        let snapshot = parse_usage_api_response(body)
            .expect("usage response should parse")
            .expect("snapshot should have windows");
        assert_eq!(snapshot.plan_type.as_deref(), Some("free"));
        assert_eq!(
            snapshot.primary.as_ref().map(|window| window.used_percent),
            Some(12.5)
        );
        assert_eq!(
            snapshot
                .primary
                .as_ref()
                .and_then(|window| window.window_minutes),
            Some(300)
        );
        assert_eq!(
            snapshot
                .secondary
                .as_ref()
                .and_then(|window| window.window_minutes),
            Some(10080)
        );
    }

    #[test]
    fn parses_curl_json_status_output_and_rejects_malformed_status() {
        let (body, status) =
            parse_curl_json_status_output("{\"ok\":true}\n200").expect("curl output should parse");
        assert_eq!(body, "{\"ok\":true}");
        assert_eq!(status, Some(200));

        let (body, status) = parse_curl_json_status_output("{\"error\":\"nope\"}\n401")
            .expect("error body should still parse");
        assert_eq!(body, "{\"error\":\"nope\"}");
        assert_eq!(status, Some(401));

        assert!(parse_curl_json_status_output("{\"ok\":true}").is_err());
        assert!(parse_curl_json_status_output("{\"ok\":true}\nnot-a-status").is_err());
    }

    #[test]
    fn quota_confirm_targets_respect_scope_cache_ttl_force_and_auth_mode() {
        let now = Utc::now().timestamp();
        let registry = RegistryFile {
            active_account_key: Some("active-key".to_string()),
            auto_switch: sample_auto_switch(),
            api: ApiConfig {
                usage: true,
                account: false,
            },
            accounts: vec![
                account_record(
                    "active-key",
                    "active@example.com",
                    "active",
                    Some(usage_snapshot(
                        Some(50.0),
                        Some(50.0),
                        Some(now + 600),
                        Some(now + 3600),
                    )),
                    Some(now - 60),
                    Some(now - 60),
                ),
                account_record(
                    "best-key",
                    "best@example.com",
                    "best",
                    Some(usage_snapshot(
                        Some(90.0),
                        Some(90.0),
                        Some(now + 600),
                        Some(now + 3600),
                    )),
                    Some(now - 30),
                    Some(now - 30),
                ),
                account_record(
                    "stale-key",
                    "stale@example.com",
                    "stale",
                    Some(usage_snapshot(
                        Some(70.0),
                        Some(70.0),
                        Some(now + 600),
                        Some(now + 3600),
                    )),
                    Some(now - LOCAL_SNAPSHOT_MAX_AGE_SECONDS - 60),
                    Some(now - 60),
                ),
                account_record(
                    "unknown-key",
                    "unknown@example.com",
                    "unknown",
                    None,
                    None,
                    None,
                ),
                AccountRecord {
                    auth_mode: Some("apikey".to_string()),
                    ..account_record(
                        "apikey-key",
                        "apikey@example.com",
                        "apikey",
                        None,
                        None,
                        None,
                    )
                },
            ],
        };
        let state = QuotaConfirmState::default();
        {
            let mut job = state.inner.lock().expect("quota confirm state poisoned");
            job.cache.insert(
                "active-key".to_string(),
                ConfirmedQuotaRecord {
                    snapshot: Some(usage_snapshot(Some(51.0), Some(51.0), None, None)),
                    checked_at: now,
                    status_code: Some(200),
                    error: None,
                },
            );
        }

        let auth_path = |account_key: &str| Some(PathBuf::from(format!("{account_key}.auth.json")));
        let dashboard_targets = quota_confirm_targets_with_auth_resolver(
            &registry,
            QuotaConfirmScope::Dashboard,
            false,
            &state,
            auth_path,
        );
        assert_eq!(
            dashboard_targets
                .iter()
                .map(|task| task.account_key.as_str())
                .collect::<Vec<_>>(),
            vec!["best-key", "stale-key", "unknown-key"]
        );

        let all_targets = quota_confirm_targets_with_auth_resolver(
            &registry,
            QuotaConfirmScope::All,
            true,
            &state,
            auth_path,
        );
        assert_eq!(
            all_targets
                .iter()
                .map(|task| task.account_key.as_str())
                .collect::<Vec<_>>(),
            vec!["active-key", "best-key", "stale-key", "unknown-key"]
        );
    }

    #[test]
    fn confirmed_quota_persist_keeps_registry_metadata_and_skips_fresh_records() {
        with_temp_codex_home("quota-persist", |codex_home| {
            let now = Utc::now().timestamp();
            let registry_path = codex_home.join("accounts").join("registry.json");
            let raw_registry = serde_json::json!({
                "schema_version": 42,
                "active_account_activated_at_ms": 12345,
                "active_account_key": "target-key",
                "api": { "usage": true, "account": true },
                "auto_switch": { "enabled": false, "mode": "reactive" },
                "accounts": [
                    {
                        "account_key": "target-key",
                        "email": "target@example.com",
                        "created_at": 111,
                        "last_usage": null,
                        "last_usage_at": null
                    },
                    {
                        "account_key": "other-key",
                        "email": "other@example.com",
                        "created_at": 222,
                        "last_usage": null,
                        "last_usage_at": null
                    }
                ]
            });
            fs::write(
                &registry_path,
                serde_json::to_vec_pretty(&raw_registry).expect("serialize registry fixture"),
            )
            .expect("write registry fixture");

            let record = ConfirmedQuotaRecord {
                snapshot: Some(usage_snapshot(
                    Some(88.0),
                    Some(77.0),
                    Some(now + 300),
                    Some(now + 600),
                )),
                checked_at: now,
                status_code: Some(200),
                error: None,
            };

            assert!(persist_confirmed_quota_record("target-key", &record).expect("persist quota"));
            assert!(!persist_confirmed_quota_record("target-key", &record)
                .expect("fresh quota should not rewrite"));

            let updated: serde_json::Value = serde_json::from_str(
                &fs::read_to_string(&registry_path).expect("read updated registry"),
            )
            .expect("parse updated registry");
            assert_eq!(updated["schema_version"], 42);
            assert_eq!(updated["active_account_activated_at_ms"], 12345);
            assert_eq!(updated["accounts"][0]["created_at"], 111);
            assert_eq!(updated["accounts"][0]["last_usage_at"], now);
            assert_eq!(updated["accounts"][0]["auth_health"], "verified");
            assert_eq!(
                updated["accounts"][0]["auth_error"],
                serde_json::Value::Null
            );
            assert_eq!(
                updated["accounts"][0]["last_usage"]["primary"]["used_percent"],
                12.0
            );
            assert_eq!(
                updated["accounts"][1]["last_usage"],
                serde_json::Value::Null
            );

            let backup_count = fs::read_dir(registry_path.parent().expect("registry parent"))
                .expect("read account dir")
                .filter_map(Result::ok)
                .filter(|entry| {
                    entry
                        .file_name()
                        .to_string_lossy()
                        .starts_with("registry.json.bak.desktop-")
                })
                .count();
            assert_eq!(backup_count, 1);
        });
    }

    #[test]
    fn confirmed_quota_overlay_replaces_local_snapshot_in_effective_registry() {
        let now = Utc::now().timestamp();
        let registry = RegistryFile {
            active_account_key: Some("overlay-key".to_string()),
            auto_switch: sample_auto_switch(),
            api: ApiConfig {
                usage: true,
                account: false,
            },
            accounts: vec![account_record(
                "overlay-key",
                "overlay@example.com",
                "overlay",
                Some(usage_snapshot(
                    Some(10.0),
                    Some(10.0),
                    Some(now + 600),
                    Some(now + 3600),
                )),
                Some(now - 60),
                Some(now - 60),
            )],
        };
        let mut cache = HashMap::new();
        cache.insert(
            "overlay-key".to_string(),
            ConfirmedQuotaRecord {
                snapshot: Some(usage_snapshot(
                    Some(88.0),
                    Some(77.0),
                    Some(now + 1200),
                    Some(now + 7200),
                )),
                checked_at: now,
                status_code: Some(200),
                error: None,
            },
        );

        let effective = registry_with_confirmed_quota(&registry, &cache);
        let status =
            sample_status_with_active_key(Some("overlay@example.com"), Some("overlay-key"));
        let accounts = build_account_views(&effective, &status, &cache);
        assert_eq!(accounts[0].effective_remaining, Some(88.0));
        assert_eq!(accounts[0].quota_source, "api-confirmed");
        assert_eq!(accounts[0].quota_confirm_status_code, Some(200));
    }

    #[test]
    fn eligible_hint_explains_zero_candidates() {
        let registry = RegistryFile {
            active_account_key: None,
            auto_switch: sample_auto_switch(),
            api: ApiConfig::default(),
            accounts: Vec::new(),
        };
        let hint = build_eligible_hint(&registry, 0, 0, None, None);
        assert_eq!(hint.code, Some(ELIGIBLE_HINT_MISSING_FRESH_LOCAL_SNAPSHOT));
        assert!(hint.text.unwrap().contains("fresh quota data"));
    }

    #[test]
    fn summary_uses_best_known_ranking_not_active_first_sort() {
        let now = Utc::now().timestamp();
        let registry = RegistryFile {
            active_account_key: Some("active-key".to_string()),
            auto_switch: sample_auto_switch(),
            api: ApiConfig::default(),
            accounts: vec![
                account_record(
                    "active-key",
                    "active@example.com",
                    "active",
                    Some(usage_snapshot(
                        Some(18.0),
                        Some(18.0),
                        Some(now + 600),
                        Some(now + 1200),
                    )),
                    Some(now - 60),
                    Some(now - 60),
                ),
                account_record(
                    "better-key",
                    "better@example.com",
                    "better",
                    Some(usage_snapshot(
                        Some(61.0),
                        Some(61.0),
                        Some(now + 300),
                        Some(now + 1800),
                    )),
                    Some(now - 30),
                    Some(now - 30),
                ),
            ],
        };

        let status = sample_status_with_active_key(Some("active@example.com"), Some("active-key"));
        let accounts = build_account_views(&registry, &status, &HashMap::new());
        let summary = build_summary(&registry, &status, &accounts);
        assert_eq!(summary.active_label.as_deref(), Some("active"));
        assert_eq!(summary.best_known_label.as_deref(), Some("better"));
        assert_eq!(summary.best_known_remaining, Some(61.0));
    }

    #[test]
    fn summary_prefers_best_known_over_eligibility_when_mode_is_pinned() {
        let now = Utc::now().timestamp();
        let registry = RegistryFile {
            active_account_key: Some("healthy-key".to_string()),
            auto_switch: AutoSwitchConfig {
                enabled: true,
                mode: "pinned".to_string(),
                pinned_account_key: Some("healthy-key".to_string()),
                blocked_account_key: None,
                blocked_until_ms: None,
                threshold_5h_percent: 10,
                threshold_weekly_percent: 5,
            },
            api: ApiConfig::default(),
            accounts: vec![
                account_record(
                    "exhausted-key",
                    "exhausted@example.com",
                    "exhausted",
                    Some(usage_snapshot(
                        Some(100.0),
                        Some(0.0),
                        Some(now + 300),
                        Some(now + 1800),
                    )),
                    Some(now - 30),
                    Some(now - 30),
                ),
                account_record(
                    "healthy-key",
                    "healthy@example.com",
                    "healthy",
                    Some(usage_snapshot(
                        Some(58.0),
                        Some(58.0),
                        Some(now + 600),
                        Some(now + 2400),
                    )),
                    Some(now - 60),
                    Some(now - 60),
                ),
            ],
        };
        let mut status =
            sample_status_with_active_key(Some("healthy@example.com"), Some("healthy-key"));
        status.selection = Some("pinned-best-known".to_string());
        status.pinned_account = Some("healthy@example.com".to_string());
        status.pin_state = Some("ready".to_string());

        let accounts = build_account_views(&registry, &status, &HashMap::new());
        let summary = build_summary(&registry, &status, &accounts);
        assert_eq!(summary.best_known_label.as_deref(), Some("exhausted"));
        assert_eq!(summary.best_known_remaining, Some(100.0));
        assert_eq!(
            summary.pinned_account_label.as_deref(),
            Some("healthy@example.com")
        );
        assert_eq!(summary.pin_state.as_deref(), Some("ready"));
        assert_eq!(summary.eligible_hint, None);
        assert_eq!(summary.eligible_hint_code, None);
    }

    #[test]
    fn summary_uses_blocked_account_and_failover_state_when_mode_is_failover() {
        let now = Utc::now().timestamp();
        let registry = RegistryFile {
            active_account_key: Some("healthy-key".to_string()),
            auto_switch: AutoSwitchConfig {
                enabled: true,
                mode: "failover".to_string(),
                pinned_account_key: None,
                blocked_account_key: Some("blocked-key".to_string()),
                blocked_until_ms: None,
                threshold_5h_percent: 10,
                threshold_weekly_percent: 5,
            },
            api: ApiConfig::default(),
            accounts: vec![
                account_record(
                    "blocked-key",
                    "blocked@example.com",
                    "blocked",
                    Some(usage_snapshot(
                        Some(0.0),
                        Some(0.0),
                        Some(now + 300),
                        Some(now + 1800),
                    )),
                    Some(now - 30),
                    Some(now - 30),
                ),
                account_record(
                    "healthy-key",
                    "healthy@example.com",
                    "healthy",
                    Some(usage_snapshot(
                        Some(58.0),
                        Some(58.0),
                        Some(now + 600),
                        Some(now + 2400),
                    )),
                    Some(now - 60),
                    Some(now - 60),
                ),
            ],
        };
        let mut status =
            sample_status_with_active_key(Some("healthy@example.com"), Some("healthy-key"));
        status.selection = Some("failover-on-rate-limit".to_string());
        status.failover_state = Some("switched".to_string());
        status.blocked_account = Some("blocked@example.com".to_string());
        status.blocked_until = Some("2026-04-08 14:30:00".to_string());

        let accounts = build_account_views(&registry, &status, &HashMap::new());
        let summary = build_summary(&registry, &status, &accounts);
        assert_eq!(
            summary.blocked_account_label.as_deref(),
            Some("blocked@example.com")
        );
        assert_eq!(summary.failover_state.as_deref(), Some("switched"));
        assert_eq!(
            summary.blocked_until.as_deref(),
            Some("2026-04-08 14:30:00")
        );
        assert_eq!(summary.eligible_hint, None);
        assert_eq!(summary.eligible_hint_code, None);
    }

    #[test]
    fn summary_uses_status_active_label_when_no_tracked_active_account_exists() {
        let registry = RegistryFile {
            active_account_key: None,
            auto_switch: sample_auto_switch(),
            api: ApiConfig::default(),
            accounts: vec![account_record(
                "tracked-key",
                "tracked@example.com",
                "",
                None,
                None,
                None,
            )],
        };
        let status = sample_status_with_active_key(Some("untracked@example.com"), None);
        let accounts = build_account_views(&registry, &status, &HashMap::new());
        let summary = build_summary(&registry, &status, &accounts);

        assert_eq!(
            summary.active_label.as_deref(),
            Some("untracked@example.com")
        );
    }

    #[test]
    fn summary_uses_status_active_label_for_api_key_mode() {
        let registry = RegistryFile {
            active_account_key: None,
            auto_switch: sample_auto_switch(),
            api: ApiConfig::default(),
            accounts: Vec::new(),
        };
        let status = sample_status_with_active_key(Some("api-key"), None);
        let accounts = build_account_views(&registry, &status, &HashMap::new());
        let summary = build_summary(&registry, &status, &accounts);

        assert_eq!(summary.active_label.as_deref(), Some("api-key"));
    }

    #[test]
    fn eligible_hint_codes_cover_threshold_and_active_best_states() {
        let registry = RegistryFile {
            active_account_key: Some("only-key".to_string()),
            auto_switch: sample_auto_switch(),
            api: ApiConfig::default(),
            accounts: Vec::new(),
        };

        let threshold_hint = build_eligible_hint(&registry, 2, 0, None, None);
        assert_eq!(threshold_hint.code, Some(ELIGIBLE_HINT_BELOW_THRESHOLD));
        assert!(threshold_hint
            .text
            .as_deref()
            .unwrap_or_default()
            .contains("current thresholds"));

        let active = account_view("only", true, true, "fresh", Some(55.0), Some(1));
        let active_best_hint = build_eligible_hint(&registry, 1, 1, Some(&active), Some(&active));
        assert_eq!(
            active_best_hint.code,
            Some(ELIGIBLE_HINT_ACTIVE_ALREADY_BEST)
        );
        assert!(active_best_hint
            .text
            .as_deref()
            .unwrap_or_default()
            .contains("only eligible candidate"));
    }

    #[test]
    fn active_resolution_prefers_exact_account_key_for_duplicate_emails() {
        let registry = RegistryFile {
            active_account_key: Some("first-key".to_string()),
            auto_switch: sample_auto_switch(),
            api: ApiConfig::default(),
            accounts: vec![
                account_record("first-key", "same@example.com", "", None, None, None),
                account_record("second-key", "same@example.com", "", None, None, None),
            ],
        };
        let status = sample_status_with_active_key(Some("same@example.com"), Some("second-key"));

        let accounts = build_account_views(&registry, &status, &HashMap::new());
        assert!(accounts
            .iter()
            .any(|account| account.key == "second-key" && account.is_active));
        assert!(accounts
            .iter()
            .any(|account| account.key == "first-key" && !account.is_active));
    }

    #[test]
    fn mutation_lock_rejects_when_login_running() {
        let state = LoginState::default();
        {
            let mut job = state.inner.lock().expect("login state poisoned");
            job.running = true;
        }

        let err = ensure_mutations_unlocked_login_state(&state).unwrap_err();
        assert!(err.contains("login flow is running"));
    }

    #[test]
    fn duplicate_display_labels_gain_stable_suffixes() {
        let registry = RegistryFile {
            active_account_key: None,
            auto_switch: sample_auto_switch(),
            api: ApiConfig::default(),
            accounts: vec![
                account_record("first-key", "same@example.com", "", None, None, None),
                account_record("second-key", "same@example.com", "", None, None, None),
            ],
        };

        let labels = build_display_labels(&registry);
        let first = labels.get("first-key").expect("missing first label");
        let second = labels.get("second-key").expect("missing second label");
        assert_ne!(first, second);
        assert!(first.starts_with("same@example.com · …"));
        assert!(second.starts_with("same@example.com · …"));
    }

    #[test]
    fn saved_override_blocks_fallback_when_invalid() {
        let resolved = resolve_cli_runtime_from_sources(
            Some(Ok(PathBuf::from("/broken/codex-auth"))),
            Vec::new(),
            None,
            vec![PathBuf::from("/path/codex-auth")],
            vec![PathBuf::from("/standard/codex-auth")],
            |path| {
                if path == Path::new("/path/codex-auth") {
                    Ok(())
                } else {
                    Err("broken override".to_string())
                }
            },
            Some("/broken/codex-auth".to_string()),
        );

        assert!(!resolved.view.available);
        assert_eq!(
            resolved.view.resolution_source.as_deref(),
            Some("saved-override")
        );
        assert!(resolved.binary_path.is_none());
        assert_eq!(resolved.view.error.as_deref(), Some("broken override"));
    }

    #[test]
    fn runtime_resolution_prefers_env_before_path_and_standard() {
        let resolved = resolve_cli_runtime_from_sources(
            None,
            Vec::new(),
            Some(Ok(PathBuf::from("/env/codex-auth"))),
            vec![PathBuf::from("/path/codex-auth")],
            vec![PathBuf::from("/standard/codex-auth")],
            |path| {
                if path == Path::new("/env/codex-auth") {
                    Ok(())
                } else {
                    Err("unexpected".to_string())
                }
            },
            None,
        );

        assert!(resolved.view.available);
        assert_eq!(resolved.view.resolution_source.as_deref(), Some("env"));
        assert_eq!(
            resolved.binary_path.as_deref(),
            Some(Path::new("/env/codex-auth"))
        );
    }

    #[test]
    fn runtime_resolution_prefers_bundled_before_env_path_and_standard() {
        let temp_root =
            std::env::temp_dir().join(format!("codex-auth-desktop-bundled-{}", std::process::id()));
        let _ = fs::create_dir_all(&temp_root);
        let bundled_path = temp_root.join("codex-auth");
        fs::write(&bundled_path, "placeholder").expect("failed to create bundled test file");

        let resolved = resolve_cli_runtime_from_sources(
            None,
            vec![bundled_path.clone()],
            Some(Ok(PathBuf::from("/env/codex-auth"))),
            vec![PathBuf::from("/path/codex-auth")],
            vec![PathBuf::from("/standard/codex-auth")],
            |path| {
                if path == bundled_path.as_path() {
                    Ok(())
                } else {
                    Err("unexpected".to_string())
                }
            },
            None,
        );

        assert!(resolved.view.available);
        assert_eq!(resolved.view.resolution_source.as_deref(), Some("bundled"));
        assert_eq!(
            resolved.binary_path.as_deref(),
            Some(bundled_path.as_path())
        );
        let _ = fs::remove_file(&bundled_path);
        let _ = fs::remove_dir_all(&temp_root);
    }

    #[test]
    fn invalid_saved_override_still_blocks_valid_bundled_candidate() {
        let temp_root = std::env::temp_dir().join(format!(
            "codex-auth-desktop-bundled-blocked-{}",
            std::process::id()
        ));
        let _ = fs::create_dir_all(&temp_root);
        let bundled_path = temp_root.join("codex-auth");
        fs::write(&bundled_path, "placeholder").expect("failed to create bundled test file");

        let resolved = resolve_cli_runtime_from_sources(
            Some(Ok(PathBuf::from("/broken/codex-auth"))),
            vec![bundled_path.clone()],
            None,
            vec![PathBuf::from("/path/codex-auth")],
            vec![PathBuf::from("/standard/codex-auth")],
            |path| {
                if path == Path::new("/broken/codex-auth") {
                    Err("broken override".to_string())
                } else if path == bundled_path.as_path() {
                    Ok(())
                } else {
                    Err("unexpected".to_string())
                }
            },
            Some("/broken/codex-auth".to_string()),
        );

        assert!(!resolved.view.available);
        assert_eq!(
            resolved.view.resolution_source.as_deref(),
            Some("saved-override")
        );
        assert!(resolved.binary_path.is_none());
        assert_eq!(resolved.view.error.as_deref(), Some("broken override"));
        let _ = fs::remove_file(&bundled_path);
        let _ = fs::remove_dir_all(&temp_root);
    }

    #[test]
    fn invalid_bundled_binary_falls_back_to_env() {
        let temp_root = std::env::temp_dir().join(format!(
            "codex-auth-desktop-invalid-bundled-{}",
            std::process::id()
        ));
        let _ = fs::create_dir_all(&temp_root);
        let bundled_path = temp_root.join("codex-auth");
        fs::write(&bundled_path, "placeholder").expect("failed to create bundled test file");

        let resolved = resolve_cli_runtime_from_sources(
            None,
            vec![bundled_path.clone()],
            Some(Ok(PathBuf::from("/env/codex-auth"))),
            vec![PathBuf::from("/path/codex-auth")],
            vec![PathBuf::from("/standard/codex-auth")],
            |path| {
                if path == bundled_path.as_path() {
                    Err("bundled binary is not executable".to_string())
                } else if path == Path::new("/env/codex-auth") {
                    Ok(())
                } else {
                    Err("unexpected".to_string())
                }
            },
            None,
        );

        assert!(resolved.view.available);
        assert_eq!(resolved.view.resolution_source.as_deref(), Some("env"));
        assert_eq!(
            resolved.binary_path.as_deref(),
            Some(Path::new("/env/codex-auth"))
        );
        assert_eq!(resolved.warnings.len(), 1);
        assert!(resolved.warnings[0].contains("Bundled codex-auth"));
        let _ = fs::remove_file(&bundled_path);
        let _ = fs::remove_dir_all(&temp_root);
    }

    #[test]
    fn linux_wayland_prefers_x11_when_display_is_available() {
        let backend =
            preferred_linux_gdk_backend(Some("wayland"), Some("wayland-0"), Some(":0"), None);

        #[cfg(target_os = "linux")]
        assert_eq!(backend, Some("x11"));

        #[cfg(not(target_os = "linux"))]
        assert_eq!(backend, None);
    }

    #[test]
    fn explicit_gdk_backend_is_respected() {
        let backend = preferred_linux_gdk_backend(
            Some("wayland"),
            Some("wayland-0"),
            Some(":0"),
            Some("wayland"),
        );
        assert_eq!(backend, None);
    }

    #[test]
    fn linux_webkit_safety_env_targets_nvidia_only() {
        #[cfg(target_os = "linux")]
        assert_eq!(
            should_apply_linux_webkit_safety_env(),
            Path::new("/proc/driver/nvidia/version").exists()
        );

        #[cfg(not(target_os = "linux"))]
        assert!(!should_apply_linux_webkit_safety_env());
    }
}
