const std = @import("std");

/// Returns the directory that contains the running executable as an absolute path.
/// The returned slice points into the provided buffer, which must live as long as
/// the slice is in use.
pub fn getExeDir(io: std.Io, buf: *[std.Io.Dir.max_path_bytes]u8) ![]const u8 {
    const len = try std.process.executableDirPath(io, buf);
    return buf[0..len];
}

/// Resolves a path relative to the executable's directory.
/// If the provided path is already absolute, it returns a duplicate of it.
/// The caller owns the returned memory and must free it with the provided allocator.
pub fn resolveRelativeToExe(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) {
        return try allocator.dupe(u8, path);
    }

    var exe_dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const exe_dir = try getExeDir(io, &exe_dir_buf);

    return try std.fs.path.resolve(allocator, &[_][]const u8{ exe_dir, path });
}
