const std = @import("std");

pub var rewriteZigFieldNameToJsonObjectKey: fn ([]const u8) []const u8 = rewriteZigFieldNameToJsonObjectKeyDont;

fn rewriteZigFieldNameToJsonObjectKeyDont(field_name: []const u8) []const u8 {
    return field_name;
}

pub fn marshal(mem: *std.heap.ArenaAllocator, from: var) std.mem.Allocator.Error!std.json.Value {
    const T = comptime @TypeOf(from);
    const type_id = comptime @typeId(T);
    const type_info = comptime @typeInfo(T);

    if (T == []const u8 or T == []u8)
        return std.json.Value{ .String = from }
    else if (type_id == .Bool)
        return std.json.Value{ .Bool = from }
    else if (type_id == .Int or type_id == .ComptimeInt)
        return std.json.Value{ .Integer = @intCast(i64, from) }
    else if (type_id == .Float or type_id == .ComptimeFloat)
        return std.json.Value{ .Float = from }
    else if (type_id == .Null or type_id == .Void)
        return std.json.Value{ .Null = .{} }
    else if (type_id == .Enum)
        return std.json.Value{ .Integer = @enumToInt(from) }
    else if (type_id == .Optional)
        return if (from) |it| try marshal(mem, it) else .{ .Null = .{} }
    else if (type_id == .Struct) {
        var ret = std.json.Value{ .Object = std.json.ObjectMap.init(&mem.allocator) };
        if (IsHashMapLike(T)) {
            var iter = from.iterator();
            while (iter.next()) |pair|
                _ = try ret.Object.put(item.key, item.value);
        } else {
            comptime var i = @memberCount(T);
            inline while (i > 0) {
                i -= 1;
                const field_type = @memberType(T, i);
                const field_name = @memberName(T, i);
                const field_value = @field(from, field_name);
                var field_is_null = false;
                if (comptime (@typeId(field_type) == .Optional))
                    field_is_null = (field_value == null);
                if (comptime std.mem.eql(u8, field_name, @typeName(field_type))) {
                    var obj = try marshal(mem, field_value).Object.iterator();
                    while (obj.next()) |item|
                        _ = try ret.Object.put(item.key, item.value);
                } else if (!field_is_null) {
                    _ = try ret.Object.put(rewriteZigFieldNameToJsonObjectKey(field_name), try marshal(mem, field_value));
                }
            }
        }
        return ret;
    } else if (type_id == .Pointer) {
        if (type_info.Pointer.size != .Slice)
            return try marshal(mem, from.*)
        else {
            var ret = std.json.Value{ .Array = std.json.Array.init(&mem.allocator) }; // TODO: use initCapacity once zig compiler's "broken LLVM module found" bug goes away
            for (from) |item|
                try ret.Array.append(try marshal(mem, item));
            return ret;
        }
    } else if (type_id == .Union) {
        comptime var i = @memberCount(T);
        inline while (i > 0) {
            i -= 1;
            if (@enumToInt(std.meta.activeTag(from)) == i) {
                return try marshal(mem, @field(from, @memberName(T, i)));
            }
        }
        unreachable;
    } else
        @compileError("please file an issue to support JSON-marshaling of: " ++ @typeName(T));
}

pub fn unmarshal(comptime T: type, mem: *std.heap.ArenaAllocator, from: *const std.json.Value) ?T {
    const type_id = comptime @typeId(T);
    const type_info = comptime @typeInfo(T);
    if (T == []const u8 or T == []u8)
        return switch (from.*) {
            .String => |jstr| jstr,
            else => null,
        }
    else if (T == bool)
        return switch (from.*) {
            .Bool => |jbool| jbool,
            .String => |jstr| if (std.mem.eql(u8, "true", jstr)) true else (if (std.mem.eql(u8, "false", jstr)) false else null),
            else => null,
        }
    else if (type_id == .Int)
        return switch (from.*) {
            .Integer => |jint| @intCast(T, jint),
            .Float => |jfloat| if (jfloat < @intToFloat(f64, std.math.minInt(T)) or jfloat > @intToFloat(f64, std.math.maxInt(T)))
                null
            else
                @floatToInt(T, jfloat),
            .String => |jstr| std.fmt.parseInt(T, jstr, 10) catch null,
            else => null,
        }
    else if (type_id == .Float)
        return switch (from.*) {
            .Float => |jfloat| jfloat,
            .Integer => |jint| @intToFloat(T, jint),
            .String => |jstr| std.fmt.parseFloat(T, jstr) catch null,
            else => null,
        }
    else if (type_id == .Enum) {
        const TEnum = std.meta.TagType(T);
        return switch (from.*) {
            .Integer => |jint| std.meta.intToEnum(T, jint) catch null,
            .String => |jstr| std.meta.stringToEnum(T, jstr) orelse (if (std.fmt.parseInt(TEnum, jstr, 10)) |i| (std.meta.intToEnum(T, i) catch null) else |_| null),
            .Float => |jfloat| if (jfloat < @intToFloat(f64, std.math.minInt(TEnum)) or jfloat > @intToFloat(f64, std.math.maxInt(TEnum)))
                null
            else
                (std.meta.intToEnum(T, @floatToInt(TEnum, jfloat)) catch null),
            else => null,
        };
    } else if (type_id == .Optional) switch (from.*) {
        .Null => return null,
        else => return unmarshal(type_info.Optional.child, mem, from) orelse null,
    } else if (type_id == .Pointer) {
        if (type_info.Pointer.size != .Slice) {
            const copy = unmarshal(type_info.Pointer.child, mem, from);
            return @import("./xstd.mem.zig").enHeap(&mem.allocator, copy orelse return null) catch unreachable;
        } else switch (from.*) {
            .Array => |jarr| {
                var ret = mem.allocator.alloc(type_info.Pointer.child, jarr.len) catch unreachable;
                for (jarr.items[0..jarr.len]) |*jval, i|
                    ret[i] = unmarshal(type_info.Pointer.child, mem, jval) orelse return null;
                return ret;
            },
            else => return null,
        }
    } else if (type_id == .Struct) {
        switch (from.*) {
            .Object => |*jmap| {
                var ret = @import("./xstd.mem.zig").zeroed(T);
                comptime var i = @memberCount(T);
                inline while (i > 0) {
                    i -= 1;
                    const field_name = @memberName(T, i);
                    const field_type = @memberType(T, i);
                    if (comptime std.mem.eql(u8, field_name, @typeName(field_type))) {
                        if (unmarshal(field_type, mem, from)) |it|
                            @field(ret, field_name) = it;
                        // else return null; // TODO: compiler segfaults with this currently (January 2020), not an issue until we begin seeing the below stderr print in the wild though
                    } else if (jmap.getValue(rewriteZigFieldNameToJsonObjectKey(field_name))) |*jval| {
                        if (unmarshal(field_type, mem, jval)) |it|
                            @field(ret, field_name) = it
                        else if (@typeId(field_type) != .Optional)
                        // return null; // TODO: see segfault note above, same here
                            std.debug.warn("MISSING:\t{}.{}\n", .{ @typeName(T), field_name });
                    }
                }
                return ret;
            },
            else => return null,
        }
    } else
        @compileError("please file an issue to support JSON-unmarshaling into: " ++ @typeName(T));
}

pub fn IsHashMapLike(comptime T: type) bool {
    switch (@typeInfo(T)) {
        else => {},
        .Struct => |maybe_hashmap_struct_info| {
            inline for (maybe_hashmap_struct_info.decls) |decl_in_hashmap| {
                comptime if (decl_in_hashmap.is_pub and std.mem.eql(u8, "iterator", decl_in_hashmap.name)) {
                    switch (decl_in_hashmap.data) {
                        else => {},
                        .Fn => |fn_decl_hashmap_iterator| {
                            switch (@typeInfo(fn_decl_hashmap_iterator.return_type)) {
                                else => {},
                                .Struct => |maybe_iterator_struct_info| {
                                    inline for (maybe_iterator_struct_info.decls) |decl_in_iterator| {
                                        comptime if (decl_in_iterator.is_pub and std.mem.eql(u8, "next", decl_in_iterator.name)) {
                                            switch (decl_in_iterator.data) {
                                                else => {},
                                                .Fn => |fn_decl_iterator_next| {
                                                    switch (@typeInfo(fn_decl_iterator_next.return_type)) {
                                                        else => {},
                                                        .Optional => |iter_ret_opt| {
                                                            switch (@typeInfo(iter_ret_opt.child)) {
                                                                else => {},
                                                                .Pointer => |iter_ret_opt_ptr| {
                                                                    switch (@typeInfo(iter_ret_opt_ptr.child)) {
                                                                        else => {},
                                                                        .Struct => |kv_struct| if (2 == kv_struct.fields.len and
                                                                            std.mem.eql(u8, "key", kv_struct.fields[0].name) and
                                                                            std.mem.eql(u8, "value", kv_struct.fields[1].name))
                                                                        inline for (maybe_hashmap_struct_info.decls) |decl2_in_hashmap|
                                                                            comptime if (decl2_in_hashmap.is_pub and std.mem.eql(u8, "put", decl2_in_hashmap.name))
                                                                                return true,
                                                                    }
                                                                },
                                                            }
                                                        },
                                                    }
                                                },
                                            }
                                        };
                                    }
                                },
                            }
                        },
                    }
                };
            }
        },
    }
    return false;
}
