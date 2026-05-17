const std = @import("std");
const auth = @import("../auth.zig");
const registry = @import("../registry.zig");
const warm = @import("../warm.zig");
const auto = @import("../auto.zig");
const bdd = @import("bdd_helpers.zig");

var runner_sequence: usize = 0;

fn resetRunnerSequence() void {
    runner_sequence = 0;
}

fn writeAccountSnapshot(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    email: []const u8,
    plan: []const u8,
) !void {
    const account_key = try bdd.accountKeyForEmailAlloc(allocator, email);
    defer allocator.free(account_key);

    const auth_path = try registry.accountAuthPath(allocator, codex_home, account_key);
    defer allocator.free(auth_path);
    const auth_json = try bdd.authJsonWithEmailPlan(allocator, email, plan);
    defer allocator.free(auth_json);
    try std.fs.cwd().writeFile(.{ .sub_path = auth_path, .data = auth_json });
}

fn writeActiveAuth(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    email: []const u8,
    plan: []const u8,
) !void {
    const auth_path = try registry.activeAuthPath(allocator, codex_home);
    defer allocator.free(auth_path);
    const auth_json = try bdd.authJsonWithEmailPlan(allocator, email, plan);
    defer allocator.free(auth_json);
    try std.fs.cwd().writeFile(.{ .sub_path = auth_path, .data = auth_json });
}

fn activeEmailAlloc(allocator: std.mem.Allocator, codex_home: []const u8) ![]u8 {
    const auth_path = try registry.activeAuthPath(allocator, codex_home);
    defer allocator.free(auth_path);
    var info = try auth.parseAuthInfo(allocator, auth_path);
    defer info.deinit(allocator);
    return allocator.dupe(u8, info.email orelse return error.MissingEmail);
}

fn authExists(codex_home: []const u8) !bool {
    const path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ codex_home, "auth.json" });
    defer std.testing.allocator.free(path);
    std.fs.cwd().access(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn writeRunnerRollout(
    allocator: std.mem.Allocator,
    ctx: warm.RunnerContext,
    rate_limits_json: []const u8,
) !void {
    runner_sequence += 1;
    const sessions_dir = try std.fs.path.join(allocator, &[_][]const u8{
        ctx.temp_codex_home,
        "sessions",
        "2099",
        "01",
        "01",
    });
    defer allocator.free(sessions_dir);
    try std.fs.cwd().makePath(sessions_dir);

    const basename = try std.fmt.allocPrint(allocator, "rollout-{d}.jsonl", .{runner_sequence});
    defer allocator.free(basename);
    const rollout_path = try std.fs.path.join(allocator, &[_][]const u8{ sessions_dir, basename });
    defer allocator.free(rollout_path);
    const line = try std.fmt.allocPrint(
        allocator,
        "{{\"timestamp\":\"2099-01-01T00:00:{d:0>2}.000Z\",\"type\":\"event_msg\",\"payload\":{{\"type\":\"token_count\",\"rate_limits\":{s}}}}}",
        .{ runner_sequence, rate_limits_json },
    );
    defer allocator.free(line);
    try std.fs.cwd().writeFile(.{ .sub_path = rollout_path, .data = line });
}

fn updatedRunner(allocator: std.mem.Allocator, ctx: warm.RunnerContext) !warm.RunnerTermination {
    try writeRunnerRollout(
        allocator,
        ctx,
        "{\"primary\":{\"used_percent\":12.0,\"window_minutes\":300,\"resets_at\":4070908800},\"secondary\":{\"used_percent\":20.0,\"window_minutes\":10080,\"resets_at\":4071427200},\"plan_type\":\"pro\"}",
    );
    return .{ .Exited = 0 };
}

fn nonZeroUpdatedRunner(allocator: std.mem.Allocator, ctx: warm.RunnerContext) !warm.RunnerTermination {
    try writeRunnerRollout(
        allocator,
        ctx,
        "{\"primary\":{\"used_percent\":8.0,\"window_minutes\":300,\"resets_at\":4070908800},\"secondary\":{\"used_percent\":15.0,\"window_minutes\":10080,\"resets_at\":4071427200},\"plan_type\":\"pro\"}",
    );
    return .{ .Exited = 1 };
}

fn exhaustedRunner(allocator: std.mem.Allocator, ctx: warm.RunnerContext) !warm.RunnerTermination {
    try writeRunnerRollout(
        allocator,
        ctx,
        "{\"secondary\":{\"used_percent\":100.0,\"window_minutes\":10080,\"resets_at\":4071427200},\"plan_type\":\"free\"}",
    );
    return .{ .Exited = 0 };
}

fn noUsableWindowsRunner(allocator: std.mem.Allocator, ctx: warm.RunnerContext) !warm.RunnerTermination {
    try writeRunnerRollout(
        allocator,
        ctx,
        "{\"primary\":null,\"secondary\":null,\"plan_type\":\"team\"}",
    );
    return .{ .Exited = 0 };
}

fn missingRunner(_: std.mem.Allocator, _: warm.RunnerContext) !warm.RunnerTermination {
    return error.RunnerMissing;
}

fn failedRunner(_: std.mem.Allocator, _: warm.RunnerContext) !warm.RunnerTermination {
    return error.RunnerFailed;
}

fn failOneThenUpdateRunner(allocator: std.mem.Allocator, ctx: warm.RunnerContext) !warm.RunnerTermination {
    if (std.mem.eql(u8, ctx.email, "broken@example.com")) return error.RunnerFailed;
    return updatedRunner(allocator, ctx);
}

test "Scenario: Given warm on a non-active account when it completes then it restores the original active account and auto-switch state" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try registry.ensureAccountsDir(gpa, codex_home);

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    reg.auto_switch.enabled = true;
    try bdd.appendAccount(gpa, &reg, "primary@example.com", "primary", .pro);
    try bdd.appendAccount(gpa, &reg, "backup@example.com", "backup", .pro);
    try registry.setActiveAccountKey(gpa, &reg, reg.accounts.items[0].account_key);
    try registry.saveRegistry(gpa, codex_home, &reg);
    try writeAccountSnapshot(gpa, codex_home, "primary@example.com", "pro");
    try writeAccountSnapshot(gpa, codex_home, "backup@example.com", "pro");
    try writeActiveAuth(gpa, codex_home, "primary@example.com", "pro");

    resetRunnerSequence();
    var summary = try warm.runWithDeps(gpa, codex_home, &reg, &[_]usize{1}, .{ .runner = updatedRunner });
    defer summary.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), summary.countOutcome(.updated));
    try std.testing.expect(summary.countOutcome(.failed) == 0);
    try std.testing.expectEqualStrings(reg.accounts.items[0].account_key, reg.active_account_key.?);
    try std.testing.expect(reg.auto_switch.enabled);

    const active_email = try activeEmailAlloc(gpa, codex_home);
    defer gpa.free(active_email);
    try std.testing.expectEqualStrings("primary@example.com", active_email);
}

test "Scenario: Given warm starts without an active account or auth file when it finishes then it restores the no-active state exactly" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try registry.ensureAccountsDir(gpa, codex_home);

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    try bdd.appendAccount(gpa, &reg, "solo@example.com", "solo", .pro);
    try registry.saveRegistry(gpa, codex_home, &reg);
    try writeAccountSnapshot(gpa, codex_home, "solo@example.com", "pro");

    resetRunnerSequence();
    var summary = try warm.runWithDeps(gpa, codex_home, &reg, &[_]usize{0}, .{ .runner = updatedRunner });
    defer summary.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), summary.countOutcome(.updated));
    try std.testing.expect(reg.active_account_key == null);
    try std.testing.expect(reg.active_account_activated_at_ms == null);
    try std.testing.expect(!(try authExists(codex_home)));
}

test "Scenario: Given warm when the runner exits non-zero but writes a usable rollout then the snapshot is still imported" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try registry.ensureAccountsDir(gpa, codex_home);

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    try bdd.appendAccount(gpa, &reg, "solo@example.com", "solo", .pro);
    try registry.setActiveAccountKey(gpa, &reg, reg.accounts.items[0].account_key);
    try registry.saveRegistry(gpa, codex_home, &reg);
    try writeAccountSnapshot(gpa, codex_home, "solo@example.com", "pro");
    try writeActiveAuth(gpa, codex_home, "solo@example.com", "pro");

    resetRunnerSequence();
    var summary = try warm.runWithDeps(gpa, codex_home, &reg, &[_]usize{0}, .{ .runner = nonZeroUpdatedRunner });
    defer summary.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), summary.countOutcome(.updated));
    try std.testing.expect(reg.accounts.items[0].last_usage != null);
    try std.testing.expect(reg.accounts.items[0].last_usage_at != null);
    try std.testing.expect(reg.accounts.items[0].last_local_rollout != null);
    try std.testing.expect(std.mem.indexOf(u8, reg.accounts.items[0].last_local_rollout.?.path, "sessions/local-seed/") != null);
}

test "Scenario: Given warm when the rollout has no usable windows then it reports unknown and leaves the account snapshot unknown" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try registry.ensureAccountsDir(gpa, codex_home);

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    try bdd.appendAccount(gpa, &reg, "team@example.com", "team", .team);
    try registry.setActiveAccountKey(gpa, &reg, reg.accounts.items[0].account_key);
    try registry.saveRegistry(gpa, codex_home, &reg);
    try writeAccountSnapshot(gpa, codex_home, "team@example.com", "team");
    try writeActiveAuth(gpa, codex_home, "team@example.com", "team");

    resetRunnerSequence();
    var summary = try warm.runWithDeps(gpa, codex_home, &reg, &[_]usize{0}, .{ .runner = noUsableWindowsRunner });
    defer summary.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), summary.countOutcome(.unknown));
    try std.testing.expectEqual(warm.FailureReason.NoUsableWindows, summary.results.items[0].reason.?);
    try std.testing.expect(reg.accounts.items[0].last_usage == null);
    try std.testing.expect(reg.accounts.items[0].last_usage_at == null);
    try std.testing.expect(reg.accounts.items[0].last_local_rollout == null);
}

test "Scenario: Given warm starts from malformed auth when it finishes then it restores the original raw auth bytes and leaves the registry active state cleared" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try registry.ensureAccountsDir(gpa, codex_home);

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    try bdd.appendAccount(gpa, &reg, "solo@example.com", "solo", .pro);
    try registry.saveRegistry(gpa, codex_home, &reg);
    try writeAccountSnapshot(gpa, codex_home, "solo@example.com", "pro");

    const auth_path = try registry.activeAuthPath(gpa, codex_home);
    defer gpa.free(auth_path);
    const broken_auth = "{\"broken\":true}";
    try std.fs.cwd().writeFile(.{ .sub_path = auth_path, .data = broken_auth });

    resetRunnerSequence();
    var summary = try warm.runWithDeps(gpa, codex_home, &reg, &[_]usize{0}, .{ .runner = updatedRunner });
    defer summary.deinit(gpa);

    const restored_auth = try bdd.readFileAlloc(gpa, auth_path);
    defer gpa.free(restored_auth);
    try std.testing.expectEqualStrings(broken_auth, restored_auth);
    try std.testing.expect(reg.active_account_key == null);
    try std.testing.expect(reg.active_account_activated_at_ms == null);
}

test "Scenario: Given warm all when every refreshed account is exhausted then it restores state and eligible candidates remain zero" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try registry.ensureAccountsDir(gpa, codex_home);

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    reg.auto_switch.enabled = true;
    try bdd.appendAccount(gpa, &reg, "active@example.com", "active", .free);
    try bdd.appendAccount(gpa, &reg, "backup@example.com", "backup", .free);
    try registry.setActiveAccountKey(gpa, &reg, reg.accounts.items[0].account_key);
    try registry.saveRegistry(gpa, codex_home, &reg);
    try writeAccountSnapshot(gpa, codex_home, "active@example.com", "free");
    try writeAccountSnapshot(gpa, codex_home, "backup@example.com", "free");
    try writeActiveAuth(gpa, codex_home, "active@example.com", "free");

    resetRunnerSequence();
    var summary = try warm.runWithDeps(gpa, codex_home, &reg, &[_]usize{ 0, 1 }, .{ .runner = exhaustedRunner });
    defer summary.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), summary.countOutcome(.updated));
    try std.testing.expect(reg.auto_switch.enabled);
    try std.testing.expectEqualStrings(reg.accounts.items[0].account_key, reg.active_account_key.?);

    var status = try auto.getStatus(gpa, codex_home);
    defer status.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), status.eligible_candidates);
}

test "Scenario: Given warm when no runner is available then it reports a runner-missing failure and restores state" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try registry.ensureAccountsDir(gpa, codex_home);

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    reg.auto_switch.enabled = true;
    try bdd.appendAccount(gpa, &reg, "solo@example.com", "solo", .pro);
    try registry.setActiveAccountKey(gpa, &reg, reg.accounts.items[0].account_key);
    try registry.saveRegistry(gpa, codex_home, &reg);
    try writeAccountSnapshot(gpa, codex_home, "solo@example.com", "pro");
    try writeActiveAuth(gpa, codex_home, "solo@example.com", "pro");

    resetRunnerSequence();
    var summary = try warm.runWithDeps(gpa, codex_home, &reg, &[_]usize{0}, .{ .runner = missingRunner });
    defer summary.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), summary.countOutcome(.failed));
    try std.testing.expectEqual(warm.FailureReason.RunnerMissing, summary.results.items[0].reason.?);
    try std.testing.expect(reg.auto_switch.enabled);
    try std.testing.expectEqualStrings(reg.accounts.items[0].account_key, reg.active_account_key.?);
}

test "Scenario: Given warm all when one runner fails to start then it continues other accounts and reports RunnerFailed per account" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try registry.ensureAccountsDir(gpa, codex_home);

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    reg.auto_switch.enabled = true;
    try bdd.appendAccount(gpa, &reg, "broken@example.com", "broken", .pro);
    try bdd.appendAccount(gpa, &reg, "healthy@example.com", "healthy", .pro);
    try registry.setActiveAccountKey(gpa, &reg, reg.accounts.items[1].account_key);
    try registry.saveRegistry(gpa, codex_home, &reg);
    try writeAccountSnapshot(gpa, codex_home, "broken@example.com", "pro");
    try writeAccountSnapshot(gpa, codex_home, "healthy@example.com", "pro");
    try writeActiveAuth(gpa, codex_home, "healthy@example.com", "pro");

    resetRunnerSequence();
    var summary = try warm.runWithDeps(gpa, codex_home, &reg, &[_]usize{ 0, 1 }, .{ .runner = failOneThenUpdateRunner });
    defer summary.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), summary.countOutcome(.failed));
    try std.testing.expectEqual(@as(usize, 1), summary.countOutcome(.updated));
    try std.testing.expectEqual(warm.FailureReason.RunnerFailed, summary.results.items[0].reason.?);
    try std.testing.expect(reg.accounts.items[1].last_usage != null);
    try std.testing.expectEqualStrings(reg.accounts.items[1].account_key, reg.active_account_key.?);
    try std.testing.expect(reg.auto_switch.enabled);
}
