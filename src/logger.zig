const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");

pub const LogLevel = enum {
    debug,
    info,
    warn,
    err,

    pub fn toStdLog(self: LogLevel) std.log.Level {
        return switch (self) {
            .debug => .debug,
            .info => .info,
            .warn => .warn,
            .err => .err,
        };
    }
};

fn formatTimestamp(buffer: []u8, timestamp_ns: i96) []u8 {
    const secs = @as(u64, @intCast(@divFloor(timestamp_ns, std.time.ns_per_s)));
    const ms = @as(u64, @intCast(@divFloor(@mod(timestamp_ns, std.time.ns_per_s), std.time.ns_per_ms)));
    const days = @divFloor(secs, std.time.s_per_day);
    const secs_of_day = secs % std.time.s_per_day;

    const epoch_days: i32 = @intCast(days);
    const year_day = epochDayToYearAndDay(epoch_days);
    const month_day = yearDayToMonthAndDay(year_day.day_of_year, year_day.is_leap);

    const hours = secs_of_day / 3600;
    const minutes = (secs_of_day % 3600) / 60;
    const seconds = secs_of_day % 60;

    return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{
        year_day.year,
        month_day.month,
        month_day.day,
        hours,
        minutes,
        seconds,
        ms,
    }) catch buffer[0..0];
}

const YearAndDay = struct {
    year: u16,
    day_of_year: u16,
    is_leap: bool,
};

fn epochDayToYearAndDay(epoch_day: i32) YearAndDay {
    var year: i32 = 1970;
    var remaining_days: i32 = epoch_day;

    while (true) {
        const is_leap = isLeapYear(year);
        const days_in_year: i32 = if (is_leap) 366 else 365;

        if (remaining_days < days_in_year) {
            return .{
                .year = @intCast(if (year >= 0) year else 0),
                .day_of_year = @intCast(if (remaining_days >= 0) remaining_days else 0),
                .is_leap = is_leap,
            };
        }

        remaining_days -= days_in_year;
        year += 1;
    }
}

fn isLeapYear(year: i32) bool {
    return (@rem(year, 4) == 0 and @rem(year, 100) != 0) or (@rem(year, 400) == 0);
}

const MonthAndDay = struct {
    month: u8,
    day: u8,
};

fn yearDayToMonthAndDay(day_of_year: u16, is_leap: bool) MonthAndDay {
    const days_per_month = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const feb_days: u8 = if (is_leap) 29 else 28;

    var remaining = day_of_year;
    var month: u8 = 1;

    for (days_per_month, 0..) |days, i| {
        const actual_days = if (i == 1) feb_days else days;
        if (remaining < actual_days) {
            return .{
                .month = month,
                .day = @intCast(remaining + 1),
            };
        }
        remaining -= actual_days;
        month += 1;
    }

    return .{ .month = 12, .day = 31 };
}

pub const Logger = struct {
    allocator: std.mem.Allocator,
    level: LogLevel,
    file: ?std.Io.File,
    file_path: ?[]const u8,
    console: bool,
    mutex: std.Io.Mutex,
    max_size_bytes: u64,
    max_files: u64,
    write_offset: u64,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, cfg: config.LogConfig, io: std.Io) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .level = @enumFromInt(@intFromEnum(cfg.level)),
            .file = null,
            .file_path = if (cfg.file_path) |p| try allocator.dupe(u8, p) else null,
            .console = cfg.console,
            .mutex = .init,
            .max_size_bytes = cfg.max_size_mb * 1024 * 1024,
            .max_files = cfg.max_files,
            .write_offset = 0,
        };

        if (self.file_path) |path| {
            self.file = std.Io.Dir.openFile(.cwd(), io, path, .{ .mode = .read_write }) catch |open_err| blk: {
                if (open_err == error.FileNotFound) {
                    break :blk std.Io.Dir.createFile(.cwd(), io, path, .{ .read = true, .truncate = false }) catch null;
                }
                break :blk null;
            };

            if (self.file) |f| {
                const stat = f.stat(io) catch null;
                if (stat) |s| {
                    self.write_offset = s.size;
                }
            }
        }

        return self;
    }

    pub fn deinit(self: *Self, io: std.Io) void {
        if (self.file) |f| {
            f.close(io);
        }
        if (self.file_path) |p| {
            self.allocator.free(p);
        }
        self.allocator.destroy(self);
    }

    pub fn log(
        self: *Self,
        level: LogLevel,
        comptime src: std.builtin.SourceLocation,
        comptime format: []const u8,
        args: anytype,
        io: std.Io,
    ) void {
        if (@intFromEnum(level) < @intFromEnum(self.level)) {
            return;
        }

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        var timestamp = std.Io.Timestamp.now(io, .real);
        
        // Adjust for local time on Windows
        if (comptime builtin.os.tag == .windows) {
            const Win32 = struct {
                const SYSTEMTIME = extern struct {
                    wYear: u16,
                    wMonth: u16,
                    wDayOfWeek: u16,
                    wDay: u16,
                    wHour: u16,
                    wMinute: u16,
                    wSecond: u16,
                    wMilliseconds: u16,
                };
                const FILETIME = extern struct {
                    dwLowDateTime: u32,
                    dwHighDateTime: u32,
                };
                extern "kernel32" fn GetSystemTime(lpSystemTime: *SYSTEMTIME) void;
                extern "kernel32" fn GetLocalTime(lpSystemTime: *SYSTEMTIME) void;
                extern "kernel32" fn SystemTimeToFileTime(lpSystemTime: *const SYSTEMTIME, lpFileTime: *FILETIME) i32;
            };

            var st_utc: Win32.SYSTEMTIME = undefined;
            var st_local: Win32.SYSTEMTIME = undefined;
            Win32.GetSystemTime(&st_utc);
            Win32.GetLocalTime(&st_local);

            var ft_utc: Win32.FILETIME = undefined;
            var ft_local: Win32.FILETIME = undefined;
            _ = Win32.SystemTimeToFileTime(&st_utc, &ft_utc);
            _ = Win32.SystemTimeToFileTime(&st_local, &ft_local);

            const v_utc = (@as(u64, ft_utc.dwHighDateTime) << 32) | ft_utc.dwLowDateTime;
            const v_local = (@as(u64, ft_local.dwHighDateTime) << 32) | ft_local.dwLowDateTime;
            
            const offset_ns = (@as(i128, @intCast(v_local)) - @as(i128, @intCast(v_utc))) * 100;
            timestamp.nanoseconds += @intCast(offset_ns);
        }

        var ts_buf: [32]u8 = undefined;
        const ts_str = formatTimestamp(&ts_buf, timestamp.nanoseconds);

        const level_str = @tagName(level);
        const file_name = std.fs.path.basename(src.file);
        const line = src.line;

        if (self.console) {
            var stderr_buffer: [1024]u8 = undefined;
            var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
            const stderr_writer = &stderr_file_writer.interface;
            stderr_writer.print("[{s}] {s} {s}:{} - " ++ format ++ "\n", .{ level_str, ts_str, file_name, line } ++ args) catch {};
            stderr_writer.flush() catch {};
        }

        if (self.file) |f| {
            var file_buffer: [1024]u8 = undefined;
            var file_writer: std.Io.File.Writer = .init(f, io, &file_buffer);
            const writer = &file_writer.interface;
            writer.print("[{s}] {s} {s}:{} - " ++ format ++ "\n", .{ level_str, ts_str, file_name, line } ++ args) catch {};
            writer.flush() catch {};
            self.checkRotation(io) catch {};
        }
    }

    pub fn debug(
        self: *Self,
        comptime format: []const u8,
        args: anytype,
        io: std.Io,
    ) void {
        self.log(.debug, @src(), format, args, io);
    }

    pub fn info(
        self: *Self,
        comptime format: []const u8,
        args: anytype,
        io: std.Io,
    ) void {
        self.log(.info, @src(), format, args, io);
    }

    pub fn warn(
        self: *Self,
        comptime format: []const u8,
        args: anytype,
        io: std.Io,
    ) void {
        self.log(.warn, @src(), format, args, io);
    }

    pub fn err(
        self: *Self,
        comptime format: []const u8,
        args: anytype,
        io: std.Io,
    ) void {
        self.log(.err, @src(), format, args, io);
    }

    fn checkRotation(self: *Self, io: std.Io) !void {
        const file = self.file orelse return;
        const stat = try file.stat(io);

        if (stat.size >= self.max_size_bytes) {
            try self.rotateFiles(io);
        }
    }

    fn rotateFiles(self: *Self, io: std.Io) !void {
        const path = self.file_path orelse return;

        if (self.file) |f| {
            f.close(io);
            self.file = null;
        }

        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var i: u64 = self.max_files;
        while (i > 0) : (i -= 1) {
            const old_path = try std.fmt.bufPrint(&buf, "{s}.{d}", .{ path, i });
            const new_path = if (i == self.max_files)
                null
            else
                try std.fmt.bufPrint(&buf, "{s}.{d}", .{ path, i + 1 });

            if (new_path) |np| {
                std.Io.Dir.rename(.cwd(), old_path, .cwd(), np, io) catch {};
            } else {
                std.Io.Dir.deleteFile(.cwd(), io, old_path) catch {};
            }
        }

        try std.Io.Dir.rename(.cwd(), path, .cwd(), try std.fmt.bufPrint(&buf, "{s}.1", .{path}), io);

        self.file = try std.Io.Dir.createFile(.cwd(), io, path, .{ .read = true });
        self.write_offset = 0;
    }
};

var global_logger: ?*Logger = null;

pub fn initGlobalLogger(allocator: std.mem.Allocator, cfg: config.LogConfig, io: std.Io) !*Logger {
    if (global_logger) |l| {
        l.deinit(io);
    }
    const logger = try Logger.init(allocator, cfg, io);
    global_logger = logger;
    return logger;
}

pub fn deinitGlobalLogger(io: std.Io) void {
    if (global_logger) |l| {
        l.deinit(io);
        global_logger = null;
    }
}

pub fn getLogger() ?*Logger {
    return global_logger;
}
