const std = @import("std");
const config = @import("config.zig");
const logger = @import("logger.zig");
const handler = @import("process_handler.zig");

pub const MonitorState = struct {
    monitored_process: []const u8,
    running: bool,
    last_check: i64,
    detected_pids: std.AutoHashMap(u32, bool),
    check_interval_ms: u64,
};

pub const ProcessMonitor = struct {
    allocator: std.mem.Allocator,
    cfg: config.Config,
    states: std.ArrayList(MonitorState),
    running: bool,
    log: ?*logger.Logger,
    io: std.Io,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config, log: ?*logger.Logger, io: std.Io) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .cfg = cfg,
            .states = .empty,
            .running = false,
            .log = log,
            .io = io,
        };

        for (cfg.monitor.process) |proc_config| {
            const state = MonitorState{
                .monitored_process = proc_config.monitored,
                .running = false,
                .last_check = 0,
                .detected_pids = std.AutoHashMap(u32, bool).init(allocator),
                .check_interval_ms = proc_config.check_interval * 1000,
            };
            try self.states.append(allocator, state);
        }

        return self;
    }

    pub fn deinit(self: *Self) void {
        for (self.states.items) |*state| {
            state.detected_pids.deinit();
        }
        self.states.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn start(self: *Self) void {
        self.running = true;

        if (self.log) |l| {
            l.info("Process monitor started", .{}, self.io);
            l.info("Monitoring {} processes", .{self.states.items.len}, self.io);
        }

        while (self.running) {
            self.checkAllProcesses() catch |err| {
                if (self.log) |l| {
                    l.err("Error during monitoring: {}", .{err}, self.io);
                }
            };

            var min_interval: u64 = std.math.maxInt(u64);
            for (self.states.items) |state| {
                if (state.check_interval_ms < min_interval) {
                    min_interval = state.check_interval_ms;
                }
            }

            const duration = std.Io.Duration.fromMilliseconds(@intCast(min_interval));
            std.Io.sleep(self.io, duration, .real) catch {};
        }
    }

    pub fn stop(self: *Self) void {
        self.running = false;
        if (self.log) |l| {
            l.info("Process monitor stopped", .{}, self.io);
        }
    }

    pub fn checkAllProcesses(self: *Self) !void {
        const processes = handler.getProcessList(self.allocator) catch |err| {
            if (self.log) |l| {
                l.err("Failed to get process list: {}", .{err}, self.io);
            }
            return;
        };
        defer handler.freeProcessList(self.allocator, processes);

        for (self.cfg.monitor.process, 0..) |proc_config, idx| {
            try self.checkProcess(proc_config, &self.states.items[idx], processes);
        }
    }

    fn checkProcess(self: *Self, proc_config: config.ProcessMonitorConfig, state: *MonitorState, processes: []handler.ProcessInfo) !void {
        const timestamp = std.Io.Timestamp.now(self.io, .real);
        const now: i64 = @intCast(@divFloor(timestamp.nanoseconds, std.time.ns_per_s));
        state.last_check = now;

        if (self.log) |l| {
            l.debug("Checking monitored process: {s}", .{proc_config.monitored}, self.io);
        }

        var found_pids = std.AutoHashMap(u32, bool).init(self.allocator);
        defer found_pids.deinit();

        const target = config.ProcessTarget{
            .name = proc_config.monitored,
            .match_type = .exact,
        };

        if (handler.findProcessByName(processes, target)) |proc| {
            try found_pids.put(proc.pid, true);

            const was_detected = state.detected_pids.contains(proc.pid);

            if (!was_detected) {
                if (self.log) |l| {
                    l.info("Process '{s}' started (pid={})", .{ proc.name, proc.pid }, self.io);
                }
                try self.executeActions(proc_config, proc);
            } else {
                if (self.log) |l| {
                    l.debug("Process '{s}' still running (pid={})", .{ proc.name, proc.pid }, self.io);
                }
            }
        }

        state.detected_pids.clearAndFree();
        var iter = found_pids.iterator();
        while (iter.next()) |entry| {
            try state.detected_pids.put(entry.key_ptr.*, true);
        }
    }

    fn executeActions(self: *Self, proc_config: config.ProcessMonitorConfig, proc: handler.ProcessInfo) !void {
        var iter = proc_config.action.iterator();
        while (iter.next()) |entry| {
            const target_process = entry.key_ptr.*;
            const action_type = entry.value_ptr.*;

            if (self.log) |l| {
                l.info("Executing action '{s}' on process '{s}' for monitored '{s}'", .{ @tagName(action_type), target_process, proc.name }, self.io);
            }

            switch (action_type) {
                .close => {
                    const target = config.ProcessTarget{
                        .name = target_process,
                        .match_type = .exact,
                    };

                    const all_processes = handler.getProcessList(self.allocator) catch |err| {
                        if (self.log) |l| {
                            l.err("Failed to get process list for action: {}", .{err}, self.io);
                        }
                        continue;
                    };
                    defer handler.freeProcessList(self.allocator, all_processes);

                    if (handler.findProcessByName(all_processes, target)) |target_proc| {
                        handler.terminateProcess(target_proc.pid) catch |err| {
                            if (self.log) |l| {
                                l.err("Failed to terminate process '{s}' (pid={}): {}", .{ target_process, target_proc.pid, err }, self.io);
                            }
                            continue;
                        };
                        if (self.log) |l| {
                            l.info("Successfully terminated process: {s} (pid={})", .{ target_process, target_proc.pid }, self.io);
                        }
                    } else {
                        if (self.log) |l| {
                            l.debug("Target process not found: {s}", .{target_process}, self.io);
                        }
                    }
                },
                .start => {
                    handler.startProcess(self.allocator, self.io, target_process) catch |err| {
                        if (self.log) |l| {
                            l.err("Failed to start process '{s}': {}", .{ target_process, err }, self.io);
                        }
                        continue;
                    };
                    if (self.log) |l| {
                        l.info("Successfully started process: {s}", .{target_process}, self.io);
                    }
                },
            }
        }
    }

    pub fn runOnce(self: *Self) !void {
        try self.checkAllProcesses();
    }
};

test "monitor initialization" {
    const allocator = std.testing.allocator;

    const test_config = config.Config{
        .monitor = .{
            .process = &.{},
        },
    };

    var monitor = try ProcessMonitor.init(allocator, test_config, null, undefined);
    defer monitor.deinit();

    try std.testing.expectEqual(@as(usize, 0), monitor.states.items.len);
}
