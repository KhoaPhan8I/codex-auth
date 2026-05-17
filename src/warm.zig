const std = @import("std");
const auto = @import("auto.zig");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("time.h");
});
const io_util = @import("io_util.zig");
const registry = @import("registry.zig");
const sessions = @import("sessions.zig");

const warm_prompt = "Reply with exactly OK and nothing else.";
const warm_config_toml =
    \\model = "gpt-5.4"
    \\model_reasoning_effort = "low"
    \\approval_policy = "never"
    \\sandbox_mode = "read-only"
    \\
    \\[profiles.default]
    \\model = "gpt-5.4"
    \\model_provider = "openai"
    \\
;

pub const WarmOutcome = enum {
    updated,
    unknown,
    failed,
};

pub const FailureReason = enum {
    InvalidAuth,
    NoUsableWindows,
    RolloutMissing,
    RunnerMissing,
    RunnerFailed,
    RefreshFailed,
};

pub const Result = struct {
    account_key: []const u8,
    email: []const u8,
    outcome: WarmOutcome,
    reason: ?FailureReason = null,
};

pub const Summary = struct {
    results: std.ArrayList(Result) = .empty,
    eligible_candidates: usize = 0,

    pub fn deinit(self: *Summary, allocator: std.mem.Allocator) void {
        self.results.deinit(allocator);
        self.* = .{};
    }

    pub fn countOutcome(self: *const Summary, outcome: WarmOutcome) usize {
        var count: usize = 0;
        for (self.results.items) |item| {
            if (item.outcome == outcome) count += 1;
        }
        return count;
    }
};

pub const RunnerTermination = union(enum) {
    Exited: u8,
    Signal: u32,
    Stopped: u32,
    Unknown: void,
};

pub const RunnerContext = struct {
    temp_home: []const u8,
    temp_codex_home: []const u8,
    output_path: []const u8,
    account_key: []const u8,
    email: []const u8,
};

pub const RunnerFn = *const fn (
    allocator: std.mem.Allocator,
    ctx: RunnerContext,
) anyerror!RunnerTermination;

pub const Deps = struct {
    runner: RunnerFn = defaultRunner,
};

const RestoreState = struct {
    active_account_key: ?[]u8,
    active_account_activated_at_ms: ?i64,
    auto_switch_enabled: bool,
    auth_json_bytes: ?[]u8,

    fn deinit(self: *RestoreState, allocator: std.mem.Allocator) void {
        if (self.active_account_key) |key| allocator.free(key);
        if (self.auth_json_bytes) |bytes| allocator.free(bytes);
        self.* = .{
            .active_account_key = null,
            .active_account_activated_at_ms = null,
            .auto_switch_enabled = false,
            .auth_json_bytes = null,
        };
    }
};

const TempWorkDir = struct {
    path: []u8,

    fn deinit(self: *TempWorkDir, allocator: std.mem.Allocator) void {
        std.fs.cwd().deleteTree(self.path) catch {};
        allocator.free(self.path);
        self.* = undefined;
    }
};

const PreparedTempHome = struct {
    temp_codex_home: []u8,
    output_path: []u8,

    fn deinit(self: *PreparedTempHome, allocator: std.mem.Allocator) void {
        allocator.free(self.temp_codex_home);
        allocator.free(self.output_path);
        self.* = undefined;
    }
};

pub fn run(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    target_indices: []const usize,
) !Summary {
    return runWithDeps(allocator, codex_home, reg, target_indices, .{});
}

pub fn runWithDeps(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    target_indices: []const usize,
    deps: Deps,
) !Summary {
    var summary = Summary{};
    errdefer summary.deinit(allocator);

    var restore = try captureRestoreState(allocator, codex_home, reg);
    defer restore.deinit(allocator);

    errdefer restoreWarmState(allocator, codex_home, reg, &restore) catch {};

    if (restore.auto_switch_enabled) {
        reg.auto_switch.enabled = false;
        try registry.saveRegistry(allocator, codex_home, reg);
    }

    for (target_indices) |target_idx| {
        if (target_idx >= reg.accounts.items.len) continue;
        const result = try warmOneAccount(allocator, codex_home, reg, target_idx, deps);
        try summary.results.append(allocator, result);
    }

    try restoreWarmState(allocator, codex_home, reg, &restore);
    var status = try auto.getStatus(allocator, codex_home);
    defer status.deinit(allocator);
    summary.eligible_candidates = status.eligible_candidates;
    return summary;
}

pub fn printSummary(summary: *const Summary) !void {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();

    for (summary.results.items) |result| {
        switch (result.outcome) {
            .updated => try out.print("updated {s}\n", .{result.email}),
            .unknown => try out.print("unknown {s} {s}\n", .{ result.email, @tagName(result.reason.?) }),
            .failed => try out.print("failed {s} {s}\n", .{ result.email, @tagName(result.reason.?) }),
        }
    }

    try out.print(
        "warm summary: updated={d}, unknown={d}, failed={d}, eligible candidates={d}\n",
        .{
            summary.countOutcome(.updated),
            summary.countOutcome(.unknown),
            summary.countOutcome(.failed),
            summary.eligible_candidates,
        },
    );
    try out.flush();
}

fn captureRestoreState(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
) !RestoreState {
    const auth_path = try registry.activeAuthPath(allocator, codex_home);
    defer allocator.free(auth_path);
    return .{
        .active_account_key = if (reg.active_account_key) |key| try allocator.dupe(u8, key) else null,
        .active_account_activated_at_ms = reg.active_account_activated_at_ms,
        .auto_switch_enabled = reg.auto_switch.enabled,
        .auth_json_bytes = try readFileIfExists(allocator, auth_path),
    };
}

fn restoreWarmState(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    restore: *const RestoreState,
) !void {
    const auth_path = try registry.activeAuthPath(allocator, codex_home);
    defer allocator.free(auth_path);

    try restoreAuthFile(auth_path, restore.auth_json_bytes);

    const active_matches = optionalBytesEqual(reg.active_account_key, restore.active_account_key);
    const changed = !active_matches or
        reg.active_account_activated_at_ms != restore.active_account_activated_at_ms or
        reg.auto_switch.enabled != restore.auto_switch_enabled;

    if (changed) {
        if (reg.active_account_key) |existing| allocator.free(existing);
        reg.active_account_key = if (restore.active_account_key) |account_key|
            try allocator.dupe(u8, account_key)
        else
            null;
        reg.active_account_activated_at_ms = restore.active_account_activated_at_ms;
        reg.auto_switch.enabled = restore.auto_switch_enabled;
        try registry.saveRegistry(allocator, codex_home, reg);
    }
}

fn warmOneAccount(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    target_idx: usize,
    deps: Deps,
) !Result {
    const account_key = reg.accounts.items[target_idx].account_key;
    const email = reg.accounts.items[target_idx].email;

    registry.validateAccountSnapshotForAccount(allocator, codex_home, reg, account_key) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{
            .account_key = account_key,
            .email = email,
            .outcome = .failed,
            .reason = .InvalidAuth,
        },
    };
    try registry.activateAccountByKey(allocator, codex_home, reg, account_key);
    try registry.saveRegistry(allocator, codex_home, reg);

    var temp_work_dir = try createTempWorkDir(allocator);
    defer temp_work_dir.deinit(allocator);

    var prepared = try prepareTempHome(allocator, codex_home, temp_work_dir.path);
    defer prepared.deinit(allocator);

    const ctx: RunnerContext = .{
        .temp_home = temp_work_dir.path,
        .temp_codex_home = prepared.temp_codex_home,
        .output_path = prepared.output_path,
        .account_key = account_key,
        .email = email,
    };

    _ = deps.runner(allocator, ctx) catch |err| switch (err) {
        error.RunnerMissing => return .{
            .account_key = account_key,
            .email = email,
            .outcome = .failed,
            .reason = .RunnerMissing,
        },
        error.RunnerFailed => return .{
            .account_key = account_key,
            .email = email,
            .outcome = .failed,
            .reason = .RunnerFailed,
        },
        else => return err,
    };

    const latest_rollout_maybe = sessions.scanLatestRolloutEventWithSource(allocator, prepared.temp_codex_home) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    var latest_rollout = latest_rollout_maybe orelse {
        return .{
            .account_key = account_key,
            .email = email,
            .outcome = .failed,
            .reason = .RolloutMissing,
        };
    };
    defer latest_rollout.deinit(allocator);

    const copied_rollout_path = try copyRolloutIntoLocalSeed(
        allocator,
        codex_home,
        latest_rollout.path,
        latest_rollout.event_timestamp_ms,
    );
    defer allocator.free(copied_rollout_path);

    const copied_signature: registry.RolloutSignature = .{
        .path = copied_rollout_path,
        .event_timestamp_ms = latest_rollout.event_timestamp_ms,
    };
    const already_imported = registry.rolloutSignaturesEqual(
        reg.accounts.items[target_idx].last_local_rollout,
        copied_signature,
    );

    if (try auto.refreshActiveUsageFromLocalSessions(allocator, codex_home, reg)) {
        try registry.saveRegistry(allocator, codex_home, reg);
        return .{
            .account_key = account_key,
            .email = email,
            .outcome = .updated,
        };
    }

    if (!latest_rollout.hasUsableWindows()) {
        try registry.markAccountAuthValid(allocator, reg, account_key);
        return .{
            .account_key = account_key,
            .email = email,
            .outcome = .unknown,
            .reason = .NoUsableWindows,
        };
    }

    if (already_imported) {
        try registry.markAccountAuthVerified(allocator, reg, account_key);
        return .{
            .account_key = account_key,
            .email = email,
            .outcome = .updated,
        };
    }

    return .{
        .account_key = account_key,
        .email = email,
        .outcome = .failed,
        .reason = .RefreshFailed,
    };
}

fn prepareTempHome(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    temp_home: []const u8,
) !PreparedTempHome {
    const temp_codex_home = try std.fs.path.join(allocator, &[_][]const u8{ temp_home, ".codex" });
    errdefer allocator.free(temp_codex_home);
    try std.fs.cwd().makePath(temp_codex_home);

    const real_auth_path = try registry.activeAuthPath(allocator, codex_home);
    defer allocator.free(real_auth_path);
    const temp_auth_path = try std.fs.path.join(allocator, &[_][]const u8{ temp_codex_home, "auth.json" });
    defer allocator.free(temp_auth_path);
    try registry.copyFile(real_auth_path, temp_auth_path);

    const temp_config_path = try std.fs.path.join(allocator, &[_][]const u8{ temp_codex_home, "config.toml" });
    defer allocator.free(temp_config_path);
    try std.fs.cwd().writeFile(.{
        .sub_path = temp_config_path,
        .data = warm_config_toml,
    });

    const output_path = try std.fs.path.join(allocator, &[_][]const u8{ temp_home, "last.txt" });
    errdefer allocator.free(output_path);

    return .{
        .temp_codex_home = temp_codex_home,
        .output_path = output_path,
    };
}

fn resolveTempRoot(allocator: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag == .windows) {
        if (std.process.getEnvVarOwned(allocator, "TEMP")) |temp| return temp else |err| switch (err) {
            error.EnvironmentVariableNotFound => {},
            else => return err,
        }
        if (std.process.getEnvVarOwned(allocator, "TMP")) |temp| return temp else |err| switch (err) {
            error.EnvironmentVariableNotFound => {},
            else => return err,
        }
    } else {
        if (std.process.getEnvVarOwned(allocator, "TMPDIR")) |temp| {
            if (temp.len != 0) return temp;
            allocator.free(temp);
        } else |err| switch (err) {
            error.EnvironmentVariableNotFound => {},
            else => return err,
        }
        return allocator.dupe(u8, "/tmp");
    }
    return registry.resolveUserHome(allocator);
}

fn createTempWorkDir(allocator: std.mem.Allocator) !TempWorkDir {
    const temp_root = try resolveTempRoot(allocator);
    defer allocator.free(temp_root);

    var attempt: u32 = 0;
    while (attempt < 128) : (attempt += 1) {
        const dirname = try std.fmt.allocPrint(
            allocator,
            "codex-auth-warm-{d}-{d}",
            .{ std.time.nanoTimestamp(), attempt },
        );
        defer allocator.free(dirname);
        const path = try std.fs.path.join(allocator, &[_][]const u8{ temp_root, dirname });
        errdefer allocator.free(path);
        std.fs.cwd().makeDir(path) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        return .{ .path = path };
    }

    return error.TemporaryPathUnavailable;
}

fn copyRolloutIntoLocalSeed(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    source_path: []const u8,
    event_timestamp_ms: i64,
) ![]u8 {
    const basename = std.fs.path.basename(source_path);
    const seeded_path = try localSeedRolloutPathAlloc(allocator, codex_home, basename, event_timestamp_ms);
    errdefer allocator.free(seeded_path);

    const parent = std.fs.path.dirname(seeded_path) orelse return error.InvalidPath;
    try std.fs.cwd().makePath(parent);
    std.fs.cwd().deleteFile(seeded_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try registry.copyFile(source_path, seeded_path);
    try touchFileNow(seeded_path);
    return seeded_path;
}

fn localSeedRolloutPathAlloc(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    basename: []const u8,
    event_timestamp_ms: i64,
) ![]u8 {
    var event_tm: c.struct_tm = undefined;
    if (!gmtimeCompat(@divTrunc(event_timestamp_ms, 1000), &event_tm)) return error.TimeConversionFailed;

    const year = try std.fmt.allocPrint(allocator, "{d:0>4}", .{event_tm.tm_year + 1900});
    defer allocator.free(year);
    const month = try std.fmt.allocPrint(allocator, "{d:0>2}", .{event_tm.tm_mon + 1});
    defer allocator.free(month);
    const day = try std.fmt.allocPrint(allocator, "{d:0>2}", .{event_tm.tm_mday});
    defer allocator.free(day);

    return std.fs.path.join(allocator, &[_][]const u8{
        codex_home,
        "sessions",
        "local-seed",
        year,
        month,
        day,
        basename,
    });
}

fn gmtimeCompat(ts: i64, out_tm: *c.struct_tm) bool {
    if (comptime builtin.os.tag == .windows) {
        if (comptime @hasDecl(c, "_gmtime64_s") and @hasDecl(c, "__time64_t")) {
            var t64 = std.math.cast(c.__time64_t, ts) orelse return false;
            return c._gmtime64_s(out_tm, &t64) == 0;
        }
        return false;
    }

    var t = std.math.cast(c.time_t, ts) orelse return false;
    if (comptime @hasDecl(c, "gmtime_r")) {
        return c.gmtime_r(&t, out_tm) != null;
    }
    if (comptime @hasDecl(c, "gmtime")) {
        const tm_ptr = c.gmtime(&t);
        if (tm_ptr == null) return false;
        out_tm.* = tm_ptr.*;
        return true;
    }
    return false;
}

fn touchFileNow(path: []const u8) !void {
    var file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
    defer file.close();
    const now_ns = std.time.nanoTimestamp();
    try file.updateTimes(now_ns, now_ns);
}

fn defaultRunner(allocator: std.mem.Allocator, ctx: RunnerContext) !RunnerTermination {
    return runFirstAvailableRunner(allocator, ctx, &[_][]const u8{ "codext", "codex" });
}

fn runFirstAvailableRunner(
    allocator: std.mem.Allocator,
    ctx: RunnerContext,
    candidates: []const []const u8,
) !RunnerTermination {
    for (candidates) |candidate| {
        return runRunnerCommand(allocator, candidate, ctx) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
    }
    return error.RunnerMissing;
}

fn runRunnerCommand(
    allocator: std.mem.Allocator,
    runner_name: []const u8,
    ctx: RunnerContext,
) !RunnerTermination {
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", ctx.temp_home);
    try env_map.put("USERPROFILE", ctx.temp_home);

    const workdir = if (builtin.os.tag == .windows) ctx.temp_home else "/tmp";
    var child = std.process.Child.init(&[_][]const u8{
        runner_name,
        "exec",
        "-C",
        workdir,
        "--skip-git-repo-check",
        "-s",
        "read-only",
        "--color",
        "never",
        "-o",
        ctx.output_path,
        warm_prompt,
    }, allocator);
    child.cwd = ctx.temp_home;
    child.env_map = &env_map;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    const term = child.spawnAndWait() catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return error.RunnerFailed,
    };
    return childTermToRunnerTermination(term);
}

fn childTermToRunnerTermination(term: std.process.Child.Term) RunnerTermination {
    return switch (term) {
        .Exited => |code| .{ .Exited = code },
        .Signal => |signal| .{ .Signal = signal },
        .Stopped => |signal| .{ .Stopped = signal },
        else => .{ .Unknown = {} },
    };
}

fn optionalBytesEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn restoreAuthFile(path: []const u8, original_bytes: ?[]const u8) !void {
    if (original_bytes) |bytes| {
        const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
        try std.fs.cwd().makePath(parent);
        try writeFile(path, bytes);
        return;
    }

    std.fs.cwd().deleteFile(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn readFileIfExists(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    var file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();
    return try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
}

fn writeFile(path: []const u8, data: []const u8) !void {
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(data);
}
