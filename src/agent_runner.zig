//! Agent subprocess runner — spawns `nullclaw agent -m "<prompt>"` as a child
//! process with timeout, output capture, and platform-specific exec fallbacks.
//!
//! Extracted from cron.zig so that any subsystem (cron, heartbeat, etc.) can
//! spawn agent jobs without depending on the scheduler.

const std = @import("std");
const std_compat = @import("compat");
const builtin = @import("builtin");
const platform = @import("platform.zig");
const dispatcher = @import("agent/dispatcher.zig");

pub const AgentRunResult = struct {
    success: bool,
    output: []const u8,
};

pub const AgentRunOptions = struct {
    origin_channel: ?[]const u8 = null,
    origin_account_id: ?[]const u8 = null,
    agent_id: ?[]const u8 = null,
};

pub const MAX_OUTPUT_BYTES: usize = 1_048_576;
const POLL_STEP_NS: u64 = 200 * std.time.ns_per_ms;
const LINUX_SELF_EXE_PATH = "/proc/self/exe";
const DELETED_EXE_SUFFIX = " (deleted)";

fn pathAgentExecutableName() []const u8 {
    return if (comptime builtin.os.tag == .windows) "nullclaw.exe" else "nullclaw";
}

fn hasTimeoutExpired(start_ns: i128, timeout_secs: u64) bool {
    if (timeout_secs == 0) return false;
    const timeout_ns = @as(i128, @intCast(timeout_secs)) * std.time.ns_per_s;
    const now_ns = std_compat.time.nanoTimestamp();
    return now_ns - start_ns >= timeout_ns;
}

fn collectChildOutputWithTimeout(
    child: *std_compat.process.Child,
    allocator: std.mem.Allocator,
    stdout: *std.ArrayList(u8),
    stderr: *std.ArrayList(u8),
    timeout_secs: u64,
    start_ns: i128,
) !bool {
    const stdout_file = child.stdout.?;
    const stderr_file = child.stderr.?;
    var stdout_open = true;
    var stderr_open = true;
    var timed_out = false;
    var read_buf: [4096]u8 = undefined;
    while (true) {
        if (!stdout_open and !stderr_open) break;

        if (comptime builtin.os.tag == .windows) {
            if (stdout_open) {
                const n = stdout_file.read(&read_buf) catch |err| switch (err) {
                    error.WouldBlock => 0,
                    else => return err,
                };
                if (n == 0) {
                    stdout_open = false;
                } else {
                    try stdout.appendSlice(allocator, read_buf[0..n]);
                    if (stdout.items.len > MAX_OUTPUT_BYTES) return error.StdoutStreamTooLong;
                }
            }

            if (stderr_open) {
                const n = stderr_file.read(&read_buf) catch |err| switch (err) {
                    error.WouldBlock => 0,
                    else => return err,
                };
                if (n == 0) {
                    stderr_open = false;
                } else {
                    try stderr.appendSlice(allocator, read_buf[0..n]);
                    if (stderr.items.len > MAX_OUTPUT_BYTES) return error.StderrStreamTooLong;
                }
            }

            if (stdout_open or stderr_open) {
                std_compat.thread.sleep(POLL_STEP_NS);
            }
        } else {
            const poll_ms: i32 = if (timeout_secs == 0 or timed_out)
                -1
            else
                @intCast(@divTrunc(POLL_STEP_NS, std.time.ns_per_ms));
            var poll_fds = [_]std.posix.pollfd{
                .{
                    .fd = if (stdout_open) stdout_file.handle else -1,
                    .events = if (stdout_open) std.posix.POLL.IN | std.posix.POLL.HUP else 0,
                    .revents = 0,
                },
                .{
                    .fd = if (stderr_open) stderr_file.handle else -1,
                    .events = if (stderr_open) std.posix.POLL.IN | std.posix.POLL.HUP else 0,
                    .revents = 0,
                },
            };
            _ = try std.posix.poll(&poll_fds, poll_ms);

            if (stdout_open and (poll_fds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP)) != 0) {
                const n = stdout_file.read(&read_buf) catch |err| switch (err) {
                    error.WouldBlock => 0,
                    else => return err,
                };
                if (n == 0) {
                    stdout_open = false;
                } else {
                    try stdout.appendSlice(allocator, read_buf[0..n]);
                    if (stdout.items.len > MAX_OUTPUT_BYTES) return error.StdoutStreamTooLong;
                }
            }

            if (stderr_open and (poll_fds[1].revents & (std.posix.POLL.IN | std.posix.POLL.HUP)) != 0) {
                const n = stderr_file.read(&read_buf) catch |err| switch (err) {
                    error.WouldBlock => 0,
                    else => return err,
                };
                if (n == 0) {
                    stderr_open = false;
                } else {
                    try stderr.appendSlice(allocator, read_buf[0..n]);
                    if (stderr.items.len > MAX_OUTPUT_BYTES) return error.StderrStreamTooLong;
                }
            }
        }

        if (!timed_out and hasTimeoutExpired(start_ns, timeout_secs)) {
            try terminateChildHard(child);
            timed_out = true;
        }
    }

    return timed_out;
}

fn terminateChildHard(child: *std_compat.process.Child) !void {
    if (comptime builtin.os.tag == .windows) {
        _ = child.kill() catch return;
        return;
    }
    if (comptime builtin.os.tag == .wasi) return error.UnsupportedOperation;

    // Signal the whole process group (negative pid), not just this PID: the
    // child was spawned with pgid = its own pid (see the `child.pgid = 0`
    // assignment at spawn time above), so this also reaches any MCP server
    // child processes it started — they'd otherwise survive as orphans,
    // since a SIGKILL'd process never runs its own cleanup defers.
    std.posix.kill(-child.id, std.posix.SIG.KILL) catch |err| switch (err) {
        error.ProcessNotFound => return,
        else => return err,
    };
}

// Last-mile safety net for the 2026-08-16/08-21/08-23/08-30 message-leak
// incidents: `agent/dispatcher.zig`'s `containsToolCallMarkup`, its XML
// marker parser, and `streaming.zig`'s `TagFilter` each independently guard
// against tool-call markup using a closed whitelist of *exact* tag
// spellings (`<tool_call>`, `[TOOL_CALL]`, ...) — and each has, in
// production, missed a malformed variant the model actually produced
// (`<tool_call]>`, `<tool_call_error>`, an unclosed `<tool_call`, a
// hallucinated `Human:` turn boundary, ...). Patching one exact spelling at
// a time is a losing game against unbounded model hallucination shapes.
//
// This check guards the single choke point where subprocess stdout becomes
// an unattended, automatically-delivered message (heartbeat/cron): a broad,
// shape-based heuristic ("does this look like it contains raw tool-call/
// turn-boundary plumbing at all"), not an exact-string match. False
// positives here just mean a generic fallback replaces one delivered report
// — much cheaper than another garbled message reaching the user.
//
// 2026-08-31: this used to be a private copy of the same logic living only
// here, gating delivery but not `agent/root.zig`'s `selectDisplayText` —
// which meant malformed output could still slip into session history and
// get auto-saved to memory before ever reaching this check, re-poisoning
// future context on every failed tick. Now shared via
// `dispatcher.containsLeakedMarkupBroad`, used at both gates.

fn buildAgentOutput(
    allocator: std.mem.Allocator,
    stdout: []const u8,
    timeout_secs: u64,
    timed_out: bool,
    success: bool,
) ![]const u8 {
    if (timed_out) {
        if (stdout.len > 0) {
            return std.fmt.allocPrint(allocator, "{s}\n\n[agent timed out after {d}s]", .{ stdout, timeout_secs });
        }
        return std.fmt.allocPrint(allocator, "agent timed out after {d}s", .{timeout_secs});
    }

    if (!success) {
        if (stdout.len > 0) {
            return std.fmt.allocPrint(allocator, "{s}\n\n[agent execution failed]", .{stdout});
        }
        return allocator.dupe(u8, "agent execution failed");
    }

    // `nullclaw agent -m` writes responses to stdout. Stderr is drained by the
    // runner to avoid pipe backpressure, but it only contains logs/diagnostics
    // and must never become user-visible agent output.
    if (dispatcher.containsLeakedMarkupBroad(stdout)) {
        return allocator.dupe(u8, "[agent produced malformed output — internal/tool-call markup detected in the response, message suppressed. Check logs for details.]");
    }
    return allocator.dupe(u8, stdout);
}

fn isSuccessfulAgentRun(timed_out: bool, exited_zero: bool, stdout: []const u8) bool {
    if (timed_out or !exited_zero) return false;
    return std.mem.trim(u8, stdout, " \t\r\n").len > 0;
}

fn preferExecPath(self_exe_path: []const u8) []const u8 {
    if (comptime builtin.os.tag == .linux) {
        if (std.mem.endsWith(u8, self_exe_path, DELETED_EXE_SUFFIX)) {
            return LINUX_SELF_EXE_PATH;
        }
    }
    return self_exe_path;
}

fn appendAgentArgv(
    allocator: std.mem.Allocator,
    argv: *std.ArrayListUnmanaged([]const u8),
    exec_path: []const u8,
    prompt: []const u8,
    model: ?[]const u8,
    options: AgentRunOptions,
) !void {
    try argv.append(allocator, exec_path);
    try argv.append(allocator, "agent");
    if (model) |m| {
        try argv.append(allocator, "--model");
        try argv.append(allocator, m);
    }
    if (options.origin_channel) |channel| {
        try argv.append(allocator, "--origin-channel");
        try argv.append(allocator, channel);
    }
    if (options.origin_account_id) |account_id| {
        try argv.append(allocator, "--origin-account-id");
        try argv.append(allocator, account_id);
    }
    if (options.agent_id) |agent_id| {
        try argv.append(allocator, "--agent");
        try argv.append(allocator, agent_id);
    }
    try argv.append(allocator, "-m");
    try argv.append(allocator, prompt);
}

pub fn run(
    allocator: std.mem.Allocator,
    cwd: ?[]const u8,
    prompt: []const u8,
    model: ?[]const u8,
    timeout_secs: u64,
) !AgentRunResult {
    return runWithOptions(allocator, cwd, prompt, model, timeout_secs, .{});
}

pub fn runWithOptions(
    allocator: std.mem.Allocator,
    cwd: ?[]const u8,
    prompt: []const u8,
    model: ?[]const u8,
    timeout_secs: u64,
    options: AgentRunOptions,
) !AgentRunResult {
    const exe_path = try std_compat.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);

    var exec_path = preferExecPath(exe_path);
    var exec_cwd = cwd;
    var tried_no_cwd = false;
    var tried_proc_self_exe = std.mem.eql(u8, exec_path, LINUX_SELF_EXE_PATH);
    var tried_path_exec = false;

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);

    var child: std_compat.process.Child = undefined;
    spawn_loop: while (true) {
        argv.clearRetainingCapacity();
        try appendAgentArgv(allocator, &argv, exec_path, prompt, model, options);

        child = std_compat.process.Child.init(argv.items, allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        child.cwd = exec_cwd;
        // New process group (pgid = the child's own pid), set atomically by
        // the standard library between fork and exec — no race window. This
        // lets terminateChildHard SIGKILL the whole group (subprocess + any
        // MCP server children it spawns) on timeout instead of just the
        // subprocess PID, so MCP grandchildren can't survive as orphans when
        // a SIGKILL'd process never gets to run its own cleanup defers. See
        // design.md in the fix-mcp-heartbeat-timeout-leak change.
        child.pgid = 0;

        child.spawn() catch |err| switch (err) {
            error.FileNotFound => {
                // If cwd disappeared, retry from process cwd.
                if (exec_cwd != null and !tried_no_cwd) {
                    exec_cwd = null;
                    tried_no_cwd = true;
                    continue :spawn_loop;
                }

                // If current binary path became stale after in-place rebuild,
                // Linux can still re-exec through /proc/self/exe.
                if (comptime builtin.os.tag == .linux) {
                    if (!tried_proc_self_exe and !std.mem.eql(u8, exec_path, LINUX_SELF_EXE_PATH)) {
                        exec_path = LINUX_SELF_EXE_PATH;
                        exec_cwd = cwd;
                        tried_no_cwd = false;
                        tried_proc_self_exe = true;
                        continue :spawn_loop;
                    }
                }

                // Cross-platform fallback: try resolving `nullclaw` from PATH.
                // Useful when self-exe path is stale or inaccessible outside Linux.
                if (!tried_path_exec) {
                    exec_path = pathAgentExecutableName();
                    exec_cwd = null;
                    tried_no_cwd = true;
                    tried_path_exec = true;
                    continue :spawn_loop;
                }

                return err;
            },
            else => return err,
        };
        break :spawn_loop;
    }

    errdefer {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
    }

    const start_ns = std_compat.time.nanoTimestamp();

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);

    const timed_out = try collectChildOutputWithTimeout(
        &child,
        allocator,
        &stdout,
        &stderr,
        timeout_secs,
        start_ns,
    );

    const term = try child.wait();
    const exited_zero = switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
    const success = isSuccessfulAgentRun(timed_out, exited_zero, stdout.items);
    const output = try buildAgentOutput(allocator, stdout.items, timeout_secs, timed_out, success);
    return .{ .success = success, .output = output };
}

// ── Tests ──────────────────────────────────────────────────────────

test "collectChildOutputWithTimeout disables timeout when set to zero" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var child = std_compat.process.Child.init(&.{ platform.getShell(), platform.getShellFlag(), "echo ready" }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    errdefer {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
    }

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);

    const timed_out = try collectChildOutputWithTimeout(
        &child,
        allocator,
        &stdout,
        &stderr,
        0,
        std_compat.time.nanoTimestamp(),
    );
    const term = try child.wait();

    try std.testing.expect(!timed_out);
    switch (term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => try std.testing.expect(false),
    }
    try std.testing.expect(std.mem.indexOf(u8, stdout.items, "ready") != null);
}

test "collectChildOutputWithTimeout kills process after deadline" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var child = std_compat.process.Child.init(&.{ platform.getShell(), platform.getShellFlag(), "sleep 2; echo never" }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    // Mirrors runWithOptions' spawn (pgid = own pid) — terminateChildHard
    // signals the process group, so the child must actually be one for the
    // hard-kill below to reach it.
    child.pgid = 0;
    try child.spawn();
    errdefer {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
    }

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);

    const timed_out = try collectChildOutputWithTimeout(
        &child,
        allocator,
        &stdout,
        &stderr,
        1,
        std_compat.time.nanoTimestamp(),
    );
    const term = try child.wait();

    try std.testing.expect(timed_out);
    const completed_ok = switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
    try std.testing.expect(!completed_ok);
}

test "terminateChildHard kills grandchild processes via process group" {
    // Regression test for the 2026-08-16 MCP-subprocess-leak incident: a
    // hard-timeout kill of the spawned child must also reach any process
    // that child itself spawned (e.g. an MCP server), not just the child.
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var child = std_compat.process.Child.init(&.{
        platform.getShell(), platform.getShellFlag(),
        "sleep 5 & echo $!; wait $!",
    }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.pgid = 0;
    try child.spawn();
    errdefer {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
    }

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);

    const timed_out = try collectChildOutputWithTimeout(
        &child,
        allocator,
        &stdout,
        &stderr,
        1,
        std_compat.time.nanoTimestamp(),
    );
    _ = try child.wait();
    try std.testing.expect(timed_out);

    const grandchild_pid = try std.fmt.parseInt(
        i32,
        std.mem.trim(u8, stdout.items, " \n\t\r"),
        10,
    );

    // Give the kernel a moment to finish delivering SIGKILL/reaping.
    std_compat.thread.sleep(200 * std.time.ns_per_ms);

    const still_alive = if (std.posix.kill(grandchild_pid, @enumFromInt(0))) |_| true else |err| switch (err) {
        error.ProcessNotFound => false,
        else => true,
    };
    try std.testing.expect(!still_alive);
}

test "buildAgentOutput returns stdout on success" {
    const allocator = std.testing.allocator;
    const result = try buildAgentOutput(allocator, "hello", 0, false, true);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello", result);
}

test "buildAgentOutput suppresses hallucinated tool_call_error markup" {
    // Regression for the 2026-08-30 web_search-failure incident: the model
    // hallucinated its own pseudo-XML echoing the internal <tool_result
    // status="error"> format it had seen, and it leaked verbatim as the
    // "successful" delivered message.
    const allocator = std.testing.allocator;
    const leaked =
        \\<tool_call_error>
        \\<tool_name>web_search</tool_name>
        \\<error>Web search failed: request failed after 3 attempts</error>
        \\<tool_name>web_search</tool_name>
        \\</tool_call_error>
        \\<tool_name>web_fetch</tool_name>
        \\</tool_call_error>
    ;
    const result = try buildAgentOutput(allocator, leaked, 0, false, true);
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "<tool") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "markup detected") != null);
}

test "buildAgentOutput suppresses malformed tool_call tag variants" {
    // Regression for a live incident where the model emitted non-canonical
    // tag shapes (<tool_call]>, <tool_call[]>) that the exact-string
    // whitelists in dispatcher.containsToolCallMarkup don't recognize.
    const allocator = std.testing.allocator;
    const leaked = "<tool_call]> {\"name\": \"web_search\"} </tool_call";
    const result = try buildAgentOutput(allocator, leaked, 0, false, true);
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "<tool_call") == null);
}

test "buildAgentOutput suppresses a hallucinated Human: turn boundary" {
    const allocator = std.testing.allocator;
    const leaked = "Готово.\nHuman: продолжай\nAssistant: конечно";
    const result = try buildAgentOutput(allocator, leaked, 0, false, true);
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "Human:") == null);
}

test "buildAgentOutput leaves an ordinary clean report untouched" {
    const allocator = std.testing.allocator;
    const clean = "Погода в Москве сегодня:\n🌤️ Переменная облачность\n🌡️ +20…+23 °C";
    const result = try buildAgentOutput(allocator, clean, 0, false, true);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(clean, result);
}

test "buildAgentOutput returns generic message for empty failure" {
    // Regression: stderr-only initialization logs must not replace the missing
    // response, while on_error delivery still needs a non-sensitive message.
    const allocator = std.testing.allocator;
    const result = try buildAgentOutput(allocator, "", 0, false, false);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("agent execution failed", result);
}

test "buildAgentOutput marks partial stdout as failed" {
    const allocator = std.testing.allocator;
    const result = try buildAgentOutput(allocator, "partial output", 0, false, false);
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "partial output") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "agent execution failed") != null);
}

test "buildAgentOutput appends timeout annotation" {
    const allocator = std.testing.allocator;
    const result = try buildAgentOutput(allocator, "working...", 30, true, false);
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "working...") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "timed out after 30s") != null);
}

test "buildAgentOutput timeout without stdout is generic" {
    // Regression: timeout diagnostics from stderr must not be delivered as an
    // agent response when the child produced no stdout.
    const allocator = std.testing.allocator;
    const result = try buildAgentOutput(allocator, "", 60, true, false);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("agent timed out after 60s", result);
}

test "isSuccessfulAgentRun rejects timeout exit failure and empty stdout" {
    // Regression: CLI soft failures can exit zero after logging only to stderr.
    try std.testing.expect(isSuccessfulAgentRun(false, true, "response\n"));
    try std.testing.expect(!isSuccessfulAgentRun(true, true, "response\n"));
    try std.testing.expect(!isSuccessfulAgentRun(false, false, "response\n"));
    try std.testing.expect(!isSuccessfulAgentRun(false, true, "\n"));
}

test "preferExecPath keeps regular executable path" {
    const input = "/home/user/bin/nullclaw";
    try std.testing.expectEqualStrings(input, preferExecPath(input));
}

test "preferExecPath uses proc self exe for deleted linux path" {
    if (comptime builtin.os.tag != .linux) return;
    try std.testing.expectEqualStrings(LINUX_SELF_EXE_PATH, preferExecPath("/tmp/nullclaw (deleted)"));
}

test "pathAgentExecutableName returns platform command name" {
    const expected = if (comptime builtin.os.tag == .windows) "nullclaw.exe" else "nullclaw";
    try std.testing.expectEqualStrings(expected, pathAgentExecutableName());
}

test "appendAgentArgv includes cron origin attribution" {
    // Regression: scheduled child agents must receive origin metadata in every spawn attempt.
    const allocator = std.testing.allocator;
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);

    try appendAgentArgv(allocator, &argv, "/usr/bin/nullclaw", "Summarize status", "test-model", .{
        .origin_channel = "telegram",
        .origin_account_id = "main",
    });

    const expected = [_][]const u8{
        "/usr/bin/nullclaw",
        "agent",
        "--model",
        "test-model",
        "--origin-channel",
        "telegram",
        "--origin-account-id",
        "main",
        "-m",
        "Summarize status",
    };
    try std.testing.expectEqual(expected.len, argv.items.len);
    for (expected, argv.items) |want, got| {
        try std.testing.expectEqualStrings(want, got);
    }
}

test "appendAgentArgv includes --agent when agent_id is set" {
    const allocator = std.testing.allocator;
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);

    try appendAgentArgv(allocator, &argv, "/usr/bin/nullclaw", "Summarize status", "test-model", .{
        .origin_channel = "telegram",
        .origin_account_id = "main",
        .agent_id = "taskmaster",
    });

    const expected = [_][]const u8{
        "/usr/bin/nullclaw",
        "agent",
        "--model",
        "test-model",
        "--origin-channel",
        "telegram",
        "--origin-account-id",
        "main",
        "--agent",
        "taskmaster",
        "-m",
        "Summarize status",
    };
    try std.testing.expectEqual(expected.len, argv.items.len);
    for (expected, argv.items) |want, got| {
        try std.testing.expectEqualStrings(want, got);
    }
}
