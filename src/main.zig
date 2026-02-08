const std = @import("std");
const dvui = @import("dvui");
const gol = @import("gol.zig");

const Allocator = std.mem.Allocator;

pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
pub const dvui_app: dvui.App = .{
    .config = .{ .options = .{
        .size = .{ .w = 800, .h = 500 },
        .title = "game of life",
        .min_size = .{ .w = 300, .h = 300 },
    } },
    .frameFn = update,
    .initFn = init,
    .deinitFn = deinit,
};

fn init(_: *dvui.Window) !void {
    try APP.init();
}
fn deinit() void {
    APP.deinit();
}
fn update() !dvui.App.Result {
    try APP.draw();

    // dvui.Examples.show_demo_window = true;
    // dvui.Examples.demo();

    return .ok;
}

const APP = struct {
    var gpa: std.mem.Allocator = std.heap.smp_allocator;
    var world_impl: gol.HashMapWorld = undefined;
    const world: gol.World = world_impl.world();
    var split_ratio: f32 = 0.3;

    pub fn init() !void {
        world_impl = .init(gpa);
    }

    pub fn deinit() void {
        world_impl.deinit();
    }

    pub fn draw() !void {
        var box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
        defer box.deinit();

        try OptionView.draw(gpa, world);

        try GridView.draw(gpa, world);
    }
};

const OptionView = struct {
    var running: bool = false;
    var update_rate: f32 = 5;
    pub fn draw(gpa: Allocator, world: gol.World) !void {
        _ = gpa;
        const box = dvui.box(@src(), .{ .dir = .vertical }, .{});
        defer box.deinit();
        {
            const box1 = dvui.box(@src(), .{ .dir = .horizontal }, .{});
            defer box1.deinit();

            if (dvui.button(@src(), if (running) "pause" else "start", .{}, .{})) {
                running = !running;
            }
            if (dvui.button(@src(), "clear", .{}, .{})) {
                running = false;
                world.clear();
            }

            dvui.label(@src(), "update rate:", .{}, .{});
            const tps_changed = dvui.sliderEntry(
                @src(),
                "tps: {d:0.1}",
                .{ .min = 0.1, .max = 100, .value = &update_rate },
                .{},
            );

            dvui.label(@src(), "living cells: {d}", .{world.count()}, .{});
            dvui.label(@src(), "iteration: {d}", .{world.iteration()}, .{});

            if (running and (dvui.timerDoneOrNone(box.data().id) or tps_changed)) {
                try world.tick();
                dvui.timer(box.data().id, @intFromFloat(1_000_000 / update_rate));
            }
        }
        {
            const box1 = dvui.box(@src(), .{ .dir = .horizontal }, .{});
            defer box1.deinit();

            dvui.label(@src(), "left-click to draw, right-click to drag the view, alt+wheel to zoom the view", .{}, .{});
        }
    }
};

const GridView = struct {
    var scale: f32 = 10;
    var origin: dvui.Point = .{};
    var scroll_info: dvui.ScrollInfo = .{ .vertical = .given, .horizontal = .given };
    var view_region: gol.Rect = undefined;
    var mouse_point: gol.Vec2 = .init(0, 0);

    pub fn draw(gpa: Allocator, world: gol.World) !void {
        _ = gpa;

        const scroll_area = dvui.scrollArea(
            @src(),
            .{ .scroll_info = &scroll_info, .vertical_bar = .hide, .horizontal_bar = .hide },
            .{ .expand = .both, .style = .content, .min_size_content = .{ .w = 1000, .h = 1000 } },
        );
        defer scroll_area.deinit();
        const scroll_container = &scroll_area.scroll.?;

        var scaler = dvui.scale(
            @src(),
            .{ .scale = &scale },
            .{ .rect = .{ .x = -origin.x, .y = -origin.y } },
        );
        defer scaler.deinit();

        const rect_scale_grid = scaler.screenRectScale(.{});
        const rect_scale_view = scroll_container.screenRectScale(.{});
        const evts = dvui.events();
        var zoom: f32 = 1;
        var zoomP: dvui.Point.Physical = .{};
        for (evts) |*e| {
            if (!scroll_container.matchEvent(e))
                continue;

            switch (e.evt) {
                .mouse => |me| {
                    const p = rect_scale_grid.pointFromPhysical(me.p);
                    mouse_point = gol.Vec2.init(@intFromFloat(p.x), @intFromFloat(p.y));

                    if (me.action == .press and me.button == .right) {
                        e.handle(@src(), scroll_container.data());
                        dvui.captureMouse(scroll_container.data(), e.num);
                        dvui.dragPreStart(me.p, .{});
                    } else if (me.action == .release and me.button == .right) {
                        if (dvui.captured(scroll_container.data().id)) {
                            e.handle(@src(), scroll_container.data());
                            dvui.captureMouse(null, e.num);
                            dvui.dragEnd();
                        }
                    } else if (me.action == .motion) {
                        if (dvui.captured(scroll_container.data().id)) {
                            if (dvui.dragging(me.p, null)) |dps| {
                                e.handle(@src(), scroll_container.data());
                                const rs = rect_scale_view;
                                scroll_info.viewport.x -= dps.x / rs.s;
                                scroll_info.viewport.y -= dps.y / rs.s;
                                dvui.refresh(null, @src(), scroll_container.data().id);
                            }
                        }
                    } else if (me.action == .wheel_y and me.mod.matchKeyBind(.{ .alt = true })) {
                        e.handle(@src(), scroll_container.data());
                        const base: f32 = 1.01;
                        const zs = @exp(@log(base) * me.action.wheel_y);
                        if (zs != 1.0) {
                            zoom *= zs;
                            zoomP = me.p;
                        }
                    } else if (me.action == .release and me.button == .left) {
                        if (world.queryCell(mouse_point)) {
                            _ = world.killCell(mouse_point);
                        } else {
                            _ = try world.addCell(mouse_point);
                        }
                    }
                },
                else => {},
            }
        }

        if (zoom != 1.0) {
            // scale around mouse point
            // first get data point of mouse
            const prevP = rect_scale_grid.pointFromPhysical(zoomP);

            // scale
            var pp = prevP.scale(1 / scale, dvui.Point);
            scale *= zoom;
            pp = pp.scale(scale, dvui.Point);

            // get where the mouse would be now
            const newP = rect_scale_grid.pointToPhysical(pp);

            // convert both to viewport
            const diff = rect_scale_view.pointFromPhysical(newP).diff(rect_scale_view.pointFromPhysical(zoomP));
            scroll_info.viewport.x += diff.x;
            scroll_info.viewport.y += diff.y;

            dvui.refresh(null, @src(), scroll_container.data().id);
        }

        if (!scroll_info.viewport.empty()) {
            // add current viewport plus padding
            const pad = 10;
            const bbox = scroll_info.viewport.outsetAll(pad);
            const scroll_container_id = scroll_area.scroll.?.data().id;

            // adjust top if needed
            if (bbox.y != 0) {
                const adj = -bbox.y;
                scroll_info.virtual_size.h += adj;
                scroll_info.viewport.y += adj;
                origin.y -= adj;
                dvui.refresh(null, @src(), scroll_container_id);
            }

            // adjust left if needed
            if (bbox.x != 0) {
                const adj = -bbox.x;
                scroll_info.virtual_size.w += adj;
                scroll_info.viewport.x += adj;
                origin.x -= adj;
                dvui.refresh(null, @src(), scroll_container_id);
            }

            // adjust bottom if needed
            if (bbox.h != scroll_info.virtual_size.h) {
                scroll_info.virtual_size.h = bbox.h;
                dvui.refresh(null, @src(), scroll_container_id);
            }

            // adjust right if needed
            if (bbox.w != scroll_info.virtual_size.w) {
                scroll_info.virtual_size.w = bbox.w;
                dvui.refresh(null, @src(), scroll_container_id);
            }
        }

        if (scale >= 10) try drawGrid(scaler);
        try drawCells(world, scaler);
        if (scale >= 10) try drawCursor(scaler);
    }

    fn calcViewRect() gol.Rect {
        const layout_rect = scroll_info.viewport;
        const padding = 3;
        const xmin: i32 = @intFromFloat(origin.x / scale);
        const xmax: i32 = @intFromFloat((origin.x + layout_rect.w) / scale);
        const ymin: i32 = @intFromFloat(origin.y / scale);
        const ymax: i32 = @intFromFloat((origin.y + layout_rect.h) / scale);
        return .init(xmin - padding, ymin - padding, xmax + padding, ymax + padding);
    }

    fn drawGrid(scaler: *dvui.ScaleWidget) !void {
        const rect_scale = scaler.screenRectScale(.{});
        const view_rect = calcViewRect();
        var x = view_rect.xmin;
        var y = view_rect.ymin;
        while (x < view_rect.xmax) : (x += 1) {
            dvui.Path.stroke(.{ .points = &.{
                rect_scale.pointToPhysical(.{ .x = @floatFromInt(x), .y = @floatFromInt(view_rect.ymin) }),
                rect_scale.pointToPhysical(.{ .x = @floatFromInt(x), .y = @floatFromInt(view_rect.ymax) }),
            } }, .{ .thickness = 1, .color = .gray });
        }
        while (y < view_rect.ymax) : (y += 1) {
            dvui.Path.stroke(.{ .points = &.{
                rect_scale.pointToPhysical(.{ .x = @floatFromInt(view_rect.xmin), .y = @floatFromInt(y) }),
                rect_scale.pointToPhysical(.{ .x = @floatFromInt(view_rect.xmax), .y = @floatFromInt(y) }),
            } }, .{ .thickness = 1, .color = .gray });
        }
    }

    fn drawCells(world: gol.World, scaler: *dvui.ScaleWidget) !void {
        const helper = struct {
            var rect_scale: dvui.RectScale = undefined;
            fn drawCell(pos: gol.Vec2) !void {
                dvui.Path.fillConvex(.{ .points = &.{
                    rect_scale.pointToPhysical(.{ .x = @floatFromInt(pos.x), .y = @floatFromInt(pos.y) }),
                    rect_scale.pointToPhysical(.{ .x = @floatFromInt(pos.x + 1), .y = @floatFromInt(pos.y) }),
                    rect_scale.pointToPhysical(.{ .x = @floatFromInt(pos.x + 1), .y = @floatFromInt(pos.y + 1) }),
                    rect_scale.pointToPhysical(.{ .x = @floatFromInt(pos.x), .y = @floatFromInt(pos.y + 1) }),
                } }, .{ .color = dvui.themeGet().color(.control, .text) });
            }
        };
        const rect_scale = scaler.screenRectScale(.{});
        helper.rect_scale = rect_scale;

        const view_rect = calcViewRect();
        try world.queryCells(view_rect, helper.drawCell);
    }

    fn drawCursor(scaler: *dvui.ScaleWidget) !void {
        const rect_scale = scaler.screenRectScale(.{});
        dvui.Path.stroke(.{ .points = &.{
            rect_scale.pointToPhysical(.{ .x = @floatFromInt(mouse_point.x), .y = @floatFromInt(mouse_point.y) }),
            rect_scale.pointToPhysical(.{ .x = @floatFromInt(mouse_point.x + 1), .y = @floatFromInt(mouse_point.y) }),
            rect_scale.pointToPhysical(.{ .x = @floatFromInt(mouse_point.x + 1), .y = @floatFromInt(mouse_point.y + 1) }),
            rect_scale.pointToPhysical(.{ .x = @floatFromInt(mouse_point.x), .y = @floatFromInt(mouse_point.y + 1) }),
            rect_scale.pointToPhysical(.{ .x = @floatFromInt(mouse_point.x), .y = @floatFromInt(mouse_point.y) }),
        } }, .{ .thickness = 2, .color = dvui.themeGet().highlight.border orelse .cyan });
    }
};
