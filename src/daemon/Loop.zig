//! An event loop on kqueue, or epoll on Linux: register fds and signals
//! once, then wait for whichever is ready. Each watch carries a token that
//! comes back with its events.

const std = @import("std");
const builtin = @import("builtin");
const fd_t = std.posix.fd_t;

const Loop = @This();

const is_linux = builtin.os.tag == .linux;

/// The kqueue, or on Linux the epoll.
kq: fd_t,
/// Signal actions before addSignal, restored on deinit.
old: [32]?std.c.Sigaction,
linux: if (is_linux) Linux else void,

pub const Event = struct {
    token: usize,
    kind: Kind,
    /// The other end hung up. There may still be bytes to read first.
    eof: bool,

    pub const Kind = enum { read, signal, timer };
};

pub fn init() !Loop {
    if (is_linux) return Linux.init();
    const kq = std.c.kqueue();
    if (kq < 0) return error.KqueueFailed;
    // not inherited by children such as Neovim
    _ = std.c.fcntl(kq, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
    return .{ .kq = kq, .old = @splat(null), .linux = {} };
}

/// Restores the old signal actions, then closes the kqueue.
pub fn deinit(self: *Loop) void {
    // restore first, so no signal is ignored once nothing watches it
    for (self.old, 0..) |maybe_old_action, n| {
        if (maybe_old_action) |old_action| {
            std.posix.sigaction(@fromBackingInt(@intCast(n)), &old_action, null);
        }
    }
    if (is_linux) self.linux.deinit();
    _ = std.c.close(self.kq);
    self.* = undefined;
}

/// Watches `fd` for reading. Adding it again replaces the token.
pub fn addRead(self: *const Loop, fd: fd_t, token: usize) !void {
    if (is_linux) return Linux.watch(self.kq, fd, Linux.tag(.read, token));
    try self.change(@intCast(fd), std.c.EVFILT.READ, std.c.EV.ADD, token);
}

/// Stops watching `fd`. Not needed before closing it.
pub fn remove(self: *const Loop, fd: fd_t) !void {
    if (is_linux) {
        if (std.c.epoll_ctl(self.kq, std.os.linux.EPOLL.CTL_DEL, fd, null) < 0) return error.EpollFailed;
        return;
    }
    try self.change(@intCast(fd), std.c.EVFILT.READ, std.c.EV.DELETE, 0);
}

/// Watches `sig`, and ignores it so its default action never runs.
pub fn addSignal(self: *Loop, sig: std.c.SIG, token: usize) !void {
    const n = @backingInt(sig);
    // only the first time, so a second call can't save our own SIG_IGN
    if (self.old[n] == null) {
        var old: std.c.Sigaction = undefined;
        std.posix.sigaction(sig, null, &old);
        self.old[n] = old;
    }
    const ignore: std.c.Sigaction = .{
        .handler = .{ .handler = std.c.SIG.IGN },
        .mask = std.mem.zeroes(std.c.sigset_t),
        .flags = 0,
    };
    if (is_linux) {
        // a handler, not SIG_IGN or a blocked mask: children such as
        // Neovim and its terminals would inherit those
        self.linux.sig_tokens[n] = token;
        const action: std.c.Sigaction = .{
            .handler = .{ .handler = Linux.onSignal },
            .mask = std.posix.sigemptyset(),
            .flags = std.c.SA.RESTART,
        };
        std.posix.sigaction(sig, &action, null);
        return;
    }
    std.posix.sigaction(sig, &ignore, null);
    try self.change(n, std.c.EVFILT.SIGNAL, std.c.EV.ADD, token);
}

/// Fires once, `ms` milliseconds from now. Adding timer `id` again
/// restarts it.
pub fn addTimer(self: *Loop, id: usize, ms: u32, token: usize) !void {
    if (is_linux) return self.linux.addTimer(self.kq, id, ms, token);
    try self.changeData(id, std.c.EVFILT.TIMER, std.c.EV.ADD | std.c.EV.ONESHOT, token, ms);
}

/// Blocks until something is ready, then fills the start of `buf`.
pub fn wait(self: *Loop, buf: []Event) ![]Event {
    if (is_linux) return self.linux.wait(self.kq, buf);
    var raw: [64]std.c.Kevent = undefined;
    const max: c_int = @intCast(@min(buf.len, raw.len));
    const n: usize = while (true) {
        const rc = std.c.kevent(self.kq, &raw, 0, &raw, max, null);
        if (rc >= 0) break @intCast(rc);
        if (std.c.errno(rc) != .INTR) return error.KeventFailed;
    };

    for (raw[0..n], buf[0..n]) |e, *out| {
        if (e.flags & std.c.EV.ERROR != 0) return error.KeventFailed;
        out.* = .{
            .token = e.udata,
            .kind = switch (e.filter) {
                std.c.EVFILT.READ => .read,
                std.c.EVFILT.SIGNAL => .signal,
                std.c.EVFILT.TIMER => .timer,
                else => unreachable, // only these are registered
            },
            .eof = e.flags & std.c.EV.EOF != 0,
        };
    }
    return buf[0..n];
}

/// Registers one change with the kqueue.
fn change(self: *const Loop, ident: usize, filter: i16, flags: u16, token: usize) !void {
    try self.changeData(ident, filter, flags, token, 0);
}

fn changeData(self: *const Loop, ident: usize, filter: i16, flags: u16, token: usize, data: isize) !void {
    const changes = [_]std.c.Kevent{.{
        .ident = ident,
        .filter = filter,
        .flags = flags,
        .fflags = 0,
        .data = data,
        .udata = token,
    }};
    var none: [0]std.c.Kevent = undefined;
    if (std.c.kevent(self.kq, &changes, changes.len, &none, 0, null) < 0) return error.KeventFailed;
}

/// Linux: epoll for fds, a self-pipe for signals, a timerfd per timer.
const Linux = struct {
    const linux = std.os.linux;

    /// The signal handler's pipe: read end in the epoll, write end for the handler.
    sig_pipe: [2]fd_t,
    /// Each watched signal's token, by number.
    sig_tokens: [32]?usize = @splat(null),
    timers: [max_timers]?Timer = @splat(null),

    const max_timers = 8;
    const Timer = struct { id: usize, fd: fd_t, token: usize };

    /// The handler can't see the Loop; one Loop per process watches signals.
    var handler_fd: fd_t = -1;

    /// What an epoll event's data holds: the kind in the top bits, then a
    /// token or timer slot.
    const Kind = enum(u2) { read, signal_pipe, timer };
    const kind_shift = 62;

    fn tag(kind: Kind, value: usize) u64 {
        std.debug.assert(value >> kind_shift == 0);
        return @as(u64, @backingInt(kind)) << kind_shift | value;
    }

    fn init() !Loop {
        const ep = std.c.epoll_create1(linux.EPOLL.CLOEXEC);
        if (ep < 0) return error.EpollFailed;
        errdefer _ = std.c.close(ep);
        const p = try std.Io.Threaded.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
        errdefer for (p) |fd| {
            _ = std.c.close(fd);
        };
        try watch(ep, p[0], tag(.signal_pipe, 0));
        std.debug.assert(handler_fd == -1);
        handler_fd = p[1];
        return .{ .kq = ep, .old = @splat(null), .linux = .{ .sig_pipe = p } };
    }

    fn deinit(self: *Linux) void {
        handler_fd = -1;
        for (self.sig_pipe) |fd| _ = std.c.close(fd);
        for (self.timers) |t| if (t) |timer| {
            _ = std.c.close(timer.fd);
        };
    }

    fn watch(ep: fd_t, fd: fd_t, data: u64) !void {
        var ev: linux.epoll_event = .{ .events = linux.EPOLL.IN | linux.EPOLL.RDHUP, .data = .{ .u64 = data } };
        if (std.c.epoll_ctl(ep, linux.EPOLL.CTL_ADD, fd, &ev) == 0) return;
        // already watched: replace its token, as kqueue's EV_ADD does
        if (std.c.errno(-1) != .EXIST) return error.EpollFailed;
        if (std.c.epoll_ctl(ep, linux.EPOLL.CTL_MOD, fd, &ev) < 0) return error.EpollFailed;
    }

    /// Only async-signal-safe calls here.
    fn onSignal(sig: std.c.SIG) callconv(.c) void {
        const saved = std.c._errno().*;
        defer std.c._errno().* = saved;
        const byte = [1]u8{@intCast(@backingInt(sig))};
        _ = std.c.write(handler_fd, &byte, byte.len);
    }

    fn addTimer(self: *Linux, ep: fd_t, id: usize, ms: u32, token: usize) !void {
        const slot = for (&self.timers, 0..) |*t, i| {
            if (t.*) |timer| if (timer.id == id) break i;
        } else for (&self.timers, 0..) |*t, i| {
            if (t.* == null) break i;
        } else return error.TooManyTimers;
        if (self.timers[slot] == null) {
            const fd = std.c.timerfd_create(.MONOTONIC, @bitCast(linux.TFD{ .CLOEXEC = true, .NONBLOCK = true }));
            if (fd < 0) return error.TimerFailed;
            errdefer _ = std.c.close(fd);
            try watch(ep, fd, tag(.timer, slot));
            self.timers[slot] = .{ .id = id, .fd = fd, .token = token };
        }
        const t = &self.timers[slot].?;
        t.token = token;
        // one shot: no interval
        const spec: linux.itimerspec = .{
            .it_interval = .{ .sec = 0, .nsec = 0 },
            .it_value = .{ .sec = @intCast(ms / 1000), .nsec = @intCast(@as(u64, ms % 1000) * std.time.ns_per_ms + @intFromBool(ms == 0)) },
        };
        if (std.c.timerfd_settime(t.fd, 0, &spec, null) < 0) return error.TimerFailed;
    }

    fn wait(self: *Linux, ep: fd_t, buf: []Event) ![]Event {
        var raw: [64]linux.epoll_event = undefined;
        const max: c_uint = @intCast(@min(buf.len, raw.len));
        const n: usize = while (true) {
            const rc = std.c.epoll_wait(ep, &raw, max, -1);
            if (rc >= 0) break @intCast(rc);
            if (std.c.errno(rc) != .INTR) return error.EpollFailed;
        };
        var out: usize = 0;
        for (raw[0..n]) |e| {
            const data = e.data.u64;
            const value: usize = @intCast(data & ((@as(u64, 1) << kind_shift) - 1));
            switch (@as(Kind, @fromBackingInt(@intCast(data >> kind_shift)))) {
                .read => {
                    buf[out] = .{ .token = value, .kind = .read, .eof = e.events & (linux.EPOLL.HUP | linux.EPOLL.RDHUP) != 0 };
                    out += 1;
                },
                .timer => {
                    const t = self.timers[value] orelse continue;
                    var expirations: u64 = undefined;
                    // a timer restarted since it fired reads nothing: not due
                    if (std.c.read(t.fd, std.mem.asBytes(&expirations), 8) != 8) continue;
                    buf[out] = .{ .token = t.token, .kind = .timer, .eof = false };
                    out += 1;
                },
                .signal_pipe => {
                    var fired: [32]bool = @splat(false);
                    var bytes: [64]u8 = undefined;
                    while (true) {
                        const r = std.c.read(self.sig_pipe[0], &bytes, bytes.len);
                        if (r <= 0) break;
                        for (bytes[0..@intCast(r)]) |b| if (b < fired.len) {
                            fired[b] = true;
                        };
                    }
                    for (fired, 0..) |f, sig| if (f) if (self.sig_tokens[sig]) |token| {
                        if (out == buf.len) break;
                        buf[out] = .{ .token = token, .kind = .signal, .eof = false };
                        out += 1;
                    };
                },
            }
        }
        return buf[0..out];
    }
};

const testing = std.testing;

fn pipe() ![2]fd_t {
    var p: [2]fd_t = undefined;
    if (std.c.pipe(&p) != 0) return error.Pipe;
    return p;
}

test "a readable pipe, then its hang-up" {
    var loop: Loop = try .init();
    defer loop.deinit();
    const p = try pipe();
    defer _ = std.c.close(p[0]);
    try loop.addRead(p[0], 7);

    _ = std.c.write(p[1], "x", 1);
    var buf: [4]Event = undefined;
    try testing.expectEqualSlices(Event, &.{.{ .token = 7, .kind = .read, .eof = false }}, try loop.wait(&buf));

    _ = std.c.close(p[1]);
    try testing.expectEqualSlices(Event, &.{.{ .token = 7, .kind = .read, .eof = true }}, try loop.wait(&buf));
}

test "only ready fds are reported; removed ones aren't" {
    var loop: Loop = try .init();
    defer loop.deinit();
    const a = try pipe();
    const b = try pipe();
    defer for (a ++ b) |fd| {
        _ = std.c.close(fd);
    };
    try loop.addRead(a[0], 1);
    try loop.addRead(b[0], 2);
    try loop.remove(a[0]);

    _ = std.c.write(a[1], "x", 1);
    _ = std.c.write(b[1], "x", 1);
    var buf: [4]Event = undefined;
    try testing.expectEqualSlices(Event, &.{.{ .token = 2, .kind = .read, .eof = false }}, try loop.wait(&buf));
}

test "signals arrive as events and the old action comes back" {
    var loop: Loop = try .init();
    try loop.addSignal(.USR1, 9);
    // the whole process: raise only signals this thread, which kqueue misses
    _ = std.c.kill(std.c.getpid(), .USR1);
    var buf: [4]Event = undefined;
    try testing.expectEqualSlices(Event, &.{.{ .token = 9, .kind = .signal, .eof = false }}, try loop.wait(&buf));

    loop.deinit();
    var now: std.c.Sigaction = undefined;
    std.posix.sigaction(.USR1, null, &now);
    try testing.expect(now.handler.handler != std.c.SIG.IGN);
}

test "a timer fires once" {
    var loop: Loop = try .init();
    defer loop.deinit();
    try loop.addTimer(1, 5, 11);
    var buf: [4]Event = undefined;
    try testing.expectEqualSlices(Event, &.{.{ .token = 11, .kind = .timer, .eof = false }}, try loop.wait(&buf));
}
