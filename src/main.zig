const std = @import("std");
const config_mod = @import("config.zig");
const logger_mod = @import("logger.zig");
const monitor_mod = @import("process_monitor.zig");
const daemon_mod = @import("daemon.zig");
const utils_mod = @import("utils.zig");

const CliArgs = struct {
    config_path: []const u8 = "config.toml",
    daemon: bool = false,
    once: bool = false,
    help: bool = false,
    version: bool = false,
};

const VERSION = "0.1.0";

fn printHelp(io: std.Io) void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    stdout_writer.print(
        \\proc_monitor - Process Monitor System v{s}
        \\
        \\USAGE:
        \\    proc_monitor [OPTIONS]
        \\
        \\OPTIONS:
        \\    -c, --config <PATH>    Configuration file path (default: config.toml)
        \\    -d, --daemon           Run as background daemon
        \\    -o, --once             Run check once and exit
        \\    -h, --help             Show this help message
        \\    -v, --version          Show version information
        \\
        \\EXAMPLES:
        \\    proc_monitor -c myconfig.toml
        \\    proc_monitor --daemon
        \\    proc_monitor --once
        \\
    , .{VERSION}) catch {};
    stdout_writer.flush() catch {};
}

fn printVersion(io: std.Io) void {
    var stdout_buffer: [256]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    stdout_writer.print("proc_monitor v{s}\n", .{VERSION}) catch {};
    stdout_writer.flush() catch {};
}

fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) !CliArgs {
    var result = CliArgs{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            result.help = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            result.version = true;
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--daemon")) {
            result.daemon = true;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--once")) {
            result.once = true;
        } else if ((std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--config")) and i + 1 < args.len) {
            i += 1;
            result.config_path = try allocator.dupe(u8, args[i]);
        }
    }

    return result;
}

pub fn main(init: std.process.Init) !void {
    const allocator: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(allocator);

    const cli_args = parseArgs(allocator, args[1..]) catch |err| {
        std.log.err("Failed to parse arguments: {}", .{err});
        return err;
    };


    if (cli_args.help) {
        printHelp(io);
        return;
    }

    if (cli_args.version) {
        printVersion(io);
        return;
    }

    // Resolve paths relative to exe directory
    const config_path = try utils_mod.resolveRelativeToExe(allocator, io, cli_args.config_path);

    var cfg: config_mod.Config = config_mod.parseFromFile(allocator, io, config_path) catch |err| {
        std.log.err("Failed to load config from '{s}': {}", .{ config_path, err });
        return err;
    };

    // Resolve other relative paths in the config relative to exe directory
    if (cfg.log.file_path) |p| {
        const absolute = try utils_mod.resolveRelativeToExe(allocator, io, p);
        allocator.free(p);
        cfg.log.file_path = absolute;
    }
    if (cfg.pid_file) |p| {
        const absolute = try utils_mod.resolveRelativeToExe(allocator, io, p);
        allocator.free(p);
        cfg.pid_file = absolute;
    }

    var cfg_mut = cfg;
    if (cli_args.daemon) {
        cfg_mut.daemon = true;
    }

    const log_instance = try logger_mod.initGlobalLogger(allocator, cfg_mut.log, io);
    defer logger_mod.deinitGlobalLogger(io);

    log_instance.info("Process Monitor starting...", .{}, io);
    log_instance.info("Config file: {s}", .{cli_args.config_path}, io);
    log_instance.info("Daemon mode: {}", .{cfg_mut.daemon}, io);

    if (cfg_mut.daemon) {
        log_instance.info("Running as daemon", .{}, io);
        daemon_mod.daemonize(allocator, io, cfg_mut.pid_file) catch |err| {
            log_instance.err("Failed to daemonize: {}", .{err}, io);
            return err;
        };
    }

    var monitor = try monitor_mod.ProcessMonitor.init(allocator, cfg_mut, log_instance, io);
    defer monitor.deinit();

    if (cli_args.once) {
        log_instance.info("Running single check", .{}, io);
        try monitor.runOnce();
        log_instance.info("Single check completed", .{}, io);
        return;
    }

    log_instance.info("Starting continuous monitoring", .{}, io);
    monitor.start();
}

test "parse args" {
    const allocator = std.testing.allocator;

    const test_args = &[_][]const u8{ "proc_monitor", "-c", "test.toml", "--daemon" };
    const cli_args = try parseArgs(allocator, test_args);
    defer allocator.free(cli_args.config_path);

    try std.testing.expectEqualSlices(u8, "test.toml", cli_args.config_path);
    try std.testing.expect(cli_args.daemon == true);
}
