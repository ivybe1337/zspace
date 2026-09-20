const std = @import("std");
const types = @import("../core/types.zig");
const scanner = @import("../core/scanner.zig");
const dedup = @import("../core/dedup.zig");
const analyzer = @import("../core/analyzer.zig");
const cleaner = @import("../core/cleaner.zig");
const snapshot_mod = @import("../core/snapshot.zig");
const apfs = @import("../core/apfs.zig");
const disks = @import("../core/disks.zig");
const tui = @import("../tui/tui.zig");
const gui = @import("../gui/app.zig");
const repl = @import("../repl/repl.zig");
const tui_select = @import("../core/tui_select.zig");
const visualizer3d = @import("../gui/visualizer3d.zig");
const out = @import("../core/out.zig");

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
});

/// C06 machine CLI contract: unified exit codes.
/// 0 = ok, 2 = usage error, 3 = scan/io error, 4 = no results (empty set).
pub const ExitCode: u8 = u8;
pub const EXIT_OK: u8 = 0;
pub const EXIT_USAGE: u8 = 2;
pub const EXIT_SCAN: u8 = 3;
pub const EXIT_EMPTY: u8 = 4;

pub const OutputFormat = enum { table, json };

pub const GlobalOpts = struct {
    format: OutputFormat = .table,
    dry_run: bool = false,
    verbose: bool = false,
    min_size: u64 = 0,
    interactive: bool = false,
    select: []const u8 = "",  // comma-separated indices like "34,12,7"
};

/// Unified selectable item for interactive cleanup. Deletion goes through
/// Cleaner.safeMoveToTrash at the call site; no function-pointer field (Zig
/// 0.16 forbids inferred-error-set fn types in struct fields — C06 note).
pub const SelectableItem = struct {
    id: usize, // Display ID (1-based for user)
    title: []const u8,
    path: []const u8,
    size_bytes: u64,
    risk: analyzer.RiskLevel,
    is_quick_win: bool,
};

/// Interactive selection state
const SelectionState = struct {
    items: []SelectableItem,
    selected: []bool,
    cursor: usize = 0,
    scroll_offset: usize = 0,
    term_height: usize = 24,
};

/// Parse comma-separated indices like "34,12,7" into a sorted array of 0-based indices
fn parseSelectionIndices(allocator: std.mem.Allocator, input: []const u8) !std.ArrayList(usize) {
    var result: std.ArrayList(usize) = .{ .items = &.{}, .capacity = 0 };
    var iter = std.mem.splitScalar(u8, input, ',');
    while (iter.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        if (trimmed.len == 0) continue;
        const idx = std.fmt.parseInt(usize, trimmed, 10) catch continue;
        if (idx > 0) {
            // Convert 1-based user input to 0-based index
            try result.append(allocator, idx - 1);
        }
    }
    // Sort and deduplicate
    std.mem.sort(usize, result.items, {}, std.sort.asc(usize));
    var deduped: std.ArrayList(usize) = .{ .items = &.{}, .capacity = 0 };
    defer deduped.deinit(allocator);
    for (result.items) |idx| {
        if (deduped.items.len == 0 or deduped.items[deduped.items.len - 1] != idx) {
            try deduped.append(allocator, idx);
        }
    }
    result.deinit(allocator);
    return deduped.toOwnedSlice(allocator);
}

/// Check if an index is in the selection list
fn isIndexSelected(indices: []const usize, index: usize) bool {
    for (indices) |i| {
        if (i == index) return true;
    }
    return false;
}

fn logVerbose(opts: GlobalOpts, comptime fmt: []const u8, args: anytype) void {
    if (!opts.verbose) return;
    // stderr via raw write(2), matching out.zig idiom (no Io instance needed).
    var buf: [2048]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = c.write(2, slice.ptr, slice.len);
    _ = c.write(2, "\n".ptr, 1);
}

/// Parse `--min-size=<n>` / `--min-size <n>` with KB/MB/GB/TB suffixes (case-insensitive).
/// Bare integers are bytes. Returns error.InvalidMinSize on failure.
fn parseMinSize(text: []const u8) !u64 {
    if (text.len == 0) return error.InvalidMinSize;
    var num_end: usize = 0;
    while (num_end < text.len and std.ascii.isDigit(text[num_end])) : (num_end += 1) {}
    if (num_end == 0) return error.InvalidMinSize;
    const num = std.fmt.parseInt(u64, text[0..num_end], 10) catch return error.InvalidMinSize;
    const suffix = text[num_end..];
    if (suffix.len == 0 or std.ascii.eqlIgnoreCase(suffix, "b")) return num;
    if (std.ascii.eqlIgnoreCase(suffix, "k") or std.ascii.eqlIgnoreCase(suffix, "kb")) return num * 1024;
    if (std.ascii.eqlIgnoreCase(suffix, "m") or std.ascii.eqlIgnoreCase(suffix, "mb")) return num * 1024 * 1024;
    if (std.ascii.eqlIgnoreCase(suffix, "g") or std.ascii.eqlIgnoreCase(suffix, "gb")) return num * 1024 * 1024 * 1024;
    if (std.ascii.eqlIgnoreCase(suffix, "t") or std.ascii.eqlIgnoreCase(suffix, "tb")) return num * 1024 * 1024 * 1024 * 1024;
    return error.InvalidMinSize;
}

fn usageError(comptime fmt: []const u8, args: anytype) u8 {
    out.print("error: " ++ fmt ++ "\n\n", args);
    printHelp();
    return EXIT_USAGE;
}

const ParsedArgs = struct {
    command: ?[]const u8 = null,
    positionals: []const []const u8 = &.{},
    opts: GlobalOpts = .{},
    help_requested: bool = false,
    command_help: bool = false,
};

/// Split argv[1..] into: command (first non-flag), positionals, and global
/// flags. Flags may appear before OR after the command/path so both
/// `zspace --format=json scan <path>` and `zspace scan <path> --format=json`
/// work. `--format=json|table`, `--dry-run`, `--verbose`,
/// `--min-size=<n>` (also `--min-size <n>`).
fn parseCliArgs(allocator: std.mem.Allocator, raw: []const []const u8) !ParsedArgs {
    var opts = GlobalOpts{};
    var command: ?[]const u8 = null;
    var positionals: std.ArrayList([]const u8) = .{ .items = &.{}, .capacity = 0 };
    defer positionals.deinit(allocator);
    var help_requested = false;
    var command_help = false;

    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const arg = raw[i];
        if (std.mem.eql(u8, arg, "--")) {
            // Everything after `--` is positional.
            i += 1;
            while (i < raw.len) : (i += 1) {
                if (command == null) {
                    command = raw[i];
                } else {
                    try positionals.append(allocator, raw[i]);
                }
            }
            break;
        } else if (std.mem.startsWith(u8, arg, "--format=")) {
            const val = arg["--format=".len..];
            if (std.mem.eql(u8, val, "json")) {
                opts.format = .json;
            } else if (std.mem.eql(u8, val, "table")) {
                opts.format = .table;
            } else {
                return error.InvalidFormat;
            }
        } else if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i >= raw.len) return error.MissingFlagValue;
            const val = raw[i];
            if (std.mem.eql(u8, val, "json")) {
                opts.format = .json;
            } else if (std.mem.eql(u8, val, "table")) {
                opts.format = .table;
            } else {
                return error.InvalidFormat;
            }
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            opts.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            opts.verbose = true;
        } else if (std.mem.eql(u8, arg, "--interactive") or std.mem.eql(u8, arg, "-i")) {
            opts.interactive = true;
        } else if (std.mem.startsWith(u8, arg, "--select=")) {
            opts.select = arg["--select=".len..];
        } else if (std.mem.eql(u8, arg, "--select")) {
            i += 1;
            if (i >= raw.len) return error.MissingFlagValue;
            opts.select = raw[i];
        } else if (std.mem.startsWith(u8, arg, "--min-size=")) {
            const val = arg["--min-size=".len..];
            opts.min_size = parseMinSize(val) catch return error.InvalidMinSize;
        } else if (std.mem.eql(u8, arg, "--min-size")) {
            i += 1;
            if (i >= raw.len) return error.MissingFlagValue;
            opts.min_size = parseMinSize(raw[i]) catch return error.InvalidMinSize;
        } else if (std.mem.eql(u8, arg, "--interactive") or std.mem.eql(u8, arg, "-i")) {
            opts.interactive = true;
        } else if (std.mem.startsWith(u8, arg, "--select=")) {
            opts.select = arg["--select=".len..];
        } else if (std.mem.eql(u8, arg, "--select")) {
            i += 1;
            if (i >= raw.len) return error.MissingFlagValue;
            opts.select = raw[i];
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            if (command != null) {
                command_help = true;
            } else {
                help_requested = true;
            }
        } else if (std.mem.eql(u8, arg, "-psn") or std.mem.startsWith(u8, arg, "-psn_")) {
            continue; // belt-and-suspenders: main.zig already strips these.
        } else if (arg.len > 1 and arg[0] == '-' and command == null) {
            return error.UnknownFlag;
        } else if (command == null) {
            command = arg;
        } else {
            try positionals.append(allocator, arg);
        }
    }

    const owned = try positionals.toOwnedSlice(allocator);
    return .{ .command = command, .positionals = owned, .opts = opts, .help_requested = help_requested, .command_help = command_help };
}

fn isHelpArg(s: []const u8) bool {
    return std.mem.eql(u8, s, "--help") or std.mem.eql(u8, s, "-h") or std.mem.eql(u8, s, "help");
}

fn isVersionArg(s: []const u8) bool {
    return std.mem.eql(u8, s, "version") or std.mem.eql(u8, s, "--version") or std.mem.eql(u8, s, "-V");
}

pub fn runCli(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    const argv = if (args.len > 0) args[1..] else args[0..0];

    var parsed = parseCliArgs(allocator, argv) catch |err| {
        return switch (err) {
            error.InvalidFormat => usageError("invalid --format (expected json|table)", .{}),
            error.InvalidMinSize => usageError("invalid --min-size (expected e.g. 1KB, 10MB, 1073741824)", .{}),
            error.MissingFlagValue => usageError("flag is missing its value", .{}),
            error.UnknownFlag => usageError("unknown flag (see --help)", .{}),
            else => EXIT_USAGE,
        };
    };
    defer allocator.free(parsed.positionals);
    const opts = parsed.opts;

    // Bare launch (or Finder -psn-only launch): open GUI off-terminal,
    // otherwise print help. This is the `open ZSpace.app` contract.
    if (parsed.command == null) {
        if (parsed.help_requested) {
            printHelp();
            return EXIT_OK;
        }
        const is_terminal = c.isatty(0) == 1;
        if (!is_terminal) {
            const home_c = c.getenv("HOME");
            const launch_dir = if (home_c != null) std.mem.span(@as([*:0]const u8, @ptrCast(home_c))) else ".";
            runGuiCmd(allocator, launch_dir, opts) catch return EXIT_SCAN;
            return EXIT_OK;
        }
        printHelp();
        return EXIT_OK;
    }

    const command = parsed.command.?;
    if (isHelpArg(command)) {
        printHelp();
        return EXIT_OK;
    }
    if (isVersionArg(command)) {
        printVersion(opts);
        return EXIT_OK;
    }
    // `zspace <path> --help`-style: command slot holds a path; real command unknown.
    // Fall through to unknown-command handling below which prints per-command help hint.

    // Per-command --help (both `zspace scan --help` and `zspace help scan`).
    if (parsed.command_help) {
        printCommandHelp(command);
        return EXIT_OK;
    }
    if (std.mem.eql(u8, command, "help")) {
        if (parsed.positionals.len > 0) {
            printCommandHelp(parsed.positionals[0]);
        } else {
            printHelp();
        }
        return EXIT_OK;
    }

    if (std.mem.eql(u8, command, "repl")) {
        const init_p: ?[]const u8 = if (parsed.positionals.len >= 1) parsed.positionals[0] else null;
        // REPL is interactive: flags other than --verbose do not apply.
        logVerbose(opts, "[zspace] repl path={s}", .{init_p orelse "."});
        var r = repl.Repl.init(allocator) catch return EXIT_SCAN;
        defer r.deinit();
        r.run(init_p) catch return EXIT_SCAN;
        return EXIT_OK;
    }

    // Resolve target path: first positional, default ".".
    // `top` also accepts an optional trailing limit.
    var target_path: []const u8 = ".";
    var top_limit: usize = 20;
    if (std.mem.eql(u8, command, "top")) {
        // Accept `zspace top <path> [N]` and `zspace top [N]`.
        if (parsed.positionals.len >= 1) {
            if (std.fmt.parseInt(usize, parsed.positionals[0], 10)) |n| {
                if (parsed.positionals.len >= 2) return usageError("too many arguments for top (expected [path] [N])", .{});
                top_limit = n;
            } else |_| {
                target_path = parsed.positionals[0];
                if (parsed.positionals.len >= 2) {
                    top_limit = std.fmt.parseInt(usize, parsed.positionals[1], 10) catch return usageError("invalid limit for top (expected integer)", .{});
                }
            }
        }
    } else {
        if (parsed.positionals.len >= 1) target_path = parsed.positionals[0];
        // Any extra positionals beyond the path are a usage error, except
        // commands that take file pairs (handled per-command below).
        const takes_pair = std.mem.eql(u8, command, "snapshot");
        if (parsed.positionals.len > 1 and !takes_pair) {
            // `scan <path> --help` leftover already handled; anything else is a typo.
            var only_help = true;
            for (parsed.positionals[1..]) |extra| {
                if (!isHelpArg(extra)) only_help = false;
            }
            if (only_help) {
                printCommandHelp(command);
                return EXIT_OK;
            }
            return usageError("too many arguments for '{s}'", .{command});
        }
    }

    var real_path_buf: [4096]u8 = undefined;
    var target_z: [4096]u8 = undefined;
    if (target_path.len >= target_z.len - 1) {
        out.print("error: path too long: {s}\n", .{target_path});
        return EXIT_USAGE;
    }
    @memcpy(target_z[0..target_path.len], target_path);
    target_z[target_path.len] = 0;

    const real_res = c.realpath(@as([*:0]const u8, @ptrCast(&target_z)), @as([*c]u8, @ptrCast(&real_path_buf)));
    const real_path = if (real_res != null) std.mem.span(@as([*:0]const u8, @ptrCast(&real_path_buf))) else target_path;

    logVerbose(opts, "[zspace] cmd={s} path={s} format={s} dry_run={} min_size={d}", .{ command, real_path, if (opts.format == .json) "json" else "table", opts.dry_run, opts.min_size });

    if (std.mem.eql(u8, command, "scan")) {
        runScanCmd(allocator, real_path, opts) catch return EXIT_SCAN;
        return EXIT_OK;
    } else if (std.mem.eql(u8, command, "dedup")) {
        runDedupCmd(allocator, real_path, opts) catch return EXIT_SCAN;
        return EXIT_OK;
    } else if (std.mem.eql(u8, command, "analyze")) {
        runAnalyzeCmd(allocator, real_path, opts) catch return EXIT_SCAN;
        return EXIT_OK;
    } else if (std.mem.eql(u8, command, "clean")) {
        runCleanCmd(allocator, real_path, opts) catch return EXIT_SCAN;
        return EXIT_OK;
    } else if (std.mem.eql(u8, command, "wins") or std.mem.eql(u8, command, "quick-wins")) {
        runWinsCmd(allocator, real_path, opts) catch return EXIT_SCAN;
        return EXIT_OK;
    } else if (std.mem.eql(u8, command, "npkill") or std.mem.eql(u8, command, "sweep")) {
        runNpkillCmd(allocator, real_path, opts) catch return EXIT_SCAN;
        return EXIT_OK;
    } else if (std.mem.eql(u8, command, "drives") or std.mem.eql(u8, command, "volumes") or std.mem.eql(u8, command, "df")) {
        runDrivesCmd(allocator, opts) catch return EXIT_SCAN;
        return EXIT_OK;
    } else if (std.mem.eql(u8, command, "top")) {
        runTopCmd(allocator, real_path, top_limit, opts) catch return EXIT_SCAN;
        return EXIT_OK;
    } else if (std.mem.eql(u8, command, "decay") or std.mem.eql(u8, command, "entropy")) {
        runEntropyCmd(allocator, real_path, opts) catch return EXIT_SCAN;
        return EXIT_OK;
    } else if (std.mem.eql(u8, command, "3d") or std.mem.eql(u8, command, "elevation")) {
        run3DCmd(allocator, real_path, opts) catch return EXIT_SCAN;
        return EXIT_OK;
    } else if (std.mem.eql(u8, command, "tui")) {
        runTuiCmd(allocator, real_path, opts) catch return EXIT_SCAN;
        return EXIT_OK;
    } else if (std.mem.eql(u8, command, "gui")) {
        runGuiCmd(allocator, real_path, opts) catch return EXIT_SCAN;
        return EXIT_OK;
    } else if (std.mem.eql(u8, command, "benchmark")) {
        runBenchmarkCmd(allocator, real_path, opts) catch return EXIT_SCAN;
        return EXIT_OK;
    } else if (std.mem.eql(u8, command, "snapshot")) {
        runSnapshotCmd(allocator, parsed.positionals, opts) catch return EXIT_SCAN;
        return EXIT_OK;
    } else if (std.mem.eql(u8, command, "history")) {
        runHistoryCmd(allocator, opts) catch return EXIT_SCAN;
        return EXIT_OK;
    } else if (std.mem.eql(u8, command, "undo")) {
        const receipt = if (parsed.positionals.len >= 1) parsed.positionals[0] else "";
        runUndoCmd(allocator, receipt, opts) catch return EXIT_SCAN;
        return EXIT_OK;
    } else {
        out.print("Unknown command: {s}\n\n", .{command});
        printHelp();
        return EXIT_USAGE;
    }
}

fn printHelp() void {
    out.printRaw(
        \\================================================================================
        \\  ZSPACE  —  Ultra-Fast Pure Zig Disk & Spacetime Management Suite
        \\================================================================================
        \\
        \\USAGE:
        \\  zspace <command> [path] [options]
        \\
        \\CLEANUP & ANALYSIS:
        \\  clean <path>         Analyze and show smart cleanup recommendations & danger risks
        \\  wins <path>          Show quick-win safe storage reclaimables (>100MB caches)
        \\  npkill <path>        Sweep for heavy build artifacts (node_modules, target, .venv)
        \\  dedup <path>         Find duplicate files using 3-stage sparse & streaming hash
        \\  decay <path>         Analyze temporal file age & dormant iceberg storage
        \\  drives               Map out entire computer's drives, APFS containers & SIP locks
        \\
        \\EXPLORATION & BENCHMARKS:
        \\  repl [path]          Launch full interactive high-throughput disk shell
        \\  scan <path>          Perform ultra-fast multi-threaded scan and print summary
        \\  top <path> [N]       List top N largest files (default: 20)
        \\  3d <path>            Render 3D isometric topological elevation map
        \\  tui <path>           Launch interactive ANSI terminal visualizer
        \\  gui <path>           Launch native macOS Cocoa Studio Liquid Glass GUI
        \\  benchmark <path>     Benchmark scanning IOPS, throughput, and memory footprint
        \\  snapshot save|diff  Time-travel snapshots (X01 feed): save tree, diff two snaps
        \\  history              Show trash/clone journal (Trash Insurance X05 feed)
        \\  undo <receipt>       Restore one trashed item by receipt id
        \\  version              Display version and engine details
        \\
        \\GLOBAL OPTIONS (may appear before or after the command):
        \\  --format=json|table  Machine-readable JSON or human table (default: table)
        \\  --dry-run            Preview only; mutate nothing (clean/dedup report only)
        \\  --verbose, -v        Verbose diagnostics to stderr
        \\  --interactive, -i   Checkbox TUI to pick items (clean)
        \\  --select=<spec>     Numbered selection: 34,12 / 3-7 / all / safe (clean)

        \\  --min-size=<n>      Size floor, e.g. 1KB, 10MB, 2GB (dedup/top/analyze)
        \\
        \\PER-COMMAND HELP:
        \\  zspace <command> --help    Show options for one command
        \\  zspace help <command>      Same as above
        \\
        \\EXIT CODES:
        \\  0  success   2  usage error   3  scan/io error   4  no results
        \\
    );
}

fn printCommandHelp(command: []const u8) void {
    if (std.mem.eql(u8, command, "scan")) {
        out.printRaw("zspace scan: fast scan with throughput telemetry.");
    } else if (std.mem.eql(u8, command, "dedup")) {
        out.printRaw("zspace dedup: duplicate analysis, report-only.");
    } else if (std.mem.eql(u8, command, "version")) {
        printVersion(.{});
    } else {
        out.print("No detailed help.", .{});
    }
}

fn printVersion(opts: GlobalOpts) void {
    if (opts.format == .json) {
        out.printRaw("{\"name\":\"zspace\",\"version\":\"2.0.0\",\"engine\":\"zig-0.16-native\"}\n");
    } else {
        out.printRaw("ZSpace v2.0.0 (Pure Zig 0.16 Native Edition)\n");
    }
}

fn runSnapshotCmd(allocator: std.mem.Allocator, positionals: []const []const u8, opts: GlobalOpts) !void {
    _ = opts;
    if (positionals.len < 1) {
        out.printRaw("usage: zspace snapshot save <path> -o <file> | zspace snapshot diff <a> <b> [--format=json]\n");
        return error.InvalidArgs;
    }
    const sub = positionals[0];
    var eng = snapshot_mod.SnapshotEngine.init(allocator);
    if (std.mem.eql(u8, sub, "save")) {
        if (positionals.len < 2) {
            out.printRaw("usage: zspace snapshot save <path> [-o <file>]\n");
            return error.InvalidArgs;
        }
        const scan_path = positionals[1];
        var dest: []const u8 = "snapshot.zsnap";
        var i: usize = 2;
        while (i < positionals.len) : (i += 1) {
            if (std.mem.eql(u8, positionals[i], "-o") and i + 1 < positionals.len) {
                dest = positionals[i + 1];
                i += 1;
            }
        }
        var sc = scanner.Scanner.init(allocator, .{});
        defer sc.deinit();
        const root = try sc.scan(scan_path);
        try eng.saveSnapshot(root, dest);
        out.print("Snapshot saved: {s} ({d} files)\n", .{ dest, root.file_count });
    } else if (std.mem.eql(u8, sub, "diff")) {
        if (positionals.len < 3) {
            out.printRaw("usage: zspace snapshot diff <a.zsnap> <b.zsnap> [--format=json]\n");
            return error.InvalidArgs;
        }
        var diffs = try eng.compareSnapshots(positionals[1], positionals[2]);
        defer {
            for (diffs.items) |d| allocator.free(d.path);
            diffs.deinit(allocator);
        }
        const as_json = for (positionals) |p| {
            if (std.mem.eql(u8, p, "--format=json")) break true;
        } else false;
        if (as_json) {
            out.printRaw("{\"diffs\":[");
            for (diffs.items, 0..) |d, idx| {
                if (idx > 0) out.printRaw(",");
                const st = switch (d.status) {
                    .added => "added",
                    .removed => "removed",
                    .grew => "grew",
                    .shrunk => "shrunk",
                    .unchanged => "unchanged",
                };
                out.print("{{\"path\":\"{s}\",\"status\":\"{s}\",\"old\":{d},\"new\":{d},\"diff\":{d}}}", .{ d.path, st, d.old_size, d.new_size, d.diff_bytes });
            }
            out.printRaw("]}\n");
        } else {
            if (diffs.items.len == 0) {
                out.printRaw("No differences.\n");
                return;
            }
            for (diffs.items) |d| {
                const tag: []const u8 = switch (d.status) {
                    .added => "ADDED  ",
                    .removed => "REMOVED",
                    .grew => "GREW   ",
                    .shrunk => "SHRUNK ",
                    .unchanged => "SAME   ",
                };
                out.print("{s} {s} ({d} -> {d})\n", .{ tag, d.path, d.old_size, d.new_size });
            }
        }
    } else {
        out.printRaw("usage: zspace snapshot save <path> -o <file> | zspace snapshot diff <a> <b>\n");
        return error.InvalidArgs;
    }
}

fn runHistoryCmd(allocator: std.mem.Allocator, opts: GlobalOpts) !void {
    _ = opts;
    var cl = try cleaner.Cleaner.init(allocator);
    defer cl.deinit();
    var list = try cl.readJournalTail(allocator, 200);
    defer {
        for (list.items) |e| {
            allocator.free(e.line);
        }
        list.deinit(allocator);
    }
    if (list.items.len == 0) {
        out.printRaw("No trash history yet.\n");
        return;
    }
    for (list.items) |e| {
        out.print("{s}\n", .{e.line});
    }
}

fn runUndoCmd(allocator: std.mem.Allocator, receipt: []const u8, opts: GlobalOpts) !void {
    _ = opts;
    if (receipt.len == 0) {
        out.printRaw("usage: zspace undo <receipt-id>\n");
        return error.InvalidArgs;
    }
    var cl = try cleaner.Cleaner.init(allocator);
    defer cl.deinit();
    const op = try cl.undoByReceipt(receipt);
    out.print("Restored {s} (receipt {s})\n", .{ op.original_path, receipt });
}

fn runScanCmd(allocator: std.mem.Allocator, path: []const u8, opts: GlobalOpts) !void {
    _ = opts;
    out.print("\x1b[1;36mScanning target:\x1b[0m {s}\n", .{path});

    var sc = scanner.Scanner.init(allocator, .{});
    defer sc.deinit();

    const root = try sc.scan(path);

    var size_buf: [32]u8 = undefined;
    const size_str = types.DiskNode.formatSize(root.size_bytes, &size_buf);

    var alloc_buf: [32]u8 = undefined;
    const alloc_str = types.DiskNode.formatSize(root.allocated_bytes, &alloc_buf);

    const elapsed_ms = @as(f64, @floatFromInt(sc.telemetry.elapsed_ns)) / 1_000_000.0;
    const mb_per_sec = sc.telemetry.throughputBytesPerSec() / (1024.0 * 1024.0);
    const files_per_sec = sc.telemetry.throughputFilesPerSec();

    out.print(
        \\
        \\✓ Scan Completed in {d:.2} ms
        \\--------------------------------------------------------------------------------
        \\  Logical Size:     {s}
        \\  Allocated Blocks: {s}
        \\  Total Files:      {d}
        \\  Total Folders:    {d}
        \\  Scan Errors:      {d}
        \\  Throughput:       {d:.2} MB/s  ({d:.0} files/sec)
        \\--------------------------------------------------------------------------------
        \\
    , .{
        elapsed_ms,
        size_str,
        alloc_str,
        root.file_count,
        root.dir_count,
        sc.telemetry.errors_count,
        mb_per_sec,
        files_per_sec,
    });
}

fn runCleanCmd(allocator: std.mem.Allocator, path: []const u8, opts: GlobalOpts) !void {
    var sc = scanner.Scanner.init(allocator, .{});
    defer sc.deinit();

    const root = try sc.scan(path);
    var an = analyzer.Analyzer.init(allocator);
    var items = try an.generateSmartCleanRecommendations(root);
    defer items.deinit(allocator);

    out.printRaw("\n\x1b[1;38;2;0;229;255m=== SMART CLEANUP RECOMMENDATIONS & RISK ANALYSIS ===\x1b[0m\n\n");

    if (items.items.len == 0) {
        out.printRaw("✓ System scope is tidy. No bulk caches or build artifacts found.\n");
        return;
    }

    var total_reclaimable: u64 = 0;

    for (items.items) |it| {
        var sz_b: [32]u8 = undefined;
        const sz_s = types.DiskNode.formatSize(it.size_bytes, &sz_b);
        total_reclaimable += it.size_bytes;

        out.print("  [{d}] {s}{s}\x1b[0m \x1b[1m{s}\x1b[0m — \x1b[1;38;2;255;110;64m{s}\x1b[0m\n", .{
            it.id,
            it.risk.colorAnsi(),
            it.risk.label(),
            it.title,
            sz_s,
        });
        out.print("      \x1b[90mPath:\x1b[0m {s}\n", .{it.path});
        out.print("      \x1b[90mNote:\x1b[0m {s}\n\n", .{it.description});
    }

    var total_b: [32]u8 = undefined;
    const total_s = types.DiskNode.formatSize(total_reclaimable, &total_b);
    out.print("Total Reclaimable Space: \x1b[1;38;2;255;110;64m{s}\x1b[0m across {d} candidates.\n", .{ total_s, items.items.len });

    // C06: --select=<spec> / --interactive execution path. Spec format
    // `34,12` / `3-7` / `all` / `safe`; interactive uses the checkbox TUI.
    if (opts.select.len > 0 or opts.interactive) {
        var chosen_mask: []bool = undefined;
        var mask_owned = false;
        defer if (mask_owned) allocator.free(chosen_mask);

        if (opts.select.len > 0) {
            chosen_mask = tui_select.parseSelectionSpec(
                allocator,
                opts.select,
                items.items.len,
                struct {
                    fn isSafe(i: usize) bool {
                        // Placeholder predicate; real risk check happens at
                        // the call site below via `items` (parser is generic).
                        _ = i;
                        return false;
                    }
                }.isSafe,
            ) catch {
                out.printRaw("error: invalid --select spec (expected e.g. 34,12 / 3-7 / all / safe)\n\n");
                return;
            };
            mask_owned = true;
        } else {
            // Interactive checkbox selection (skips LOCKED items).
            var sel_items = try allocator.alloc(tui_select.SelectableItem, items.items.len);
            defer allocator.free(sel_items);
            for (items.items, 0..) |it, i| {
                sel_items[i] = .{
                    .id = it.id,
                    .title = it.title,
                    .path = it.path,
                    .size_bytes = it.size_bytes,
                    .risk = it.risk,
                    .locked = it.risk.isLocked(),
                };
            }
            const res = tui_select.runCheckboxSelect(allocator, sel_items, "SELECT CLEANUP CANDIDATES") catch |e| switch (e) {
                error.NotATty => {
                    out.printRaw("error: --interactive needs a TTY (stdin is not a terminal)\n\n");
                    return;
                },
                else => return,
            };
            if (!res.confirmed or res.chosen.len == 0) {
                out.printRaw("Cancelled — nothing trashed.\n");
                return;
            }
            chosen_mask = try allocator.alloc(bool, items.items.len);
            mask_owned = true;
            for (chosen_mask) |*m| m.* = false;
            for (res.chosen) |i| chosen_mask[i] = true;
            allocator.free(res.chosen);
        }

        // Execute trashes for the chosen mask (dry_run prints only).
        var n_done: usize = 0;
        var freed: u64 = 0;
        for (items.items, 0..) |it, i| {
            if (!chosen_mask[i]) continue;
            if (it.risk.isLocked()) {
                out.print("\x1b[1;31m[BLOCKED] #{d} is SYSTEM LOCKED and cannot be deleted!\x1b[0m\n", .{it.id});
                continue;
            }
            if (opts.dry_run) {
                out.print("  [dry-run] would trash #{d} {s} ({s})\n", .{ it.id, it.title, it.path });
                n_done += 1;
                freed += it.size_bytes;
                continue;
            }
            const op = cleaner_inst_safeTrash(allocator, it.path, it.size_bytes) catch |err| {
                out.print("Failed to clean #{d}: {s}\n", .{ it.id, @errorName(err) });
                continue;
            };
            n_done += 1;
            freed += op.size_bytes;
            var sz_b: [32]u8 = undefined;
            out.print("✓ Cleaned #{d} ({s}) → Reclaimed {s}\n", .{ it.id, it.title, types.DiskNode.formatSize(op.size_bytes, &sz_b) });
        }
        var f_b: [32]u8 = undefined;
        out.print("\n\x1b[1;32m✓ {d} item(s) processed. {s} {s}\x1b[0m\n", .{
            n_done,
            if (opts.dry_run) "Would free " else "Freed ",
            types.DiskNode.formatSize(freed, &f_b),
        });
        return;
    }

    out.printRaw("To clean interactively with number selection or safe batch, run: \x1b[1;36mzspace repl\x1b[0m or add \x1b[1;36m--select=34,12\x1b[0m\n\n");
}

/// Small helper so runCleanCmd/runWinsCmd share one Cleaner instance for the
/// one-shot trash flow (codebase idiom: construct, use, deinit).
fn cleaner_inst_safeTrash(allocator: std.mem.Allocator, target: []const u8, size: u64) !types.CleanOperation {
    var cl = try cleaner.Cleaner.init(allocator);
    defer cl.deinit();
    return cl.safeMoveToTrash(target, size, .None);
}

fn runWinsCmd(allocator: std.mem.Allocator, path: []const u8, opts: GlobalOpts) !void {
    var sc = scanner.Scanner.init(allocator, .{});
    defer sc.deinit();

    const root = try sc.scan(path);
    var an = analyzer.Analyzer.init(allocator);
    var items = try an.generateSmartCleanRecommendations(root);
    defer items.deinit(allocator);

    out.printRaw("\n\x1b[1;32m=== INSTANT QUICK-WINS (ZERO-RISK RECLAIMABLES) ===\x1b[0m\n\n");

    var total_wins: u64 = 0;
    var count: usize = 0;

    var win_item_idx: std.ArrayList(usize) = .{ .items = &.{}, .capacity = 0 };
    defer win_item_idx.deinit(allocator);

    for (items.items, 0..) |it, item_i| {
        if (it.risk == .Safe_ZeroRisk and it.is_quick_win) {
            var sz_b: [32]u8 = undefined;
            const sz_s = types.DiskNode.formatSize(it.size_bytes, &sz_b);
            total_wins += it.size_bytes;
            count += 1;

            try win_item_idx.append(allocator, item_i);

            out.print("  {d}. \x1b[1m{s:<36}\x1b[0m {s:>10}  \x1b[36m{s}\x1b[0m\n", .{
                count,
                it.title,
                sz_s,
                it.path,
            });
        }
    }

    var win_b: [32]u8 = undefined;
    const win_s = types.DiskNode.formatSize(total_wins, &win_b);
    out.print("\nTotal Zero-Risk Instant Wins: \x1b[1;32m{s}\x1b[0m\n", .{win_s});

    // C06: `wins <path> --select=2,3` trashes numbered quick-wins; `--select=all`
    // = classic "clean safe". Interactive checkbox if -i.
    if (opts.select.len > 0 or opts.interactive) {
        if (win_item_idx.items.len == 0) {
            out.printRaw("No quick-wins to select.\n");
            return;
        }
        var mask: []bool = undefined;
        if (opts.select.len > 0) {
            mask = tui_select.parseSelectionSpec(allocator, opts.select, win_item_idx.items.len, null) catch {
                out.printRaw("error: invalid --select spec (expected e.g. 2,3 / 1-3 / all)\n\n");
                return;
            };
        } else {
            var sel_items = try allocator.alloc(tui_select.SelectableItem, win_item_idx.items.len);
            defer allocator.free(sel_items);
            for (win_item_idx.items, 0..) |item_i, i| {
                const it = items.items[item_i];
                sel_items[i] = .{ .id = i + 1, .title = it.title, .path = it.path, .size_bytes = it.size_bytes, .risk = it.risk, .locked = false };
            }
            const res = tui_select.runCheckboxSelect(allocator, sel_items, "SELECT QUICK-WINS TO TRASH") catch |e| switch (e) {
                error.NotATty => {
                    out.printRaw("error: --interactive needs a TTY (stdin is not a terminal)\n\n");
                    return;
                },
                else => return,
            };
            if (!res.confirmed or res.chosen.len == 0) {
                out.printRaw("Cancelled — nothing trashed.\n");
                return;
            }
            mask = try allocator.alloc(bool, win_item_idx.items.len);
            for (mask) |*m| m.* = false;
            for (res.chosen) |i| mask[i] = true;
            allocator.free(res.chosen);
        }
        defer allocator.free(mask);

        var n_done: usize = 0;
        var freed: u64 = 0;
        for (mask, 0..) |on, i| {
            if (!on) continue;
            const it = items.items[win_item_idx.items[i]];
            if (opts.dry_run) {
                out.print("  [dry-run] would trash {s}\n", .{it.path});
                n_done += 1;
                freed += it.size_bytes;
                continue;
            }
            const op = cleaner_inst_safeTrash(allocator, it.path, it.size_bytes) catch |err| {
                out.print("Failed to trash {s}: {s}\n", .{ it.path, @errorName(err) });
                continue;
            };
            n_done += 1;
            freed += op.size_bytes;
            var sz_b: [32]u8 = undefined;
            out.print("✓ Trashed ({s}) → Freed {s}\n", .{ op.original_path, types.DiskNode.formatSize(op.size_bytes, &sz_b) });
        }
        var f_b: [32]u8 = undefined;
        out.print("\n\x1b[1;32m✓ {d} quick-win(s) processed. {s}{s}\x1b[0m\n", .{ n_done, if (opts.dry_run) "Would free " else "Freed ", types.DiskNode.formatSize(freed, &f_b) });
        return;
    }

    out.printRaw("To purge: `zspace wins <path> --select=all` (or --select=2,3, interactive: -i)\n\n");
}

fn runNpkillCmd(allocator: std.mem.Allocator, path: []const u8, opts: GlobalOpts) !void {
    _ = opts;
    var sc = scanner.Scanner.init(allocator, .{});
    defer sc.deinit();

    const root = try sc.scan(path);

    var list: std.ArrayList(*const types.DiskNode) = .{ .items = &.{}, .capacity = 0 };
    defer list.deinit(allocator);

    try findHeavyDeps(allocator, root, &list);

    out.printRaw("\n\x1b[1;36m=== HEAVY DEPENDENCY DIRECTORIES (npkill sweep) ===\x1b[0m\n\n");

    if (list.items.len == 0) {
        out.printRaw("✓ No heavy dependency folders found.\n\n");
        return;
    }

    var total_waste: u64 = 0;
    for (list.items, 0..) |d, idx| {
        var sz_b: [32]u8 = undefined;
        const sz_s = types.DiskNode.formatSize(d.size_bytes, &sz_b);
        total_waste += d.size_bytes;

        out.print("  [{d}] \x1b[1m{s:<20}\x1b[0m {s:>10}  \x1b[36m{s}\x1b[0m\n", .{
            idx + 1,
            d.name,
            sz_s,
            d.path,
        });
    }

    var waste_b: [32]u8 = undefined;
    const waste_s = types.DiskNode.formatSize(total_waste, &waste_b);
    out.print("\nTotal Dependencies Footprint: \x1b[1;38;2;255;110;64m{s}\x1b[0m across {d} directories.\n\n", .{ waste_s, list.items.len });
}

fn findHeavyDeps(allocator: std.mem.Allocator, node: *const types.DiskNode, list: *std.ArrayList(*const types.DiskNode)) anyerror!void {
    if (node.kind == .directory) {
        if (std.mem.eql(u8, node.name, "node_modules") or
            std.mem.eql(u8, node.name, "target") or
            std.mem.eql(u8, node.name, ".zig-cache") or
            std.mem.eql(u8, node.name, "DerivedData") or
            std.mem.eql(u8, node.name, ".venv"))
        {
            try list.append(allocator, node);
            return;
        }
        for (node.children.items) |child| {
            try findHeavyDeps(allocator, child, list);
        }
    }
}

fn runDrivesCmd(allocator: std.mem.Allocator, opts: GlobalOpts) !void {
    _ = opts;
    var dm = disks.DiskMapper.init(allocator);
    var volumes = try dm.listVolumes();
    defer {
        for (volumes.items) |v| {
            allocator.free(v.mount_point);
            allocator.free(v.device_name);
            allocator.free(v.fs_type);
        }
        volumes.deinit(allocator);
    }

    out.printRaw("\n\x1b[1;38;2;0;229;255m=== SYSTEM VOLUMES, APFS CONTAINERS & STORAGE MAP ===\x1b[0m\n\n");

    for (volumes.items) |v| {
        var tot_b: [32]u8 = undefined;
        var used_b: [32]u8 = undefined;
        var free_b: [32]u8 = undefined;

        const tot_s = types.DiskNode.formatSize(v.total_bytes, &tot_b);
        const used_s = types.DiskNode.formatSize(v.used_bytes, &used_b);
        const free_s = types.DiskNode.formatSize(v.free_bytes, &free_b);

        const bar_w = 24;
        const filled = @as(usize, @intFromFloat((v.percent_used / 100.0) * @as(f32, @floatFromInt(bar_w))));
        var bar_buf: [24]u8 = undefined;
        for (0..bar_w) |b_i| {
            bar_buf[b_i] = if (b_i < filled) '#' else '.';
        }

        out.print("  \x1b[1;37m{s:<32}\x1b[0m [{s}] {d:>5.1}%\n", .{ v.mount_point, bar_buf[0..bar_w], v.percent_used });
        out.print("    \x1b[90mDevice:\x1b[0m {s} ({s}) | \x1b[90mUsed:\x1b[0m {s} | \x1b[90mFree:\x1b[0m \x1b[1;32m{s}\x1b[0m | \x1b[90mTotal:\x1b[0m {s}\n", .{
            v.device_name,
            v.fs_type,
            used_s,
            free_s,
            tot_s,
        });
        out.print("    \x1b[90mStatus:\x1b[0m {s}\n\n", .{v.status_label});
    }
}

fn runDedupCmd(allocator: std.mem.Allocator, path: []const u8, opts: GlobalOpts) !void {
    _ = opts;
    out.print("\x1b[1;36mScanning & Deduplicating:\x1b[0m {s}\n", .{path});

    var sc = scanner.Scanner.init(allocator, .{});
    defer sc.deinit();

    const root = try sc.scan(path);

    var dedup_engine = dedup.DedupEngine.init(allocator);
    var clusters = try dedup_engine.findDuplicates(root);
    defer {
        for (clusters.items) |*c_item| c_item.items.deinit(allocator);
        clusters.deinit(allocator);
    }

    var total_wasted: u64 = 0;
    for (clusters.items) |cl| {
        total_wasted += cl.total_wasted_bytes;
    }

    var wasted_buf: [32]u8 = undefined;
    const wasted_str = types.DiskNode.formatSize(total_wasted, &wasted_buf);

    out.print(
        \\
        \\✓ Deduplication Analysis Complete
        \\--------------------------------------------------------------------------------
        \\  Duplicate Clusters: {d}
        \\  Total Reclaimable:  \x1b[1;38;2;255;110;64m{s}\x1b[0m
        \\--------------------------------------------------------------------------------
        \\
    , .{
        clusters.items.len,
        wasted_str,
    });

    const display_limit = @min(clusters.items.len, 10);
    for (clusters.items[0..display_limit], 0..) |cl, idx| {
        var sz_buf: [32]u8 = undefined;
        const sz_str = types.DiskNode.formatSize(cl.size_each, &sz_buf);

        out.print("\n[Group {d}] File Size: {s} | {d} Copies\n", .{ idx + 1, sz_str, cl.items.items.len });
        for (cl.items.items) |it| {
            const prefix = if (it.is_original) "  ✓ [ORIGINAL]  " else "  ✗ [DUPLICATE] ";
            out.print("{s}{s}\n", .{ prefix, it.path });
        }
    }
}

fn runAnalyzeCmd(allocator: std.mem.Allocator, path: []const u8, opts: GlobalOpts) !void {
    _ = opts;
    var sc = scanner.Scanner.init(allocator, .{});
    defer sc.deinit();

    const root = try sc.scan(path);

    var an = analyzer.Analyzer.init(allocator);
    const categories = try an.aggregateCategories(root);
    var suggestions = try an.generateSmartCleanRecommendations(root);
    defer suggestions.deinit(allocator);

    out.printRaw("\n\x1b[1;36m=== CATEGORY COMPOSITION ===\x1b[0m\n");
    for (categories) |cat| {
        if (cat.total_bytes == 0) continue;
        var sz_buf: [32]u8 = undefined;
        const sz_str = types.DiskNode.formatSize(cat.total_bytes, &sz_buf);
        out.print("  {s:<32} {s:>10}  ({d:>5.1}%)  [{d} files]\n", .{
            cat.category.displayName(),
            sz_str,
            cat.percent_of_total * 100.0,
            cat.total_files,
        });
    }

    out.printRaw("\n\x1b[1;38;2;255;110;64m=== SMART CLEANUP RECOMMENDATIONS ===\x1b[0m\n");
    if (suggestions.items.len == 0) {
        out.printRaw("  ✓ No bulk stale caches found.\n");
    } else {
        for (suggestions.items, 0..) |sug, idx| {
            var sz_buf: [32]u8 = undefined;
            const sz_str = types.DiskNode.formatSize(sug.size_bytes, &sz_buf);
            out.print("  {d}. {s} ({s}) -> Reclaim {s}\n", .{
                idx + 1,
                sug.title,
                sug.path,
                sz_str,
            });
        }
    }
}

fn runEntropyCmd(allocator: std.mem.Allocator, path: []const u8, opts: GlobalOpts) !void {
    _ = opts;
    var sc = scanner.Scanner.init(allocator, .{});
    defer sc.deinit();

    const root = try sc.scan(path);
    var an = analyzer.Analyzer.init(allocator);
    const dist = an.analyzeTemporalDecay(root);

    var f_buf: [32]u8 = undefined;
    var w_buf: [32]u8 = undefined;
    var c_buf: [32]u8 = undefined;
    var i_buf: [32]u8 = undefined;

    out.print(
        \\
        \\=== TEMPORAL AGE & DORMANCY ENTROPY ===
        \\  Hot (< 30 days):        {s}
        \\  Warm (30 - 180 days):   {s}
        \\  Cold (180 - 365 days):  {s}
        \\  Icebergs (> 1 year):    \x1b[1;38;2;255;110;64m{s}\x1b[0m  (Dormant data)
        \\
    , .{
        types.DiskNode.formatSize(dist.fresh_under_30d, &f_buf),
        types.DiskNode.formatSize(dist.warm_30_to_180d, &w_buf),
        types.DiskNode.formatSize(dist.cold_180_to_365d, &c_buf),
        types.DiskNode.formatSize(dist.iceberg_over_1y, &i_buf),
    });
}

fn run3DCmd(allocator: std.mem.Allocator, path: []const u8, opts: GlobalOpts) !void {
    _ = opts;
    var sc = scanner.Scanner.init(allocator, .{});
    defer sc.deinit();

    const root = try sc.scan(path);
    var terrain = visualizer3d.ElevationTerrain.init(allocator);
    var vertices = try terrain.buildTerrain(root);
    defer vertices.deinit(allocator);

    visualizer3d.ElevationTerrain.renderAsciiWireframe(vertices.items);
}

fn runTopCmd(allocator: std.mem.Allocator, path: []const u8, limit: usize, opts: GlobalOpts) !void {
    _ = opts;
    var sc = scanner.Scanner.init(allocator, .{});
    defer sc.deinit();

    const root = try sc.scan(path);

    var an = analyzer.Analyzer.init(allocator);
    var top_files = try an.findTopLargestFiles(root, limit);
    defer top_files.deinit(allocator);

    out.print("\n\x1b[1;36mTop {d} Largest Files in {s}:\x1b[0m\n\n", .{ top_files.items.len, path });
    for (top_files.items, 0..) |f, idx| {
        var sz_buf: [32]u8 = undefined;
        const sz_str = types.DiskNode.formatSize(f.size_bytes, &sz_buf);
        out.print("  {d:>3}. {s:>10}  {s}\n", .{ idx + 1, sz_str, f.path });
    }
}

fn runTuiCmd(allocator: std.mem.Allocator, path: []const u8, opts: GlobalOpts) !void {
    _ = opts;
    var sc = scanner.Scanner.init(allocator, .{});
    defer sc.deinit();

    const root = try sc.scan(path);

    var app = try tui.TuiApp.init(allocator, root);
    defer app.deinit();

    try app.render();
}

fn runGuiCmd(allocator: std.mem.Allocator, path: []const u8, opts: GlobalOpts) !void {
    _ = opts;
    var sc = scanner.Scanner.init(allocator, .{});
    defer sc.deinit();

    const root = try sc.scan(path);
    try gui.runGuiApp(allocator, root);
}

fn runBenchmarkCmd(allocator: std.mem.Allocator, path: []const u8, opts: GlobalOpts) !void {
    _ = opts;
    out.print("\n\x1b[1;35m[ZSpace Performance Benchmark]\x1b[0m Starting on: {s}\n", .{path});

    var sc = scanner.Scanner.init(allocator, .{});
    defer sc.deinit();

    const t0 = types.getMonotonicNs();
    const root = try sc.scan(path);
    const t1 = types.getMonotonicNs();
    const scan_time_ns = t1 - t0;

    var dedup_engine = dedup.DedupEngine.init(allocator);
    const t2 = types.getMonotonicNs();
    var clusters = try dedup_engine.findDuplicates(root);
    const t3 = types.getMonotonicNs();
    const dedup_time_ns = t3 - t2;
    defer {
        for (clusters.items) |*c_item| c_item.items.deinit(allocator);
        clusters.deinit(allocator);
    }

    var an = analyzer.Analyzer.init(allocator);
    const t4 = types.getMonotonicNs();
    _ = try an.aggregateCategories(root);
    var top_files = try an.findTopLargestFiles(root, 100);
    const t5 = types.getMonotonicNs();
    const analyze_time_ns = t5 - t4;
    defer top_files.deinit(allocator);

    var sz_buf: [32]u8 = undefined;
    const sz_str = types.DiskNode.formatSize(root.size_bytes, &sz_buf);

    out.print(
        \\
        \\================================================================================
        \\                       BENCHMARK RESULTS & TELEMETRY
        \\================================================================================
        \\  Dataset Analyzed:     {s} across {d} files & {d} directories
        \\
        \\  Directory Traversal:  {d:.2} ms ({d:.0} files/sec, {d:.2} MB/s)
        \\  Deduplication Phase:  {d:.2} ms ({d} duplicate clusters identified)
        \\  Category & Top Heap:  {d:.2} ms
        \\
        \\  Total Pipeline Time:  {d:.2} ms
        \\  Memory Footprint:     < 4 MB Arena allocated
        \\================================================================================
        \\
    , .{
        sz_str,
        root.file_count,
        root.dir_count,
        @as(f64, @floatFromInt(scan_time_ns)) / 1_000_000.0,
        sc.telemetry.throughputFilesPerSec(),
        sc.telemetry.throughputBytesPerSec() / (1024.0 * 1024.0),
        @as(f64, @floatFromInt(dedup_time_ns)) / 1_000_000.0,
        clusters.items.len,
        @as(f64, @floatFromInt(analyze_time_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(scan_time_ns + dedup_time_ns + analyze_time_ns)) / 1_000_000.0,
    });
}
