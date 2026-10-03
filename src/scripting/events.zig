//! Events between scripts ([#498](https://github.com/OpenReliant/openreliant/issues/498)).
//! `core.send_global_event(name, data)` sends an event to the global scripts, and
//! `object:send_event(name, data)` to the scripts of one object. An event carries one value of plain
//! data (`data.zig`), copied as it's sent. Events wait until the game's next update, which delivers
//! them in the order they were sent, before the scripts' `on_update` (`game.Game`). Each script
//! that has a handler for the event in its `event_handlers` gets it, newest mod first; a handler
//! that returns `false` stops the rest.

const std = @import("std");
const Allocator = std.mem.Allocator;

const runtime_module = @import("runtime.zig");
const Runtime = runtime_module.Runtime;
const Name = runtime_module.Name;
const objects = @import("objects.zig");
const data = @import("data.zig");
const api = @import("api.zig");
const Call = api.Call;

/// Where an event goes.
pub const To = union(enum) {
    /// The global scripts, and the mission's.
    global,
    /// The scripts of one object.
    object: objects.Handle,
};

/// An event sent and not delivered yet.
pub const Pending = struct {
    to: To,
    name: Name,
    data: data.Data,
};

/// The events sent and not delivered yet.
pub const Events = struct {
    gpa: Allocator,
    runtime: *Runtime,
    pending: std.ArrayList(Pending) = .empty,

    pub fn deinit(events: *Events) void {
        for (events.pending.items) |*sent| events.runtime.release(sent.data.ref);
        events.pending.deinit(events.gpa);
    }

    /// Queues the event `name` with `payload` for `to`. Takes `payload` over, and lets it go if the
    /// event can't be sent.
    pub fn send(events: *Events, call: Call, to: To, name: []const u8, payload: data.Data) void {
        const held = Name.of(name) orelse {
            events.runtime.release(payload.ref);
            call.raise("an event's name has at most {d} bytes", .{runtime_module.max_name});
        };
        events.pending.append(events.gpa, .{ .to = to, .name = held, .data = payload }) catch {
            events.runtime.release(payload.ref);
            call.raise("out of memory sending the event {s}", .{name});
        };
    }

    /// Takes the events sent so far, for their delivery. Events sent while they're delivered wait
    /// for the next update.
    pub fn take(events: *Events) std.ArrayList(Pending) {
        defer events.pending = .empty;
        return events.pending;
    }
};
