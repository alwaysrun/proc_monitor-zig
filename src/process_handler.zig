const std = @import("std");
const logger = @import("logger.zig");
const config = @import("config.zig");
const utils = @import("utils.zig");

const windows = std.os.windows;

const HANDLE = windows.HANDLE;
const DWORD = windows.DWORD;
const BOOL = windows.BOOL;
const LPCSTR = ?[*:0]const u8;
const LPCWSTR = ?[*:0]const u16;

extern "kernel32" fn CreateToolhelp32Snapshot(dwFlags: DWORD, th32ProcessID: DWORD) callconv(.winapi) HANDLE;
extern "kernel32" fn Process32First(hSnapshot: HANDLE, lppe: *PROCESSENTRY32) callconv(.winapi) BOOL;
extern "kernel32" fn Process32Next(hSnapshot: HANDLE, lppe: *PROCESSENTRY32) callconv(.winapi) BOOL;
extern "kernel32" fn OpenProcess(dwDesiredAccess: DWORD, bInheritHandle: BOOL, dwProcessId: DWORD) callconv(.winapi) ?HANDLE;
extern "kernel32" fn TerminateProcess(hProcess: HANDLE, uExitCode: u32) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;

extern "kernel32" fn CreateProcessW(
    lpApplicationName: LPCWSTR,
    lpCommandLine: ?[*:0]u16,
    lpProcessAttributes: ?*windows.SECURITY_ATTRIBUTES,
    lpThreadAttributes: ?*windows.SECURITY_ATTRIBUTES,
    bInheritHandles: BOOL,
    dwCreationFlags: DWORD,
    lpEnvironment: ?*anyopaque,
    lpCurrentDirectory: LPCWSTR,
    lpStartupInfo: *STARTUPINFOW,
    lpProcessInformation: *PROCESS_INFORMATION,
) callconv(.winapi) BOOL;

const TH32CS_SNAPPROCESS: DWORD = 0x00000002;
const PROCESS_TERMINATE: DWORD = 0x0001;
const PROCESS_QUERY_INFORMATION: DWORD = 0x0400;

const MAX_PATH: usize = 260;

const PROCESSENTRY32 = extern struct {
    dwSize: DWORD,
    cntUsage: DWORD,
    th32ProcessID: DWORD,
    th32DefaultHeapID: usize,
    th32ModuleID: DWORD,
    cntThreads: DWORD,
    th32ParentProcessID: DWORD,
    pcPriClassBase: i32,
    dwFlags: DWORD,
    szExeFile: [MAX_PATH]u8,
};

const STARTUPINFOW = extern struct {
    cb: DWORD,
    lpReserved: ?[*:0]u16,
    lpDesktop: ?[*:0]u16,
    lpTitle: ?[*:0]u16,
    dwX: DWORD,
    dwY: DWORD,
    dwXSize: DWORD,
    dwYSize: DWORD,
    dwXCountChars: DWORD,
    dwYCountChars: DWORD,
    dwFillAttribute: DWORD,
    dwFlags: DWORD,
    wShowWindow: u16,
    cbReserved2: u16,
    lpReserved2: ?*anyopaque,
    hStdInput: ?HANDLE,
    hStdOutput: ?HANDLE,
    hStdError: ?HANDLE,
};

const PROCESS_INFORMATION = extern struct {
    hProcess: ?HANDLE,
    hThread: ?HANDLE,
    dwProcessId: DWORD,
    dwThreadId: DWORD,
};

pub const ProcessInfo = struct {
    pid: DWORD,
    name: []const u8,
    parent_pid: DWORD,
};

pub const ProcessError = error{
    SnapshotFailed,
    ProcessNotFound,
    TerminateFailed,
    OpenFailed,
    StartFailed,
    OutOfMemory,
};

pub fn getProcessList(allocator: std.mem.Allocator) ProcessError![]ProcessInfo {
    const snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == windows.INVALID_HANDLE_VALUE) {
        return ProcessError.SnapshotFailed;
    }
    defer _ = CloseHandle(snapshot);

    var entry: PROCESSENTRY32 = std.mem.zeroes(PROCESSENTRY32);
    entry.dwSize = @sizeOf(PROCESSENTRY32);

    if (Process32First(snapshot, &entry) == .FALSE) {
        return ProcessError.SnapshotFailed;
    }

    var list: std.ArrayList(ProcessInfo) = .empty;
    errdefer list.deinit(allocator);

    while (true) {
        const name_len = std.mem.indexOfScalar(u8, &entry.szExeFile, 0) orelse MAX_PATH;
        const name = try allocator.dupe(u8, entry.szExeFile[0..name_len]);

        try list.append(allocator, .{
            .pid = entry.th32ProcessID,
            .name = name,
            .parent_pid = entry.th32ParentProcessID,
        });

        if (Process32Next(snapshot, &entry) == .FALSE) {
            break;
        }
    }

    return list.toOwnedSlice(allocator);
}

pub fn freeProcessList(allocator: std.mem.Allocator, list: []ProcessInfo) void {
    for (list) |info| {
        allocator.free(info.name);
    }
    allocator.free(list);
}

pub fn findProcessByName(processes: []const ProcessInfo, target: config.ProcessTarget) ?ProcessInfo {
    for (processes) |proc| {
        const matches = switch (target.match_type) {
            .exact => std.mem.eql(u8, proc.name, target.name),
            .contains => std.mem.indexOf(u8, proc.name, target.name) != null,
            .regex => false,
        };
        if (matches) return proc;
    }
    return null;
}

pub fn terminateProcess(pid: DWORD) ProcessError!void {
    const handle = OpenProcess(PROCESS_TERMINATE, BOOL.fromBool(false), pid);
    if (handle == null) {
        return ProcessError.OpenFailed;
    }
    defer _ = CloseHandle(handle.?);

    if (TerminateProcess(handle.?, 0) == .FALSE) {
        return ProcessError.TerminateFailed;
    }
}

pub fn startProcess(allocator: std.mem.Allocator, io: std.Io, exe_path: []const u8) ProcessError!void {
    const resolved_path = utils.resolveRelativeToExe(allocator, io, exe_path) catch {
        return ProcessError.StartFailed;
    };
    defer allocator.free(resolved_path);

    const wide_path = std.unicode.utf8ToUtf16LeAllocZ(allocator, resolved_path) catch {
        return ProcessError.StartFailed;
    };
    defer allocator.free(wide_path);

    var startup_info: STARTUPINFOW = std.mem.zeroes(STARTUPINFOW);
    startup_info.cb = @sizeOf(STARTUPINFOW);

    var process_info: PROCESS_INFORMATION = undefined;

    const result = CreateProcessW(
        null,
        wide_path.ptr,
        null,
        null,
        BOOL.fromBool(false),
        0,
        null,
        null,
        &startup_info,
        &process_info,
    );

    if (result == .FALSE) {
        const err = GetLastError();
        std.log.err("CreateProcessW failed for '{s}' with error code: {}", .{ exe_path, err });
        return ProcessError.StartFailed;
    }

    if (process_info.hProcess) |h| {
        _ = CloseHandle(h);
    }
    if (process_info.hThread) |h| {
        _ = CloseHandle(h);
    }
}

test "get process list" {
    const allocator = std.testing.allocator;
    const processes = try getProcessList(allocator);
    defer freeProcessList(allocator, processes);

    try std.testing.expect(processes.len > 0);
}
