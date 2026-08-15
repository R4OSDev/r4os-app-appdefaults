const r4os = @import("r4os");
const r4std = @import("r4std");

const AppApi = struct {
    sys: r4os.r4sys.Context,
    desk: r4os.r4desk.Context,
    draw: r4os.r4draw.Context,

    fn init(r4_app: *r4os.App) ?AppApi {
        return .{
            .sys = r4_app.system(),
            .desk = r4_app.desktop() orelse return null,
            .draw = r4_app.drawing() orelse return null,
        };
    }
};

const assoc_config_max_bytes: usize = 4096;
const bg: u32 = 0xD8D0C8;
const panel: u32 = 0xFFFFFF;
const panel_shadow: u32 = 0x808080;
const panel_light: u32 = 0xFFFFFF;
const header_bg: u32 = 0x0A246A;
const header_text: u32 = 0xFFFFFF;
const selected_bg: u32 = 0x0A246A;
const selected_text: u32 = 0xFFFFFF;
const text: u32 = 0x000000;
const muted: u32 = 0x606060;
const danger: u32 = 0xA00000;
const ok_green: u32 = 0x007020;
const row_h: i32 = 20;
const toolbar_h: i32 = 42;
const details_h: i32 = 118;
const status_h: i32 = 22;
const button_h: i32 = 22;
const button_gap: i32 = 6;

const palette = r4os.gui.Palette{
    .text = text,
    .disabled_text = muted,
    .face = bg,
    .face_light = panel_light,
    .face_shadow = panel_shadow,
    .client_bg = panel,
    .select_bg = selected_bg,
    .select_text = selected_text,
    .title_bg = header_bg,
    .title_text = header_text,
};

const Action = enum(u8) {
    change,
    add,
    remove,
    reset,
    ok,
    cancel,
};

const AddFocus = enum(u8) {
    ext,
    ok,
    cancel,
};

pub fn r4_app_main(r4_app: *r4os.App) i32 {
    if (!r4std.init(r4_app.startContext())) return r4os.abi.err_no_group;
    var ctx = AppApi.init(r4_app) orelse return r4os.abi.err_no_group;
    if (hasArg(ctx.sys.argsRaw(), "/SELFTEST")) return runSelfTest(&ctx.sys);
    var app = App{ .ctx = &ctx };
    return app.run();
}

const App = struct {
    ctx: *AppApi,
    w: i32 = 700,
    h: i32 = 420,
    should_exit: bool = false,
    config: r4std.app_assoc.Config = .{},
    original: [assoc_config_max_bytes]u8 = .{0} ** assoc_config_max_bytes,
    original_len: usize = 0,
    original_present: bool = false,
    selected: usize = 0,
    scroll: usize = 0,
    dirty: bool = false,
    status: [128]u8 = .{0} ** 128,
    mouse_down_action: ?Action = null,
    change_open: bool = false,
    change_selected: usize = 0,
    app_menu_items: [r4std.app_assoc.max_apps]r4os.gui.MenuItem = undefined,
    app_menu_labels: [r4std.app_assoc.max_apps][56]u8 = undefined,
    app_menu_count: usize = 0,
    add_open: bool = false,
    add_focus: AddFocus = .ext,
    add_mouse_down: ?AddFocus = null,
    add_ext: r4os.gui.TextField(r4std.app_assoc.ext_max + 2) = .{},

    fn run(self: *App) i32 {
        if (self.ctx.desk.programWindowId() >= 0) return self.runHosted();
        self.ctx.sys.println("APPDEF is a desktop GUI application.");
        self.ctx.sys.println("Please start from Desktop or through GUI launch.");
        return 0;
    }

    fn runHosted(self: *App) i32 {
        _ = self.ctx.desk.guiSetTitle("Default Apps");
        _ = self.ctx.desk.guiSetMinSize(660, 360);
        self.loadConfig();
        self.updateMetrics();
        self.render();

        while (!self.ctx.sys.programShouldClose() and !self.should_exit) {
            var event: r4os.abi.GuiEvent = .{};
            while (self.ctx.desk.guiPollEvent(&event) > 0) {
                const kind: r4os.abi.GuiEventKind = @enumFromInt(event.kind);
                switch (kind) {
                    .close => return 0,
                    .resize => {
                        self.updateMetrics();
                        self.render();
                    },
                    .mouse_down => self.handleMouseDown(event.x, event.y),
                    .mouse_up => self.handleMouseUp(event.x, event.y),
                    .key_down => self.handleKey(@intCast(event.key & 0xFF)),
                    else => {},
                }
            }
            self.ctx.sys.sleepTicks(3);
        }
        return 0;
    }

    fn loadConfig(self: *App) void {
        self.config = r4std.app_assoc.Config.initDefault();
        @memset(self.original[0..], 0);
        self.original_len = 0;
        self.original_present = false;
        const len = self.ctx.sys.fileRead(r4std.settings.paths.assoc, self.original[0..]);
        if (len > 0) {
            self.original_len = @intCast(len);
            self.original_present = true;
            if (self.config.loadFromBytes(self.original[0..self.original_len])) {
                self.setStatus("ASSOC.R4S geladen.");
            } else {
                self.setStatus("ASSOC.R4S unvollstaendig; Defaults aktiv.");
            }
        } else {
            self.setStatus("Defaults aktiv.");
        }
        self.selected = 0;
        self.scroll = 0;
        self.dirty = false;
        self.ensureSelection();
    }

    fn updateMetrics(self: *App) void {
        var info: r4os.abi.GuiWindowInfo = .{};
        _ = self.ctx.desk.guiWindowInfo(&info);
        const canvas = r4os.gui.Canvas.init(&self.ctx.draw, info);
        self.w = clampI32(canvas.w, 660, 1600);
        self.h = clampI32(canvas.h, 360, 1000);
    }

    fn render(self: *App) void {
        var paint = switch (r4os.app_gui.beginPaintForSize(&self.ctx.draw, self.w, self.h)) {
            .paint => |value| value,
            .failure => return,
        };
        defer paint.discard();
        const canvas = paint.canvas;
        var scratch: [192]u8 = .{0} ** 192;
        _ = canvas.clear(bg);
        self.drawToolbar(canvas, scratch[0..]);
        self.drawList(canvas, scratch[0..]);
        self.drawDetails(canvas, scratch[0..]);
        self.drawStatus(canvas, scratch[0..]);
        if (self.change_open) self.drawChangeMenu(canvas, scratch[0..]);
        if (self.add_open) self.drawAddDialog(canvas, scratch[0..]);
        _ = paint.present();
    }

    fn drawToolbar(self: *App, canvas: r4os.gui.Canvas, scratch: []u8) void {
        _ = canvas.rect(.{ .x = 0, .y = 0, .w = self.w, .h = toolbar_h }, bg);
        self.drawActionButton(canvas, scratch, .change, "Change...");
        self.drawActionButton(canvas, scratch, .add, "Add Type");
        self.drawActionButton(canvas, scratch, .remove, "Remove");
        self.drawActionButton(canvas, scratch, .reset, "Reset");
        self.drawActionButton(canvas, scratch, .ok, "OK");
        self.drawActionButton(canvas, scratch, .cancel, "Cancel");
    }

    fn drawActionButton(self: *App, canvas: r4os.gui.Canvas, scratch: []u8, action: Action, label: []const u8) void {
        _ = canvas.button(.{
            .rect = self.actionRect(action),
            .text = label,
            .state = if (self.actionDisabled(action)) .disabled else if (self.mouse_down_action != null and self.mouse_down_action.? == action) .pressed else .normal,
            .is_default = action == .ok,
            .is_cancel = action == .cancel,
        }, scratch);
    }

    fn drawList(self: *App, canvas: r4os.gui.Canvas, scratch: []u8) void {
        const rect = self.listRect();
        _ = canvas.rect(rect, panel_shadow);
        _ = canvas.rect(.{ .x = rect.x + 1, .y = rect.y + 1, .w = rect.w - 2, .h = rect.h - 2 }, panel);
        const header = self.headerRect();
        _ = canvas.rect(header, header_bg);
        _ = canvas.text(header.x + 6, header.y + 5, "Ext", header_text, header_bg);
        _ = canvas.text(header.x + 82, header.y + 5, "Description", header_text, header_bg);
        _ = canvas.text(header.x + 260, header.y + 5, "Default App", header_text, header_bg);
        _ = canvas.text(header.x + 438, header.y + 5, "Path", header_text, header_bg);

        var row: usize = 0;
        const rows = self.visibleRows();
        while (row < rows and self.scroll + row < self.config.extension_count) : (row += 1) {
            self.drawExtRow(canvas, scratch, self.scroll + row, row);
        }
    }

    fn drawExtRow(self: *App, canvas: r4os.gui.Canvas, scratch: []u8, index: usize, row: usize) void {
        const ext = &self.config.extensions[index];
        const rect = self.rowRect(row);
        const selected_row = index == self.selected;
        const bg_color = if (selected_row) selected_bg else panel;
        const fg_color = if (selected_row) selected_text else text;
        _ = canvas.rect(rect, bg_color);
        _ = canvas.textClipped(rect.x + 6, rect.y + 4, 68, scratch, ext.extText(), fg_color, bg_color);
        _ = canvas.textClipped(rect.x + 82, rect.y + 4, 170, scratch, ext.typeNameText(), fg_color, bg_color);
        _ = canvas.textClipped(rect.x + 260, rect.y + 4, 170, scratch, self.appTitleForId(ext.appIdText()), fg_color, bg_color);
        _ = canvas.textClipped(rect.x + 438, rect.y + 4, rect.w - 444, scratch, self.appPathForId(ext.appIdText()), fg_color, bg_color);
    }

    fn drawDetails(self: *App, canvas: r4os.gui.Canvas, scratch: []u8) void {
        const rect = self.detailsRect();
        _ = canvas.groupBox(.{ .rect = rect, .title = "Details" }, scratch);
        if (self.config.extension_count == 0) {
            _ = canvas.text(rect.x + 12, rect.y + 28, "No file types registered.", muted, bg);
            return;
        }
        const ext = &self.config.extensions[self.selected];
        const app = self.config.appById(ext.appIdText());
        var line: [180]u8 = .{0} ** 180;

        setZ(line[0..], "File type: .");
        appendZ(line[0..], ext.extText());
        appendZ(line[0..], "   Description: ");
        appendZ(line[0..], ext.typeNameText());
        _ = canvas.textClipped(rect.x + 12, rect.y + 24, rect.w - 24, scratch, spanZ(line[0..]), text, bg);

        setZ(line[0..], "App: ");
        if (app) |entry| {
            appendZ(line[0..], entry.titleText());
            appendZ(line[0..], " (");
            appendZ(line[0..], entry.idText());
            appendZ(line[0..], ")");
        } else {
            appendZ(line[0..], ext.appIdText());
            appendZ(line[0..], " missing");
        }
        _ = canvas.textClipped(rect.x + 12, rect.y + 44, rect.w - 24, scratch, spanZ(line[0..]), if (app == null) danger else text, bg);

        setZ(line[0..], "Path: ");
        appendZ(line[0..], if (app) |entry| entry.pathText() else "");
        _ = canvas.textClipped(rect.x + 12, rect.y + 64, rect.w - 24, scratch, spanZ(line[0..]), text, bg);

        setZ(line[0..], "Policy: ");
        appendZ(line[0..], if (app) |entry| policyName(entry.policy) else "-");
        appendZ(line[0..], "   Args: ");
        appendZ(line[0..], if (app) |entry| entry.argsText() else "-");
        appendZ(line[0..], "   Prefix: ");
        appendZ(line[0..], ext.prefixText());
        _ = canvas.textClipped(rect.x + 12, rect.y + 84, rect.w - 24, scratch, spanZ(line[0..]), text, bg);
    }

    fn drawStatus(self: *App, canvas: r4os.gui.Canvas, scratch: []u8) void {
        const rect = self.statusRect();
        _ = canvas.rect(rect, panel_shadow);
        _ = canvas.rect(.{ .x = rect.x + 1, .y = rect.y + 1, .w = rect.w - 2, .h = rect.h - 2 }, bg);
        _ = canvas.textClipped(rect.x + 6, rect.y + 5, rect.w - 12, scratch, spanZ(self.status[0..]), if (self.dirty) ok_green else text, bg);
    }

    fn drawChangeMenu(self: *App, canvas: r4os.gui.Canvas, scratch: []u8) void {
        self.buildAppMenu();
        const menu = r4os.gui.Menu{
            .rect = self.changeMenuRect(),
            .items = self.app_menu_items[0..self.app_menu_count],
            .selected_index = self.change_selected,
            .row_h = row_h,
            .palette = palette,
        };
        _ = menu.draw(canvas, scratch);
    }

    fn drawAddDialog(self: *App, canvas: r4os.gui.Canvas, scratch: []u8) void {
        self.add_ext.focused = self.add_focus == .ext;
        const rect = self.addDialogRect();
        _ = canvas.rect(.{ .x = rect.x + 3, .y = rect.y + 3, .w = rect.w, .h = rect.h }, panel_shadow);
        _ = canvas.rect(rect, bg);
        _ = canvas.rect(.{ .x = rect.x, .y = rect.y, .w = rect.w, .h = 20 }, header_bg);
        _ = canvas.text(rect.x + 8, rect.y + 5, "Add file type", header_text, header_bg);
        _ = canvas.label(.{ .rect = .{ .x = rect.x + 18, .y = rect.y + 42, .w = 92, .h = 16 }, .text = "Extension:", .alignment = .right, .fg = text, .bg = bg }, scratch);
        _ = self.add_ext.draw(canvas, self.addFieldRect(), scratch);
        self.drawAddButton(canvas, scratch, .ok, "OK");
        self.drawAddButton(canvas, scratch, .cancel, "Cancel");
    }

    fn drawAddButton(self: *App, canvas: r4os.gui.Canvas, scratch: []u8, focus: AddFocus, label: []const u8) void {
        _ = canvas.button(.{
            .rect = self.addButtonRect(focus),
            .text = label,
            .state = if (self.add_mouse_down != null and self.add_mouse_down.? == focus) .pressed else .normal,
            .focused = self.add_focus == focus,
            .is_default = focus == .ok,
            .is_cancel = focus == .cancel,
        }, scratch);
    }

    fn handleMouseDown(self: *App, x: i32, y: i32) void {
        self.mouse_down_action = null;
        self.add_mouse_down = null;
        if (self.add_open) {
            if (self.addFieldRect().contains(x, y)) {
                self.add_focus = .ext;
                self.render();
                return;
            }
            if (self.addButtonRect(.ok).contains(x, y)) return self.pressAdd(.ok);
            if (self.addButtonRect(.cancel).contains(x, y)) return self.pressAdd(.cancel);
            self.render();
            return;
        }
        if (self.change_open) {
            const menu = self.changeMenu();
            if (menu.indexAt(x, y)) |index| {
                self.chooseApp(index);
                self.change_open = false;
                self.render();
                return;
            }
            if (!self.changeMenuRect().contains(x, y) and !self.actionRect(.change).contains(x, y)) {
                self.change_open = false;
                self.render();
                return;
            }
        }
        if (self.selectRowAt(x, y)) return;
        if (self.actionAt(x, y)) |action| {
            if (!self.actionDisabled(action)) {
                self.mouse_down_action = action;
                self.render();
            }
        }
    }

    fn handleMouseUp(self: *App, x: i32, y: i32) void {
        if (self.add_open) {
            if (self.add_mouse_down) |focus| {
                const hit = self.addButtonRect(focus).contains(x, y);
                self.add_mouse_down = null;
                if (hit) self.activateAdd(focus);
                self.render();
            }
            return;
        }
        if (self.mouse_down_action) |action| {
            const hit = self.actionRect(action).contains(x, y);
            self.mouse_down_action = null;
            if (hit and !self.actionDisabled(action)) self.activate(action);
            self.render();
        }
    }

    fn handleKey(self: *App, key: u8) void {
        if (self.add_open) return self.handleAddKey(key);
        if (self.change_open) return self.handleChangeKey(key);
        switch (key) {
            r4os.gui.Key.escape => self.should_exit = true,
            r4os.gui.Key.up, r4os.gui.Key.down, r4os.gui.Key.home, r4os.gui.Key.end, r4os.gui.Key.page_up, r4os.gui.Key.page_down => {
                self.moveSelection(key);
                self.render();
            },
            'c', 'C' => {
                if (!self.actionDisabled(.change)) self.openChangeMenu();
                self.render();
            },
            'a', 'A' => {
                self.openAddDialog();
                self.render();
            },
            r4os.gui.Key.delete => {
                if (!self.actionDisabled(.remove)) self.removeSelected();
                self.render();
            },
            r4os.gui.Key.enter => {
                self.saveAndMaybeClose(true);
                self.render();
            },
            else => {},
        }
    }

    fn handleChangeKey(self: *App, key: u8) void {
        switch (key) {
            r4os.gui.Key.escape => self.change_open = false,
            r4os.gui.Key.up, r4os.gui.Key.down, r4os.gui.Key.home, r4os.gui.Key.end => {
                const step = r4os.gui.selectionStep(self.app_menu_count, self.change_selected, key);
                if (step.action == .selection_changed) self.change_selected = step.index;
            },
            r4os.gui.Key.enter => {
                self.chooseApp(self.change_selected);
                self.change_open = false;
            },
            else => {},
        }
        self.render();
    }

    fn handleAddKey(self: *App, key: u8) void {
        if (key == r4os.gui.Key.escape) {
            self.add_open = false;
            self.setStatus("Hinzufuegen abgebrochen.");
            self.render();
            return;
        }
        if (key == r4os.gui.Key.tab or key == r4os.gui.Key.shift_tab) {
            self.nextAddFocus(key == r4os.gui.Key.shift_tab);
            self.render();
            return;
        }
        if (key == r4os.gui.Key.enter) {
            if (self.add_focus == .ext) self.activateAdd(.ok) else self.activateAdd(self.add_focus);
            self.render();
            return;
        }
        if (self.add_focus == .ext and self.add_ext.handleClipboardKey(&self.ctx.desk, key)) self.render();
    }

    fn activate(self: *App, action: Action) void {
        switch (action) {
            .change => self.openChangeMenu(),
            .add => self.openAddDialog(),
            .remove => self.removeSelected(),
            .reset => self.resetDefaults(),
            .ok => self.saveAndMaybeClose(true),
            .cancel => {
                self.setStatus("Changes discarded.");
                self.should_exit = true;
            },
        }
    }

    fn openChangeMenu(self: *App) void {
        self.buildAppMenu();
        if (self.app_menu_count == 0 or self.config.extension_count == 0) {
            self.setStatus("No apps registered.");
            self.change_open = false;
            return;
        }
        self.change_selected = self.defaultAppMenuIndex();
        self.change_open = true;
    }

    fn chooseApp(self: *App, menu_index: usize) void {
        const app = appByUsableIndex(&self.config, menu_index) orelse {
            self.setStatus("Invalid app selection.");
            return;
        };
        if (self.selected >= self.config.extension_count) return;
        if (!copyNormalizedId(self.config.extensions[self.selected].app_id[0..], app.idText())) {
            self.setStatus("Invalid app ID.");
            return;
        }
        self.dirty = true;
        self.setStatus("Zuordnung geaendert.");
    }

    fn openAddDialog(self: *App) void {
        self.add_ext.clear();
        self.add_ext.set("DAT");
        self.add_ext.selectAll();
        self.add_focus = .ext;
        self.add_open = true;
    }

    fn activateAdd(self: *App, focus: AddFocus) void {
        if (focus == .cancel) {
            self.add_open = false;
            self.setStatus("Hinzufuegen abgebrochen.");
            return;
        }
        if (self.addOrSelectExtension(self.add_ext.value())) {
            self.add_open = false;
        }
    }

    fn removeSelected(self: *App) void {
        if (self.config.extension_count == 0 or self.selected >= self.config.extension_count) return;
        var index = self.selected;
        while (index + 1 < self.config.extension_count) : (index += 1) {
            self.config.extensions[index] = self.config.extensions[index + 1];
        }
        self.config.extension_count -= 1;
        if (self.config.extension_count < self.config.extensions.len) self.config.extensions[self.config.extension_count] = .{};
        self.ensureSelection();
        self.dirty = true;
        self.setStatus("File type removed.");
    }

    fn resetDefaults(self: *App) void {
        self.config.loadDefaults();
        self.selected = 0;
        self.scroll = 0;
        self.dirty = true;
        self.setStatus("Defaults restored. Not saved yet.");
    }

    fn saveAndMaybeClose(self: *App, close_on_success: bool) void {
        var validation: [96]u8 = .{0} ** 96;
        if (!validateConfig(&self.config, validation[0..])) {
            self.setStatus(spanZ(validation[0..]));
            return;
        }
        var buffer: [assoc_config_max_bytes]u8 = .{0} ** assoc_config_max_bytes;
        const bytes = self.config.writeTo(buffer[0..]);
        if (bytes.len == 0) {
            self.setStatus("Save failed: config too large.");
            return;
        }
        r4std.settings.ensureSystemDirs(&self.ctx.sys);
        if (!self.writeAssocWithRollback(bytes)) {
            self.setStatus("Save failed; rollback completed.");
            return;
        }
        self.original_present = true;
        self.original_len = bytes.len;
        @memset(self.original[0..], 0);
        @memcpy(self.original[0..bytes.len], bytes);
        self.dirty = false;
        self.setStatus("ASSOC.R4S saved.");
        if (close_on_success) self.should_exit = true;
    }

    fn writeAssocWithRollback(self: *App, bytes: []const u8) bool {
        if (self.ctx.sys.fileWrite(r4std.settings.paths.assoc, bytes) <= 0) return false;
        var verify: [assoc_config_max_bytes]u8 = .{0} ** assoc_config_max_bytes;
        const len = self.ctx.sys.fileRead(r4std.settings.paths.assoc, verify[0..]);
        if (len > 0 and @as(usize, @intCast(len)) == bytes.len and sameBytes(verify[0..@intCast(len)], bytes)) return true;
        self.rollbackAssoc();
        return false;
    }

    fn rollbackAssoc(self: *App) void {
        if (self.original_present) {
            _ = self.ctx.sys.fileWrite(r4std.settings.paths.assoc, self.original[0..self.original_len]);
        } else {
            _ = self.ctx.sys.fileDelete(r4std.settings.paths.assoc);
        }
    }

    fn addOrSelectExtension(self: *App, raw_ext: []const u8) bool {
        var normalized: [r4std.app_assoc.ext_max + 1]u8 = .{0} ** (r4std.app_assoc.ext_max + 1);
        if (!copyNormalizedExt(normalized[0..], raw_ext)) {
            self.setStatus("Invalid extension.");
            return false;
        }
        const ext_name = spanZ(normalized[0..]);
        if (indexOfExtension(&self.config, ext_name)) |existing| {
            self.selected = existing;
            self.ensureSelection();
            self.setStatus("File type already exists.");
            return true;
        }
        if (self.config.extension_count >= self.config.extensions.len) {
            self.setStatus("Maximum number of file types reached.");
            return false;
        }
        const app = firstUsableApp(&self.config) orelse {
            self.setStatus("No valid default app registered.");
            return false;
        };
        const index = self.config.extension_count;
        self.config.extension_count += 1;
        self.config.extensions[index] = .{ .valid = true, .rank = 6 };
        setZ(self.config.extensions[index].ext[0..], ext_name);
        setZ(self.config.extensions[index].app_id[0..], app.idText());
        setTypeName(self.config.extensions[index].type_name[0..], ext_name);
        setZ(self.config.extensions[index].short_name[0..], ext_name);
        setPrefix(self.config.extensions[index].prefix[0..], ext_name);
        self.selected = index;
        self.ensureSelection();
        self.dirty = true;
        self.setStatus("File type added.");
        return true;
    }

    fn selectRowAt(self: *App, x: i32, y: i32) bool {
        if (!self.listRect().contains(x, y)) return false;
        if (y < self.firstRowY()) return false;
        const visible: usize = @intCast(@divTrunc(y - self.firstRowY(), row_h));
        const index = self.scroll + visible;
        if (visible >= self.visibleRows() or index >= self.config.extension_count) return false;
        self.selected = index;
        self.ensureSelection();
        self.render();
        return true;
    }

    fn moveSelection(self: *App, key: u8) void {
        if (self.config.extension_count == 0) return;
        const step = r4os.gui.selectionStepPaged(self.config.extension_count, self.visibleRows(), self.selected, key);
        if (step.action == .selection_changed) {
            self.selected = step.index;
            self.ensureSelection();
        }
    }

    fn ensureSelection(self: *App) void {
        if (self.config.extension_count == 0) {
            self.selected = 0;
            self.scroll = 0;
            return;
        }
        if (self.selected >= self.config.extension_count) self.selected = self.config.extension_count - 1;
        const visible = self.visibleRows();
        if (visible == 0) {
            self.scroll = 0;
            return;
        }
        if (self.selected < self.scroll) self.scroll = self.selected;
        if (self.selected >= self.scroll + visible) self.scroll = self.selected + 1 - visible;
    }

    fn buildAppMenu(self: *App) void {
        self.app_menu_count = 0;
        var app_index: usize = 0;
        while (app_index < self.config.app_count and self.app_menu_count < self.app_menu_items.len) : (app_index += 1) {
            const app = &self.config.apps[app_index];
            if (!usableApp(app)) continue;
            const label = self.app_menu_labels[self.app_menu_count][0..];
            setZ(label, app.titleText());
            appendZ(label, " (");
            appendZ(label, app.idText());
            appendZ(label, ")");
            self.app_menu_items[self.app_menu_count] = .{ .text = spanZ(label), .id = @intCast(self.app_menu_count) };
            self.app_menu_count += 1;
        }
    }

    fn defaultAppMenuIndex(self: *const App) usize {
        if (self.selected >= self.config.extension_count) return 0;
        const app_id = self.config.extensions[self.selected].appIdText();
        var usable_index: usize = 0;
        var app_index: usize = 0;
        while (app_index < self.config.app_count) : (app_index += 1) {
            const app = &self.config.apps[app_index];
            if (!usableApp(app)) continue;
            if (equalsIgnoreCase(app.idText(), app_id)) return usable_index;
            usable_index += 1;
        }
        return 0;
    }

    fn changeMenu(self: *App) r4os.gui.Menu {
        self.buildAppMenu();
        return .{
            .rect = self.changeMenuRect(),
            .items = self.app_menu_items[0..self.app_menu_count],
            .selected_index = self.change_selected,
            .row_h = row_h,
            .palette = palette,
        };
    }

    fn actionDisabled(self: *const App, action: Action) bool {
        return switch (action) {
            .change, .remove => self.config.extension_count == 0,
            else => false,
        };
    }

    fn actionAt(self: *const App, x: i32, y: i32) ?Action {
        inline for (action_order) |action| {
            if (self.actionRect(action).contains(x, y)) return action;
        }
        return null;
    }

    fn pressAdd(self: *App, focus: AddFocus) void {
        self.add_focus = focus;
        self.add_mouse_down = focus;
        self.render();
    }

    fn nextAddFocus(self: *App, previous: bool) void {
        const raw: u8 = @intFromEnum(self.add_focus);
        const next = if (previous)
            if (raw == 0) @as(u8, 2) else raw - 1
        else if (raw >= 2)
            @as(u8, 0)
        else
            raw + 1;
        self.add_focus = @enumFromInt(next);
    }

    fn appTitleForId(self: *const App, app_id: []const u8) []const u8 {
        if (self.config.appById(app_id)) |app| return app.titleText();
        return app_id;
    }

    fn appPathForId(self: *const App, app_id: []const u8) []const u8 {
        if (self.config.appById(app_id)) |app| return app.pathText();
        return "";
    }

    fn setStatus(self: *App, value: []const u8) void {
        setZ(self.status[0..], value);
    }

    fn actionRect(self: *const App, action: Action) r4os.gui.Rect {
        return switch (action) {
            .change => .{ .x = 8, .y = 10, .w = 86, .h = button_h },
            .add => .{ .x = 8 + 86 + button_gap, .y = 10, .w = 78, .h = button_h },
            .remove => .{ .x = 8 + 86 + button_gap + 78 + button_gap, .y = 10, .w = 72, .h = button_h },
            .reset => .{ .x = 8 + 86 + button_gap + 78 + button_gap + 72 + button_gap, .y = 10, .w = 64, .h = button_h },
            .ok => .{ .x = self.w - 166, .y = 10, .w = 72, .h = button_h },
            .cancel => .{ .x = self.w - 86, .y = 10, .w = 78, .h = button_h },
        };
    }

    fn listRect(self: *const App) r4os.gui.Rect {
        return .{ .x = 8, .y = toolbar_h, .w = self.w - 16, .h = self.h - toolbar_h - details_h - status_h - 12 };
    }

    fn headerRect(self: *const App) r4os.gui.Rect {
        const rect = self.listRect();
        return .{ .x = rect.x + 1, .y = rect.y + 1, .w = rect.w - 2, .h = row_h };
    }

    fn firstRowY(self: *const App) i32 {
        return self.headerRect().y + row_h;
    }

    fn rowRect(self: *const App, visible_row: usize) r4os.gui.Rect {
        const rect = self.listRect();
        return .{ .x = rect.x + 1, .y = self.firstRowY() + @as(i32, @intCast(visible_row)) * row_h, .w = rect.w - 2, .h = row_h };
    }

    fn visibleRows(self: *const App) usize {
        const rows = @divTrunc(self.listRect().h - row_h - 2, row_h);
        return if (rows <= 0) 0 else @intCast(rows);
    }

    fn detailsRect(self: *const App) r4os.gui.Rect {
        return .{ .x = 8, .y = self.h - details_h - status_h - 6, .w = self.w - 16, .h = details_h };
    }

    fn statusRect(self: *const App) r4os.gui.Rect {
        return .{ .x = 8, .y = self.h - status_h - 4, .w = self.w - 16, .h = status_h };
    }

    fn changeMenuRect(self: *const App) r4os.gui.Rect {
        const count: i32 = @intCast(@max(@as(usize, 1), self.app_menu_count));
        return .{ .x = 8, .y = 34, .w = 230, .h = count * row_h + 4 };
    }

    fn addDialogRect(self: *const App) r4os.gui.Rect {
        const w: i32 = 380;
        const h: i32 = 132;
        return .{ .x = @divTrunc(self.w - w, 2), .y = @divTrunc(self.h - h, 2), .w = w, .h = h };
    }

    fn addFieldRect(self: *const App) r4os.gui.Rect {
        const rect = self.addDialogRect();
        return .{ .x = rect.x + 118, .y = rect.y + 38, .w = rect.w - 138, .h = 20 };
    }

    fn addButtonRect(self: *const App, focus: AddFocus) r4os.gui.Rect {
        const rect = self.addDialogRect();
        return switch (focus) {
            .ok => .{ .x = rect.x + rect.w - 168, .y = rect.y + rect.h - 34, .w = 72, .h = 22 },
            .cancel => .{ .x = rect.x + rect.w - 88, .y = rect.y + rect.h - 34, .w = 78, .h = 22 },
            else => .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        };
    }
};

const action_order = [_]Action{ .change, .add, .remove, .reset, .ok, .cancel };

fn runSelfTest(ctx: *const r4os.r4sys.Context) i32 {
    ctx.println("APPDEF selftest");
    var original: [assoc_config_max_bytes]u8 = .{0} ** assoc_config_max_bytes;
    const original_read = ctx.fileRead(r4std.settings.paths.assoc, original[0..]);
    const original_present = original_read > 0;
    const original_len: usize = if (original_read > 0) @intCast(original_read) else 0;
    defer restoreAssoc(ctx, original_present, original_len, original[0..]);

    var config = r4std.app_assoc.Config.initDefault();
    if (original_present) _ = config.loadFromBytes(original[0..original_len]);
    if (usableAppCount(&config) < 3) return appdefFail(ctx, "apps");
    const txt = indexOfExtension(&config, "TXT") orelse return appdefFail(ctx, "txt");
    if (!setExtensionApp(&config, txt, "PAINT")) return appdefFail(ctx, "change");
    if (!equalsIgnoreCase(config.extensions[txt].appIdText(), "PAINT")) return appdefFail(ctx, "change-result");

    if (!addExtensionToConfig(&config, "DAT")) return appdefFail(ctx, "add");
    const dat = indexOfExtension(&config, "DAT") orelse return appdefFail(ctx, "add-result");
    removeExtensionFromConfig(&config, dat);
    if (indexOfExtension(&config, "DAT") != null) return appdefFail(ctx, "remove");

    config.loadDefaults();
    const reset_txt = indexOfExtension(&config, "TXT") orelse return appdefFail(ctx, "reset-txt");
    if (!equalsIgnoreCase(config.extensions[reset_txt].appIdText(), "NOTEPAD")) return appdefFail(ctx, "reset");

    var before: [assoc_config_max_bytes]u8 = .{0} ** assoc_config_max_bytes;
    const before_len = ctx.fileRead(r4std.settings.paths.assoc, before[0..]);
    var cancel_config = config;
    _ = setExtensionApp(&cancel_config, reset_txt, "PAINT");
    var after_cancel: [assoc_config_max_bytes]u8 = .{0} ** assoc_config_max_bytes;
    const after_len = ctx.fileRead(r4std.settings.paths.assoc, after_cancel[0..]);
    if (before_len != after_len) return appdefFail(ctx, "cancel-length");
    if (before_len > 0 and !sameBytes(before[0..@intCast(before_len)], after_cancel[0..@intCast(after_len)])) return appdefFail(ctx, "cancel-write");

    if (!addExtensionToConfig(&config, "DAT")) return appdefFail(ctx, "save-add");
    var status: [96]u8 = .{0} ** 96;
    if (!saveConfigToPath(ctx, r4std.settings.paths.assoc, &config, status[0..])) return appdefFail(ctx, "save");
    var saved: [assoc_config_max_bytes]u8 = .{0} ** assoc_config_max_bytes;
    const saved_len = ctx.fileRead(r4std.settings.paths.assoc, saved[0..]);
    if (saved_len <= 0 or !contains(saved[0..@intCast(saved_len)], "EXT.DAT.APP=NOTEPAD")) return appdefFail(ctx, "save-verify");

    var invalid = config;
    const invalid_txt = indexOfExtension(&invalid, "TXT") orelse return appdefFail(ctx, "invalid-txt");
    setZ(invalid.extensions[invalid_txt].app_id[0..], "MISSING");
    @memset(status[0..], 0);
    if (validateConfig(&invalid, status[0..])) return appdefFail(ctx, "invalid-accepted");
    if (spanZ(status[0..]).len == 0) return appdefFail(ctx, "invalid-status");

    @memset(status[0..], 0);
    if (saveConfigToPath(ctx, "Z:\\NO\\ASSOC.R4S", &config, status[0..])) return appdefFail(ctx, "writefail");
    if (spanZ(status[0..]).len == 0) return appdefFail(ctx, "writefail-status");

    ctx.println("APPDEF selftest: OK");
    return 0;
}

fn restoreAssoc(ctx: *const r4os.r4sys.Context, present: bool, len: usize, bytes: []const u8) void {
    if (present) {
        _ = ctx.fileWrite(r4std.settings.paths.assoc, bytes[0..len]);
    } else {
        _ = ctx.fileDelete(r4std.settings.paths.assoc);
    }
}

fn saveConfigToPath(ctx: *const r4os.r4sys.Context, path: [*:0]const u8, config: *const r4std.app_assoc.Config, status: []u8) bool {
    if (!validateConfig(config, status)) return false;
    var out: [assoc_config_max_bytes]u8 = .{0} ** assoc_config_max_bytes;
    const bytes = config.writeTo(out[0..]);
    if (bytes.len == 0) {
        setZ(status, "Config too large.");
        return false;
    }
    r4std.settings.ensureSystemDirs(ctx);
    if (ctx.fileWrite(path, bytes) <= 0) {
        setZ(status, "Write error.");
        return false;
    }
    setZ(status, "Saved.");
    return true;
}

fn validateConfig(config: *const r4std.app_assoc.Config, status: []u8) bool {
    if (usableAppCount(config) == 0) {
        setZ(status, "No valid app registered.");
        return false;
    }
    var index: usize = 0;
    while (index < config.extension_count) : (index += 1) {
        const ext = &config.extensions[index];
        if (!ext.valid or ext.extText().len == 0) {
            setZ(status, "Invalid file type.");
            return false;
        }
        if (config.appById(ext.appIdText()) == null) {
            setZ(status, "Invalid target for file type.");
            return false;
        }
    }
    setZ(status, "OK");
    return true;
}

fn addExtensionToConfig(config: *r4std.app_assoc.Config, ext_name: []const u8) bool {
    var normalized: [r4std.app_assoc.ext_max + 1]u8 = .{0} ** (r4std.app_assoc.ext_max + 1);
    if (!copyNormalizedExt(normalized[0..], ext_name)) return false;
    const text_value = spanZ(normalized[0..]);
    if (indexOfExtension(config, text_value) != null) return false;
    if (config.extension_count >= config.extensions.len) return false;
    const app = firstUsableApp(config) orelse return false;
    const index = config.extension_count;
    config.extension_count += 1;
    config.extensions[index] = .{ .valid = true, .rank = 6 };
    setZ(config.extensions[index].ext[0..], text_value);
    setZ(config.extensions[index].app_id[0..], app.idText());
    setTypeName(config.extensions[index].type_name[0..], text_value);
    setZ(config.extensions[index].short_name[0..], text_value);
    setPrefix(config.extensions[index].prefix[0..], text_value);
    return true;
}

fn removeExtensionFromConfig(config: *r4std.app_assoc.Config, index: usize) void {
    if (index >= config.extension_count) return;
    var pos = index;
    while (pos + 1 < config.extension_count) : (pos += 1) {
        config.extensions[pos] = config.extensions[pos + 1];
    }
    config.extension_count -= 1;
    if (config.extension_count < config.extensions.len) config.extensions[config.extension_count] = .{};
}

fn setExtensionApp(config: *r4std.app_assoc.Config, index: usize, app_id: []const u8) bool {
    if (index >= config.extension_count) return false;
    if (config.appById(app_id) == null) return false;
    return copyNormalizedId(config.extensions[index].app_id[0..], app_id);
}

fn indexOfExtension(config: *const r4std.app_assoc.Config, ext_name: []const u8) ?usize {
    var normalized: [r4std.app_assoc.ext_max + 1]u8 = .{0} ** (r4std.app_assoc.ext_max + 1);
    if (!copyNormalizedExt(normalized[0..], ext_name)) return null;
    var index: usize = 0;
    while (index < config.extension_count) : (index += 1) {
        if (equalsZ(config.extensions[index].ext[0..], normalized[0..])) return index;
    }
    return null;
}

fn firstUsableApp(config: *const r4std.app_assoc.Config) ?*const r4std.app_assoc.AppEntry {
    var index: usize = 0;
    while (index < config.app_count) : (index += 1) {
        const app = &config.apps[index];
        if (usableApp(app)) return app;
    }
    return null;
}

fn appByUsableIndex(config: *const r4std.app_assoc.Config, wanted: usize) ?*const r4std.app_assoc.AppEntry {
    var usable_index: usize = 0;
    var index: usize = 0;
    while (index < config.app_count) : (index += 1) {
        const app = &config.apps[index];
        if (!usableApp(app)) continue;
        if (usable_index == wanted) return app;
        usable_index += 1;
    }
    return null;
}

fn usableAppCount(config: *const r4std.app_assoc.Config) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < config.app_count) : (index += 1) {
        if (usableApp(&config.apps[index])) count += 1;
    }
    return count;
}

fn usableApp(app: *const r4std.app_assoc.AppEntry) bool {
    return app.valid and app.idText().len != 0 and endsWithIgnoreCase(app.pathText(), ".R4X") and contains(app.argsText(), "%1");
}

fn setTypeName(out: []u8, ext_name: []const u8) void {
    setZ(out, ext_name);
    appendZ(out, " file");
}

fn setPrefix(out: []u8, ext_name: []const u8) void {
    if (out.len == 0) return;
    @memset(out, 0);
    var pos: usize = 0;
    _ = appendByte(out, &pos, '[');
    var index: usize = 0;
    while (index < ext_name.len and index < 5) : (index += 1) {
        _ = appendByte(out, &pos, ext_name[index]);
    }
    _ = appendByte(out, &pos, ']');
    out[pos] = 0;
}

fn policyName(policy: r4os.abi.LaunchPolicy) []const u8 {
    return switch (policy) {
        .auto => "auto",
        .console => "console",
        .gui => "gui",
    };
}

fn clampI32(value: i32, min: i32, max: i32) i32 {
    if (value < min) return min;
    if (value > max) return max;
    return value;
}

fn copyNormalizedId(out: []u8, value: []const u8) bool {
    return copyNormalizedSymbol(out, trim(value), r4std.app_assoc.app_id_max, false);
}

fn copyNormalizedExt(out: []u8, value: []const u8) bool {
    var text_value = trim(value);
    if (text_value.len > 0 and text_value[0] == '.') text_value = text_value[1..];
    return copyNormalizedSymbol(out, text_value, r4std.app_assoc.ext_max, true);
}

fn copyNormalizedSymbol(out: []u8, value: []const u8, max_len: usize, extension: bool) bool {
    const text_value = trim(value);
    if (out.len == 0 or text_value.len == 0 or text_value.len > max_len or text_value.len + 1 > out.len) return false;
    @memset(out, 0);
    var index: usize = 0;
    while (index < text_value.len) : (index += 1) {
        const upper = asciiUpper(text_value[index]);
        if (extension) {
            if (!isAsciiAlnum(upper)) return false;
        } else if (!isAsciiAlnum(upper) and upper != '_' and upper != '-') {
            return false;
        }
        out[index] = upper;
    }
    out[text_value.len] = 0;
    return true;
}

fn setZ(out: []u8, value: []const u8) void {
    if (out.len == 0) return;
    @memset(out, 0);
    const count = @min(value.len, out.len - 1);
    if (count > 0) @memcpy(out[0..count], value[0..count]);
    out[count] = 0;
}

fn appendZ(out: []u8, value: []const u8) void {
    var pos = spanZ(out).len;
    _ = appendSlice(out, &pos, value);
    if (pos < out.len) out[pos] = 0;
}

fn appendSlice(out: []u8, pos: *usize, value: []const u8) bool {
    if (out.len == 0 or pos.* > out.len - 1 or value.len > out.len - 1 - pos.*) return false;
    if (value.len > 0) @memcpy(out[pos.* .. pos.* + value.len], value);
    pos.* += value.len;
    return true;
}

fn appendByte(out: []u8, pos: *usize, value: u8) bool {
    if (out.len == 0 or pos.* >= out.len - 1) return false;
    out[pos.*] = value;
    pos.* += 1;
    return true;
}

fn spanZ(buf: []const u8) []const u8 {
    var len: usize = 0;
    while (len < buf.len and buf[len] != 0) : (len += 1) {}
    return buf[0..len];
}

fn equalsZ(a: []const u8, b: []const u8) bool {
    return sameBytes(spanZ(a), spanZ(b));
}

fn sameBytes(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var index: usize = 0;
    while (index < a.len) : (index += 1) {
        if (a[index] != b[index]) return false;
    }
    return true;
}

fn equalsIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var index: usize = 0;
    while (index < a.len) : (index += 1) {
        if (asciiUpper(a[index]) != asciiUpper(b[index])) return false;
    }
    return true;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (sameBytes(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn endsWithIgnoreCase(value: []const u8, suffix: []const u8) bool {
    if (value.len < suffix.len) return false;
    const start = value.len - suffix.len;
    var index: usize = 0;
    while (index < suffix.len) : (index += 1) {
        if (asciiUpper(value[start + index]) != asciiUpper(suffix[index])) return false;
    }
    return true;
}

fn trim(value: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = value.len;
    while (start < end and isSpace(value[start])) : (start += 1) {}
    while (end > start and isSpace(value[end - 1])) : (end -= 1) {}
    return value[start..end];
}

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n';
}

fn asciiUpper(ch: u8) u8 {
    if (ch >= 'a' and ch <= 'z') return ch - ('a' - 'A');
    return ch;
}

fn isAsciiAlnum(ch: u8) bool {
    return (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9');
}

fn hasArg(args: [*:0]const u8, wanted: []const u8) bool {
    var offset: usize = 0;
    while (offset < 256 and args[offset] != 0) {
        while (offset < 256 and (args[offset] == ' ' or args[offset] == '\t')) : (offset += 1) {}
        const start = offset;
        while (offset < 256 and args[offset] != 0 and args[offset] != ' ' and args[offset] != '\t') : (offset += 1) {}
        if (equalsIgnoreCase(args[start..offset], wanted)) return true;
    }
    return false;
}

fn appdefFail(ctx: *const r4os.r4sys.Context, label: []const u8) i32 {
    ctx.write("APPDEF selftest FAILED: ");
    ctx.println(label);
    return 1;
}
