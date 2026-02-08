const std = @import("std");

const Allocator = std.mem.Allocator;
const HashMap = std.AutoHashMapUnmanaged;
const ArrayList = std.ArrayList;

const dtype = i32;

pub const Vec2 = struct {
    x: dtype,
    y: dtype,

    pub const zero: @This() = .{
        .x = 0,
        .y = 0,
    };

    pub fn init(x: dtype, y: dtype) @This() {
        return .{
            .x = x,
            .y = y,
        };
    }
};

pub const Rect = struct {
    xmin: dtype,
    ymin: dtype,
    xmax: dtype,
    ymax: dtype,

    pub fn init(xmin: dtype, ymin: dtype, xmax: dtype, ymax: dtype) @This() {
        return .{
            .xmin = xmin,
            .ymin = ymin,
            .xmax = xmax,
            .ymax = ymax,
        };
    }

    pub fn contain(self: @This(), p: Vec2) bool {
        return self.xmin <= p.x and self.ymin <= p.y and self.xmax >= p.x and self.ymax >= p.y;
    }
};

const GolErrors = Allocator.Error;

pub const World = struct {
    ptr: *Ctx,
    vtable: *const VTable,

    const VTable = struct {
        addCell: *const fn (ctx: *Ctx, pos: Vec2) GolErrors!bool,
        killCell: *const fn (ctx: *Ctx, pos: Vec2) bool,
        queryCell: *const fn (ctx: *const Ctx, pos: Vec2) bool,
        queryCells: *const fn (ctx: *const Ctx, rect: Rect, callback: fn (pos: Vec2) anyerror!void) anyerror!void,
        queryAllCells: *const fn (ctx: *const Ctx, callback: fn (pos: Vec2) anyerror!void) anyerror!void,
        count: *const fn (ctx: *const Ctx) usize,
        clear: *const fn (ctx: *Ctx) void,
        tick: *const fn (ctx: *Ctx) GolErrors!void,
        iteration: *const fn (ctx: *Ctx) usize,
    };

    const Self = @This();
    const Ctx = anyopaque;

    pub inline fn addCell(self: Self, pos: Vec2) GolErrors!bool {
        return self.vtable.addCell(self.ptr, pos);
    }
    pub inline fn killCell(self: Self, pos: Vec2) bool {
        return self.vtable.killCell(self.ptr, pos);
    }
    pub inline fn queryCell(self: Self, pos: Vec2) bool {
        return self.vtable.queryCell(self.ptr, pos);
    }
    pub inline fn queryCells(self: Self, rect: Rect, callback: fn (pos: Vec2) anyerror!void) anyerror!void {
        return self.vtable.queryCells(self.ptr, rect, callback);
    }
    pub inline fn queryAllCells(self: Self, callback: fn (pos: Vec2) anyerror!void) anyerror!void {
        return self.vtable.queryAllCells(self.ptr, callback);
    }
    pub inline fn count(self: Self) usize {
        return self.vtable.count(self.ptr);
    }
    pub inline fn clear(self: Self) void {
        return self.vtable.clear(self.ptr);
    }
    pub inline fn tick(self: Self) GolErrors!void {
        return self.vtable.tick(self.ptr);
    }
    pub inline fn iteration(self: Self) usize {
        return self.vtable.iteration(self.ptr);
    }
};

pub const HashMapWorld = struct {
    gpa: Allocator,
    cells: HashMap(Vec2, i8),
    iter: usize = 0,

    const Self = @This();
    const Ctx = anyopaque;

    pub fn init(gpa: Allocator) Self {
        return .{
            .gpa = gpa,
            .cells = .empty,
        };
    }

    pub fn deinit(self: *Self) void {
        self.cells.deinit(self.gpa);
    }

    pub fn world(self: *Self) World {
        return .{
            .ptr = self,
            .vtable = &.{
                .addCell = &Self.addCell,
                .killCell = &Self.killCell,
                .queryCell = &Self.queryCell,
                .clear = &Self.clear,
                .count = &Self.count,
                .queryAllCells = &Self.queryAllCells,
                .queryCells = &Self.queryCells,
                .tick = &Self.tick,
                .iteration = &Self.iteration,
            },
        };
    }

    fn addCell(ctx: *Ctx, pos: Vec2) GolErrors!bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const gop = try self.cells.getOrPut(self.gpa, pos);
        if (gop.found_existing) return false;
        gop.value_ptr.* = 0;
        return true;
    }

    fn killCell(ctx: *Ctx, pos: Vec2) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.cells.remove(pos);
    }
    fn queryCell(ctx: *const Ctx, pos: Vec2) bool {
        const self: *const Self = @ptrCast(@alignCast(ctx));
        return self.cells.getPtr(pos) != null;
    }

    fn queryCells(ctx: *const Ctx, rect: Rect, callback: fn (pos: Vec2) anyerror!void) anyerror!void {
        const self: *const Self = @ptrCast(@alignCast(ctx));
        var iter = self.cells.keyIterator();
        while (iter.next()) |pos| {
            if (rect.contain(pos.*)) {
                try callback(pos.*);
            }
        }
    }
    fn queryAllCells(ctx: *const Ctx, callback: fn (pos: Vec2) anyerror!void) anyerror!void {
        const self: *const Self = @ptrCast(@alignCast(ctx));
        var iter = self.cells.keyIterator();
        while (iter.next()) |pos| {
            try callback(pos.*);
        }
    }

    fn count(ctx: *const Ctx) usize {
        const self: *const Self = @ptrCast(@alignCast(ctx));
        return self.cells.size;
    }

    fn clear(ctx: *Ctx) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.cells.clearAndFree(self.gpa);
        self.iter = 0;
    }

    fn tick(ctx: *Ctx) GolErrors!void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        defer self.iter += 1;
        var new_cells: HashMap(Vec2, i8) = .empty;
        defer new_cells.deinit(self.gpa);

        {
            var iter = self.cells.valueIterator();
            while (iter.next()) |cnt| {
                cnt.* = 0;
            }
        }

        {
            var iter = self.cells.keyIterator();
            while (iter.next()) |pos| {
                comptime var dx: dtype = -1;
                inline while (dx < 2) : (dx += 1) {
                    comptime var dy: dtype = -1;
                    inline while (dy < 2) : (dy += 1) {
                        if (dx == 0 and dy == 0) continue;
                        const p = Vec2.init(pos.x + dx, pos.y + dy);
                        if (self.cells.getEntry(p)) |e| {
                            e.value_ptr.* += 1;
                        } else {
                            const gop = try new_cells.getOrPut(self.gpa, p);
                            if (gop.found_existing) {
                                gop.value_ptr.* += 1;
                            } else {
                                gop.value_ptr.* = 1;
                            }
                        }
                    }
                }
            }
        }

        {
            var iter = self.cells.iterator();
            while (iter.next()) |e| {
                if (e.value_ptr.* < 2 or e.value_ptr.* > 3) {
                    self.cells.removeByPtr(e.key_ptr);
                }
            }
        }

        {
            var iter = new_cells.iterator();
            while (iter.next()) |e| {
                if (e.value_ptr.* == 3) {
                    try self.cells.put(self.gpa, e.key_ptr.*, e.value_ptr.*);
                }
            }
        }
    }

    fn iteration(ctx: *const Ctx) usize {
        const self: *const Self = @ptrCast(@alignCast(ctx));
        return self.iter;
    }
};
