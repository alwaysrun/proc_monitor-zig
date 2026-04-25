const std = @import("std");
const toml = @import("toml");

pub const ActionType = enum {
    close,
    start,
};

pub const ProcessTarget = struct {
    name: []const u8,
    match_type: enum { exact, contains, regex },
};

pub const ProcessAction = struct {
    process_name: []const u8,
    action: ActionType,
};

pub const ProcessMonitorConfig = struct {
    monitored: []const u8,
    action: std.StringHashMap(ActionType),
    check_interval: u64 = 10,

    pub fn deinit(self: *ProcessMonitorConfig, allocator: std.mem.Allocator) void {
        var iter = self.action.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        self.action.deinit();
        allocator.free(self.monitored);
    }
};

pub const LogLevel = enum {
    debug,
    info,
    warn,
    err,
};

pub const LogConfig = struct {
    level: LogLevel = .info,
    file_path: ?[]const u8 = null,
    console: bool = true,
    max_size_mb: u64 = 10,
    max_files: u64 = 5,
};

pub const MonitorSection = struct {
    process: []const ProcessMonitorConfig = &.{},
};

pub const Config = struct {
    log: LogConfig = .{},
    daemon: bool = false,
    pid_file: ?[]const u8 = null,
    monitor: MonitorSection = .{},

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.monitor.process) |*proc| {
            proc.deinit(allocator);
        }
        allocator.free(self.monitor.process);
        if (self.log.file_path) |path| {
            allocator.free(path);
        }
        if (self.pid_file) |path| {
            allocator.free(path);
        }
    }
};

pub const ConfigError = error{
    InvalidConfig,
    MissingRequiredField,
    InvalidActionType,
    FileNotFound,
    ParseError,
    OutOfMemory,
};

const TomlLogLevel = enum {
    debug,
    info,
    warn,
    err,
};

const TomlLogConfig = struct {
    level: TomlLogLevel = .info,
    file_path: ?[]const u8 = null,
    console: bool = true,
    max_size_mb: i64 = 10,
    max_files: i64 = 5,
};

const TomlProcessMonitorConfig = struct {
    monitored: []const u8 = "",
    action: ?toml.Table = null,
    check_interval: i64 = 10,
};

const TomlMonitorSection = struct {
    process: []const TomlProcessMonitorConfig = &.{},
};

const TomlConfig = struct {
    log: TomlLogConfig = .{},
    daemon: bool = false,
    pid_file: ?[]const u8 = null,
    monitor: TomlMonitorSection = .{},
};

pub fn parseFromFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ConfigError!Config {
    const file = std.Io.Dir.openFile(.cwd(), io, path, .{ .mode = .read_only }) catch |err| {
        std.log.err("Failed to open config file: {s}, error: {}", .{ path, err });
        return ConfigError.FileNotFound;
    };
    defer file.close(io);

    const stat = file.stat(io) catch |err| {
        std.log.err("Failed to get file stats: {s}, error: {}", .{ path, err });
        return ConfigError.ParseError;
    };

    const content = allocator.alloc(u8, stat.size) catch return ConfigError.OutOfMemory;
    defer allocator.free(content);

    var buf: [4096]u8 = undefined;
    var file_reader: std.Io.File.Reader = .init(file, io, &buf);
    const reader = &file_reader.interface;

    reader.readSliceAll(content) catch |err| {
        std.log.err("Failed to read config file: {s}, error: {}", .{ path, err });
        return ConfigError.ParseError;
    };

    return parseFromContent(allocator, content);
}

pub fn parseFromContent(allocator: std.mem.Allocator, content: []const u8) ConfigError!Config {
    var parser = toml.Parser(TomlConfig).init(allocator);
    defer parser.deinit();

    var result = parser.parseString(content) catch |err| {
        std.log.err("Failed to parse TOML content: {}", .{err});
        return ConfigError.ParseError;
    };
    defer result.deinit();

    return convertConfig(allocator, result.value);
}

fn convertConfig(allocator: std.mem.Allocator, toml_cfg: TomlConfig) ConfigError!Config {
    var config: Config = .{
        .log = .{
            .level = @enumFromInt(@intFromEnum(toml_cfg.log.level)),
            .file_path = if (toml_cfg.log.file_path) |p| try allocator.dupe(u8, p) else null,
            .console = toml_cfg.log.console,
            .max_size_mb = @intCast(toml_cfg.log.max_size_mb),
            .max_files = @intCast(toml_cfg.log.max_files),
        },
        .daemon = toml_cfg.daemon,
        .pid_file = if (toml_cfg.pid_file) |p| try allocator.dupe(u8, p) else null,
    };

    const process_count = toml_cfg.monitor.process.len;
    if (process_count > 0) {
        var process_configs = try allocator.alloc(ProcessMonitorConfig, process_count);

        for (toml_cfg.monitor.process, 0..) |proc, i| {
            var action_map = std.StringHashMap(ActionType).init(allocator);

            if (proc.action) |action_table| {
                var iter = action_table.iterator();
                while (iter.next()) |entry| {
                    const action_str = entry.value_ptr.*.string;
                    const action_type: ActionType = if (std.mem.eql(u8, action_str, "close"))
                        .close
                    else if (std.mem.eql(u8, action_str, "start"))
                        .start
                    else
                        return ConfigError.InvalidActionType;

                    const key = try allocator.dupe(u8, entry.key_ptr.*);
                    try action_map.put(key, action_type);
                }
            }

            process_configs[i] = .{
                .monitored = try allocator.dupe(u8, proc.monitored),
                .action = action_map,
                .check_interval = @intCast(proc.check_interval),
            };
        }

        config.monitor.process = process_configs;
    }

    return config;
}

test "parse basic config" {
    const config_str =
        \\[log]
        \\level = "info"
        \\console = true
        \\
        \\[[monitor.process]]
        \\monitored = "steam.exe"
        \\action = { "clash-verge.exe" = "close", "ShadowsocksR.exe" = "close" }
        \\check_interval = 10
    ;

    const allocator = std.testing.allocator;
    var config = try parseFromContent(allocator, config_str);
    defer config.deinit(allocator);

    try std.testing.expect(config.log.console == true);
    try std.testing.expect(config.monitor.process.len == 1);
    try std.testing.expectEqualStrings("steam.exe", config.monitor.process[0].monitored);
    try std.testing.expectEqual(@as(u64, 10), config.monitor.process[0].check_interval);
}
