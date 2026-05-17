const std = @import("std");
const registry = @import("registry.zig");

pub const LatestUsage = struct {
    path: []u8,
    mtime: i64,
    event_timestamp_ms: i64,
    snapshot: registry.RateLimitSnapshot,

    pub fn deinit(self: *LatestUsage, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        registry.freeRateLimitSnapshot(allocator, &self.snapshot);
    }
};

fn cloneLatestUsage(allocator: std.mem.Allocator, latest: LatestUsage) !LatestUsage {
    return .{
        .path = try allocator.dupe(u8, latest.path),
        .mtime = latest.mtime,
        .event_timestamp_ms = latest.event_timestamp_ms,
        .snapshot = try registry.cloneRateLimitSnapshot(allocator, latest.snapshot),
    };
}

pub const LatestRolloutEvent = struct {
    path: []u8,
    mtime: i64,
    event_timestamp_ms: i64,
    snapshot: ?registry.RateLimitSnapshot,

    pub fn deinit(self: *LatestRolloutEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.snapshot) |*snapshot| {
            registry.freeRateLimitSnapshot(allocator, snapshot);
        }
    }

    pub fn hasUsableWindows(self: LatestRolloutEvent) bool {
        if (self.snapshot) |snapshot| {
            return snapshot.primary != null or snapshot.secondary != null;
        }
        return false;
    }
};

const RolloutCandidate = struct {
    path: []u8,
    mtime: i64,
};

const ParsedUsageEvent = struct {
    event_timestamp_ms: i64,
    snapshot: ?registry.RateLimitSnapshot,
};

const UsageEventLineJson = struct {
    timestamp: []const u8 = "",
    type: []const u8 = "",
    payload: UsagePayloadJson = .{},
};

const UsagePayloadJson = struct {
    type: []const u8 = "",
    rate_limits: ?UsageRateLimitsJson = null,
};

const UsageRateLimitsJson = struct {
    primary: ?UsageWindowJson = null,
    secondary: ?UsageWindowJson = null,
    credits: ?UsageCreditsJson = null,
    plan_type: ?[]const u8 = null,
};

const UsageWindowJson = struct {
    used_percent: ?std.json.Value = null,
    window_minutes: ?i64 = null,
    resets_at: ?i64 = null,
};

const UsageCreditsJson = struct {
    has_credits: bool = false,
    unlimited: bool = false,
    balance: ?[]const u8 = null,
};

const max_recent_rollout_files: usize = 1;
const max_rollout_line_bytes: usize = 10 * 1024 * 1024;
const rollout_full_rescan_interval_ns = 15 * std.time.ns_per_s;
const runtime_rollout_cache_file_name = "latest-rollout.json";

pub const RolloutScanCache = struct {
    last_full_scan_at_ns: i128 = 0,
    latest: ?LatestRolloutEvent = null,
    latest_usable: ?LatestUsage = null,

    pub fn deinit(self: *RolloutScanCache, allocator: std.mem.Allocator) void {
        self.clear(allocator);
    }

    fn clear(self: *RolloutScanCache, allocator: std.mem.Allocator) void {
        if (self.latest) |*latest| {
            latest.deinit(allocator);
        }
        if (self.latest_usable) |*latest_usable| {
            latest_usable.deinit(allocator);
        }
        self.latest = null;
        self.latest_usable = null;
        self.last_full_scan_at_ns = 0;
    }

    fn replace(
        self: *RolloutScanCache,
        allocator: std.mem.Allocator,
        latest: ?LatestRolloutEvent,
        latest_usable: ?LatestUsage,
        scanned_at_ns: i128,
    ) void {
        if (self.latest) |*cached| {
            cached.deinit(allocator);
        }
        if (self.latest_usable) |*cached_usable| {
            cached_usable.deinit(allocator);
        }
        self.latest = latest;
        self.latest_usable = latest_usable;
        self.last_full_scan_at_ns = scanned_at_ns;
    }

    fn cloneLatest(self: *const RolloutScanCache, allocator: std.mem.Allocator) !?LatestRolloutEvent {
        if (self.latest) |latest| {
            return try cloneLatestRolloutEvent(allocator, latest);
        }
        return null;
    }

    fn cloneLatestUsable(self: *const RolloutScanCache, allocator: std.mem.Allocator) !?LatestUsage {
        if (self.latest_usable) |latest| {
            return try cloneLatestUsage(allocator, latest);
        }
        return null;
    }
};

pub fn scanLatestUsage(allocator: std.mem.Allocator, codex_home: []const u8) !?registry.RateLimitSnapshot {
    const latest = try scanLatestUsageWithSource(allocator, codex_home);
    if (latest == null) return null;
    allocator.free(latest.?.path);
    return latest.?.snapshot;
}

pub fn scanLatestUsageWithSource(allocator: std.mem.Allocator, codex_home: []const u8) !?LatestUsage {
    var latest_rollout = (try scanLatestRolloutEventWithSource(allocator, codex_home)) orelse return null;
    errdefer latest_rollout.deinit(allocator);
    var resolved = try resolveLatestRolloutState(allocator, latest_rollout);
    defer resolved.deinit(allocator);
    saveRuntimeRolloutCacheBestEffort(allocator, codex_home, resolved.latest, resolved.latest_usable, std.time.nanoTimestamp());
    if (resolved.latest_usable) |latest_usable| {
        return try cloneLatestUsage(allocator, latest_usable);
    }
    return null;
}

pub fn scanLatestUsageWithRuntimeCache(allocator: std.mem.Allocator, codex_home: []const u8) !?LatestUsage {
    const now_ns = std.time.nanoTimestamp();
    if (try loadRuntimeRolloutCache(allocator, codex_home, now_ns)) |loaded| {
        var cached = loaded;
        defer cached.deinit(allocator);
        if (cached.latest_usable == null and !cached.latest.hasUsableWindows()) {
            // Older cache files may not include the newest usable snapshot.
        } else if (cached.latest_usable) |latest_usable| {
            return try cloneLatestUsage(allocator, latest_usable);
        } else if (cached.latest.hasUsableWindows()) {
            return try cloneLatestUsage(allocator, .{
                .path = cached.latest.path,
                .mtime = cached.latest.mtime,
                .event_timestamp_ms = cached.latest.event_timestamp_ms,
                .snapshot = cached.latest.snapshot.?,
            });
        } else {
            return null;
        }
    }

    var latest_rollout = (try scanLatestRolloutEventWithSource(allocator, codex_home)) orelse return null;
    errdefer latest_rollout.deinit(allocator);
    var resolved = try resolveLatestRolloutState(allocator, latest_rollout);
    defer resolved.deinit(allocator);
    saveRuntimeRolloutCacheBestEffort(allocator, codex_home, resolved.latest, resolved.latest_usable, now_ns);
    if (resolved.latest_usable) |latest_usable| {
        return try cloneLatestUsage(allocator, latest_usable);
    }
    return null;
}

fn latestUsageFromRolloutEvent(allocator: std.mem.Allocator, latest_rollout: LatestRolloutEvent) !?LatestUsage {
    var owned = latest_rollout;
    errdefer owned.deinit(allocator);
    if (!latest_rollout.hasUsableWindows()) {
        const latest_usable = try scanLatestUsableUsageInFile(allocator, owned.path, owned.mtime);
        if (latest_usable == null) {
            owned.deinit(allocator);
            return null;
        }
        owned.deinit(allocator);
        return latest_usable;
    }

    const snapshot = owned.snapshot.?;
    owned.snapshot = null;
    return .{
        .path = owned.path,
        .mtime = owned.mtime,
        .event_timestamp_ms = owned.event_timestamp_ms,
        .snapshot = snapshot,
    };
}

const ResolvedLatestRolloutState = struct {
    latest: LatestRolloutEvent,
    latest_usable: ?LatestUsage = null,

    fn deinit(self: *ResolvedLatestRolloutState, allocator: std.mem.Allocator) void {
        self.latest.deinit(allocator);
        if (self.latest_usable) |*latest_usable| {
            latest_usable.deinit(allocator);
        }
    }
};

fn resolveLatestRolloutState(
    allocator: std.mem.Allocator,
    latest_rollout: LatestRolloutEvent,
) !ResolvedLatestRolloutState {
    var owned = latest_rollout;
    errdefer owned.deinit(allocator);

    const latest_usable = if (owned.hasUsableWindows())
        try cloneLatestUsage(allocator, .{
            .path = owned.path,
            .mtime = owned.mtime,
            .event_timestamp_ms = owned.event_timestamp_ms,
            .snapshot = owned.snapshot.?,
        })
    else
        try scanLatestUsableUsageInFile(allocator, owned.path, owned.mtime);

    return .{
        .latest = owned,
        .latest_usable = latest_usable,
    };
}

pub fn scanLatestUsableUsageInFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    mtime: i64,
) !?LatestUsage {
    var latest_usable = (try scanFileForLatestUsableUsage(allocator, path)) orelse return null;
    errdefer if (latest_usable.snapshot) |*snapshot| {
        registry.freeRateLimitSnapshot(allocator, snapshot);
    };

    const owned_path = try allocator.dupe(u8, path);
    const snapshot = latest_usable.snapshot.?;
    latest_usable.snapshot = null;
    return .{
        .path = owned_path,
        .mtime = mtime,
        .event_timestamp_ms = latest_usable.event_timestamp_ms,
        .snapshot = snapshot,
    };
}

pub fn scanLatestRolloutEventWithSource(allocator: std.mem.Allocator, codex_home: []const u8) !?LatestRolloutEvent {
    const sessions_root = try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "sessions" });
    defer allocator.free(sessions_root);

    var candidates = std.ArrayList(RolloutCandidate).empty;
    defer {
        for (candidates.items) |candidate| {
            allocator.free(candidate.path);
        }
        candidates.deinit(allocator);
    }

    var dir = try std.fs.cwd().openDir(sessions_root, .{ .iterate = true });
    defer dir.close();
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!isRolloutFile(entry.path)) continue;
        const stat = try dir.statFile(entry.path);
        const path = try std.fs.path.join(allocator, &[_][]const u8{ sessions_root, entry.path });
        errdefer allocator.free(path);
        try candidates.append(allocator, .{
            .path = path,
            .mtime = @intCast(stat.mtime),
        });
    }

    std.mem.sort(RolloutCandidate, candidates.items, {}, struct {
        fn lessThan(_: void, a: RolloutCandidate, b: RolloutCandidate) bool {
            return a.mtime > b.mtime;
        }
    }.lessThan);

    var best: ?LatestRolloutEvent = null;
    const scan_count = @min(candidates.items.len, max_recent_rollout_files);

    for (candidates.items[0..scan_count]) |candidate| {
        var parsed = (try scanFileForUsage(allocator, candidate.path)) orelse continue;
        const better = best == null or
            parsed.event_timestamp_ms > best.?.event_timestamp_ms or
            (parsed.event_timestamp_ms == best.?.event_timestamp_ms and candidate.mtime > best.?.mtime);

        if (!better) {
            if (parsed.snapshot) |*snapshot| {
                registry.freeRateLimitSnapshot(allocator, snapshot);
            }
            continue;
        }

        if (best) |*prev| {
            prev.deinit(allocator);
        }

        const path = allocator.dupe(u8, candidate.path) catch |err| {
            if (parsed.snapshot) |*snapshot| {
                registry.freeRateLimitSnapshot(allocator, snapshot);
            }
            return err;
        };
        best = .{
            .path = path,
            .mtime = candidate.mtime,
            .event_timestamp_ms = parsed.event_timestamp_ms,
            .snapshot = parsed.snapshot,
        };
    }

    return best;
}

pub fn scanLatestRolloutEventWithCache(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    cache: *RolloutScanCache,
) !?LatestRolloutEvent {
    const now_ns = std.time.nanoTimestamp();

    if (cache.latest == null) {
        if (try loadRuntimeRolloutCache(allocator, codex_home, now_ns)) |cached| {
            cache.replace(allocator, cached.latest, cached.latest_usable, now_ns);
        }
    }

    if (cache.latest) |cached| {
        const stat = std.fs.cwd().statFile(cached.path) catch |err| switch (err) {
            error.FileNotFound => return try refreshRolloutScanCache(allocator, codex_home, cache, now_ns),
            else => return err,
        };
        const current_mtime: i64 = @intCast(stat.mtime);
        if (current_mtime != cached.mtime) {
            const reparsed = try scanFileForUsage(allocator, cached.path);
            if (reparsed) |parsed| {
                var updated = try latestRolloutEventFromParsedUsage(allocator, cached.path, current_mtime, parsed);
                errdefer updated.deinit(allocator);
                const resolved = try resolveLatestRolloutState(allocator, updated);
                cache.replace(allocator, resolved.latest, resolved.latest_usable, cache.last_full_scan_at_ns);
                if (cache.latest) |latest| {
                    saveRuntimeRolloutCacheBestEffort(allocator, codex_home, latest, cache.latest_usable, now_ns);
                }
                return try cache.cloneLatest(allocator);
            }
            return try refreshRolloutScanCache(allocator, codex_home, cache, now_ns);
        }

        if (!cached.hasUsableWindows() and cache.latest_usable == null) {
            return try refreshRolloutScanCache(allocator, codex_home, cache, now_ns);
        }

        if (cache.last_full_scan_at_ns != 0 and (now_ns - cache.last_full_scan_at_ns) < rollout_full_rescan_interval_ns) {
            return try cache.cloneLatest(allocator);
        }
    }

    return try refreshRolloutScanCache(allocator, codex_home, cache, now_ns);
}

fn scanFileForUsage(allocator: std.mem.Allocator, path: []const u8) !?ParsedUsageEvent {
    return scanFileForUsageWithMode(allocator, path, true);
}

fn scanFileForLatestUsableUsage(allocator: std.mem.Allocator, path: []const u8) !?ParsedUsageEvent {
    return scanFileForUsageWithMode(allocator, path, false);
}

fn scanFileForUsageWithMode(allocator: std.mem.Allocator, path: []const u8, keep_latest_unusable: bool) !?ParsedUsageEvent {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var read_buffer: [8192]u8 = undefined;
    var file_reader = file.reader(&read_buffer);
    const reader = &file_reader.interface;
    var line_buffer: std.Io.Writer.Allocating = .init(allocator);
    defer line_buffer.deinit();
    var last: ?ParsedUsageEvent = null;

    while (true) {
        line_buffer.clearRetainingCapacity();
        const line_len = reader.streamDelimiterLimit(
            &line_buffer.writer,
            '\n',
            .limited(max_rollout_line_bytes),
        ) catch |err| switch (err) {
            error.StreamTooLong => {
                _ = reader.discardDelimiterInclusive('\n') catch |discard_err| switch (discard_err) {
                    error.EndOfStream => break,
                    error.ReadFailed => return file_reader.err orelse error.ReadFailed,
                };
                continue;
            },
            error.ReadFailed => return file_reader.err orelse error.ReadFailed,
            error.WriteFailed => return error.OutOfMemory,
        };
        const line = line_buffer.written();
        const next_byte: ?u8 = reader.peekByte() catch |err| switch (err) {
            error.EndOfStream => null,
            error.ReadFailed => return file_reader.err orelse error.ReadFailed,
        };
        if (next_byte) |byte| {
            std.debug.assert(byte == '\n');
            _ = reader.discardDelimiterInclusive('\n') catch |err| switch (err) {
                error.EndOfStream => unreachable,
                error.ReadFailed => return file_reader.err orelse error.ReadFailed,
            };
        } else if (line_len == 0) {
            break;
        }
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;
        if (parseUsageEventLine(allocator, trimmed)) |event| {
            if (!keep_latest_unusable and event.snapshot == null) {
                continue;
            }
            if (last) |*prev| {
                if (prev.snapshot) |*snapshot| {
                    registry.freeRateLimitSnapshot(allocator, snapshot);
                }
            }
            last = event;
        }
    }
    return last;
}

fn refreshRolloutScanCache(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    cache: *RolloutScanCache,
    scanned_at_ns: i128,
) !?LatestRolloutEvent {
    const latest = try scanLatestRolloutEventWithSource(allocator, codex_home);
    if (latest) |latest_rollout| {
        const resolved = try resolveLatestRolloutState(allocator, latest_rollout);
        cache.replace(allocator, resolved.latest, resolved.latest_usable, scanned_at_ns);
    } else {
        cache.replace(allocator, null, null, scanned_at_ns);
    }
    if (cache.latest) |resolved| {
        saveRuntimeRolloutCacheBestEffort(allocator, codex_home, resolved, cache.latest_usable, scanned_at_ns);
    } else {
        clearRuntimeRolloutCacheBestEffort(allocator, codex_home);
    }
    return try cache.cloneLatest(allocator);
}

const RuntimeRolloutCacheFile = struct {
    scanned_at_ns: i64,
    path: []const u8,
    mtime: i64,
    event_timestamp_ms: i64,
    snapshot: ?RuntimeSnapshotFile = null,
    latest_usable_event_timestamp_ms: ?i64 = null,
    latest_usable_snapshot: ?RuntimeSnapshotFile = null,
};

const RuntimeSnapshotFile = struct {
    primary: ?RuntimeWindowFile = null,
    secondary: ?RuntimeWindowFile = null,
    credits: ?RuntimeCreditsFile = null,
    plan_type: ?[]const u8 = null,
};

const RuntimeWindowFile = struct {
    used_percent: f64,
    window_minutes: ?i64 = null,
    resets_at: ?i64 = null,
};

const RuntimeCreditsFile = struct {
    has_credits: bool = false,
    unlimited: bool = false,
};

fn runtimeDirPath(allocator: std.mem.Allocator, codex_home: []const u8) ![]u8 {
    return try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "runtime" });
}

fn runtimeRolloutCachePath(allocator: std.mem.Allocator, codex_home: []const u8) ![]u8 {
    return try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "runtime", runtime_rollout_cache_file_name });
}

fn saveRuntimeRolloutCacheBestEffort(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    latest: LatestRolloutEvent,
    latest_usable: ?LatestUsage,
    scanned_at_ns: i128,
) void {
    saveRuntimeRolloutCache(allocator, codex_home, latest, latest_usable, scanned_at_ns) catch {};
}

fn clearRuntimeRolloutCacheBestEffort(allocator: std.mem.Allocator, codex_home: []const u8) void {
    const cache_path = runtimeRolloutCachePath(allocator, codex_home) catch return;
    defer allocator.free(cache_path);
    std.fs.cwd().deleteFile(cache_path) catch {};
}

fn saveRuntimeRolloutCache(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    latest: LatestRolloutEvent,
    latest_usable: ?LatestUsage,
    scanned_at_ns: i128,
) !void {
    const runtime_dir = try runtimeDirPath(allocator, codex_home);
    defer allocator.free(runtime_dir);
    try std.fs.cwd().makePath(runtime_dir);

    const cache_path = try runtimeRolloutCachePath(allocator, codex_home);
    defer allocator.free(cache_path);

    const payload: RuntimeRolloutCacheFile = .{
        .scanned_at_ns = std.math.cast(i64, scanned_at_ns) orelse std.math.maxInt(i64),
        .path = latest.path,
        .mtime = latest.mtime,
        .event_timestamp_ms = latest.event_timestamp_ms,
        .snapshot = if (latest.snapshot) |snapshot| snapshotToRuntimeFile(snapshot) else null,
        .latest_usable_event_timestamp_ms = if (latest_usable) |usage| usage.event_timestamp_ms else null,
        .latest_usable_snapshot = if (latest_usable) |usage| snapshotToRuntimeFile(usage.snapshot) else null,
    };

    var json_buffer: std.Io.Writer.Allocating = .init(allocator);
    defer json_buffer.deinit();
    try std.json.Stringify.value(payload, .{}, &json_buffer.writer);

    var write_buffer: [4096]u8 = undefined;
    var atomic_file = try std.fs.cwd().atomicFile(cache_path, .{ .write_buffer = &write_buffer });
    defer atomic_file.deinit();
    try atomic_file.file_writer.interface.writeAll(json_buffer.written());
    try atomic_file.finish();
}

fn loadRuntimeRolloutCache(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    now_ns: i128,
) !?ResolvedLatestRolloutState {
    const cache_path = try runtimeRolloutCachePath(allocator, codex_home);
    defer allocator.free(cache_path);

    const file = std.fs.cwd().openFile(cache_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();

    const data = file.readToEndAlloc(allocator, 128 * 1024) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer allocator.free(data);

    var parsed = std.json.parseFromSlice(RuntimeRolloutCacheFile, allocator, data, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer parsed.deinit();

    const cached = parsed.value;
    if (cached.scanned_at_ns == 0) return null;
    const scanned_at_ns: i128 = cached.scanned_at_ns;
    if ((now_ns - scanned_at_ns) >= rollout_full_rescan_interval_ns) return null;

    const stat = std.fs.cwd().statFile(cached.path) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    if (@as(i64, @intCast(stat.mtime)) != cached.mtime) return null;

    return .{
        .latest = .{
            .path = try allocator.dupe(u8, cached.path),
            .mtime = cached.mtime,
            .event_timestamp_ms = cached.event_timestamp_ms,
            .snapshot = if (cached.snapshot) |snapshot| try runtimeFileToSnapshot(allocator, snapshot) else null,
        },
        .latest_usable = if (cached.latest_usable_snapshot) |snapshot| .{
            .path = try allocator.dupe(u8, cached.path),
            .mtime = cached.mtime,
            .event_timestamp_ms = cached.latest_usable_event_timestamp_ms orelse return null,
            .snapshot = try runtimeFileToSnapshot(allocator, snapshot),
        } else if (cached.snapshot) |snapshot| blk: {
            const latest_snapshot = try runtimeFileToSnapshot(allocator, snapshot);
            if (latest_snapshot.primary == null and latest_snapshot.secondary == null) {
                registry.freeRateLimitSnapshot(allocator, &latest_snapshot);
                break :blk null;
            }
            break :blk .{
                .path = try allocator.dupe(u8, cached.path),
                .mtime = cached.mtime,
                .event_timestamp_ms = cached.event_timestamp_ms,
                .snapshot = latest_snapshot,
            };
        } else null,
    };
}

pub fn cloneLatestUsableFromCache(
    allocator: std.mem.Allocator,
    cache: *const RolloutScanCache,
) !?LatestUsage {
    return try cache.cloneLatestUsable(allocator);
}

fn snapshotToRuntimeFile(snapshot: registry.RateLimitSnapshot) RuntimeSnapshotFile {
    return .{
        .primary = if (snapshot.primary) |window| windowToRuntimeFile(window) else null,
        .secondary = if (snapshot.secondary) |window| windowToRuntimeFile(window) else null,
        .credits = if (snapshot.credits) |credits| creditsToRuntimeFile(credits) else null,
        .plan_type = if (snapshot.plan_type) |plan| @tagName(plan) else null,
    };
}

fn windowToRuntimeFile(window: registry.RateLimitWindow) RuntimeWindowFile {
    return .{
        .used_percent = window.used_percent,
        .window_minutes = window.window_minutes,
        .resets_at = window.resets_at,
    };
}

fn creditsToRuntimeFile(credits: registry.CreditsSnapshot) RuntimeCreditsFile {
    return .{
        .has_credits = credits.has_credits,
        .unlimited = credits.unlimited,
    };
}

fn runtimeFileToSnapshot(allocator: std.mem.Allocator, snapshot: RuntimeSnapshotFile) !registry.RateLimitSnapshot {
    return .{
        .primary = if (snapshot.primary) |window| runtimeFileToWindow(window) else null,
        .secondary = if (snapshot.secondary) |window| runtimeFileToWindow(window) else null,
        .credits = if (snapshot.credits) |credits| try runtimeFileToCredits(allocator, credits) else null,
        .plan_type = if (snapshot.plan_type) |plan| parsePlanType(plan) else null,
    };
}

fn runtimeFileToWindow(window: RuntimeWindowFile) registry.RateLimitWindow {
    return .{
        .used_percent = window.used_percent,
        .window_minutes = window.window_minutes,
        .resets_at = window.resets_at,
    };
}

fn runtimeFileToCredits(allocator: std.mem.Allocator, credits: RuntimeCreditsFile) !registry.CreditsSnapshot {
    _ = allocator;
    return .{
        .has_credits = credits.has_credits,
        .unlimited = credits.unlimited,
        .balance = null,
    };
}

fn latestRolloutEventFromParsedUsage(
    allocator: std.mem.Allocator,
    path: []const u8,
    mtime: i64,
    parsed: ParsedUsageEvent,
) !LatestRolloutEvent {
    errdefer if (parsed.snapshot) |*snapshot| {
        registry.freeRateLimitSnapshot(allocator, snapshot);
    };
    return .{
        .path = try allocator.dupe(u8, path),
        .mtime = mtime,
        .event_timestamp_ms = parsed.event_timestamp_ms,
        .snapshot = parsed.snapshot,
    };
}

fn cloneLatestRolloutEvent(allocator: std.mem.Allocator, latest: LatestRolloutEvent) !LatestRolloutEvent {
    return .{
        .path = try allocator.dupe(u8, latest.path),
        .mtime = latest.mtime,
        .event_timestamp_ms = latest.event_timestamp_ms,
        .snapshot = if (latest.snapshot) |snapshot|
            try registry.cloneRateLimitSnapshot(allocator, snapshot)
        else
            null,
    };
}

pub fn parseUsageLine(allocator: std.mem.Allocator, line: []const u8) ?registry.RateLimitSnapshot {
    const event = parseUsageEventLine(allocator, line) orelse return null;
    return event.snapshot;
}

fn parseUsageEventLine(allocator: std.mem.Allocator, line: []const u8) ?ParsedUsageEvent {
    if (!looksLikeUsageEventLine(line)) return null;

    var parsed = std.json.parseFromSlice(UsageEventLineJson, allocator, line, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();

    const root = parsed.value;
    if (!std.mem.eql(u8, root.type, "event_msg")) return null;
    if (!std.mem.eql(u8, root.payload.type, "token_count")) return null;

    const event_timestamp_ms = parseTimestampMs(root.timestamp) orelse return null;
    const snapshot = if (root.payload.rate_limits) |rate_limits|
        parseRateLimits(allocator, rate_limits)
    else
        null;
    return .{
        .event_timestamp_ms = event_timestamp_ms,
        .snapshot = snapshot,
    };
}

fn looksLikeUsageEventLine(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "\"event_msg\"") != null and
        std.mem.indexOf(u8, line, "\"token_count\"") != null and
        std.mem.indexOf(u8, line, "\"rate_limits\"") != null and
        std.mem.indexOf(u8, line, "\"timestamp\"") != null;
}

fn parseRateLimits(allocator: std.mem.Allocator, parsed: UsageRateLimitsJson) ?registry.RateLimitSnapshot {
    var snap = registry.RateLimitSnapshot{ .primary = null, .secondary = null, .credits = null, .plan_type = null };
    if (parsed.primary) |p| snap.primary = parseWindow(p);
    if (parsed.secondary) |p| snap.secondary = parseWindow(p);
    if (parsed.credits) |c| snap.credits = parseCredits(allocator, c);
    if (parsed.plan_type) |p| snap.plan_type = parsePlanType(p);
    if (snap.primary == null and snap.secondary == null) {
        if (snap.credits) |*credits| {
            if (credits.balance) |balance| allocator.free(balance);
        }
        return null;
    }
    return snap;
}

fn parseWindow(parsed: UsageWindowJson) ?registry.RateLimitWindow {
    const used = parsed.used_percent orelse return null;
    const used_percent = switch (used) {
        .float => |f| f,
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => 0.0,
    };
    return .{
        .used_percent = used_percent,
        .window_minutes = parsed.window_minutes,
        .resets_at = parsed.resets_at,
    };
}

fn parseCredits(allocator: std.mem.Allocator, parsed: UsageCreditsJson) registry.CreditsSnapshot {
    var balance: ?[]u8 = null;
    if (parsed.balance) |b| {
        balance = allocator.dupe(u8, b) catch null;
    }
    return .{
        .has_credits = parsed.has_credits,
        .unlimited = parsed.unlimited,
        .balance = balance,
    };
}

fn parsePlanType(s: []const u8) registry.PlanType {
    if (std.ascii.eqlIgnoreCase(s, "free")) return .free;
    if (std.ascii.eqlIgnoreCase(s, "plus")) return .plus;
    if (std.ascii.eqlIgnoreCase(s, "pro")) return .pro;
    if (std.ascii.eqlIgnoreCase(s, "team")) return .team;
    if (std.ascii.eqlIgnoreCase(s, "business")) return .business;
    if (std.ascii.eqlIgnoreCase(s, "enterprise")) return .enterprise;
    if (std.ascii.eqlIgnoreCase(s, "edu")) return .edu;
    return .unknown;
}

fn parseTimestampMs(s: []const u8) ?i64 {
    if (s.len < 20) return null;
    if (s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':' or s[16] != ':') return null;

    const year = parseDecimal(s[0..4]) orelse return null;
    const month = parseDecimal(s[5..7]) orelse return null;
    const day = parseDecimal(s[8..10]) orelse return null;
    const hour = parseDecimal(s[11..13]) orelse return null;
    const minute = parseDecimal(s[14..16]) orelse return null;
    const second = parseDecimal(s[17..19]) orelse return null;

    if (month < 1 or month > 12) return null;
    if (day < 1 or day > 31) return null;
    if (hour > 23 or minute > 59 or second > 59) return null;

    var idx: usize = 19;
    var millis: i64 = 0;
    if (idx < s.len and s[idx] == '.') {
        idx += 1;
        const frac_start = idx;
        while (idx < s.len and std.ascii.isDigit(s[idx])) : (idx += 1) {}
        if (idx == frac_start) return null;

        const frac_len = idx - frac_start;
        const use_len = @min(frac_len, 3);
        millis = parseDecimal(s[frac_start .. frac_start + use_len]) orelse return null;
        if (use_len == 1) millis *= 100 else if (use_len == 2) millis *= 10;
    }

    if (idx >= s.len or s[idx] != 'Z' or idx + 1 != s.len) return null;

    const days = daysFromCivil(year, month, day);
    return (((days * 24) + hour) * 60 + minute) * 60 * 1000 + second * 1000 + millis;
}

fn parseDecimal(slice: []const u8) ?i64 {
    if (slice.len == 0) return null;
    var value: i64 = 0;
    for (slice) |ch| {
        if (!std.ascii.isDigit(ch)) return null;
        value = value * 10 + (ch - '0');
    }
    return value;
}

fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    const adjusted_year = year - (if (month <= 2) @as(i64, 1) else 0);
    const era = @divFloor(if (adjusted_year >= 0) adjusted_year else adjusted_year - 399, 400);
    const year_of_era = adjusted_year - era * 400;
    const month_prime = month + (if (month > 2) @as(i64, -3) else 9);
    const day_of_year = @divFloor(153 * month_prime + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

fn isRolloutFile(path: []const u8) bool {
    if (!std.mem.endsWith(u8, path, ".jsonl")) return false;
    const base = std.fs.path.basename(path);
    return std.mem.startsWith(u8, base, "rollout-");
}
