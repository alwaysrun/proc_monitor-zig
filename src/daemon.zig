const std = @import("std");
const logger = @import("logger.zig");

const windows = std.os.windows;

const HANDLE = windows.HANDLE;
const DWORD = windows.DWORD;
const BOOL = windows.BOOL;

extern "kernel32" fn GetStdHandle(nStdHandle: DWORD) callconv(.winapi) ?HANDLE;
extern "kernel32" fn SetStdHandle(nStdHandle: DWORD, hHandle: ?HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn GetConsoleWindow() callconv(.winapi) ?windows.HWND;
extern "kernel32" fn FreeConsole() callconv(.winapi) BOOL;
extern "user32" fn ShowWindow(hWnd: ?windows.HWND, nCmdShow: i32) callconv(.winapi) BOOL;

const SW_HIDE = 0;

const STD_INPUT_HANDLE: DWORD = 0xFFFFFFF6;
const STD_OUTPUT_HANDLE: DWORD = 0xFFFFFFF5;
const STD_ERROR_HANDLE: DWORD = 0xFFFFFFF4;


pub const DaemonError = error{
    ForkFailed,
    SetsidFailed,
    OpenFailed,
    WriteFailed,
    AlreadyRunning,
};

pub fn daemonize(allocator: std.mem.Allocator, io: std.Io, pid_file: ?[]const u8) DaemonError!void {
    // 1. Hide the console window if it exists
    if (GetConsoleWindow()) |hwnd| {
        _ = ShowWindow(hwnd, SW_HIDE);
    }

    // 2. Detach from the console
    _ = FreeConsole();

    // 3. Nullify standard handles to prevent unexpected behavior
    _ = SetStdHandle(STD_INPUT_HANDLE, null);
    _ = SetStdHandle(STD_OUTPUT_HANDLE, null);
    _ = SetStdHandle(STD_ERROR_HANDLE, null);

    if (pid_file) |path| {
        const file = std.Io.Dir.createFile(.cwd(), io, path, .{ .truncate = true }) catch |err| {
            std.log.err("Failed to create pid file: {}", .{err});
            return DaemonError.OpenFailed;
        };
        defer file.close(io);

        const pid = std.os.windows.GetCurrentProcessId();
        const pid_str = std.fmt.allocPrint(allocator, "{}\n", .{pid}) catch return DaemonError.WriteFailed;
        defer allocator.free(pid_str);

        var buf: [64]u8 = undefined;
        var file_writer: std.Io.File.Writer = .init(file, io, &buf);
        const writer = &file_writer.interface;
        writer.writeAll(pid_str) catch return DaemonError.WriteFailed;
        writer.flush() catch return DaemonError.WriteFailed;
    }
}

pub fn writePidFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const file = try std.Io.Dir.createFile(.cwd(), io, path, .{ .truncate = true });
    defer file.close(io);

    const pid = std.os.windows.GetCurrentProcessId();
    const pid_str = try std.fmt.allocPrint(allocator, "{}\n", .{pid});
    defer allocator.free(pid_str);

    var buf: [64]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(file, io, &buf);
    const writer = &file_writer.interface;
    try writer.writeAll(pid_str);
    try writer.flush();
}

pub fn removePidFile(io: std.Io, path: []const u8) void {
    std.Io.Dir.deleteFile(.cwd(), io, path) catch {};
}

pub fn checkPidFile(io: std.Io, path: []const u8) !?u32 {
    const file = std.Io.Dir.openFile(.cwd(), io, path, .{ .mode = .read_only }) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer file.close(io);

    var buf: [32]u8 = undefined;
    var file_reader: std.Io.File.Reader = .init(file, io, &buf);
    const reader = &file_reader.interface;

    var content_buf: [32]u8 = undefined;
    const content = reader.readWithAtMost(&content_buf, 32) catch return error.ReadFailed;

    const pid_str = std.mem.trim(u8, content, " \t\r\n");
    return std.fmt.parseInt(u32, pid_str, 10) catch error.ParseError;
}

pub fn isProcessRunning(pid: u32) bool {
    const PROCESS_QUERY_LIMITED_INFORMATION: DWORD = 0x1000;

    const handle = std.os.windows.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) catch return false;
    defer _ = std.os.windows.CloseHandle(handle);

    var exit_code: DWORD = 0;
    const result = std.os.windows.GetExitCodeProcess(handle, &exit_code);
    return result == windows.TRUE and exit_code == 259;
}
