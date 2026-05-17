const std = @import("std");
const account_api = @import("account_api.zig");
const account_name_refresh = @import("account_name_refresh.zig");
const auth = @import("auth.zig");
const builtin = @import("builtin");
const c_time = @cImport({
    @cInclude("time.h");
});
const cli = @import("cli.zig");
const io_util = @import("io_util.zig");
const registry = @import("registry.zig");
const sessions = @import("sessions.zig");
const usage_api = @import("usage_api.zig");
const version = @import("version.zig");

const linux_service_name = "codex-auth-autoswitch.service";
const linux_timer_name = "codex-auth-autoswitch.timer";
const mac_label = "com.loongphy.codex-auth.auto";
const windows_task_name = "CodexAuthAutoSwitch";
const windows_helper_name = "codex-auth-auto.exe";
const windows_task_trigger_kind = "LogonTrigger";
const windows_task_restart_count = "999";
const windows_task_restart_interval_xml = "PT1M";
const windows_task_execution_time_limit_xml = "PT0S";
const lock_file_name = "auto-switch.lock";
const switch_lock_file_name = "switch-coordinator.lock";
const watch_poll_interval_ns = 1 * std.time.ns_per_s;
const api_refresh_interval_ns = 60 * std.time.ns_per_s;
const free_plan_realtime_guard_5h_percent: i64 = 35;
const failover_queue_dir_name = "failover-events";
const failover_pending_dir_name = "pending";
const failover_processing_dir_name = "processing";
const failover_done_dir_name = "done";
pub const RuntimeState = enum { running, stopped, unknown };
pub const ActiveAuthState = enum { ready, missing, malformed, untracked, api_key };
pub const PinState = enum { none, ready, missing_snapshot, out_of_sync, low, exhausted };

pub const Status = struct {
    enabled: bool,
    selection_mode: registry.AutoSwitchMode = .reactive,
    runtime: RuntimeState,
    threshold_5h_percent: u8,
    threshold_weekly_percent: u8,
    api_usage_enabled: bool,
    api_account_enabled: bool,
    active_auth: ActiveAuthState = .missing,
    active_account_label: ?[]u8 = null,
    active_account_key: ?[]u8 = null,
    registry_active_label: ?[]u8 = null,
    registry_active_out_of_sync: bool = false,
    pinned_account_label: ?[]u8 = null,
    pin_state: ?PinState = null,
    failover_state: ?registry.FailoverState = null,
    blocked_account_label: ?[]u8 = null,
    blocked_until_ms: ?i64 = null,
    known_snapshots: usize = 0,
    total_accounts: usize = 0,
    eligible_candidates: usize = 0,

    pub fn deinit(self: *Status, allocator: std.mem.Allocator) void {
        if (self.active_account_label) |label| allocator.free(label);
        if (self.active_account_key) |key| allocator.free(key);
        if (self.registry_active_label) |label| allocator.free(label);
        if (self.pinned_account_label) |label| allocator.free(label);
        if (self.blocked_account_label) |label| allocator.free(label);
        self.active_account_label = null;
        self.active_account_key = null;
        self.registry_active_label = null;
        self.pinned_account_label = null;
        self.blocked_account_label = null;
        self.registry_active_out_of_sync = false;
        self.pin_state = null;
        self.failover_state = null;
        self.blocked_until_ms = null;
    }
};

const service_version_env_name = "CODEX_AUTH_VERSION";

pub const AutoSwitchAttempt = struct {
    refreshed_candidates: bool,
    state_changed: bool = false,
    switched: bool,
};

const CandidateScore = struct {
    effective_remaining: i64,
    weekly_remaining: i64,
    effective_resets_at: i64,
    last_usage_at: i64,
    last_used_at: i64,
    refresh_only: bool,
    alias: []const u8,
    email: []const u8,
    account_key: []const u8,
};

const candidate_upkeep_refresh_limit: usize = 1;
const candidate_switch_validation_limit: usize = 3;
const candidate_parallel_fetch_limit: usize = 2;
const account_name_parallel_fetch_limit: usize = 2;
const worker_fetch_allocator = std.heap.c_allocator;

const CandidateEntry = struct {
    account_key: []const u8,
    score: CandidateScore,
};

const CandidateIndex = struct {
    heap: std.ArrayListUnmanaged(CandidateEntry) = .empty,
    positions: std.StringHashMapUnmanaged(usize) = .empty,
    next_score_change_at: ?i64 = null,

    fn deinit(self: *CandidateIndex, allocator: std.mem.Allocator) void {
        self.heap.deinit(allocator);
        self.positions.deinit(allocator);
        self.* = .{};
    }

    fn rebuild(self: *CandidateIndex, allocator: std.mem.Allocator, reg: *const registry.Registry, now: i64) !void {
        self.deinit(allocator);
        const active = reg.active_account_key;
        for (reg.accounts.items) |*rec| {
            if (active) |account_key| {
                if (std.mem.eql(u8, rec.account_key, account_key)) continue;
            }
            if (accountIsBlocked(reg, rec.account_key, now)) continue;
            const score = daemonCandidateScore(rec, reg, now) orelse continue;
            try self.insert(allocator, .{
                .account_key = rec.account_key,
                .score = score,
            });
        }
        self.refreshNextScoreChangeAt(reg, now);
    }

    fn rebuildIfScoreExpired(
        self: *CandidateIndex,
        allocator: std.mem.Allocator,
        reg: *const registry.Registry,
        now: i64,
    ) !void {
        if (self.next_score_change_at) |deadline| {
            if (deadline <= now) {
                try self.rebuild(allocator, reg, now);
            }
        }
    }

    fn best(self: *const CandidateIndex) ?CandidateEntry {
        if (self.heap.items.len == 0) return null;
        return self.heap.items[0];
    }

    fn insert(self: *CandidateIndex, allocator: std.mem.Allocator, entry: CandidateEntry) !void {
        try self.heap.append(allocator, entry);
        const idx = self.heap.items.len - 1;
        try self.positions.put(allocator, entry.account_key, idx);
        _ = self.siftUp(idx);
    }

    fn remove(self: *CandidateIndex, account_key: []const u8) void {
        const idx = self.positions.get(account_key) orelse return;
        _ = self.positions.remove(account_key);
        const last_idx = self.heap.items.len - 1;
        if (idx != last_idx) {
            self.heap.items[idx] = self.heap.items[last_idx];
            if (self.positions.getPtr(self.heap.items[idx].account_key)) |ptr| {
                ptr.* = idx;
            }
        }
        self.heap.items.len = last_idx;
        if (idx < self.heap.items.len) {
            self.restore(idx);
        }
    }

    fn upsertFromRegistry(self: *CandidateIndex, allocator: std.mem.Allocator, reg: *registry.Registry, account_key: []const u8, now: i64) !void {
        if (reg.active_account_key) |active| {
            if (std.mem.eql(u8, active, account_key)) {
                self.remove(account_key);
                self.refreshNextScoreChangeAt(reg, now);
                return;
            }
        }
        if (accountIsBlocked(reg, account_key, now)) {
            self.remove(account_key);
            self.refreshNextScoreChangeAt(reg, now);
            return;
        }

        const idx = registry.findAccountIndexByAccountKey(reg, account_key) orelse {
            self.remove(account_key);
            self.refreshNextScoreChangeAt(reg, now);
            return;
        };
        const score = daemonCandidateScore(&reg.accounts.items[idx], reg, now) orelse {
            self.remove(account_key);
            self.refreshNextScoreChangeAt(reg, now);
            return;
        };
        const entry: CandidateEntry = .{
            .account_key = reg.accounts.items[idx].account_key,
            .score = score,
        };
        if (self.positions.get(entry.account_key)) |heap_idx| {
            self.heap.items[heap_idx] = entry;
            self.restore(heap_idx);
            self.refreshNextScoreChangeAt(reg, now);
            return;
        }
        try self.insert(allocator, entry);
        self.refreshNextScoreChangeAt(reg, now);
    }

    fn handleActiveSwitch(
        self: *CandidateIndex,
        allocator: std.mem.Allocator,
        reg: *registry.Registry,
        old_active_account_key: []const u8,
        new_active_account_key: []const u8,
        now: i64,
    ) !void {
        self.remove(new_active_account_key);
        try self.upsertFromRegistry(allocator, reg, old_active_account_key, now);
    }

    fn refreshNextScoreChangeAt(self: *CandidateIndex, reg: *const registry.Registry, now: i64) void {
        const active = reg.active_account_key;
        var next_score_change_at: ?i64 = null;
        for (reg.accounts.items) |*rec| {
            if (active) |account_key| {
                if (std.mem.eql(u8, rec.account_key, account_key)) continue;
            }
            if (accountIsBlocked(reg, rec.account_key, now)) continue;
            next_score_change_at = earlierFutureTimestamp(
                next_score_change_at,
                candidateScoreChangeAt(rec, now),
                now,
            );
        }
        self.next_score_change_at = next_score_change_at;
    }

    fn orderedKeys(self: *const CandidateIndex, allocator: std.mem.Allocator) !std.ArrayList([]const u8) {
        var ordered = try std.ArrayList([]const u8).initCapacity(allocator, self.heap.items.len);
        for (self.heap.items) |entry| {
            try ordered.append(allocator, entry.account_key);
        }
        std.sort.block([]const u8, ordered.items, self, candidateEntryLessThan);
        return ordered;
    }

    fn candidateEntryLessThan(self: *const CandidateIndex, lhs: []const u8, rhs: []const u8) bool {
        const left_idx = self.positions.get(lhs) orelse return false;
        const right_idx = self.positions.get(rhs) orelse return false;
        const left = self.heap.items[left_idx].score;
        const right = self.heap.items[right_idx].score;
        return candidateRefreshBetter(left, right);
    }

    fn restore(self: *CandidateIndex, idx: usize) void {
        if (!self.siftUp(idx)) {
            self.siftDown(idx);
        }
    }

    fn siftUp(self: *CandidateIndex, start_idx: usize) bool {
        var idx = start_idx;
        var moved = false;
        while (idx > 0) {
            const parent_idx = (idx - 1) / 2;
            if (!candidateRefreshBetter(self.heap.items[idx].score, self.heap.items[parent_idx].score)) break;
            self.swap(idx, parent_idx);
            idx = parent_idx;
            moved = true;
        }
        return moved;
    }

    fn siftDown(self: *CandidateIndex, start_idx: usize) void {
        var idx = start_idx;
        while (true) {
            const left = idx * 2 + 1;
            if (left >= self.heap.items.len) break;
            const right = left + 1;
            var best_idx = left;
            if (right < self.heap.items.len and candidateRefreshBetter(self.heap.items[right].score, self.heap.items[left].score)) {
                best_idx = right;
            }
            if (!candidateRefreshBetter(self.heap.items[best_idx].score, self.heap.items[idx].score)) break;
            self.swap(idx, best_idx);
            idx = best_idx;
        }
    }

    fn swap(self: *CandidateIndex, a: usize, b: usize) void {
        if (a == b) return;
        std.mem.swap(CandidateEntry, &self.heap.items[a], &self.heap.items[b]);
        if (self.positions.getPtr(self.heap.items[a].account_key)) |ptr| ptr.* = a;
        if (self.positions.getPtr(self.heap.items[b].account_key)) |ptr| ptr.* = b;
    }
};

pub const DaemonRefreshState = struct {
    last_api_refresh_at_ns: i128 = 0,
    last_api_refresh_account_key: ?[]u8 = null,
    last_account_name_refresh_at_ns: i128 = 0,
    last_account_name_refresh_account_key: ?[]u8 = null,
    pending_bad_account_key: ?[]u8 = null,
    pending_bad_rollout: ?registry.RolloutSignature = null,
    current_reg: ?registry.Registry = null,
    registry_mtime_ns: i128 = 0,
    auth_mtime_ns: i128 = 0,
    candidate_index: CandidateIndex = .{},
    candidate_check_times: std.StringHashMapUnmanaged(i128) = .empty,
    candidate_rejections: std.StringHashMapUnmanaged(bool) = .empty,
    rollout_scan_cache: sessions.RolloutScanCache = .{},

    pub fn deinit(self: *DaemonRefreshState, allocator: std.mem.Allocator) void {
        self.clearApiRefresh(allocator);
        self.clearAccountNameRefresh(allocator);
        self.clearPending(allocator);
        if (self.current_reg) |*reg| {
            self.candidate_index.deinit(allocator);
            self.candidate_check_times.deinit(allocator);
            self.candidate_rejections.deinit(allocator);
            reg.deinit(allocator);
            self.current_reg = null;
        } else {
            self.candidate_index.deinit(allocator);
            self.candidate_check_times.deinit(allocator);
            self.candidate_rejections.deinit(allocator);
        }
        self.rollout_scan_cache.deinit(allocator);
    }

    fn clearApiRefresh(self: *DaemonRefreshState, allocator: std.mem.Allocator) void {
        if (self.last_api_refresh_account_key) |account_key| {
            allocator.free(account_key);
        }
        self.last_api_refresh_account_key = null;
        self.last_api_refresh_at_ns = 0;
    }

    fn clearAccountNameRefresh(self: *DaemonRefreshState, allocator: std.mem.Allocator) void {
        if (self.last_account_name_refresh_account_key) |account_key| {
            allocator.free(account_key);
        }
        self.last_account_name_refresh_account_key = null;
        self.last_account_name_refresh_at_ns = 0;
    }

    fn clearPending(self: *DaemonRefreshState, allocator: std.mem.Allocator) void {
        if (self.pending_bad_account_key) |account_key| {
            allocator.free(account_key);
        }
        if (self.pending_bad_rollout) |*signature| {
            registry.freeRolloutSignature(allocator, signature);
        }
        self.pending_bad_account_key = null;
        self.pending_bad_rollout = null;
    }

    fn clearPendingIfAccountChanged(
        self: *DaemonRefreshState,
        allocator: std.mem.Allocator,
        active_account_key: ?[]const u8,
    ) void {
        if (self.pending_bad_account_key == null) return;
        if (active_account_key) |account_key| {
            if (std.mem.eql(u8, self.pending_bad_account_key.?, account_key)) return;
        }
        self.clearPending(allocator);
    }

    fn pendingMatches(self: *const DaemonRefreshState, account_key: []const u8, signature: registry.RolloutSignature) bool {
        if (self.pending_bad_account_key == null or self.pending_bad_rollout == null) return false;
        return std.mem.eql(u8, self.pending_bad_account_key.?, account_key) and
            registry.rolloutSignaturesEqual(self.pending_bad_rollout, signature);
    }

    fn setPending(
        self: *DaemonRefreshState,
        allocator: std.mem.Allocator,
        account_key: []const u8,
        signature: registry.RolloutSignature,
    ) !void {
        if (self.pendingMatches(account_key, signature)) return;
        self.clearPending(allocator);
        self.pending_bad_account_key = try allocator.dupe(u8, account_key);
        errdefer {
            allocator.free(self.pending_bad_account_key.?);
            self.pending_bad_account_key = null;
        }
        self.pending_bad_rollout = try registry.cloneRolloutSignature(allocator, signature);
    }

    fn resetApiCooldownIfAccountChanged(
        self: *DaemonRefreshState,
        allocator: std.mem.Allocator,
        active_account_key: []const u8,
    ) !void {
        if (self.last_api_refresh_account_key) |account_key| {
            if (std.mem.eql(u8, account_key, active_account_key)) return;
        }
        self.clearApiRefresh(allocator);
        self.last_api_refresh_account_key = try allocator.dupe(u8, active_account_key);
    }

    fn resetAccountNameCooldownIfAccountChanged(
        self: *DaemonRefreshState,
        allocator: std.mem.Allocator,
        active_account_key: []const u8,
    ) !void {
        if (self.last_account_name_refresh_account_key) |account_key| {
            if (std.mem.eql(u8, account_key, active_account_key)) return;
        }
        self.clearAccountNameRefresh(allocator);
        self.last_account_name_refresh_account_key = try allocator.dupe(u8, active_account_key);
    }

    fn currentRegistry(self: *DaemonRefreshState) *registry.Registry {
        return &self.current_reg.?;
    }

    fn ensureRegistryLoaded(self: *DaemonRefreshState, allocator: std.mem.Allocator, codex_home: []const u8) !*registry.Registry {
        if (self.current_reg == null) {
            try self.reloadRegistryState(allocator, codex_home);
            // Force the first daemon cycle to sync auth.json into accounts/ snapshots
            // before grouped account-name refresh looks for stored auth contexts.
            self.auth_mtime_ns = -1;
        } else {
            try self.reloadRegistryStateIfChanged(allocator, codex_home);
        }
        return self.currentRegistry();
    }

    fn reloadRegistryStateIfChanged(self: *DaemonRefreshState, allocator: std.mem.Allocator, codex_home: []const u8) !void {
        const registry_path = try registry.registryPath(allocator, codex_home);
        defer allocator.free(registry_path);
        const current_mtime = (try fileMtimeNsIfExists(registry_path)) orelse 0;
        if (self.current_reg == null or current_mtime != self.registry_mtime_ns) {
            try self.reloadRegistryState(allocator, codex_home);
        }
    }

    fn reloadRegistryState(self: *DaemonRefreshState, allocator: std.mem.Allocator, codex_home: []const u8) !void {
        var loaded = try registry.loadRegistry(allocator, codex_home);
        errdefer loaded.deinit(allocator);

        self.candidate_index.deinit(allocator);
        self.candidate_check_times.deinit(allocator);
        self.candidate_check_times = .empty;
        self.candidate_rejections.deinit(allocator);
        self.candidate_rejections = .empty;
        if (self.current_reg) |*reg| {
            reg.deinit(allocator);
        }
        self.current_reg = loaded;
        try self.candidate_index.rebuild(allocator, &self.current_reg.?, std.time.timestamp());
        try self.refreshTrackedFileMtims(allocator, codex_home);
    }

    fn rebuildCandidateState(self: *DaemonRefreshState, allocator: std.mem.Allocator) !void {
        if (self.current_reg == null) return;
        self.candidate_index.deinit(allocator);
        self.candidate_check_times.deinit(allocator);
        self.candidate_check_times = .empty;
        self.candidate_rejections.deinit(allocator);
        self.candidate_rejections = .empty;
        try self.candidate_index.rebuild(allocator, &self.current_reg.?, std.time.timestamp());
    }

    fn refreshTrackedFileMtims(self: *DaemonRefreshState, allocator: std.mem.Allocator, codex_home: []const u8) !void {
        const registry_path = try registry.registryPath(allocator, codex_home);
        defer allocator.free(registry_path);
        self.registry_mtime_ns = (try fileMtimeNsIfExists(registry_path)) orelse 0;

        const auth_path = try registry.activeAuthPath(allocator, codex_home);
        defer allocator.free(auth_path);
        self.auth_mtime_ns = (try fileMtimeNsIfExists(auth_path)) orelse 0;
    }

    fn syncActiveAuthIfChanged(self: *DaemonRefreshState, allocator: std.mem.Allocator, codex_home: []const u8) !bool {
        const auth_path = try registry.activeAuthPath(allocator, codex_home);
        defer allocator.free(auth_path);
        const current_auth_mtime = (try fileMtimeNsIfExists(auth_path)) orelse 0;
        if (self.current_reg != null and current_auth_mtime == self.auth_mtime_ns) return false;
        self.auth_mtime_ns = current_auth_mtime;
        if (self.current_reg == null) return false;
        if (try registry.syncActiveAccountFromAuth(allocator, codex_home, &self.current_reg.?)) {
            try self.rebuildCandidateState(allocator);
            return true;
        }
        return false;
    }

    fn markCandidateChecked(self: *DaemonRefreshState, allocator: std.mem.Allocator, account_key: []const u8, now_ns: i128) !void {
        try self.candidate_check_times.put(allocator, account_key, now_ns);
    }

    fn candidateCheckedAt(self: *const DaemonRefreshState, account_key: []const u8) ?i128 {
        return self.candidate_check_times.get(account_key);
    }

    fn clearCandidateChecked(self: *DaemonRefreshState, account_key: []const u8) void {
        _ = self.candidate_check_times.remove(account_key);
    }

    fn markCandidateRejected(self: *DaemonRefreshState, allocator: std.mem.Allocator, account_key: []const u8) !void {
        try self.candidate_rejections.put(allocator, account_key, true);
    }

    fn clearCandidateRejected(self: *DaemonRefreshState, account_key: []const u8) void {
        _ = self.candidate_rejections.remove(account_key);
    }

    fn candidateIsRejected(self: *DaemonRefreshState, account_key: []const u8, now_ns: i128) bool {
        if (!self.candidate_rejections.contains(account_key)) return false;
        if (self.candidateIsStale(account_key, now_ns)) {
            self.clearCandidateRejected(account_key);
            return false;
        }
        return true;
    }

    fn candidateIsStale(self: *const DaemonRefreshState, account_key: []const u8, now_ns: i128) bool {
        const checked_at = self.candidateCheckedAt(account_key) orelse return true;
        return (now_ns - checked_at) >= api_refresh_interval_ns;
    }
};

const DaemonLock = struct {
    file: std.fs.File,

    fn acquire(allocator: std.mem.Allocator, codex_home: []const u8) !?DaemonLock {
        const path = try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "accounts", lock_file_name });
        defer allocator.free(path);
        var file = try std.fs.cwd().createFile(path, .{ .read = true, .truncate = false });
        errdefer file.close();
        if (!(try tryExclusiveLock(file))) {
            file.close();
            return null;
        }
        return .{ .file = file };
    }

    fn release(self: *DaemonLock) void {
        self.file.unlock();
        self.file.close();
    }
};

pub const SwitchCoordinatorLock = struct {
    file: std.fs.File,

    pub fn acquire(allocator: std.mem.Allocator, codex_home: []const u8) !?SwitchCoordinatorLock {
        const path = try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "accounts", switch_lock_file_name });
        defer allocator.free(path);
        var file = try std.fs.cwd().createFile(path, .{ .read = true, .truncate = false });
        errdefer file.close();
        if (!(try tryExclusiveLock(file))) {
            file.close();
            return null;
        }
        return .{ .file = file };
    }

    pub fn release(self: *SwitchCoordinatorLock) void {
        self.file.unlock();
        self.file.close();
    }
};

fn tryExclusiveLock(file: std.fs.File) !bool {
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const range_off: windows.LARGE_INTEGER = 0;
        const range_len: windows.LARGE_INTEGER = 1;
        var io_status_block: windows.IO_STATUS_BLOCK = undefined;
        windows.LockFile(
            file.handle,
            null,
            null,
            null,
            &io_status_block,
            &range_off,
            &range_len,
            null,
            windows.TRUE,
            windows.TRUE,
        ) catch |err| switch (err) {
            error.WouldBlock => return false,
            else => |e| return e,
        };
        return true;
    }

    return try file.tryLock(.exclusive);
}

pub fn helpStateLabel(enabled: bool) []const u8 {
    return if (enabled) "ON" else "OFF";
}

fn colorEnabled() bool {
    return std.fs.File.stdout().isTty();
}

pub fn printStatus(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    var status = try getStatus(allocator, codex_home);
    defer status.deinit(allocator);
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    try writeStatusWithColor(stdout.out(), status, colorEnabled());
}

pub fn getStatus(allocator: std.mem.Allocator, codex_home: []const u8) !Status {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    _ = try normalizeBlockedAccountState(allocator, &reg, std.time.timestamp());
    var status: Status = .{
        .enabled = reg.auto_switch.enabled,
        .selection_mode = reg.auto_switch.mode,
        .runtime = queryRuntimeState(allocator),
        .threshold_5h_percent = reg.auto_switch.threshold_5h_percent,
        .threshold_weekly_percent = reg.auto_switch.threshold_weekly_percent,
        .api_usage_enabled = reg.api.usage,
        .api_account_enabled = reg.api.account,
    };
    errdefer status.deinit(allocator);
    const auth_active_key = try populateActiveAuthStatus(allocator, codex_home, &reg, &status);
    const active_key = auth_active_key orelse reg.active_account_key;
    const now = std.time.timestamp();
    if (reg.auto_switch.mode == .pinned) {
        try populatePinnedStatus(allocator, &reg, &status, auth_active_key, now);
    } else if (reg.auto_switch.mode == .failover) {
        try populateFailoverStatus(allocator, &reg, &status, now);
    }
    var known_snapshots: usize = 0;
    var eligible_candidates: usize = 0;
    for (reg.accounts.items) |*rec| {
        if (registry.accountSnapshotFreshness(rec, now) == .fresh) {
            known_snapshots += 1;
        }
        if (active_key) |excluded| {
            if (std.mem.eql(u8, rec.account_key, excluded)) continue;
        }
        if (accountIsBlocked(&reg, rec.account_key, now)) continue;
        if (candidateScore(rec, reg.auto_switch, now) != null) {
            eligible_candidates += 1;
        }
    }
    status.known_snapshots = known_snapshots;
    status.total_accounts = reg.accounts.items.len;
    status.eligible_candidates = eligible_candidates;
    return status;
}

pub fn writeStatus(out: *std.Io.Writer, status: Status) !void {
    try writeStatusWithColor(out, status, false);
}

fn writeStatusWithColor(out: *std.Io.Writer, status: Status, use_color: bool) !void {
    _ = use_color;
    try out.writeAll("auto-switch: ");
    try out.writeAll(helpStateLabel(status.enabled));
    try out.writeAll("\n");

    try out.writeAll("service: ");
    try out.writeAll(@tagName(status.runtime));
    try out.writeAll("\n");

    try out.writeAll("thresholds: ");
    try out.print(
        "5h<{d}%, weekly<{d}%",
        .{ status.threshold_5h_percent, status.threshold_weekly_percent },
    );
    try out.writeAll("\n");

    try out.writeAll("usage: ");
    try out.writeAll(if (status.api_usage_enabled) "api" else "local");
    try out.writeAll("\n");

    try out.writeAll("account API: ");
    try out.writeAll(if (status.api_account_enabled) "api" else "disabled");
    try out.writeAll("\n");

    try out.writeAll("active auth: ");
    try out.writeAll(activeAuthStateLabel(status.active_auth));
    try out.writeAll("\n");

    try out.writeAll("active account: ");
    try out.writeAll(status.active_account_label orelse "none");
    try out.writeAll("\n");

    try out.writeAll("active account key: ");
    try out.writeAll(status.active_account_key orelse "none");
    try out.writeAll("\n");

    if (status.registry_active_out_of_sync) {
        try out.writeAll("registry active: ");
        try out.writeAll(status.registry_active_label orelse "none");
        try out.writeAll(" (out of sync)\n");
    }

    try out.writeAll("selection: ");
    try out.writeAll(selectionLabel(status.selection_mode));
    try out.writeAll("\n");

    if (status.selection_mode == .pinned) {
        try out.writeAll("pinned account: ");
        try out.writeAll(status.pinned_account_label orelse "none");
        try out.writeAll("\n");

        try out.writeAll("pin state: ");
        try out.writeAll(pinStateLabel(status.pin_state orelse .none));
        try out.writeAll("\n");
    }
    if (status.selection_mode == .failover) {
        try out.writeAll("failover state: ");
        try out.writeAll(failoverStateLabel(status.failover_state orelse .idle));
        try out.writeAll("\n");

        try out.writeAll("blocked account: ");
        try out.writeAll(status.blocked_account_label orelse "none");
        try out.writeAll("\n");

        try out.writeAll("blocked until: ");
        if (status.blocked_account_label == null) {
            try out.writeAll("none");
        } else if (status.blocked_until_ms) |blocked_until_ms| {
            var blocked_until_buf: [19]u8 = undefined;
            try out.writeAll(localDateTimeLabel(&blocked_until_buf, blocked_until_ms));
        } else {
            try out.writeAll("unknown");
        }
        try out.writeAll("\n");
    }

    try out.writeAll("usage source mode: ");
    try out.writeAll(if (status.api_usage_enabled) "api" else "local-only");
    try out.writeAll("\n");

    try out.print(
        "known snapshots: {d}/{d}\n",
        .{ status.known_snapshots, status.total_accounts },
    );
    try out.print("eligible candidates: {d}\n", .{status.eligible_candidates});

    try out.flush();
}

fn activeAuthStateLabel(state: ActiveAuthState) []const u8 {
    return switch (state) {
        .ready => "ready",
        .missing => "missing",
        .malformed => "malformed",
        .untracked => "untracked",
        .api_key => "api-key",
    };
}

fn selectionLabel(mode: registry.AutoSwitchMode) []const u8 {
    return switch (mode) {
        .reactive => "reactive-best-snapshot",
        .proactive => "proactive-best-snapshot",
        .pinned => "pinned-best-known",
        .failover => "failover-on-rate-limit",
    };
}

fn pinStateLabel(state: PinState) []const u8 {
    return switch (state) {
        .none => "none",
        .ready => "ready",
        .missing_snapshot => "missing-snapshot",
        .out_of_sync => "out-of-sync",
        .low => "low",
        .exhausted => "exhausted",
    };
}

fn failoverStateLabel(state: registry.FailoverState) []const u8 {
    return switch (state) {
        .idle => "idle",
        .processing => "processing",
        .switched => "switched",
        .no_target => "no-target",
        .stale_event => "stale-event",
        .@"error" => "error",
    };
}

fn populateActiveAuthStatus(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *const registry.Registry,
    status: *Status,
) !?[]const u8 {
    const auth_path = try registry.activeAuthPath(allocator, codex_home);
    defer allocator.free(auth_path);

    var info = auth.parseAuthInfo(allocator, auth_path) catch |err| switch (err) {
        error.FileNotFound => {
            status.active_auth = .missing;
            try maybeSetRegistryActiveOutOfSync(allocator, reg, status);
            return null;
        },
        error.OutOfMemory => return err,
        else => {
            status.active_auth = .malformed;
            try maybeSetRegistryActiveOutOfSync(allocator, reg, status);
            return null;
        },
    };
    defer info.deinit(allocator);

    switch (info.auth_mode) {
        .apikey => {
            status.active_auth = .api_key;
            status.active_account_label = try allocator.dupe(u8, "api-key");
            try maybeSetRegistryActiveOutOfSync(allocator, reg, status);
            return null;
        },
        .chatgpt => {
            const email = info.email orelse {
                status.active_auth = .malformed;
                try maybeSetRegistryActiveOutOfSync(allocator, reg, status);
                return null;
            };
            const record_key = info.record_key orelse {
                status.active_auth = .malformed;
                try maybeSetRegistryActiveOutOfSync(allocator, reg, status);
                return null;
            };

            if (registry.findAccountIndexByAccountKey(@constCast(reg), record_key)) |idx| {
                status.active_auth = .ready;
                status.active_account_label = try allocator.dupe(u8, reg.accounts.items[idx].email);
                status.active_account_key = try allocator.dupe(u8, reg.accounts.items[idx].account_key);
                if (reg.active_account_key) |active_account_key| {
                    if (!std.mem.eql(u8, active_account_key, record_key)) {
                        try maybeSetRegistryActiveOutOfSync(allocator, reg, status);
                    }
                }
                return reg.accounts.items[idx].account_key;
            }

            status.active_auth = .untracked;
            status.active_account_label = try allocator.dupe(u8, email);
            try maybeSetRegistryActiveOutOfSync(allocator, reg, status);
            return null;
        },
    }
}

fn maybeSetRegistryActiveOutOfSync(
    allocator: std.mem.Allocator,
    reg: *const registry.Registry,
    status: *Status,
) !void {
    const active_account_key = reg.active_account_key orelse return;
    status.registry_active_out_of_sync = true;
    status.registry_active_label = try registryAccountLabelAlloc(allocator, reg, active_account_key);
}

fn populatePinnedStatus(
    allocator: std.mem.Allocator,
    reg: *const registry.Registry,
    status: *Status,
    auth_active_key: ?[]const u8,
    now: i64,
) !void {
    const pinned_key = reg.auto_switch.pinned_account_key orelse {
        status.pin_state = .none;
        return;
    };
    const pinned_idx = registry.findAccountIndexByAccountKey(@constCast(reg), pinned_key) orelse {
        status.pin_state = .none;
        return;
    };
    const rec = &reg.accounts.items[pinned_idx];
    status.pinned_account_label = try allocator.dupe(u8, rec.email);

    if (auth_active_key == null or !std.mem.eql(u8, auth_active_key.?, pinned_key)) {
        status.pin_state = .out_of_sync;
        return;
    }

    const headroom = rankedHeadroom(rec, now) orelse {
        status.pin_state = .missing_snapshot;
        return;
    };
    const resolved_5h = resolve5hCandidateWindow(rec.last_usage);
    const weekly_window = registry.resolveRateWindow(rec.last_usage, 10080, false);
    const rem_5h = registry.remainingPercentAt(resolved_5h.window, now);
    const rem_week = registry.remainingPercentAt(weekly_window, now);
    if ((rem_5h != null and rem_5h.? <= 0) or
        (rem_week != null and rem_week.? <= 0) or
        headroom.effective_remaining <= 0)
    {
        status.pin_state = .exhausted;
        return;
    }
    if (candidateScore(rec, reg.auto_switch, now) == null) {
        status.pin_state = .low;
        return;
    }
    status.pin_state = .ready;
}

fn blockedAccountStillApplies(
    reg: *const registry.Registry,
    rec: *const registry.AccountRecord,
    now: i64,
) bool {
    if (reg.auto_switch.blocked_until_ms) |blocked_until_ms| {
        return std.time.milliTimestamp() < blocked_until_ms;
    }
    if (rankedHeadroom(rec, now)) |headroom| {
        return headroom.effective_remaining <= 0;
    }
    return true;
}

fn activeBlockedAccountKey(reg: *const registry.Registry, now: i64) ?[]const u8 {
    const blocked_key = reg.auto_switch.blocked_account_key orelse return null;
    const blocked_idx = registry.findAccountIndexByAccountKey(@constCast(reg), blocked_key) orelse return null;
    const rec = &reg.accounts.items[blocked_idx];
    if (!blockedAccountStillApplies(reg, rec, now)) return null;
    return rec.account_key;
}

fn accountIsBlocked(reg: *const registry.Registry, account_key: []const u8, now: i64) bool {
    const blocked_key = activeBlockedAccountKey(reg, now) orelse return false;
    return std.mem.eql(u8, blocked_key, account_key);
}

fn normalizeBlockedAccountState(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    now: i64,
) !bool {
    if (reg.auto_switch.blocked_account_key == null) return false;
    if (activeBlockedAccountKey(reg, now) != null) return false;
    try registry.setBlockedAccount(allocator, reg, null, null);
    if (reg.auto_switch.failover_state == .processing) {
        reg.auto_switch.failover_state = .idle;
    }
    return true;
}

fn populateFailoverStatus(
    allocator: std.mem.Allocator,
    reg: *const registry.Registry,
    status: *Status,
    now: i64,
) !void {
    status.failover_state = reg.auto_switch.failover_state;
    const blocked_key = activeBlockedAccountKey(reg, now) orelse return;
    status.blocked_account_label = try registryAccountLabelAlloc(allocator, reg, blocked_key);
    status.blocked_until_ms = reg.auto_switch.blocked_until_ms;
}

fn registryAccountLabelAlloc(
    allocator: std.mem.Allocator,
    reg: *const registry.Registry,
    account_key: []const u8,
) ![]u8 {
    if (registry.findAccountIndexByAccountKey(@constCast(reg), account_key)) |idx| {
        return allocator.dupe(u8, reg.accounts.items[idx].email);
    }
    return allocator.dupe(u8, account_key);
}

pub fn writeAutoSwitchLogLine(
    out: *std.Io.Writer,
    from: *const registry.AccountRecord,
    to: *const registry.AccountRecord,
) !void {
    try out.print("[switch] {s} -> {s}\n", .{ from.email, to.email });
    try out.flush();
}

fn emitAutoSwitchLog(from: *const registry.AccountRecord, to: *const registry.AccountRecord) void {
    var stderr_buffer: [256]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&stderr_buffer);
    writeAutoSwitchLogLine(&writer.interface, from, to) catch {};
}

const DaemonLogPriority = enum {
    err,
    warning,
    notice,
    info,
    debug,
};

fn emitDaemonLog(priority: DaemonLogPriority, comptime fmt: []const u8, args: anytype) void {
    _ = priority;
    var stderr_buffer: [512]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&stderr_buffer);
    writer.interface.print(fmt ++ "\n", args) catch {};
    writer.interface.flush() catch {};
}

fn emitTaggedDaemonLog(
    priority: DaemonLogPriority,
    tag: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) void {
    _ = priority;
    var stderr_buffer: [1024]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&stderr_buffer);
    writer.interface.print("[{s}] ", .{tag}) catch {};
    writer.interface.print(fmt ++ "\n", args) catch {};
    writer.interface.flush() catch {};
}

fn percentLabel(buf: *[5]u8, value: ?i64) []const u8 {
    const percent = value orelse return "-";
    const clamped = @min(@max(percent, 0), 100);
    return std.fmt.bufPrint(buf, "{d}%", .{clamped}) catch "-";
}

fn localDateTimeLabel(buf: *[19]u8, timestamp_ms: i64) []const u8 {
    const seconds = @divTrunc(timestamp_ms, std.time.ms_per_s);
    var tm: c_time.struct_tm = undefined;
    if (!localtimeCompat(seconds, &tm)) return "-";
    const year: u32 = @intCast(tm.tm_year + 1900);
    const month: u32 = @intCast(tm.tm_mon + 1);
    const day: u32 = @intCast(tm.tm_mday);
    const hour: u32 = @intCast(tm.tm_hour);
    const minute: u32 = @intCast(tm.tm_min);
    const second: u32 = @intCast(tm.tm_sec);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        year,
        month,
        day,
        hour,
        minute,
        second,
    }) catch "-";
}

fn rolloutFileLabel(buf: *[96]u8, path: []const u8) []const u8 {
    const basename = std.fs.path.basename(path);
    return std.fmt.bufPrint(buf, "{s}", .{basename}) catch basename;
}

fn localtimeCompat(ts: i64, out_tm: *c_time.struct_tm) bool {
    if (comptime builtin.os.tag == .windows) {
        if (comptime @hasDecl(c_time, "_localtime64_s") and @hasDecl(c_time, "__time64_t")) {
            var t64 = std.math.cast(c_time.__time64_t, ts) orelse return false;
            return c_time._localtime64_s(out_tm, &t64) == 0;
        }
        return false;
    }

    var t = std.math.cast(c_time.time_t, ts) orelse return false;
    if (comptime @hasDecl(c_time, "localtime_r")) {
        return c_time.localtime_r(&t, out_tm) != null;
    }
    if (comptime @hasDecl(c_time, "localtime")) {
        const tm_ptr = c_time.localtime(&t);
        if (tm_ptr == null) return false;
        out_tm.* = tm_ptr.*;
        return true;
    }
    return false;
}

const FailoverEventKind = enum {
    usage_limit_reached,
    quota_exceeded,
    usage_not_included,
};

const FailoverEventWindow = struct {
    used_percent: f64,
    window_minutes: ?i64 = null,
    resets_at: ?i64 = null,
};

const FailoverEventCredits = struct {
    has_credits: bool,
    unlimited: bool,
    balance: ?[]u8 = null,

    fn deinit(self: *FailoverEventCredits, allocator: std.mem.Allocator) void {
        if (self.balance) |balance| allocator.free(balance);
        self.balance = null;
    }
};

const FailoverEventRateLimits = struct {
    primary: ?FailoverEventWindow = null,
    secondary: ?FailoverEventWindow = null,
    credits: ?FailoverEventCredits = null,

    fn deinit(self: *FailoverEventRateLimits, allocator: std.mem.Allocator) void {
        if (self.credits) |*credits| credits.deinit(allocator);
        self.credits = null;
    }
};

const FailoverEventFile = struct {
    version: u32 = 1,
    event_id: []u8,
    occurred_at_ms: i64,
    source: []u8,
    thread_id: []u8,
    turn_id: []u8,
    source_auth_mode: []u8,
    source_email: ?[]u8 = null,
    source_account_id: ?[]u8 = null,
    source_record_key: ?[]u8 = null,
    error_kind: FailoverEventKind,
    resets_at_ms: ?i64 = null,
    rate_limits: ?FailoverEventRateLimits = null,

    fn deinit(self: *FailoverEventFile, allocator: std.mem.Allocator) void {
        allocator.free(self.event_id);
        allocator.free(self.source);
        allocator.free(self.thread_id);
        allocator.free(self.turn_id);
        allocator.free(self.source_auth_mode);
        if (self.source_email) |value| allocator.free(value);
        if (self.source_account_id) |value| allocator.free(value);
        if (self.source_record_key) |value| allocator.free(value);
        if (self.rate_limits) |*rate_limits| rate_limits.deinit(allocator);
        self.source_email = null;
        self.source_account_id = null;
        self.source_record_key = null;
        self.rate_limits = null;
    }
};

const ClaimedFailoverEvent = struct {
    file_name: []u8,
    processing_path: []u8,
    done_path: []u8,

    fn deinit(self: *ClaimedFailoverEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.file_name);
        allocator.free(self.processing_path);
        allocator.free(self.done_path);
    }
};

fn failoverQueueBaseDirPath(allocator: std.mem.Allocator, codex_home: []const u8) ![]u8 {
    const parts = [_][]const u8{
        codex_home,
        "runtime",
        failover_queue_dir_name,
    };
    return try std.fs.path.join(allocator, &parts);
}

fn failoverQueueDirPath(allocator: std.mem.Allocator, codex_home: []const u8, subdir: []const u8) ![]u8 {
    const parts = [_][]const u8{
        codex_home,
        "runtime",
        failover_queue_dir_name,
        subdir,
    };
    return try std.fs.path.join(allocator, &parts);
}

fn failoverQueueFilePath(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    subdir: []const u8,
    file_name: []const u8,
) ![]u8 {
    const parts = [_][]const u8{
        codex_home,
        "runtime",
        failover_queue_dir_name,
        subdir,
        file_name,
    };
    return try std.fs.path.join(allocator, &parts);
}

fn ensureFailoverQueueDirs(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    const base = try failoverQueueBaseDirPath(allocator, codex_home);
    defer allocator.free(base);
    try std.fs.cwd().makePath(base);

    inline for (&[_][]const u8{ failover_pending_dir_name, failover_processing_dir_name, failover_done_dir_name }) |subdir| {
        const dir_path = try failoverQueueDirPath(allocator, codex_home, subdir);
        defer allocator.free(dir_path);
        try std.fs.cwd().makePath(dir_path);
    }
}

fn renameReplacing(src_path: []const u8, dest_path: []const u8) !void {
    std.fs.cwd().deleteFile(dest_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try std.fs.cwd().rename(src_path, dest_path);
}

fn requeueProcessingFailoverEvents(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    try ensureFailoverQueueDirs(allocator, codex_home);
    const processing_dir_path = try failoverQueueDirPath(allocator, codex_home, failover_processing_dir_name);
    defer allocator.free(processing_dir_path);

    var dir = std.fs.cwd().openDir(processing_dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        const src_path = try failoverQueueFilePath(allocator, codex_home, failover_processing_dir_name, entry.name);
        defer allocator.free(src_path);
        const dest_path = try failoverQueueFilePath(allocator, codex_home, failover_pending_dir_name, entry.name);
        defer allocator.free(dest_path);
        try renameReplacing(src_path, dest_path);
    }
}

fn claimNextFailoverEvent(allocator: std.mem.Allocator, codex_home: []const u8) !?ClaimedFailoverEvent {
    try ensureFailoverQueueDirs(allocator, codex_home);
    try requeueProcessingFailoverEvents(allocator, codex_home);

    const pending_dir_path = try failoverQueueDirPath(allocator, codex_home, failover_pending_dir_name);
    defer allocator.free(pending_dir_path);

    var dir = std.fs.cwd().openDir(pending_dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close();

    var chosen_name: ?[]u8 = null;
    defer if (chosen_name) |name| allocator.free(name);

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (chosen_name == null or std.mem.order(u8, entry.name, chosen_name.?) == .lt) {
            if (chosen_name) |existing| allocator.free(existing);
            chosen_name = try allocator.dupe(u8, entry.name);
        }
    }

    const file_name = chosen_name orelse return null;
    chosen_name = null;

    const pending_path = try failoverQueueFilePath(allocator, codex_home, failover_pending_dir_name, file_name);
    defer allocator.free(pending_path);
    const processing_path = try failoverQueueFilePath(allocator, codex_home, failover_processing_dir_name, file_name);
    errdefer allocator.free(processing_path);
    const done_path = try failoverQueueFilePath(allocator, codex_home, failover_done_dir_name, file_name);
    errdefer allocator.free(done_path);

    try renameReplacing(pending_path, processing_path);
    return .{
        .file_name = file_name,
        .processing_path = processing_path,
        .done_path = done_path,
    };
}

fn archiveClaimedFailoverEvent(event: *ClaimedFailoverEvent) !void {
    try renameReplacing(event.processing_path, event.done_path);
}

fn loadClaimedFailoverEvent(allocator: std.mem.Allocator, event: *const ClaimedFailoverEvent) !FailoverEventFile {
    const data = try std.fs.cwd().readFileAlloc(allocator, event.processing_path, 128 * 1024);
    defer allocator.free(data);

    var parsed = try std.json.parseFromSlice(FailoverEventFile, allocator, data, .{
        .ignore_unknown_fields = true,
    });
    errdefer parsed.deinit();
    return parsed.value;
}

fn failoverEventMatchesCurrentAuth(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    event: *const FailoverEventFile,
) !?[]u8 {
    if (!std.mem.eql(u8, event.source, "codext")) return null;
    if (!std.mem.eql(u8, event.source_auth_mode, "chatgpt")) return null;

    const auth_path = try registry.activeAuthPath(allocator, codex_home);
    defer allocator.free(auth_path);

    var info = auth.parseAuthInfo(allocator, auth_path) catch return null;
    defer info.deinit(allocator);
    if (info.auth_mode != .chatgpt) return null;

    if (event.source_email) |email| {
        const current_email = info.email orelse return null;
        if (!std.ascii.eqlIgnoreCase(current_email, email)) return null;
    }
    if (event.source_account_id) |account_id| {
        const current_account_id = info.chatgpt_account_id orelse return null;
        if (!std.mem.eql(u8, current_account_id, account_id)) return null;
    }
    if (event.source_record_key) |record_key| {
        const current_record_key = info.record_key orelse return null;
        if (!std.mem.eql(u8, current_record_key, record_key)) return null;
    }

    const matched_record_key = info.record_key orelse return null;
    return try allocator.dupe(u8, matched_record_key);
}
fn windowDurationLabel(buf: *[16]u8, window_minutes: ?i64) []const u8 {
    const minutes = window_minutes orelse return "unlabeled";
    if (minutes <= 0) return "unlabeled";
    if (@mod(minutes, 24 * 60) == 0) {
        return std.fmt.bufPrint(buf, "{d}d", .{@divExact(minutes, 24 * 60)}) catch "unlabeled";
    }
    if (@mod(minutes, 60) == 0) {
        return std.fmt.bufPrint(buf, "{d}h", .{@divExact(minutes, 60)}) catch "unlabeled";
    }
    return std.fmt.bufPrint(buf, "{d}m", .{minutes}) catch "unlabeled";
}

fn windowSnapshotLabel(buf: *[32]u8, window: ?registry.RateLimitWindow, now: i64) []const u8 {
    const resolved = window orelse return "-";
    var percent_buf: [5]u8 = undefined;
    var duration_buf: [16]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}@{s}", .{
        percentLabel(&percent_buf, registry.remainingPercentAt(resolved, now)),
        windowDurationLabel(&duration_buf, resolved.window_minutes),
    }) catch "-";
}

fn windowUsageEntryLabel(buf: *[24]u8, window: ?registry.RateLimitWindow, now: i64) []const u8 {
    const resolved = window orelse return "";
    var percent_buf: [5]u8 = undefined;
    var duration_buf: [16]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}={s}", .{
        windowDurationLabel(&duration_buf, resolved.window_minutes),
        percentLabel(&percent_buf, registry.remainingPercentAt(resolved, now)),
    }) catch "";
}

fn rolloutWindowsLabel(buf: *[64]u8, snapshot: registry.RateLimitSnapshot, now: i64) []const u8 {
    var primary_buf: [24]u8 = undefined;
    var secondary_buf: [24]u8 = undefined;
    const primary = windowUsageEntryLabel(&primary_buf, snapshot.primary, now);
    const secondary = windowUsageEntryLabel(&secondary_buf, snapshot.secondary, now);

    if (primary.len != 0 and secondary.len != 0) {
        return std.fmt.bufPrint(buf, "{s} {s}", .{ primary, secondary }) catch primary;
    }
    if (primary.len != 0) {
        return std.fmt.bufPrint(buf, "{s}", .{primary}) catch "no-usage-limits-window";
    }
    if (secondary.len != 0) {
        return std.fmt.bufPrint(buf, "{s}", .{secondary}) catch "no-usage-limits-window";
    }
    return "no-usage-limits-window";
}

fn fileMtimeNsIfExists(path: []const u8) !?i128 {
    const stat = std.fs.cwd().statFile(path) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return @as(i128, stat.mtime);
}

fn apiStatusLabel(buf: *[24]u8, status_code: ?u16, has_usage_windows: bool, missing_auth: bool) []const u8 {
    if (missing_auth) return "MissingAuth";
    if (status_code) |status| {
        if (status == 200 and !has_usage_windows) return "NoUsageLimitsWindow";
        return std.fmt.bufPrint(buf, "{d}", .{status}) catch "-";
    }
    return if (has_usage_windows) "-" else "NoUsageLimitsWindow";
}

fn fieldSeparator() []const u8 {
    return " | ";
}

pub fn handleAutoCommand(allocator: std.mem.Allocator, codex_home: []const u8, cmd: cli.AutoOptions) !void {
    switch (cmd) {
        .action => |action| switch (action) {
            .enable => try enable(allocator, codex_home),
            .disable => try disable(allocator, codex_home),
        },
        .mode => |mode| try configureMode(allocator, codex_home, mode),
        .configure => |opts| try configureThresholds(allocator, codex_home, opts),
    }
}

pub fn handleApiCommand(allocator: std.mem.Allocator, codex_home: []const u8, action: cli.ApiAction) !void {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    const enabled = action == .enable;
    reg.api.usage = enabled;
    reg.api.account = enabled;
    try registry.saveRegistry(allocator, codex_home, &reg);
}

pub fn shouldEnsureManagedService(enabled: bool, runtime: RuntimeState, definition_matches: bool) bool {
    if (!enabled) return false;
    return runtime != .running or !definition_matches;
}

pub fn supportsManagedServiceOnPlatform(os_tag: std.Target.Os.Tag) bool {
    return switch (os_tag) {
        .linux, .macos, .windows => true,
        else => false,
    };
}

pub fn reconcileManagedService(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    if (!supportsManagedServiceOnPlatform(builtin.os.tag)) return;

    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);

    if (!reg.auto_switch.enabled) {
        try uninstallService(allocator, codex_home);
        return;
    }

    if (builtin.os.tag == .linux and !linuxUserSystemdAvailable(allocator)) return;

    const runtime = queryRuntimeState(allocator);
    const self_exe = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(self_exe);
    const managed_self_exe = try managedServiceSelfExePath(allocator, self_exe);
    defer allocator.free(managed_self_exe);
    const definition_matches = try currentServiceDefinitionMatches(allocator, codex_home, managed_self_exe);
    if (!shouldEnsureManagedService(reg.auto_switch.enabled, runtime, definition_matches)) return;

    try installService(allocator, codex_home, managed_self_exe);
}

pub fn runDaemon(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    try registry.ensureAccountsDir(allocator, codex_home);
    var daemon_lock = (try DaemonLock.acquire(allocator, codex_home)) orelse return;
    defer daemon_lock.release();
    var refresh_state = DaemonRefreshState{};
    defer refresh_state.deinit(allocator);

    while (true) {
        const keep_running = daemonCycle(allocator, codex_home, &refresh_state) catch |err| blk: {
            std.log.err("auto daemon cycle failed: {s}", .{@errorName(err)});
            break :blk true;
        };
        if (!keep_running) return;
        std.Thread.sleep(watch_poll_interval_ns);
    }
}

pub fn runDaemonOnce(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    try registry.ensureAccountsDir(allocator, codex_home);
    var daemon_lock = (try DaemonLock.acquire(allocator, codex_home)) orelse return;
    defer daemon_lock.release();

    var refresh_state = DaemonRefreshState{};
    defer refresh_state.deinit(allocator);
    _ = try daemonCycle(allocator, codex_home, &refresh_state);
}

pub fn refreshActiveUsage(allocator: std.mem.Allocator, codex_home: []const u8, reg: *registry.Registry) !bool {
    return refreshActiveUsageWithApiFetcher(allocator, codex_home, reg, usage_api.fetchActiveUsage);
}

pub fn refreshActiveUsageFromLocalSessions(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
) !bool {
    return refreshActiveUsageFromSessions(allocator, codex_home, reg);
}

fn fetchActiveAccountNames(
    allocator: std.mem.Allocator,
    access_token: []const u8,
    account_id: []const u8,
) !account_api.FetchResult {
    return try account_api.fetchAccountsForTokenDetailed(
        allocator,
        account_api.default_account_endpoint,
        access_token,
        account_id,
    );
}

fn applyDaemonAccountNameEntriesToLatestRegistry(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    chatgpt_user_id: []const u8,
    entries: []const account_api.AccountEntry,
) !bool {
    var latest = try registry.loadRegistry(allocator, codex_home);
    defer latest.deinit(allocator);

    if (!latest.auto_switch.enabled or !latest.api.account) return false;
    if (!registry.shouldFetchTeamAccountNamesForUser(&latest, chatgpt_user_id)) return false;
    if (!try registry.applyAccountNamesForUser(allocator, &latest, chatgpt_user_id, entries)) return false;

    try registry.saveRegistry(allocator, codex_home, &latest);
    return true;
}

fn refreshActiveAccountNamesForDaemon(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    refresh_state: *DaemonRefreshState,
) !bool {
    return refreshActiveAccountNamesForDaemonWithFetcher(
        allocator,
        codex_home,
        reg,
        refresh_state,
        fetchActiveAccountNames,
    );
}

pub fn refreshActiveAccountNamesForDaemonWithFetcher(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    refresh_state: *DaemonRefreshState,
    fetcher: anytype,
) !bool {
    if (!reg.auto_switch.enabled) return false;
    if (!reg.api.account) return false;
    const account_key = reg.active_account_key orelse return false;
    try refresh_state.resetAccountNameCooldownIfAccountChanged(allocator, account_key);

    const now_ns = std.time.nanoTimestamp();
    if (refresh_state.last_account_name_refresh_at_ns != 0 and
        (now_ns - refresh_state.last_account_name_refresh_at_ns) < api_refresh_interval_ns)
    {
        return false;
    }

    var candidates = try account_name_refresh.collectCandidates(allocator, reg);
    defer {
        for (candidates.items) |*candidate| candidate.deinit(allocator);
        candidates.deinit(allocator);
    }
    if (candidates.items.len == 0) return false;

    var tasks = std.ArrayList(AccountNameFetchTask).empty;
    defer {
        for (tasks.items) |*task| task.deinit(allocator);
        tasks.deinit(allocator);
    }

    for (candidates.items) |candidate| {
        var latest = try registry.loadRegistry(allocator, codex_home);
        defer latest.deinit(allocator);

        if (!latest.auto_switch.enabled or !latest.api.account) continue;
        if (!registry.shouldFetchTeamAccountNamesForUser(&latest, candidate.chatgpt_user_id)) continue;

        var info = (try account_name_refresh.loadStoredAuthInfoForUser(
            allocator,
            codex_home,
            &latest,
            candidate.chatgpt_user_id,
        )) orelse continue;
        defer info.deinit(allocator);

        const access_token = info.access_token orelse continue;
        const chatgpt_account_id = info.chatgpt_account_id orelse continue;
        try tasks.append(allocator, try AccountNameFetchTask.init(
            allocator,
            candidate.chatgpt_user_id,
            access_token,
            chatgpt_account_id,
        ));
    }

    if (tasks.items.len == 0) return false;
    refresh_state.last_account_name_refresh_at_ns = now_ns;

    var changed = false;
    var start: usize = 0;
    while (start < tasks.items.len) : (start += account_name_parallel_fetch_limit) {
        const end = @min(start + account_name_parallel_fetch_limit, tasks.items.len);
        try runAccountNameFetchBatch(fetcher, tasks.items[start..end]);
        for (tasks.items[start..end]) |*task| {
            if (task.fetch_error) |err| {
                std.log.warn("account metadata refresh skipped: {s}", .{@errorName(err)});
                continue;
            }
            const result = task.fetch_result orelse continue;
            const entries = result.entries orelse continue;
            if (try applyDaemonAccountNameEntriesToLatestRegistry(allocator, codex_home, task.chatgpt_user_id, entries)) {
                changed = true;
            }
        }
    }

    return changed;
}

pub fn refreshActiveUsageWithApiFetcher(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    api_fetcher: anytype,
) !bool {
    if (reg.api.usage) {
        return switch (try refreshActiveUsageFromApi(allocator, codex_home, reg, api_fetcher)) {
            .updated => true,
            .unchanged, .unavailable => false,
        };
    }
    return try refreshActiveUsageFromSessions(allocator, codex_home, reg);
}

const ApiRefreshResult = enum { unavailable, unchanged, updated };

fn refreshActiveUsageFromApi(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    api_fetcher: anytype,
) !ApiRefreshResult {
    const latest_usage = api_fetcher(allocator, codex_home) catch return .unavailable;
    if (latest_usage == null) return .unavailable;

    var latest = latest_usage.?;
    var snapshot_consumed = false;
    defer if (!snapshot_consumed) registry.freeRateLimitSnapshot(allocator, &latest);

    const account_key = reg.active_account_key orelse return .unchanged;
    const idx = registry.findAccountIndexByAccountKey(reg, account_key) orelse return .unchanged;
    if (registry.rateLimitSnapshotsEqualIgnoringCreditBalance(reg.accounts.items[idx].last_usage, latest)) {
        try registry.markAccountAuthVerified(allocator, reg, account_key);
        return .unchanged;
    }

    try registry.preserveCreditBalanceIfMissing(allocator, reg.accounts.items[idx].last_usage, &latest);
    registry.updateUsage(allocator, reg, account_key, latest);
    try registry.markAccountAuthVerified(allocator, reg, account_key);
    snapshot_consumed = true;
    return .updated;
}

fn refreshActiveUsageFromSessions(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
) !bool {
    const latest_usage = sessions.scanLatestUsageWithRuntimeCache(allocator, codex_home) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    if (latest_usage == null) return false;
    var latest = latest_usage.?;
    var snapshot_consumed = false;
    defer {
        allocator.free(latest.path);
        if (!snapshot_consumed) {
            registry.freeRateLimitSnapshot(allocator, &latest.snapshot);
        }
    }
    const signature: registry.RolloutSignature = .{
        .path = latest.path,
        .event_timestamp_ms = latest.event_timestamp_ms,
    };
    const account_key = reg.active_account_key orelse return false;
    const activated_at_ms = reg.active_account_activated_at_ms orelse 0;
    if (latest.event_timestamp_ms < activated_at_ms) return false;
    const idx = registry.findAccountIndexByAccountKey(reg, account_key) orelse return false;
    if (registry.rolloutSignaturesEqual(reg.accounts.items[idx].last_local_rollout, signature)) {
        try registry.markAccountAuthVerified(allocator, reg, account_key);
        return false;
    }
    try registry.preserveCreditBalanceIfMissing(allocator, reg.accounts.items[idx].last_usage, &latest.snapshot);
    registry.updateUsage(allocator, reg, account_key, latest.snapshot);
    snapshot_consumed = true;
    try registry.setAccountLastLocalRollout(allocator, &reg.accounts.items[idx], latest.path, latest.event_timestamp_ms);
    try registry.markAccountAuthVerified(allocator, reg, account_key);
    return true;
}

fn refreshActiveUsageForDaemon(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    refresh_state: *DaemonRefreshState,
) !bool {
    return refreshActiveUsageForDaemonWithDetailedApiFetcher(
        allocator,
        codex_home,
        reg,
        refresh_state,
        usage_api.fetchActiveUsageDetailed,
    );
}

fn refreshActiveUsageForDaemonWithDetailedApiFetcher(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    refresh_state: *DaemonRefreshState,
    api_fetcher: anytype,
) !bool {
    const account_key = reg.active_account_key orelse return false;
    refresh_state.clearPendingIfAccountChanged(allocator, account_key);
    try refresh_state.resetApiCooldownIfAccountChanged(allocator, account_key);
    const active_idx = registry.findAccountIndexByAccountKey(reg, account_key);

    if (try refreshActiveUsageFromSessionsForDaemon(allocator, codex_home, reg, refresh_state)) {
        return true;
    }
    if (!reg.api.usage) return false;

    const now_ns = std.time.nanoTimestamp();
    if (refresh_state.last_api_refresh_at_ns != 0 and (now_ns - refresh_state.last_api_refresh_at_ns) < api_refresh_interval_ns) {
        return false;
    }
    refresh_state.last_api_refresh_at_ns = now_ns;

    const fetch_result = api_fetcher(allocator, codex_home) catch |err| {
        emitTaggedDaemonLog(.warning, "api", "refresh usage{s}status={s}", .{
            fieldSeparator(),
            @errorName(err),
        });
        return false;
    };

    const latest_usage = fetch_result.snapshot;
    const status_code = fetch_result.status_code;
    const missing_auth = fetch_result.missing_auth;
    var status_buf: [24]u8 = undefined;
    if (latest_usage == null) {
        emitTaggedDaemonLog(.warning, "api", "refresh usage{s}status={s}", .{
            fieldSeparator(),
            apiStatusLabel(&status_buf, status_code, false, missing_auth),
        });
        return false;
    }

    var latest = latest_usage.?;
    var snapshot_consumed = false;
    defer if (!snapshot_consumed) registry.freeRateLimitSnapshot(allocator, &latest);

    if (active_idx == null) {
        emitTaggedDaemonLog(.debug, "api", "refresh usage{s}status={s}", .{
            fieldSeparator(),
            apiStatusLabel(&status_buf, status_code, true, missing_auth),
        });
        return false;
    }
    if (registry.rateLimitSnapshotsEqualIgnoringCreditBalance(reg.accounts.items[active_idx.?].last_usage, latest)) {
        emitTaggedDaemonLog(.debug, "api", "refresh usage{s}status={s}", .{
            fieldSeparator(),
            apiStatusLabel(&status_buf, status_code, true, missing_auth),
        });
        refresh_state.clearPending(allocator);
        return false;
    }

    try registry.preserveCreditBalanceIfMissing(allocator, reg.accounts.items[active_idx.?].last_usage, &latest);
    registry.updateUsage(allocator, reg, account_key, latest);
    snapshot_consumed = true;
    emitTaggedDaemonLog(.info, "api", "refresh usage{s}status={s}", .{
        fieldSeparator(),
        apiStatusLabel(&status_buf, status_code, true, missing_auth),
    });
    refresh_state.clearPending(allocator);
    return true;
}

pub fn refreshActiveUsageForDaemonWithApiFetcher(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    refresh_state: *DaemonRefreshState,
    api_fetcher: anytype,
) !bool {
    const account_key = reg.active_account_key orelse return false;
    refresh_state.clearPendingIfAccountChanged(allocator, account_key);
    try refresh_state.resetApiCooldownIfAccountChanged(allocator, account_key);
    if (try refreshActiveUsageFromSessionsForDaemon(allocator, codex_home, reg, refresh_state)) {
        return true;
    }
    if (!reg.api.usage) return false;

    const now_ns = std.time.nanoTimestamp();
    if (refresh_state.last_api_refresh_at_ns != 0 and (now_ns - refresh_state.last_api_refresh_at_ns) < api_refresh_interval_ns) {
        return false;
    }
    refresh_state.last_api_refresh_at_ns = now_ns;

    return switch (try refreshActiveUsageFromApi(allocator, codex_home, reg, api_fetcher)) {
        .updated => blk: {
            emitTaggedDaemonLog(.info, "api", "refresh usage{s}status=200", .{fieldSeparator()});
            refresh_state.clearPending(allocator);
            break :blk true;
        },
        .unchanged => blk: {
            emitTaggedDaemonLog(.debug, "api", "refresh usage{s}status=200", .{fieldSeparator()});
            refresh_state.clearPending(allocator);
            break :blk false;
        },
        .unavailable => blk: {
            emitTaggedDaemonLog(.warning, "api", "refresh usage{s}status=NoUsageLimitsWindow", .{fieldSeparator()});
            break :blk false;
        },
    };
}

fn refreshActiveUsageFromSessionsForDaemon(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    refresh_state: *DaemonRefreshState,
) !bool {
    var latest_event = (sessions.scanLatestRolloutEventWithCache(allocator, codex_home, &refresh_state.rollout_scan_cache) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    }) orelse return false;
    defer latest_event.deinit(allocator);

    const account_key = reg.active_account_key orelse return false;
    const activated_at_ms = reg.active_account_activated_at_ms orelse 0;
    if (latest_event.event_timestamp_ms < activated_at_ms) return false;

    const signature: registry.RolloutSignature = .{
        .path = latest_event.path,
        .event_timestamp_ms = latest_event.event_timestamp_ms,
    };
    const idx = registry.findAccountIndexByAccountKey(reg, account_key) orelse return false;
    if (registry.rolloutSignaturesEqual(reg.accounts.items[idx].last_local_rollout, signature)) {
        refresh_state.clearPending(allocator);
        return false;
    }

    var event_time_buf: [19]u8 = undefined;
    const event_time = localDateTimeLabel(&event_time_buf, latest_event.event_timestamp_ms);
    var file_buf: [96]u8 = undefined;
    const file_label = rolloutFileLabel(&file_buf, latest_event.path);

    if (!latest_event.hasUsableWindows()) {
        if (try sessions.cloneLatestUsableFromCache(allocator, &refresh_state.rollout_scan_cache)) |cloned_usable| {
            var usable = cloned_usable;
            defer usable.deinit(allocator);
            if (usable.event_timestamp_ms >= activated_at_ms) {
                const usable_signature: registry.RolloutSignature = .{
                    .path = usable.path,
                    .event_timestamp_ms = usable.event_timestamp_ms,
                };
                if (registry.rolloutSignaturesEqual(reg.accounts.items[idx].last_local_rollout, usable_signature)) {
                    refresh_state.clearPending(allocator);
                    return false;
                }
            }
        }
        if (try applyLatestUsableSnapshotFromRolloutCache(
            allocator,
            reg,
            account_key,
            idx,
            &refresh_state.rollout_scan_cache,
            activated_at_ms,
        )) {
            refresh_state.clearPending(allocator);
            return true;
        }
        if (refresh_state.pendingMatches(account_key, signature)) {
            return false;
        }
        if (reg.api.usage) {
            emitTaggedDaemonLog(.warning, "local", "no usable local snapshot{s}fallback-to-api{s}event={s}{s}file={s}", .{
                fieldSeparator(),
                fieldSeparator(),
                event_time,
                fieldSeparator(),
                file_label,
            });
        } else {
            emitTaggedDaemonLog(.warning, "local", "no usable local snapshot{s}event={s}{s}file={s}", .{
                fieldSeparator(),
                event_time,
                fieldSeparator(),
                file_label,
            });
        }
        try refresh_state.setPending(allocator, account_key, signature);
        return false;
    }

    const now = std.time.timestamp();
    var windows_buf: [64]u8 = undefined;
    emitTaggedDaemonLog(.notice, "local", "{s}{s}event={s}{s}file={s}", .{
        rolloutWindowsLabel(&windows_buf, latest_event.snapshot.?, now),
        fieldSeparator(),
        event_time,
        fieldSeparator(),
        file_label,
    });
    var latest_snapshot = latest_event.snapshot.?;
    try registry.preserveCreditBalanceIfMissing(allocator, reg.accounts.items[idx].last_usage, &latest_snapshot);
    registry.updateUsage(allocator, reg, account_key, latest_snapshot);
    latest_event.snapshot = null;
    try registry.setAccountLastLocalRollout(allocator, &reg.accounts.items[idx], latest_event.path, latest_event.event_timestamp_ms);
    refresh_state.clearPending(allocator);
    return true;
}

fn applyLatestUsableSnapshotFromRolloutCache(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    account_key: []const u8,
    idx: usize,
    cache: *const sessions.RolloutScanCache,
    activated_at_ms: i64,
) !bool {
    const latest_usage = try sessions.cloneLatestUsableFromCache(allocator, cache);
    if (latest_usage == null) return false;

    var usable = latest_usage.?;
    var snapshot_consumed = false;
    defer {
        allocator.free(usable.path);
        if (!snapshot_consumed) {
            registry.freeRateLimitSnapshot(allocator, &usable.snapshot);
        }
    }

    if (usable.event_timestamp_ms < activated_at_ms) return false;

    const usable_signature: registry.RolloutSignature = .{
        .path = usable.path,
        .event_timestamp_ms = usable.event_timestamp_ms,
    };
    if (registry.rolloutSignaturesEqual(reg.accounts.items[idx].last_local_rollout, usable_signature)) {
        return false;
    }

    try registry.preserveCreditBalanceIfMissing(allocator, reg.accounts.items[idx].last_usage, &usable.snapshot);
    registry.updateUsage(allocator, reg, account_key, usable.snapshot);
    snapshot_consumed = true;
    try registry.setAccountLastLocalRollout(allocator, &reg.accounts.items[idx], usable.path, usable.event_timestamp_ms);
    return true;
}

fn applyLatestUsableSnapshotFromRolloutFile(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    account_key: []const u8,
    idx: usize,
    rollout_path: []const u8,
    rollout_mtime: i64,
    activated_at_ms: i64,
) !bool {
    const latest_usage = sessions.scanLatestUsableUsageInFile(allocator, rollout_path, rollout_mtime) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    if (latest_usage == null) return false;

    var usable = latest_usage.?;
    var snapshot_consumed = false;
    defer {
        allocator.free(usable.path);
        if (!snapshot_consumed) {
            registry.freeRateLimitSnapshot(allocator, &usable.snapshot);
        }
    }

    if (usable.event_timestamp_ms < activated_at_ms) return false;

    const usable_signature: registry.RolloutSignature = .{
        .path = usable.path,
        .event_timestamp_ms = usable.event_timestamp_ms,
    };
    if (registry.rolloutSignaturesEqual(reg.accounts.items[idx].last_local_rollout, usable_signature)) {
        return false;
    }

    try registry.preserveCreditBalanceIfMissing(allocator, reg.accounts.items[idx].last_usage, &usable.snapshot);
    registry.updateUsage(allocator, reg, account_key, usable.snapshot);
    snapshot_consumed = true;
    try registry.setAccountLastLocalRollout(allocator, &reg.accounts.items[idx], usable.path, usable.event_timestamp_ms);
    return true;
}

pub fn bestAutoSwitchCandidateIndex(reg: *registry.Registry, now: i64) ?usize {
    const active = reg.active_account_key orelse return null;
    return bestEligibleAccountIndexAt(reg, now, active, &.{});
}

pub fn shouldSwitchCurrent(reg: *registry.Registry, now: i64) bool {
    const account_key = reg.active_account_key orelse return false;
    const idx = registry.findAccountIndexByAccountKey(reg, account_key) orelse return false;
    const rec = &reg.accounts.items[idx];
    if (registry.accountSnapshotFreshness(rec, now) != .fresh) return false;
    const resolved_5h = resolve5hTriggerWindow(rec.last_usage);
    const threshold_5h_percent = effective5hThresholdPercent(reg.auto_switch, rec, resolved_5h.allow_free_guard);
    const rem_5h = registry.remainingPercentAt(resolved_5h.window, now);
    const rem_week = registry.remainingPercentAt(registry.resolveRateWindow(rec.last_usage, 10080, false), now);
    return (rem_5h != null and rem_5h.? < threshold_5h_percent) or
        (rem_week != null and rem_week.? < @as(i64, reg.auto_switch.threshold_weekly_percent));
}

fn effective5hThresholdPercent(cfg: registry.AutoSwitchConfig, rec: *const registry.AccountRecord, allow_free_guard: bool) i64 {
    var threshold = @as(i64, cfg.threshold_5h_percent);
    if (allow_free_guard and registry.resolvePlan(rec) == .free) {
        threshold = @max(threshold, free_plan_realtime_guard_5h_percent);
    }
    return threshold;
}

pub fn maybeAutoSwitch(allocator: std.mem.Allocator, codex_home: []const u8, reg: *registry.Registry) !bool {
    const attempt = try maybeAutoSwitchWithUsageFetcher(allocator, codex_home, reg, usage_api.fetchUsageForAuthPath);
    return attempt.switched;
}

pub fn refreshBestSwitchCandidatesForForeground(allocator: std.mem.Allocator, codex_home: []const u8, reg: *registry.Registry) !bool {
    return refreshBestSwitchCandidatesForForegroundWithUsageFetcher(
        allocator,
        codex_home,
        reg,
        usage_api.fetchUsageForAuthPathDetailed,
    );
}

pub fn refreshBestSwitchCandidatesForForegroundWithUsageFetcher(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    usage_fetcher: anytype,
) !bool {
    if (!reg.api.usage) return false;
    const now = std.time.timestamp();
    var skipped_candidates = std.ArrayListUnmanaged([]const u8).empty;
    defer skipped_candidates.deinit(allocator);
    const summary = try refreshBestKnownSwitchCandidatesWithUsageFetcher(
        allocator,
        codex_home,
        reg,
        usage_fetcher,
        now,
        std.time.nanoTimestamp(),
        &skipped_candidates,
    );
    return summary.updated != 0;
}

pub fn maybeAutoSwitchWithUsageFetcher(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    usage_fetcher: anytype,
) !AutoSwitchAttempt {
    return maybeAutoSwitchWithUsageFetcherAndRefreshState(allocator, codex_home, reg, null, usage_fetcher);
}

pub fn maybeAutoSwitchForDaemonWithUsageFetcher(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    refresh_state: *DaemonRefreshState,
    usage_fetcher: anytype,
) !AutoSwitchAttempt {
    if (!reg.auto_switch.enabled) return .{ .refreshed_candidates = false, .switched = false };
    if (reg.auto_switch.mode == .pinned or reg.auto_switch.mode == .failover) {
        return .{ .refreshed_candidates = false, .switched = false };
    }
    const now = std.time.timestamp();
    const should_switch_current = shouldSwitchCurrent(reg, now);
    const proactive_mode = reg.auto_switch.mode == .proactive;
    if (refresh_state.current_reg == null and refresh_state.candidate_index.heap.items.len == 0) {
        try refresh_state.candidate_index.rebuild(allocator, reg, now);
    } else {
        try refresh_state.candidate_index.rebuildIfScoreExpired(allocator, reg, now);
    }
    const active = reg.active_account_key orelse return .{ .refreshed_candidates = false, .switched = false };
    const now_ns = std.time.nanoTimestamp();
    const active_idx = registry.findAccountIndexByAccountKey(reg, active) orelse return .{
        .refreshed_candidates = false,
        .switched = false,
    };
    const current = currentScore(&reg.accounts.items[active_idx], now);

    var changed = false;
    var refreshed_candidates = false;

    if (reg.api.usage and !should_switch_current) {
        const upkeep = try refreshDaemonCandidateUpkeepWithUsageFetcher(
            allocator,
            codex_home,
            reg,
            refresh_state,
            usage_fetcher,
            now,
            now_ns,
        );
        refreshed_candidates = upkeep.attempted != 0;
        changed = upkeep.updated != 0;
    }

    if (!should_switch_current and !proactive_mode) {
        return .{
            .refreshed_candidates = refreshed_candidates,
            .state_changed = changed,
            .switched = false,
        };
    }

    if (reg.api.usage) {
        var skipped_candidates = std.ArrayListUnmanaged([]const u8).empty;
        defer skipped_candidates.deinit(allocator);
        const validation = try refreshDaemonSwitchCandidatesWithUsageFetcher(
            allocator,
            codex_home,
            reg,
            refresh_state,
            usage_fetcher,
            now,
            now_ns,
            &skipped_candidates,
        );
        refreshed_candidates = refreshed_candidates or validation.attempted != 0;
        changed = changed or validation.updated != 0;

        const best_candidate_key = (try bestDaemonCandidateForSwitch(allocator, refresh_state, skipped_candidates.items, now_ns)) orelse return .{
            .refreshed_candidates = refreshed_candidates,
            .state_changed = changed,
            .switched = false,
        };
        const candidate_idx = registry.findAccountIndexByAccountKey(reg, best_candidate_key) orelse return .{
            .refreshed_candidates = refreshed_candidates,
            .state_changed = changed,
            .switched = false,
        };
        if (current != null and !candidateBeatsCurrent(reg, active_idx, candidate_idx, now)) {
            return .{
                .refreshed_candidates = refreshed_candidates,
                .state_changed = changed,
                .switched = false,
            };
        }

        const previous_active_key = reg.accounts.items[active_idx].account_key;
        const next_active_key = reg.accounts.items[candidate_idx].account_key;
        try registry.activateAccountByKey(allocator, codex_home, reg, next_active_key);
        try refresh_state.candidate_index.handleActiveSwitch(
            allocator,
            reg,
            previous_active_key,
            next_active_key,
            std.time.timestamp(),
        );
        try refresh_state.markCandidateChecked(allocator, previous_active_key, now_ns);
        refresh_state.clearCandidateChecked(next_active_key);
        return .{
            .refreshed_candidates = refreshed_candidates,
            .state_changed = true,
            .switched = true,
        };
    }

    const candidate_entry = refresh_state.candidate_index.best() orelse return .{
        .refreshed_candidates = refreshed_candidates,
        .state_changed = changed,
        .switched = false,
    };
    const candidate_idx = registry.findAccountIndexByAccountKey(reg, candidate_entry.account_key) orelse return .{
        .refreshed_candidates = refreshed_candidates,
        .state_changed = changed,
        .switched = false,
    };
    if (current != null and !candidateBeatsCurrent(reg, active_idx, candidate_idx, now)) {
        return .{
            .refreshed_candidates = refreshed_candidates,
            .state_changed = changed,
            .switched = false,
        };
    }

    const previous_active_key = reg.accounts.items[active_idx].account_key;
    const next_active_key = reg.accounts.items[candidate_idx].account_key;
    try registry.activateAccountByKey(allocator, codex_home, reg, next_active_key);
    try refresh_state.candidate_index.handleActiveSwitch(
        allocator,
        reg,
        previous_active_key,
        next_active_key,
        std.time.timestamp(),
    );
    try refresh_state.markCandidateChecked(allocator, previous_active_key, now_ns);
    refresh_state.clearCandidateChecked(next_active_key);
    return .{
        .refreshed_candidates = refreshed_candidates,
        .state_changed = true,
        .switched = true,
    };
}

fn maybeAutoSwitchWithUsageFetcherAndRefreshState(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    refresh_state: ?*DaemonRefreshState,
    usage_fetcher: anytype,
) !AutoSwitchAttempt {
    if (!reg.auto_switch.enabled) return .{ .refreshed_candidates = false, .switched = false };
    if (reg.auto_switch.mode == .pinned or reg.auto_switch.mode == .failover) {
        return .{ .refreshed_candidates = false, .switched = false };
    }
    const active = reg.active_account_key orelse return .{ .refreshed_candidates = false, .switched = false };
    const now = std.time.timestamp();
    const should_switch_current = shouldSwitchCurrent(reg, now);
    const proactive_mode = reg.auto_switch.mode == .proactive;
    if (!should_switch_current and !proactive_mode) return .{ .refreshed_candidates = false, .switched = false };

    _ = refresh_state;
    const should_refresh_candidates = reg.api.usage;

    const refreshed_candidates = if (should_refresh_candidates)
        try refreshAutoSwitchCandidatesWithUsageFetcher(allocator, codex_home, reg, usage_fetcher)
    else
        false;

    const active_idx = registry.findAccountIndexByAccountKey(reg, active) orelse return .{
        .refreshed_candidates = refreshed_candidates,
        .switched = false,
    };
    const candidate_idx = bestAutoSwitchCandidateIndex(reg, now) orelse return .{
        .refreshed_candidates = refreshed_candidates,
        .switched = false,
    };
    const current = currentScore(&reg.accounts.items[active_idx], now);
    if (current != null and !candidateBeatsCurrent(reg, active_idx, candidate_idx, now)) {
        return .{
            .refreshed_candidates = refreshed_candidates,
            .switched = false,
        };
    }

    try registry.activateAccountByKey(allocator, codex_home, reg, reg.accounts.items[candidate_idx].account_key);
    return .{ .refreshed_candidates = refreshed_candidates, .state_changed = true, .switched = true };
}

fn refreshAutoSwitchCandidatesWithUsageFetcher(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    usage_fetcher: anytype,
) !bool {
    const active = reg.active_account_key orelse return false;
    var changed = false;
    var attempted: usize = 0;
    var updated: usize = 0;

    for (reg.accounts.items) |rec| {
        if (std.mem.eql(u8, rec.account_key, active)) continue;
        if (accountIsBlocked(reg, rec.account_key, std.time.timestamp())) continue;
        if (rec.auth_mode != null and rec.auth_mode.? != .chatgpt) continue;
        attempted += 1;

        const auth_path = registry.accountAuthPath(allocator, codex_home, rec.account_key) catch continue;
        defer allocator.free(auth_path);

        const latest_usage = usage_fetcher(allocator, auth_path) catch continue;
        if (latest_usage == null) continue;

        var latest = latest_usage.?;
        var snapshot_consumed = false;
        defer if (!snapshot_consumed) registry.freeRateLimitSnapshot(allocator, &latest);

        if (registry.rateLimitSnapshotsEqualIgnoringCreditBalance(rec.last_usage, latest)) continue;
        try registry.preserveCreditBalanceIfMissing(allocator, rec.last_usage, &latest);
        registry.updateUsage(allocator, reg, rec.account_key, latest);
        snapshot_consumed = true;
        changed = true;
        updated += 1;
    }

    return changed;
}

const CandidateRefreshSummary = struct {
    attempted: usize = 0,
    updated: usize = 0,
};

fn keyIsSkipped(skipped_keys: []const []const u8, account_key: []const u8) bool {
    for (skipped_keys) |skipped| {
        if (std.mem.eql(u8, skipped, account_key)) return true;
    }
    return false;
}

fn bestDaemonCandidateForSwitch(
    _: std.mem.Allocator,
    refresh_state: *DaemonRefreshState,
    skipped_keys: []const []const u8,
    now_ns: i128,
) !?[]const u8 {
    var best: ?CandidateScore = null;
    var best_account_key: ?[]const u8 = null;
    for (refresh_state.candidate_index.heap.items) |entry| {
        const account_key = entry.account_key;
        if (refresh_state.candidateIsRejected(account_key, now_ns)) continue;
        if (keyIsSkipped(skipped_keys, account_key)) continue;
        if (refresh_state.candidateIsStale(account_key, now_ns)) continue;
        if (entry.score.refresh_only) continue;
        if (best == null or candidateBetter(entry.score, best.?)) {
            best = entry.score;
            best_account_key = account_key;
        }
    }
    return best_account_key;
}

fn nextDaemonCandidateToValidate(
    allocator: std.mem.Allocator,
    refresh_state: *DaemonRefreshState,
    skipped_keys: []const []const u8,
    now_ns: i128,
) !?[]const u8 {
    var ordered = try refresh_state.candidate_index.orderedKeys(allocator);
    defer ordered.deinit(allocator);

    for (ordered.items) |account_key| {
        if (refresh_state.candidateIsRejected(account_key, now_ns)) continue;
        if (keyIsSkipped(skipped_keys, account_key)) continue;
        if (!refresh_state.candidateIsStale(account_key, now_ns)) continue;
        return account_key;
    }
    return null;
}

fn refreshDaemonCandidateUpkeepWithUsageFetcher(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    refresh_state: *DaemonRefreshState,
    usage_fetcher: anytype,
    now: i64,
    now_ns: i128,
) !CandidateRefreshSummary {
    var keys: [1][]const u8 = undefined;
    const selected = try collectNextDaemonCandidatesToValidate(allocator, refresh_state, &.{}, now_ns, keys[0..]);
    if (selected == 0) return .{};
    const summary = try refreshDaemonCandidateUsageBatchWithFetcher(
        allocator,
        codex_home,
        reg,
        refresh_state,
        keys[0..selected],
        usage_fetcher,
        now_ns,
        null,
    );
    _ = now;
    return summary;
}

fn refreshDaemonSwitchCandidatesWithUsageFetcher(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    refresh_state: *DaemonRefreshState,
    usage_fetcher: anytype,
    now: i64,
    now_ns: i128,
    skipped_keys: *std.ArrayListUnmanaged([]const u8),
) !CandidateRefreshSummary {
    var summary: CandidateRefreshSummary = .{};
    var visited: usize = 0;
    while (visited < candidate_switch_validation_limit) : (visited += 1) {
        var keys: [candidate_parallel_fetch_limit][]const u8 = undefined;
        const limit = @min(candidate_parallel_fetch_limit, candidate_switch_validation_limit - visited);
        const selected = try collectNextDaemonCandidatesToValidate(
            allocator,
            refresh_state,
            skipped_keys.items,
            now_ns,
            keys[0..limit],
        );
        if (selected == 0) break;

        const batch = try refreshDaemonCandidateUsageBatchWithFetcher(
            allocator,
            codex_home,
            reg,
            refresh_state,
            keys[0..selected],
            usage_fetcher,
            now_ns,
            skipped_keys,
        );
        summary.attempted += batch.attempted;
        summary.updated += batch.updated;
        visited += selected - 1;
    }

    _ = now;
    return summary;
}

fn refreshBestKnownSwitchCandidatesWithUsageFetcher(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    usage_fetcher: anytype,
    now: i64,
    now_ns: i128,
    skipped_keys: *std.ArrayListUnmanaged([]const u8),
) !CandidateRefreshSummary {
    _ = now_ns;
    var summary: CandidateRefreshSummary = .{};
    var visited: usize = 0;
    while (visited < candidate_switch_validation_limit) : (visited += 1) {
        var keys: [candidate_parallel_fetch_limit][]const u8 = undefined;
        const limit = @min(candidate_parallel_fetch_limit, candidate_switch_validation_limit - visited);
        const selected = try collectBestKnownCandidatesToValidate(
            allocator,
            reg,
            skipped_keys.items,
            now,
            keys[0..limit],
        );
        if (selected == 0) break;

        const batch = try refreshForegroundBestKnownCandidateUsageBatchWithFetcher(
            allocator,
            codex_home,
            reg,
            keys[0..selected],
            usage_fetcher,
            skipped_keys,
        );
        summary.attempted += batch.attempted;
        summary.updated += batch.updated;
        visited += selected - 1;
    }
    return summary;
}

fn refreshForegroundBestKnownCandidateUsageBatchWithFetcher(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    account_keys: []const []const u8,
    usage_fetcher: anytype,
    skipped_keys: *std.ArrayListUnmanaged([]const u8),
) !CandidateRefreshSummary {
    var summary: CandidateRefreshSummary = .{};
    var tasks: [candidate_parallel_fetch_limit]CandidateUsageFetchTask = undefined;
    var prepared_count: usize = 0;
    defer {
        for (tasks[0..prepared_count]) |*task| task.deinit(allocator);
    }

    for (account_keys) |account_key| {
        const idx = registry.findAccountIndexByAccountKey(reg, account_key) orelse continue;
        const rec = &reg.accounts.items[idx];
        if (rec.auth_mode != null and rec.auth_mode.? != .chatgpt) continue;
        registry.validateAccountSnapshotForAccount(allocator, codex_home, reg, account_key) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try skipped_keys.append(allocator, account_key);
                continue;
            },
        };

        const auth_path = registry.accountAuthPath(allocator, codex_home, account_key) catch continue;
        errdefer allocator.free(auth_path);
        tasks[prepared_count] = .{
            .account_key = account_key,
            .auth_path = auth_path,
        };
        prepared_count += 1;
    }

    if (prepared_count == 0) return summary;
    try runCandidateUsageFetchBatch(usage_fetcher, tasks[0..prepared_count]);

    for (tasks[0..prepared_count]) |*task| {
        const result = try applyForegroundBestKnownFetchTaskResult(
            allocator,
            reg,
            task.account_key,
            task.fetch_result orelse .{ .snapshot = null, .status_code = null },
            task.fetch_error,
        );
        summary.attempted += result.attempted;
        summary.updated += result.updated;
        if (result.disqualify_for_switch) {
            try skipped_keys.append(allocator, task.account_key);
        }
    }

    return summary;
}

fn applyForegroundBestKnownFetchTaskResult(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    account_key: []const u8,
    fetch_result: usage_api.UsageFetchResult,
    fetch_error: ?anyerror,
) !SingleCandidateRefreshResult {
    const idx = registry.findAccountIndexByAccountKey(reg, account_key) orelse return .{};
    const rec = &reg.accounts.items[idx];
    const needs_verified_record = rec.auth_health != .verified or rec.auth_error != null;

    if (fetch_error != null) {
        try registry.markAccountAuthFailure(allocator, reg, account_key, .api_failed, @errorName(fetch_error.?));
        return .{ .visited = true, .attempted = 1, .updated = 1, .disqualify_for_switch = true };
    }
    if (fetch_result.missing_auth) {
        try registry.markAccountAuthFailure(allocator, reg, account_key, .missing_auth, "usage API could not load account auth");
        return .{ .visited = true, .attempted = 1, .updated = 1, .disqualify_for_switch = true };
    }
    if (fetch_result.status_code) |status_code| {
        if (status_code != 200) {
            var buf: [32]u8 = undefined;
            const reason = std.fmt.bufPrint(&buf, "usage API HTTP {d}", .{status_code}) catch "usage API HTTP error";
            try registry.markAccountAuthFailure(allocator, reg, account_key, .api_failed, reason);
            return .{ .visited = true, .attempted = 1, .updated = 1, .disqualify_for_switch = true };
        }
    }

    const latest_usage = fetch_result.snapshot;
    if (latest_usage == null) {
        if (fetch_result.status_code != null) {
            try registry.markAccountAuthFailure(allocator, reg, account_key, .api_failed, "usage API returned no usable quota windows");
        }
        return .{
            .visited = true,
            .attempted = 1,
            .updated = if (fetch_result.status_code != null) 1 else 0,
            .disqualify_for_switch = fetch_result.status_code != null,
        };
    }

    if (registry.rateLimitSnapshotsEqualIgnoringCreditBalance(rec.last_usage, latest_usage.?)) {
        if (needs_verified_record) {
            try registry.markAccountAuthVerified(allocator, reg, account_key);
            return .{ .visited = true, .attempted = 1, .updated = 1 };
        }
        return .{ .visited = true, .attempted = 1 };
    }

    var cloned = try registry.cloneRateLimitSnapshot(allocator, latest_usage.?);
    errdefer registry.freeRateLimitSnapshot(allocator, &cloned);
    try registry.preserveCreditBalanceIfMissing(allocator, rec.last_usage, &cloned);
    registry.updateUsage(allocator, reg, account_key, cloned);
    try registry.markAccountAuthVerified(allocator, reg, account_key);
    return .{ .visited = true, .attempted = 1, .updated = 1 };
}

const SingleCandidateRefreshResult = struct {
    visited: bool = false,
    attempted: usize = 0,
    updated: usize = 0,
    disqualify_for_switch: bool = false,
};

fn refreshDaemonCandidateUsageByKeyWithFetcher(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    refresh_state: *DaemonRefreshState,
    account_key: []const u8,
    usage_fetcher: anytype,
    now_ns: i128,
) !SingleCandidateRefreshResult {
    const idx = registry.findAccountIndexByAccountKey(reg, account_key) orelse return .{};
    const rec = &reg.accounts.items[idx];

    if (rec.auth_mode != null and rec.auth_mode.? != .chatgpt) {
        try refresh_state.markCandidateChecked(allocator, account_key, now_ns);
        refresh_state.clearCandidateRejected(account_key);
        return .{ .visited = true };
    }

    const auth_path = registry.accountAuthPath(allocator, codex_home, account_key) catch {
        try refresh_state.markCandidateChecked(allocator, account_key, now_ns);
        return .{ .visited = true };
    };
    defer allocator.free(auth_path);

    try refresh_state.markCandidateChecked(allocator, account_key, now_ns);
    const fetch_result = usage_fetcher(allocator, auth_path) catch {
        return .{
            .visited = true,
            .attempted = 1,
        };
    };
    if (fetch_result.missing_auth) {
        try refresh_state.markCandidateRejected(allocator, account_key);
        return .{
            .visited = true,
            .attempted = 1,
            .disqualify_for_switch = true,
        };
    }
    if (fetch_result.status_code) |status_code| {
        if (status_code != 200) {
            try refresh_state.markCandidateRejected(allocator, account_key);
            return .{
                .visited = true,
                .attempted = 1,
                .disqualify_for_switch = true,
            };
        }
    }

    const latest_usage = fetch_result.snapshot;
    if (latest_usage == null) {
        if (fetch_result.status_code != null) {
            try refresh_state.markCandidateRejected(allocator, account_key);
        }
        return .{
            .visited = true,
            .attempted = 1,
            .disqualify_for_switch = fetch_result.status_code != null,
        };
    }

    var latest = latest_usage.?;
    var snapshot_consumed = false;
    defer if (!snapshot_consumed) registry.freeRateLimitSnapshot(allocator, &latest);

    refresh_state.clearCandidateRejected(account_key);

    if (registry.rateLimitSnapshotsEqualIgnoringCreditBalance(rec.last_usage, latest)) {
        return .{ .visited = true, .attempted = 1 };
    }

    try registry.preserveCreditBalanceIfMissing(allocator, rec.last_usage, &latest);
    registry.updateUsage(allocator, reg, account_key, latest);
    snapshot_consumed = true;
    try refresh_state.candidate_index.upsertFromRegistry(allocator, reg, account_key, std.time.timestamp());
    return .{ .visited = true, .attempted = 1, .updated = 1 };
}

const CandidateUsageFetchTask = struct {
    account_key: []const u8,
    auth_path: []u8,
    fetch_result: ?usage_api.UsageFetchResult = null,
    fetch_error: ?anyerror = null,

    fn deinit(self: *CandidateUsageFetchTask, allocator: std.mem.Allocator) void {
        allocator.free(self.auth_path);
        if (self.fetch_result) |*result| {
            freeUsageFetchResult(worker_fetch_allocator, result);
        }
        self.fetch_result = null;
    }

    fn run(self: *CandidateUsageFetchTask, comptime usage_fetcher: anytype) void {
        self.fetch_result = usage_fetcher(worker_fetch_allocator, self.auth_path) catch |err| {
            self.fetch_error = err;
            return;
        };
    }
};

const AccountNameFetchTask = struct {
    chatgpt_user_id: []u8,
    access_token: []u8,
    chatgpt_account_id: []u8,
    fetch_result: ?account_api.FetchResult = null,
    fetch_error: ?anyerror = null,

    fn init(
        allocator: std.mem.Allocator,
        chatgpt_user_id: []const u8,
        access_token: []const u8,
        chatgpt_account_id: []const u8,
    ) !AccountNameFetchTask {
        return .{
            .chatgpt_user_id = try allocator.dupe(u8, chatgpt_user_id),
            .access_token = try allocator.dupe(u8, access_token),
            .chatgpt_account_id = try allocator.dupe(u8, chatgpt_account_id),
        };
    }

    fn deinit(self: *AccountNameFetchTask, allocator: std.mem.Allocator) void {
        allocator.free(self.chatgpt_user_id);
        allocator.free(self.access_token);
        allocator.free(self.chatgpt_account_id);
        if (self.fetch_result) |*result| {
            result.deinit(worker_fetch_allocator);
        }
        self.fetch_result = null;
    }

    fn run(self: *AccountNameFetchTask, comptime fetcher: anytype) void {
        self.fetch_result = fetcher(worker_fetch_allocator, self.access_token, self.chatgpt_account_id) catch |err| {
            self.fetch_error = err;
            return;
        };
    }
};

fn freeUsageFetchResult(allocator: std.mem.Allocator, result: *usage_api.UsageFetchResult) void {
    if (result.snapshot) |*snapshot| {
        registry.freeRateLimitSnapshot(allocator, snapshot);
    }
    result.snapshot = null;
}

fn runThreadBatch(
    comptime ThreadType: type,
    threads: []ThreadType,
    context: anytype,
    comptime spawn_one: anytype,
    comptime join_one: anytype,
) !void {
    var spawned_count: usize = 0;
    errdefer {
        var idx: usize = 0;
        while (idx < spawned_count) : (idx += 1) {
            join_one(context, &threads[idx]);
        }
    }

    for (threads, 0..) |*thread, idx| {
        thread.* = try spawn_one(context, idx);
        spawned_count += 1;
    }

    for (threads[0..spawned_count]) |*thread| {
        join_one(context, thread);
    }
}

fn runCandidateUsageFetchBatch(comptime usage_fetcher: anytype, tasks: []CandidateUsageFetchTask) !void {
    var threads: [candidate_parallel_fetch_limit]std.Thread = undefined;
    const Context = struct {
        tasks: []CandidateUsageFetchTask,
    };
    try runThreadBatch(std.Thread, threads[0..tasks.len], Context{ .tasks = tasks }, struct {
        fn spawn(ctx: Context, idx: usize) !std.Thread {
            return std.Thread.spawn(.{}, struct {
                fn run(job: *CandidateUsageFetchTask) void {
                    job.run(usage_fetcher);
                }
            }.run, .{&ctx.tasks[idx]});
        }
    }.spawn, struct {
        fn join(_: Context, thread: *std.Thread) void {
            thread.join();
        }
    }.join);
}

fn runAccountNameFetchBatch(comptime fetcher: anytype, tasks: []AccountNameFetchTask) !void {
    var threads: [account_name_parallel_fetch_limit]std.Thread = undefined;
    const Context = struct {
        tasks: []AccountNameFetchTask,
    };
    try runThreadBatch(std.Thread, threads[0..tasks.len], Context{ .tasks = tasks }, struct {
        fn spawn(ctx: Context, idx: usize) !std.Thread {
            return std.Thread.spawn(.{}, struct {
                fn run(job: *AccountNameFetchTask) void {
                    job.run(fetcher);
                }
            }.run, .{&ctx.tasks[idx]});
        }
    }.spawn, struct {
        fn join(_: Context, thread: *std.Thread) void {
            thread.join();
        }
    }.join);
}

fn collectNextDaemonCandidatesToValidate(
    allocator: std.mem.Allocator,
    refresh_state: *DaemonRefreshState,
    skipped_keys: []const []const u8,
    now_ns: i128,
    out_keys: [][]const u8,
) !usize {
    var ordered = try refresh_state.candidate_index.orderedKeys(allocator);
    defer ordered.deinit(allocator);

    var count: usize = 0;
    for (ordered.items) |account_key| {
        if (refresh_state.candidateIsRejected(account_key, now_ns)) continue;
        if (keyIsSkipped(skipped_keys, account_key)) continue;
        if (!refresh_state.candidateIsStale(account_key, now_ns)) continue;
        out_keys[count] = account_key;
        count += 1;
        if (count == out_keys.len) break;
    }
    return count;
}

fn refreshDaemonCandidateUsageBatchWithFetcher(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    refresh_state: *DaemonRefreshState,
    account_keys: []const []const u8,
    usage_fetcher: anytype,
    now_ns: i128,
    skipped_keys: ?*std.ArrayListUnmanaged([]const u8),
) !CandidateRefreshSummary {
    var summary: CandidateRefreshSummary = .{};
    var tasks: [candidate_parallel_fetch_limit]CandidateUsageFetchTask = undefined;
    var prepared_count: usize = 0;
    defer {
        for (tasks[0..prepared_count]) |*task| task.deinit(allocator);
    }

    for (account_keys) |account_key| {
        const idx = registry.findAccountIndexByAccountKey(reg, account_key) orelse continue;
        const rec = &reg.accounts.items[idx];
        if (rec.auth_mode != null and rec.auth_mode.? != .chatgpt) {
            try refresh_state.markCandidateChecked(allocator, account_key, now_ns);
            refresh_state.clearCandidateRejected(account_key);
            continue;
        }

        const auth_path = registry.accountAuthPath(allocator, codex_home, account_key) catch {
            try refresh_state.markCandidateChecked(allocator, account_key, now_ns);
            continue;
        };
        errdefer allocator.free(auth_path);
        try refresh_state.markCandidateChecked(allocator, account_key, now_ns);
        tasks[prepared_count] = .{
            .account_key = account_key,
            .auth_path = auth_path,
        };
        prepared_count += 1;
    }

    if (prepared_count == 0) return summary;
    try runCandidateUsageFetchBatch(usage_fetcher, tasks[0..prepared_count]);

    for (tasks[0..prepared_count]) |*task| {
        const result = try applyCandidateUsageFetchTaskResult(
            allocator,
            reg,
            refresh_state,
            task.account_key,
            task.fetch_result orelse .{ .snapshot = null, .status_code = null },
            task.fetch_error,
        );
        summary.attempted += result.attempted;
        summary.updated += result.updated;
        if (result.disqualify_for_switch) {
            if (skipped_keys) |list| {
                try list.append(allocator, task.account_key);
            }
        }
    }

    return summary;
}

fn applyCandidateUsageFetchTaskResult(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    refresh_state: *DaemonRefreshState,
    account_key: []const u8,
    fetch_result: usage_api.UsageFetchResult,
    fetch_error: ?anyerror,
) !SingleCandidateRefreshResult {
    const idx = registry.findAccountIndexByAccountKey(reg, account_key) orelse return .{};
    const rec = &reg.accounts.items[idx];

    if (fetch_error != null) {
        return .{
            .visited = true,
            .attempted = 1,
        };
    }

    if (fetch_result.missing_auth) {
        try refresh_state.markCandidateRejected(allocator, account_key);
        return .{
            .visited = true,
            .attempted = 1,
            .disqualify_for_switch = true,
        };
    }
    if (fetch_result.status_code) |status_code| {
        if (status_code != 200) {
            try refresh_state.markCandidateRejected(allocator, account_key);
            return .{
                .visited = true,
                .attempted = 1,
                .disqualify_for_switch = true,
            };
        }
    }

    const latest_usage = fetch_result.snapshot;
    if (latest_usage == null) {
        if (fetch_result.status_code != null) {
            try refresh_state.markCandidateRejected(allocator, account_key);
        }
        return .{
            .visited = true,
            .attempted = 1,
            .disqualify_for_switch = fetch_result.status_code != null,
        };
    }

    refresh_state.clearCandidateRejected(account_key);

    if (registry.rateLimitSnapshotsEqualIgnoringCreditBalance(rec.last_usage, latest_usage.?)) {
        return .{ .visited = true, .attempted = 1 };
    }

    const cloned = try registry.cloneRateLimitSnapshot(allocator, latest_usage.?);
    var normalized = cloned;
    errdefer registry.freeRateLimitSnapshot(allocator, &normalized);
    try registry.preserveCreditBalanceIfMissing(allocator, rec.last_usage, &normalized);
    registry.updateUsage(allocator, reg, account_key, normalized);
    try refresh_state.candidate_index.upsertFromRegistry(allocator, reg, account_key, std.time.timestamp());
    return .{ .visited = true, .attempted = 1, .updated = 1 };
}

const Resolved5hWindow = struct {
    window: ?registry.RateLimitWindow,
    allow_free_guard: bool,
};

fn resolve5hTriggerWindow(usage: ?registry.RateLimitSnapshot) Resolved5hWindow {
    if (usage == null) return .{ .window = null, .allow_free_guard = false };
    if (usage.?.primary) |primary| {
        if (primary.window_minutes == null) {
            return .{ .window = primary, .allow_free_guard = true };
        }
        if (primary.window_minutes.? == 300) {
            return .{ .window = primary, .allow_free_guard = true };
        }
    }
    if (usage.?.secondary) |secondary| {
        if (secondary.window_minutes != null and secondary.window_minutes.? == 300) {
            return .{ .window = secondary, .allow_free_guard = true };
        }
    }
    if (usage.?.primary) |primary| {
        return .{ .window = primary, .allow_free_guard = false };
    }
    return .{ .window = null, .allow_free_guard = false };
}

fn processFailoverQueueWithUsageFetcher(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    refresh_state: *DaemonRefreshState,
    usage_fetcher: anytype,
) !bool {
    var changed = try normalizeBlockedAccountState(allocator, reg, std.time.timestamp());
    if (changed) {
        try refresh_state.rebuildCandidateState(allocator);
    }
    if (reg.auto_switch.mode != .failover) return changed;

    var switch_lock = (try SwitchCoordinatorLock.acquire(allocator, codex_home)) orelse return changed;
    defer switch_lock.release();

    var claimed = (try claimNextFailoverEvent(allocator, codex_home)) orelse {
        if (reg.auto_switch.failover_state == .processing) {
            reg.auto_switch.failover_state = .idle;
            changed = true;
        }
        return changed;
    };
    defer claimed.deinit(allocator);

    reg.auto_switch.failover_state = .processing;
    changed = true;

    var event = loadClaimedFailoverEvent(allocator, &claimed) catch {
        reg.auto_switch.failover_state = .@"error";
        try archiveClaimedFailoverEvent(&claimed);
        return true;
    };
    defer event.deinit(allocator);

    const current_source_key = (try failoverEventMatchesCurrentAuth(allocator, codex_home, &event)) orelse {
        reg.auto_switch.failover_state = .stale_event;
        try archiveClaimedFailoverEvent(&claimed);
        return true;
    };
    defer allocator.free(current_source_key);

    const source_idx = registry.findAccountIndexByAccountKey(reg, current_source_key) orelse {
        reg.auto_switch.failover_state = .stale_event;
        try archiveClaimedFailoverEvent(&claimed);
        return true;
    };
    const source_key = reg.accounts.items[source_idx].account_key;
    try registry.setBlockedAccount(allocator, reg, source_key, event.resets_at_ms);
    changed = true;
    try refresh_state.rebuildCandidateState(allocator);

    if (reg.api.usage and (try refreshBestSwitchCandidatesForForegroundWithUsageFetcher(
        allocator,
        codex_home,
        reg,
        usage_fetcher,
    ))) {
        changed = true;
    }

    const target_idx = bestFreshKnownAccountIndexExcluding(reg, source_key, &.{}) orelse {
        reg.auto_switch.failover_state = .no_target;
        try refresh_state.rebuildCandidateState(allocator);
        try archiveClaimedFailoverEvent(&claimed);
        return true;
    };
    const target_key = reg.accounts.items[target_idx].account_key;
    if (std.mem.eql(u8, target_key, source_key)) {
        reg.auto_switch.failover_state = .no_target;
        try refresh_state.rebuildCandidateState(allocator);
        try archiveClaimedFailoverEvent(&claimed);
        return true;
    }

    try registry.activateAccountByKey(allocator, codex_home, reg, target_key);
    reg.auto_switch.failover_state = .switched;
    try refresh_state.rebuildCandidateState(allocator);
    try archiveClaimedFailoverEvent(&claimed);
    return true;
}

fn daemonCycleWithAccountNameFetcher(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    refresh_state: *DaemonRefreshState,
    account_name_fetcher: anytype,
) !bool {
    var reg = try refresh_state.ensureRegistryLoaded(allocator, codex_home);
    if (!reg.auto_switch.enabled) return false;

    var changed = false;
    if (try refresh_state.syncActiveAuthIfChanged(allocator, codex_home)) {
        changed = true;
    }

    if (changed) {
        try registry.saveRegistry(allocator, codex_home, reg);
        try refresh_state.refreshTrackedFileMtims(allocator, codex_home);
        changed = false;
    }

    if (try refreshActiveAccountNamesForDaemonWithFetcher(allocator, codex_home, reg, refresh_state, account_name_fetcher)) {
        changed = true;
    }
    try refresh_state.reloadRegistryStateIfChanged(allocator, codex_home);
    reg = refresh_state.currentRegistry();
    if (!reg.auto_switch.enabled) return true;

    if (try refreshActiveUsageForDaemon(allocator, codex_home, reg, refresh_state)) {
        changed = true;
    }
    if (try processFailoverQueueWithUsageFetcher(
        allocator,
        codex_home,
        reg,
        refresh_state,
        usage_api.fetchUsageForAuthPathDetailed,
    )) {
        changed = true;
    }
    const active_idx_before = if (reg.active_account_key) |account_key|
        registry.findAccountIndexByAccountKey(reg, account_key)
    else
        null;
    const auto_switch_attempt = try maybeAutoSwitchForDaemonWithUsageFetcher(allocator, codex_home, reg, refresh_state, usage_api.fetchUsageForAuthPathDetailed);
    if (auto_switch_attempt.state_changed or auto_switch_attempt.switched) {
        changed = true;
    }
    if (auto_switch_attempt.switched) {
        if (active_idx_before) |from_idx| {
            if (reg.active_account_key) |account_key| {
                if (registry.findAccountIndexByAccountKey(reg, account_key)) |to_idx| {
                    emitAutoSwitchLog(&reg.accounts.items[from_idx], &reg.accounts.items[to_idx]);
                }
            }
        }
    }

    if (changed) {
        try registry.saveRegistry(allocator, codex_home, reg);
        try refresh_state.refreshTrackedFileMtims(allocator, codex_home);
    }
    return true;
}

fn daemonCycle(allocator: std.mem.Allocator, codex_home: []const u8, refresh_state: *DaemonRefreshState) !bool {
    return daemonCycleWithAccountNameFetcher(allocator, codex_home, refresh_state, fetchActiveAccountNames);
}

pub fn daemonCycleWithAccountNameFetcherForTest(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    refresh_state: *DaemonRefreshState,
    account_name_fetcher: anytype,
) !bool {
    return daemonCycleWithAccountNameFetcher(allocator, codex_home, refresh_state, account_name_fetcher);
}

fn enable(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    const self_exe = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(self_exe);
    const managed_self_exe = try managedServiceSelfExePath(allocator, self_exe);
    defer allocator.free(managed_self_exe);
    try enableWithServiceHooks(allocator, codex_home, managed_self_exe, installService, uninstallService);
}

fn ensureAutoSwitchCanEnable(allocator: std.mem.Allocator) !void {
    if (builtin.os.tag == .linux and !linuxUserSystemdAvailable(allocator)) {
        std.log.err("cannot enable auto-switch: systemd --user is unavailable", .{});
        return error.CommandFailed;
    }
}

pub fn enableWithServiceHooks(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    self_exe: []const u8,
    installer: anytype,
    uninstaller: anytype,
) !void {
    try enableWithServiceHooksAndPreflight(
        allocator,
        codex_home,
        self_exe,
        installer,
        uninstaller,
        ensureAutoSwitchCanEnable,
    );
}

pub fn enableWithServiceHooksAndPreflight(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    self_exe: []const u8,
    installer: anytype,
    uninstaller: anytype,
    preflight: anytype,
) !void {
    try preflight(allocator);

    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);

    reg.auto_switch.enabled = true;
    try registry.saveRegistry(allocator, codex_home, &reg);
    errdefer {
        reg.auto_switch.enabled = false;
        registry.saveRegistry(allocator, codex_home, &reg) catch {};
    }
    // Service installation can partially succeed on some platforms, so clean up
    // any managed artifacts before persisting the disabled rollback state.
    errdefer uninstaller(allocator, codex_home) catch {};
    try installer(allocator, codex_home, self_exe);
    printAutoEnableUsageNote(reg.api.usage) catch |err| {
        std.log.warn("failed to print auto-enable usage note: {}", .{err});
    };
}

fn printAutoEnableUsageNote(api_enabled: bool) !void {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    if (api_enabled) {
        try out.writeAll("auto-switch enabled; usage mode: api (default, most accurate for switching decisions)\n");
    } else {
        try out.writeAll("auto-switch enabled; usage mode: local-only (switching still works, but candidate validation is less accurate)\n");
        try out.writeAll("Tip: run `codex-auth config api enable` for the most accurate switching decisions.\n");
    }
    try out.flush();
}

fn disable(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    reg.auto_switch.enabled = false;
    try registry.saveRegistry(allocator, codex_home, &reg);
    try uninstallService(allocator, codex_home);
}

pub fn applyThresholdConfig(cfg: *registry.AutoSwitchConfig, opts: cli.AutoThresholdOptions) void {
    if (opts.threshold_5h_percent) |value| {
        cfg.threshold_5h_percent = value;
    }
    if (opts.threshold_weekly_percent) |value| {
        cfg.threshold_weekly_percent = value;
    }
}

fn configureThresholds(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.AutoThresholdOptions) !void {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    applyThresholdConfig(&reg.auto_switch, opts);
    try registry.saveRegistry(allocator, codex_home, &reg);
    try printStatus(allocator, codex_home);
}

fn configureMode(allocator: std.mem.Allocator, codex_home: []const u8, mode: registry.AutoSwitchMode) !void {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    reg.auto_switch.mode = mode;
    reg.auto_switch.failover_state = .idle;
    if (mode != .pinned) {
        try registry.setPinnedAccountKey(allocator, &reg, null);
    }
    try registry.saveRegistry(allocator, codex_home, &reg);
    try printStatus(allocator, codex_home);
}

const ResolvedCandidate5hWindow = struct {
    window: ?registry.RateLimitWindow,
    allow_free_guard: bool,
};

const RankedHeadroom = struct {
    effective_remaining: i64,
    weekly_remaining: i64,
    effective_resets_at: i64,
};

fn resolve5hCandidateWindow(usage: ?registry.RateLimitSnapshot) ResolvedCandidate5hWindow {
    if (usage == null) return .{ .window = null, .allow_free_guard = false };
    if (usage.?.primary) |primary| {
        if (primary.window_minutes == null) {
            return .{ .window = primary, .allow_free_guard = true };
        }
        if (primary.window_minutes.? == 300) {
            return .{ .window = primary, .allow_free_guard = true };
        }
    }
    if (usage.?.secondary) |secondary| {
        if (secondary.window_minutes != null and secondary.window_minutes.? == 300) {
            return .{ .window = secondary, .allow_free_guard = true };
        }
    }
    return .{ .window = null, .allow_free_guard = false };
}

fn resetAtOrMax(window: ?registry.RateLimitWindow) i64 {
    if (window) |resolved| {
        if (resolved.resets_at) |reset_at| return reset_at;
    }
    return std.math.maxInt(i64);
}

fn rankedHeadroom(rec: *const registry.AccountRecord, now: i64) ?RankedHeadroom {
    if (registry.accountSnapshotFreshness(rec, now) != .fresh) return null;

    const resolved_5h = resolve5hCandidateWindow(rec.last_usage);
    const weekly_window = registry.resolveRateWindow(rec.last_usage, 10080, false);
    const rem_5h = registry.remainingPercentAt(resolved_5h.window, now);
    const rem_week = registry.remainingPercentAt(weekly_window, now);
    const effective_remaining = rem_5h orelse rem_week orelse return null;
    const effective_resets_at = if (rem_5h != null)
        resetAtOrMax(resolved_5h.window)
    else
        resetAtOrMax(weekly_window);

    return .{
        .effective_remaining = effective_remaining,
        .weekly_remaining = rem_week orelse effective_remaining,
        .effective_resets_at = effective_resets_at,
    };
}

fn buildCandidateScore(rec: *const registry.AccountRecord, headroom: RankedHeadroom) CandidateScore {
    return .{
        .effective_remaining = headroom.effective_remaining,
        .weekly_remaining = headroom.weekly_remaining,
        .effective_resets_at = headroom.effective_resets_at,
        .last_usage_at = rec.last_usage_at orelse -1,
        .last_used_at = rec.last_used_at orelse -1,
        .refresh_only = false,
        .alias = rec.alias,
        .email = rec.email,
        .account_key = rec.account_key,
    };
}

fn refreshPlaceholderScore(rec: *const registry.AccountRecord) CandidateScore {
    return .{
        .effective_remaining = -1,
        .weekly_remaining = -1,
        .effective_resets_at = std.math.maxInt(i64),
        .last_usage_at = rec.last_usage_at orelse -1,
        .last_used_at = rec.last_used_at orelse -1,
        .refresh_only = true,
        .alias = rec.alias,
        .email = rec.email,
        .account_key = rec.account_key,
    };
}

fn rankedHeadroomIgnoringFreshness(rec: *const registry.AccountRecord, now: i64) ?RankedHeadroom {
    const resolved_5h = resolve5hCandidateWindow(rec.last_usage);
    const weekly_window = registry.resolveRateWindow(rec.last_usage, 10080, false);
    const rem_5h = registry.remainingPercentAt(resolved_5h.window, now);
    const rem_week = registry.remainingPercentAt(weekly_window, now);
    const effective_remaining = rem_5h orelse rem_week orelse return null;
    const effective_resets_at = if (rem_5h != null)
        resetAtOrMax(resolved_5h.window)
    else
        resetAtOrMax(weekly_window);

    return .{
        .effective_remaining = effective_remaining,
        .weekly_remaining = rem_week orelse effective_remaining,
        .effective_resets_at = effective_resets_at,
    };
}

fn bestKnownRefreshScore(rec: *const registry.AccountRecord, now: i64) ?CandidateScore {
    if (rec.auth_mode != null and rec.auth_mode.? == .apikey) return null;
    if (bestKnownQuotaScore(rec, now)) |score| return score;

    if (rankedHeadroomIgnoringFreshness(rec, now)) |headroom| {
        var score = buildCandidateScore(rec, headroom);
        score.refresh_only = true;
        return score;
    }

    return refreshPlaceholderScore(rec);
}

fn currentScore(rec: *const registry.AccountRecord, now: i64) ?CandidateScore {
    return bestKnownQuotaScore(rec, now);
}

fn candidateBeatsCurrent(
    reg: *registry.Registry,
    active_idx: usize,
    candidate_idx: usize,
    now: i64,
) bool {
    const candidate = candidateScore(&reg.accounts.items[candidate_idx], reg.auto_switch, now) orelse return false;
    const current = currentScore(&reg.accounts.items[active_idx], now) orelse return true;
    return candidateBetter(candidate, current);
}

pub fn bestEligibleAccountIndex(reg: *registry.Registry) ?usize {
    return bestEligibleAccountIndexExcluding(reg, null, &.{});
}

pub fn bestFreshKnownAccountIndex(reg: *registry.Registry) ?usize {
    return bestFreshKnownAccountIndexExcluding(reg, null, &.{});
}

pub fn bestEligibleAccountIndexExcluding(
    reg: *registry.Registry,
    excluded_account_key: ?[]const u8,
    excluded_indices: []const usize,
) ?usize {
    if (reg.accounts.items.len == 0) return null;
    const now = std.time.timestamp();
    return bestEligibleAccountIndexAt(reg, now, excluded_account_key, excluded_indices);
}

pub fn bestFreshKnownAccountIndexExcluding(
    reg: *registry.Registry,
    excluded_account_key: ?[]const u8,
    excluded_indices: []const usize,
) ?usize {
    if (reg.accounts.items.len == 0) return null;
    const now = std.time.timestamp();
    return bestFreshKnownAccountIndexAt(reg, now, excluded_account_key, excluded_indices);
}

fn bestEligibleAccountIndexAt(
    reg: *registry.Registry,
    now: i64,
    excluded_account_key: ?[]const u8,
    excluded_indices: []const usize,
) ?usize {
    var best_idx: ?usize = null;
    var best: ?CandidateScore = null;
    for (reg.accounts.items, 0..) |*rec, idx| {
        if (excluded_account_key) |account_key| {
            if (std.mem.eql(u8, rec.account_key, account_key)) continue;
        }
        if (selectionContainsIndex(excluded_indices, idx)) continue;
        if (accountIsBlocked(reg, rec.account_key, now)) continue;
        const score = candidateScore(rec, reg.auto_switch, now) orelse continue;
        if (best == null or candidateBetter(score, best.?)) {
            best = score;
            best_idx = idx;
        }
    }
    return best_idx;
}

fn bestFreshKnownAccountIndexAt(
    reg: *registry.Registry,
    now: i64,
    excluded_account_key: ?[]const u8,
    excluded_indices: []const usize,
) ?usize {
    var best_idx: ?usize = null;
    var best: ?CandidateScore = null;
    for (reg.accounts.items, 0..) |*rec, idx| {
        if (excluded_account_key) |account_key| {
            if (std.mem.eql(u8, rec.account_key, account_key)) continue;
        }
        if (selectionContainsIndex(excluded_indices, idx)) continue;
        if (accountIsBlocked(reg, rec.account_key, now)) continue;
        const score = bestKnownQuotaScore(rec, now) orelse continue;
        if (best == null or candidateBetter(score, best.?)) {
            best = score;
            best_idx = idx;
        }
    }
    return best_idx;
}

fn selectionContainsIndex(indices: []const usize, target: usize) bool {
    for (indices) |idx| {
        if (idx == target) return true;
    }
    return false;
}

fn bestKnownQuotaScore(rec: *const registry.AccountRecord, now: i64) ?CandidateScore {
    if (!registry.accountAuthSelectable(rec)) return null;
    if (rec.auth_mode != null and rec.auth_mode.? == .apikey) return null;
    const headroom = rankedHeadroom(rec, now) orelse return null;
    return buildCandidateScore(rec, headroom);
}

fn collectBestKnownCandidatesToValidate(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    skipped_keys: []const []const u8,
    now: i64,
    out_keys: [][]const u8,
) !usize {
    var candidates = std.ArrayList(CandidateEntry).empty;
    defer candidates.deinit(allocator);

    const active = reg.active_account_key;
    for (reg.accounts.items) |*rec| {
        if (active) |active_key| {
            if (std.mem.eql(u8, rec.account_key, active_key)) continue;
        }
        if (accountIsBlocked(reg, rec.account_key, now)) continue;
        if (registry.accountSnapshotFreshness(rec, now) == .fresh) continue;
        const score = bestKnownRefreshScore(rec, now) orelse continue;
        try candidates.append(allocator, .{
            .account_key = rec.account_key,
            .score = score,
        });
    }

    std.mem.sort(CandidateEntry, candidates.items, {}, struct {
        fn lessThan(_: void, a: CandidateEntry, b: CandidateEntry) bool {
            return candidateRefreshBetter(a.score, b.score);
        }
    }.lessThan);

    var count: usize = 0;
    for (candidates.items) |candidate| {
        if (keyIsSkipped(skipped_keys, candidate.account_key)) continue;
        out_keys[count] = candidate.account_key;
        count += 1;
        if (count == out_keys.len) break;
    }
    return count;
}

fn candidateScore(rec: *const registry.AccountRecord, cfg: registry.AutoSwitchConfig, now: i64) ?CandidateScore {
    const base = bestKnownQuotaScore(rec, now) orelse return null;

    const resolved_5h = resolve5hCandidateWindow(rec.last_usage);
    const threshold_5h_percent = effective5hThresholdPercent(cfg, rec, resolved_5h.allow_free_guard);
    const rem_5h = registry.remainingPercentAt(resolved_5h.window, now);
    const rem_week = registry.remainingPercentAt(registry.resolveRateWindow(rec.last_usage, 10080, false), now);

    if (rem_5h != null and rem_5h.? < threshold_5h_percent) return null;
    if (rem_week != null and rem_week.? < @as(i64, cfg.threshold_weekly_percent)) return null;

    return base;
}

fn daemonCandidateScore(
    rec: *const registry.AccountRecord,
    reg: *const registry.Registry,
    now: i64,
) ?CandidateScore {
    if (candidateScore(rec, reg.auto_switch, now)) |score| return score;
    if (!reg.api.usage) return null;
    if (rec.auth_mode != null and rec.auth_mode.? != .chatgpt) return null;
    return refreshPlaceholderScore(rec);
}

fn candidateBetter(a: CandidateScore, b: CandidateScore) bool {
    if (a.refresh_only != b.refresh_only) return !a.refresh_only;
    if (a.effective_remaining != b.effective_remaining) return a.effective_remaining > b.effective_remaining;
    if (a.weekly_remaining != b.weekly_remaining) return a.weekly_remaining > b.weekly_remaining;
    if (a.effective_resets_at != b.effective_resets_at) return a.effective_resets_at < b.effective_resets_at;
    if (a.last_usage_at != b.last_usage_at) return a.last_usage_at > b.last_usage_at;
    if (a.last_used_at != b.last_used_at) return a.last_used_at > b.last_used_at;

    const a_primary = if (a.alias.len != 0) a.alias else a.email;
    const b_primary = if (b.alias.len != 0) b.alias else b.email;
    const primary_cmp = std.mem.order(u8, a_primary, b_primary);
    if (primary_cmp != .eq) return primary_cmp == .lt;

    const email_cmp = std.mem.order(u8, a.email, b.email);
    if (email_cmp != .eq) return email_cmp == .lt;

    return std.mem.order(u8, a.account_key, b.account_key) == .lt;
}

fn candidateRefreshBetter(a: CandidateScore, b: CandidateScore) bool {
    if (a.refresh_only != b.refresh_only) return a.refresh_only;
    return candidateBetter(a, b);
}

fn candidateScoreChangeAt(rec: *const registry.AccountRecord, now: i64) ?i64 {
    if (rec.last_usage == null) return null;
    var next_change_at: ?i64 = null;
    if (rec.last_usage_at) |last_usage_at| {
        next_change_at = earlierFutureTimestamp(
            next_change_at,
            last_usage_at + registry.local_snapshot_max_age_seconds + 1,
            now,
        );
    }
    if (rec.last_usage.?.primary) |window| {
        next_change_at = earlierFutureTimestamp(next_change_at, window.resets_at, now);
    }
    if (rec.last_usage.?.secondary) |window| {
        next_change_at = earlierFutureTimestamp(next_change_at, window.resets_at, now);
    }
    return next_change_at;
}

fn earlierFutureTimestamp(current: ?i64, candidate: ?i64, now: i64) ?i64 {
    if (candidate == null or candidate.? <= now) return current;
    if (current == null) return candidate.?;
    return @min(current.?, candidate.?);
}

fn queryRuntimeState(allocator: std.mem.Allocator) RuntimeState {
    return switch (builtin.os.tag) {
        .linux => queryLinuxRuntimeState(allocator),
        .macos => queryMacRuntimeState(allocator),
        .windows => queryWindowsRuntimeState(allocator),
        else => .unknown,
    };
}

fn installService(allocator: std.mem.Allocator, codex_home: []const u8, self_exe: []const u8) !void {
    switch (builtin.os.tag) {
        .linux => try installLinuxService(allocator, codex_home, self_exe),
        .macos => try installMacService(allocator, codex_home, self_exe),
        .windows => try installWindowsService(allocator, codex_home, self_exe),
        else => return error.UnsupportedPlatform,
    }
}

fn uninstallService(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    switch (builtin.os.tag) {
        .linux => try uninstallLinuxService(allocator, codex_home),
        .macos => try uninstallMacService(allocator, codex_home),
        .windows => try uninstallWindowsService(allocator),
        else => return error.UnsupportedPlatform,
    }
}

fn installLinuxService(allocator: std.mem.Allocator, codex_home: []const u8, self_exe: []const u8) !void {
    const unit_path = try linuxUnitPath(allocator, linux_service_name);
    defer allocator.free(unit_path);
    const unit_text = try linuxUnitText(allocator, self_exe, codex_home);
    defer allocator.free(unit_text);

    const unit_dir = std.fs.path.dirname(unit_path).?;
    try std.fs.cwd().makePath(unit_dir);
    try std.fs.cwd().writeFile(.{ .sub_path = unit_path, .data = unit_text });
    try removeLinuxUnit(allocator, linux_timer_name);
    try runChecked(allocator, &[_][]const u8{ "systemctl", "--user", "daemon-reload" });
    try runChecked(allocator, &[_][]const u8{ "systemctl", "--user", "enable", linux_service_name });
    switch (queryLinuxRuntimeState(allocator)) {
        .running => try runChecked(allocator, &[_][]const u8{ "systemctl", "--user", "restart", linux_service_name }),
        else => try runChecked(allocator, &[_][]const u8{ "systemctl", "--user", "start", linux_service_name }),
    }
}

fn uninstallLinuxService(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    _ = codex_home;
    try removeLinuxUnit(allocator, linux_timer_name);
    try removeLinuxUnit(allocator, linux_service_name);
}

fn removeLinuxUnit(allocator: std.mem.Allocator, service_name: []const u8) !void {
    const unit_path = try linuxUnitPath(allocator, service_name);
    defer allocator.free(unit_path);
    runIgnoringFailure(allocator, &[_][]const u8{ "systemctl", "--user", "stop", service_name });
    runIgnoringFailure(allocator, &[_][]const u8{ "systemctl", "--user", "disable", service_name });
    runIgnoringFailure(allocator, &[_][]const u8{ "systemctl", "--user", "reset-failed", service_name });
    deleteAbsoluteFileIfExists(unit_path);
    runIgnoringFailure(allocator, &[_][]const u8{ "systemctl", "--user", "daemon-reload" });
}

fn linuxUserSystemdAvailable(allocator: std.mem.Allocator) bool {
    const result = runCapture(allocator, &[_][]const u8{ "systemctl", "--user", "show-environment" }) catch return false;
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    return switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

fn installMacService(allocator: std.mem.Allocator, codex_home: []const u8, self_exe: []const u8) !void {
    const plist_path = try macPlistPath(allocator);
    defer allocator.free(plist_path);
    const plist = try macPlistText(allocator, self_exe, codex_home);
    defer allocator.free(plist);

    const dir = std.fs.path.dirname(plist_path).?;
    try std.fs.cwd().makePath(dir);
    try std.fs.cwd().writeFile(.{ .sub_path = plist_path, .data = plist });
    _ = runChecked(allocator, &[_][]const u8{ "launchctl", "unload", plist_path }) catch {};
    try runChecked(allocator, &[_][]const u8{ "launchctl", "load", plist_path });
}

fn uninstallMacService(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    _ = codex_home;
    const plist_path = try macPlistPath(allocator);
    defer allocator.free(plist_path);
    _ = runChecked(allocator, &[_][]const u8{ "launchctl", "unload", plist_path }) catch {};
    deleteAbsoluteFileIfExists(plist_path);
}

pub fn deleteAbsoluteFileIfExists(path: []const u8) void {
    std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => {},
    };
}

fn installWindowsService(allocator: std.mem.Allocator, codex_home: []const u8, self_exe: []const u8) !void {
    _ = codex_home;
    const helper_path = try windowsHelperPath(allocator, self_exe);
    defer allocator.free(helper_path);
    try std.fs.cwd().access(helper_path, .{});

    const register_script = try windowsRegisterTaskScript(allocator, helper_path);
    defer allocator.free(register_script);
    const end_script = try windowsEndTaskScript(allocator);
    defer allocator.free(end_script);
    _ = runChecked(allocator, &[_][]const u8{
        "powershell.exe",
        "-NoLogo",
        "-NoProfile",
        "-Command",
        end_script,
    }) catch {};
    try runChecked(allocator, &[_][]const u8{
        "powershell.exe",
        "-NoLogo",
        "-NoProfile",
        "-Command",
        register_script,
    });
    try runChecked(allocator, &[_][]const u8{
        "schtasks",
        "/Run",
        "/TN",
        windows_task_name,
    });
}

fn uninstallWindowsService(allocator: std.mem.Allocator) !void {
    const script = try windowsDeleteTaskScript(allocator);
    defer allocator.free(script);
    try runChecked(allocator, &[_][]const u8{
        "powershell.exe",
        "-NoLogo",
        "-NoProfile",
        "-Command",
        script,
    });
}

fn queryLinuxRuntimeState(allocator: std.mem.Allocator) RuntimeState {
    const result = runCapture(allocator, &[_][]const u8{ "systemctl", "--user", "is-active", linux_service_name }) catch return .unknown;
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    return switch (result.term) {
        .Exited => |code| if (code == 0 and std.mem.startsWith(u8, std.mem.trim(u8, result.stdout, " \n\r\t"), "active")) .running else .stopped,
        else => .unknown,
    };
}

fn queryMacRuntimeState(allocator: std.mem.Allocator) RuntimeState {
    const plist_path = macPlistPath(allocator) catch return .unknown;
    defer allocator.free(plist_path);
    const result = runCapture(allocator, &[_][]const u8{ "launchctl", "list", mac_label }) catch return .unknown;
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    return switch (result.term) {
        .Exited => |code| if (code == 0) .running else .stopped,
        else => .unknown,
    };
}

fn queryWindowsRuntimeState(allocator: std.mem.Allocator) RuntimeState {
    const script = windowsTaskStateScript();
    const result = runCapture(allocator, &[_][]const u8{
        "powershell.exe",
        "-NoLogo",
        "-NoProfile",
        "-Command",
        script,
    }) catch return .unknown;
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    return switch (result.term) {
        .Exited => |code| if (code == 0) parseWindowsTaskStateOutput(result.stdout) else if (code == 1) .stopped else .unknown,
        else => .unknown,
    };
}

pub fn linuxUnitText(allocator: std.mem.Allocator, self_exe: []const u8, codex_home: []const u8) ![]u8 {
    _ = codex_home;
    const exec = try std.fmt.allocPrint(allocator, "\"{s}\" daemon --watch", .{self_exe});
    defer allocator.free(exec);
    const escaped_version = try escapeSystemdValue(allocator, version.app_version);
    defer allocator.free(escaped_version);
    return try std.fmt.allocPrint(
        allocator,
        "[Unit]\nDescription=codex-auth auto-switch watcher\n\n[Service]\nType=simple\nRestart=on-failure\nRestartSec=1\nEnvironment=\"{s}={s}\"\nExecStart={s}\n\n[Install]\nWantedBy=default.target\n",
        .{
            service_version_env_name,
            escaped_version,
            exec,
        },
    );
}

pub fn macPlistText(allocator: std.mem.Allocator, self_exe: []const u8, codex_home: []const u8) ![]u8 {
    _ = codex_home;
    const exe = try escapeXml(allocator, self_exe);
    defer allocator.free(exe);
    const current_version = try escapeXml(allocator, version.app_version);
    defer allocator.free(current_version);
    return try std.fmt.allocPrint(
        allocator,
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n  <key>Label</key>\n  <string>{s}</string>\n  <key>ProgramArguments</key>\n  <array>\n    <string>{s}</string>\n    <string>daemon</string>\n    <string>--watch</string>\n  </array>\n  <key>EnvironmentVariables</key>\n  <dict>\n    <key>{s}</key>\n    <string>{s}</string>\n  </dict>\n  <key>RunAtLoad</key>\n  <true/>\n  <key>KeepAlive</key>\n  <true/>\n</dict>\n</plist>\n",
        .{ mac_label, exe, service_version_env_name, current_version },
    );
}

pub fn windowsTaskAction(allocator: std.mem.Allocator, helper_path: []const u8) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "\"{s}\" --service-version {s}",
        .{ helper_path, version.app_version },
    );
}

pub fn windowsRegisterTaskScript(allocator: std.mem.Allocator, helper_path: []const u8) ![]u8 {
    const escaped_helper_path = try escapePowerShellSingleQuoted(allocator, helper_path);
    defer allocator.free(escaped_helper_path);
    const escaped_version = try escapePowerShellSingleQuoted(allocator, version.app_version);
    defer allocator.free(escaped_version);
    return try std.fmt.allocPrint(
        allocator,
        "$action = New-ScheduledTaskAction -Execute '{s}' -Argument '--service-version {s}'; $trigger = New-ScheduledTaskTrigger -AtLogOn; $settings = New-ScheduledTaskSettingsSet -RestartCount {s} -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Seconds 0); Register-ScheduledTask -TaskName '{s}' -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null",
        .{ escaped_helper_path, escaped_version, windows_task_restart_count, windows_task_name },
    );
}

pub fn windowsTaskMatchScript(allocator: std.mem.Allocator) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "$task = Get-ScheduledTask -TaskName '{s}' -ErrorAction SilentlyContinue; if ($null -eq $task) {{ exit 1 }}; $action = $task.Actions | Select-Object -First 1; if ($null -eq $action) {{ exit 2 }}; $xml = [xml](Export-ScheduledTask -TaskName '{s}'); $triggers = @($xml.Task.Triggers.ChildNodes | Where-Object {{ $_.NodeType -eq [System.Xml.XmlNodeType]::Element }}); if ($triggers.Count -ne 1) {{ exit 3 }}; $triggerKind = [string]$triggers[0].LocalName; if ([string]::IsNullOrWhiteSpace($triggerKind)) {{ exit 4 }}; $restartNode = $xml.Task.Settings.RestartOnFailure; if ($null -eq $restartNode) {{ exit 5 }}; $restartCount = [string]$restartNode.Count; $restartInterval = [string]$restartNode.Interval; if ([string]::IsNullOrWhiteSpace($restartCount) -or [string]::IsNullOrWhiteSpace($restartInterval)) {{ exit 6 }}; $executionLimit = [string]$xml.Task.Settings.ExecutionTimeLimit; if ([string]::IsNullOrWhiteSpace($executionLimit)) {{ exit 7 }}; $args = if ([string]::IsNullOrWhiteSpace($action.Arguments)) {{ '' }} else {{ ' ' + $action.Arguments }}; Write-Output ($action.Execute + $args + '|TRIGGER:' + $triggerKind + '|RESTART:' + $restartCount + ',' + $restartInterval + '|LIMIT:' + $executionLimit)",
        .{ windows_task_name, windows_task_name },
    );
}

pub fn windowsEndTaskScript(allocator: std.mem.Allocator) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "$task = Get-ScheduledTask -TaskName '{s}' -ErrorAction SilentlyContinue; if ($null -eq $task) {{ exit 0 }}; if ($task.State -eq 4) {{ Stop-ScheduledTask -TaskName '{s}' -ErrorAction SilentlyContinue }}",
        .{ windows_task_name, windows_task_name },
    );
}

pub fn windowsDeleteTaskScript(allocator: std.mem.Allocator) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "$task = Get-ScheduledTask -TaskName '{s}' -ErrorAction SilentlyContinue; if ($null -eq $task) {{ exit 0 }}; Unregister-ScheduledTask -TaskName '{s}' -Confirm:$false",
        .{ windows_task_name, windows_task_name },
    );
}

pub fn windowsTaskStateScript() []const u8 {
    return "$task = Get-ScheduledTask -TaskName '" ++ windows_task_name ++ "' -ErrorAction SilentlyContinue; if ($null -eq $task) { exit 1 }; Write-Output ([int]$task.State)";
}

pub fn parseWindowsTaskStateOutput(output: []const u8) RuntimeState {
    const trimmed = std.mem.trim(u8, output, " \n\r\t");
    if (trimmed.len == 0) return .unknown;
    const value = std.fmt.parseInt(u8, trimmed, 10) catch return .unknown;
    return switch (value) {
        4 => .running,
        0, 1, 2, 3 => .stopped,
        else => .unknown,
    };
}

fn linuxUnitPath(allocator: std.mem.Allocator, service_name: []const u8) ![]u8 {
    const home = try registry.resolveUserHome(allocator);
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &[_][]const u8{ home, ".config", "systemd", "user", service_name });
}

pub fn managedServiceSelfExePath(allocator: std.mem.Allocator, self_exe: []const u8) ![]u8 {
    return managedServiceSelfExePathFromDir(allocator, std.fs.cwd(), self_exe);
}

pub fn managedServiceSelfExePathFromDir(allocator: std.mem.Allocator, cwd: std.fs.Dir, self_exe: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, self_exe, "/.zig-cache/") != null or std.mem.indexOf(u8, self_exe, "\\.zig-cache\\") != null) {
        const candidate_rel = try std.fs.path.join(allocator, &[_][]const u8{ "zig-out", "bin", std.fs.path.basename(self_exe) });
        defer allocator.free(candidate_rel);
        cwd.access(candidate_rel, .{}) catch return try allocator.dupe(u8, self_exe);
        return try cwd.realpathAlloc(allocator, candidate_rel);
    }
    return try allocator.dupe(u8, self_exe);
}

fn currentServiceDefinitionMatches(allocator: std.mem.Allocator, codex_home: []const u8, self_exe: []const u8) !bool {
    return switch (builtin.os.tag) {
        .linux => try linuxUnitMatches(allocator, codex_home, self_exe),
        .macos => try macPlistMatches(allocator, codex_home, self_exe),
        .windows => try windowsTaskMatches(allocator, codex_home, self_exe),
        else => true,
    };
}

fn linuxUnitMatches(allocator: std.mem.Allocator, codex_home: []const u8, self_exe: []const u8) !bool {
    const unit_path = try linuxUnitPath(allocator, linux_service_name);
    defer allocator.free(unit_path);
    const expected = try linuxUnitText(allocator, self_exe, codex_home);
    defer allocator.free(expected);
    if (!(try fileEqualsBytes(allocator, unit_path, expected))) return false;
    return !(try linuxUnitHasLegacyResidue(allocator, linux_timer_name));
}

fn linuxUnitHasLegacyResidue(allocator: std.mem.Allocator, service_name: []const u8) !bool {
    const unit_path = try linuxUnitPath(allocator, service_name);
    defer allocator.free(unit_path);
    const legacy_unit = try readFileIfExists(allocator, unit_path);
    defer if (legacy_unit) |bytes| allocator.free(bytes);
    if (legacy_unit != null) return true;

    const result = runCapture(allocator, &[_][]const u8{
        "systemctl",
        "--user",
        "show",
        service_name,
        "--property=LoadState,ActiveState,UnitFileState",
    }) catch return false;
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    return switch (result.term) {
        .Exited => |code| code == 0 and linuxShowUnitHasResidue(result.stdout),
        else => false,
    };
}

fn linuxShowUnitHasResidue(output: []const u8) bool {
    const load_state = linuxShowProperty(output, "LoadState") orelse return false;
    const active_state = linuxShowProperty(output, "ActiveState") orelse return false;
    const unit_file_state = linuxShowProperty(output, "UnitFileState") orelse return false;

    if (!std.mem.eql(u8, load_state, "not-found")) return true;
    if (!std.mem.eql(u8, active_state, "inactive")) return true;
    if (unit_file_state.len != 0 and !std.mem.eql(u8, unit_file_state, "not-found") and !std.mem.eql(u8, unit_file_state, "disabled")) {
        return true;
    }
    return false;
}

fn linuxShowProperty(output: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r\t");
        if (line.len == 0) continue;
        if (!std.mem.startsWith(u8, line, key)) continue;
        if (line.len <= key.len or line[key.len] != '=') continue;
        return std.mem.trim(u8, line[key.len + 1 ..], " \r\t");
    }
    return null;
}

fn macPlistMatches(allocator: std.mem.Allocator, codex_home: []const u8, self_exe: []const u8) !bool {
    const plist_path = try macPlistPath(allocator);
    defer allocator.free(plist_path);
    const expected = try macPlistText(allocator, self_exe, codex_home);
    defer allocator.free(expected);
    return try fileEqualsBytes(allocator, plist_path, expected);
}

fn windowsTaskMatches(allocator: std.mem.Allocator, codex_home: []const u8, self_exe: []const u8) !bool {
    _ = codex_home;
    const helper_path = try windowsHelperPath(allocator, self_exe);
    defer allocator.free(helper_path);
    const expected_action = try windowsExpectedTaskFingerprint(allocator, helper_path);
    defer allocator.free(expected_action);
    const expected_fingerprint = try windowsExpectedTaskDefinitionFingerprint(allocator, expected_action);
    defer allocator.free(expected_fingerprint);
    const script = try windowsTaskMatchScript(allocator);
    defer allocator.free(script);
    const result = runCapture(allocator, &[_][]const u8{
        "powershell.exe",
        "-NoLogo",
        "-NoProfile",
        "-Command",
        script,
    }) catch return false;
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    return switch (result.term) {
        .Exited => |code| code == 0 and std.mem.eql(u8, std.mem.trim(u8, result.stdout, " \n\r\t"), expected_fingerprint),
        else => false,
    };
}

fn windowsExpectedTaskFingerprint(allocator: std.mem.Allocator, helper_path: []const u8) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "{s} --service-version {s}",
        .{ helper_path, version.app_version },
    );
}

fn windowsExpectedTaskDefinitionFingerprint(allocator: std.mem.Allocator, action: []const u8) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "{s}|TRIGGER:{s}|RESTART:{s},{s}|LIMIT:{s}",
        .{ action, windows_task_trigger_kind, windows_task_restart_count, windows_task_restart_interval_xml, windows_task_execution_time_limit_xml },
    );
}

fn windowsHelperPath(allocator: std.mem.Allocator, self_exe: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(self_exe) orelse return error.FileNotFound;
    return try std.fs.path.join(allocator, &[_][]const u8{ dir, windows_helper_name });
}

fn macPlistPath(allocator: std.mem.Allocator) ![]u8 {
    const home = try registry.resolveUserHome(allocator);
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &[_][]const u8{ home, "Library", "LaunchAgents", mac_label ++ ".plist" });
}

fn runChecked(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const result = try runCapture(allocator, argv);
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    switch (result.term) {
        .Exited => |code| {
            if (code == 0) return;
        },
        else => {},
    }
    if (result.stderr.len > 0) {
        std.log.err("{s}", .{std.mem.trim(u8, result.stderr, " \n\r\t")});
    }
    return error.CommandFailed;
}

fn readFileIfExists(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    var file = std.fs.cwd().openFile(path, .{}) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer file.close();
    return try file.readToEndAlloc(allocator, 1024 * 1024);
}

fn fileEqualsBytes(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !bool {
    const data = try readFileIfExists(allocator, path);
    defer if (data) |buf| allocator.free(buf);
    if (data == null) return false;
    return std.mem.eql(u8, data.?, bytes);
}

fn runCapture(allocator: std.mem.Allocator, argv: []const []const u8) !std.process.Child.RunResult {
    return try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 1024 * 1024,
    });
}

fn runIgnoringFailure(allocator: std.mem.Allocator, argv: []const []const u8) void {
    const result = runCapture(allocator, argv) catch return;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

fn escapeXml(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    for (raw) |ch| {
        switch (ch) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            '\'' => try out.appendSlice(allocator, "&apos;"),
            else => try out.append(allocator, ch),
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn escapeSystemdValue(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    for (raw) |ch| {
        switch (ch) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            else => try out.append(allocator, ch),
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn escapePowerShellSingleQuoted(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, allocator, input, "'", "''");
}

test "candidate index refreshes cached ranking after a reset window expires" {
    const bdd = @import("tests/bdd_helpers.zig");
    const gpa = std.testing.allocator;

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);

    try bdd.appendAccount(gpa, &reg, "active@example.com", "", null);
    try bdd.appendAccount(gpa, &reg, "reset@example.com", "", null);
    try bdd.appendAccount(gpa, &reg, "steady@example.com", "", null);

    const active_account_key = try bdd.accountKeyForEmailAlloc(gpa, "active@example.com");
    defer gpa.free(active_account_key);
    const reset_account_key = try bdd.accountKeyForEmailAlloc(gpa, "reset@example.com");
    defer gpa.free(reset_account_key);
    const steady_account_key = try bdd.accountKeyForEmailAlloc(gpa, "steady@example.com");
    defer gpa.free(steady_account_key);

    try registry.setActiveAccountKey(gpa, &reg, active_account_key);

    const reset_idx = registry.findAccountIndexByAccountKey(&reg, reset_account_key) orelse return error.TestExpectedEqual;
    reg.accounts.items[reset_idx].last_usage = .{
        .primary = .{ .used_percent = 95.0, .window_minutes = 300, .resets_at = 1010 },
        .secondary = null,
        .credits = null,
        .plan_type = .pro,
    };
    reg.accounts.items[reset_idx].last_usage_at = 100;

    const steady_idx = registry.findAccountIndexByAccountKey(&reg, steady_account_key) orelse return error.TestExpectedEqual;
    reg.accounts.items[steady_idx].last_usage = .{
        .primary = .{ .used_percent = 60.0, .window_minutes = 300, .resets_at = null },
        .secondary = null,
        .credits = null,
        .plan_type = .pro,
    };
    reg.accounts.items[steady_idx].last_usage_at = 50;

    var index = CandidateIndex{};
    defer index.deinit(gpa);

    try index.rebuild(gpa, &reg, 1000);
    try std.testing.expect(index.best() != null);
    try std.testing.expect(std.mem.eql(u8, index.best().?.account_key, reset_account_key));
    try std.testing.expect(index.best().?.score.refresh_only);

    try index.rebuildIfScoreExpired(gpa, &reg, 1011);
    try std.testing.expect(index.best() != null);
    try std.testing.expect(std.mem.eql(u8, index.best().?.account_key, reset_account_key));
    try std.testing.expect(!index.best().?.score.refresh_only);
}

test "thread batch joins already spawned workers before returning a later spawn failure" {
    const FakeThread = struct {
        id: usize,
    };
    const State = struct {
        joined_ids: [candidate_parallel_fetch_limit]usize = undefined,
        join_count: usize = 0,
    };

    var state = State{};
    var threads: [candidate_parallel_fetch_limit]FakeThread = undefined;

    try std.testing.expectError(error.TestSpawnFailure, runThreadBatch(
        FakeThread,
        threads[0..candidate_parallel_fetch_limit],
        &state,
        struct {
            fn spawn(_: *State, idx: usize) !FakeThread {
                if (idx == 1) return error.TestSpawnFailure;
                return .{ .id = idx };
            }
        }.spawn,
        struct {
            fn join(ctx: *State, thread: *FakeThread) void {
                ctx.joined_ids[ctx.join_count] = thread.id;
                ctx.join_count += 1;
            }
        }.join,
    ));

    try std.testing.expectEqual(@as(usize, 1), state.join_count);
    try std.testing.expectEqual(@as(usize, 0), state.joined_ids[0]);
}
