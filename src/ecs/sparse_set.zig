const std = @import("std");
const warn = std.debug.warn;

// TODO: fix entity_mask. it should come from EntityTraitsDefinition.
pub fn SparseSet(comptime SparseT: type, comptime DenseT: type) type {
    return struct {
        const Self = @This();

        sparse: std.ArrayList(DenseT),
        dense: std.ArrayList(SparseT),
        entity_mask: SparseT,
        allocator: ?*std.mem.Allocator,

        pub fn initPtr(allocator: *std.mem.Allocator) *Self {
            var set = allocator.create(Self) catch unreachable;
            set.sparse = std.ArrayList(DenseT).init(allocator);
            set.dense = std.ArrayList(SparseT).init(allocator);
            set.entity_mask = std.math.maxInt(SparseT);
            set.allocator = allocator;
            return set;
        }

        pub fn init(allocator: *std.mem.Allocator) Self {
            return Self{
                .sparse = std.ArrayList(DenseT).init(allocator),
                .dense = std.ArrayList(SparseT).init(allocator),
                .entity_mask = std.math.maxInt(SparseT),
                .allocator = null,
            };
        }

        pub fn deinit(self: *Self) void {
            self.dense.deinit();
            self.sparse.deinit();

            if (self.allocator) |allocator|
                allocator.destroy(self);
        }

        fn page(self: Self, sparse: SparseT) usize {
            // TODO: support paging
            // return (sparse & EntityTraits.entity_mask) / sparse_per_page;
            return sparse & self.entity_mask;
        }

        fn offset(self: Self, sparse: SparseT) usize {
            // TODO: support paging
            // return entt & (sparse_per_page - 1)
            return sparse & self.entity_mask;
        }

        fn assure(self: *Self, pos: usize) []DenseT {
            // TODO: support paging
            if (self.sparse.capacity <= pos or self.sparse.capacity == 0) {
                const amount = pos + 1 - self.sparse.capacity;

                // expand and fill with maxInt as an identifier
                const old_len = self.sparse.items.len;
                self.sparse.resize(self.sparse.items.len + amount) catch unreachable;
                self.sparse.expandToCapacity();
                std.mem.set(DenseT, self.sparse.items[old_len..self.sparse.items.len], std.math.maxInt(DenseT));
            }

            return self.sparse.items;
        }

        /// Increases the capacity of a sparse sets index array
        pub fn reserve(self: *Self, cap: usize) void {
            self.sparse.resize(cap) catch unreachable;
        }

        /// Returns the number of dense elements that a sparse set has currently allocated space for
        pub fn capacity(self: *Self) usize {
            return self.dense.capacity;
        }

        /// Returns the number of dense elements in a sparse set
        pub fn len(self: Self) usize {
            return self.dense.items.len;
        }

        pub fn empty(self: *Self) bool {
            return self.dense.items.len == 0;
        }

        pub fn data(self: Self) *const []SparseT {
            return &self.dense.items;
        }

        pub fn contains(self: Self, sparse: SparseT) bool {
            const curr = self.page(sparse);
            if (curr >= self.sparse.items.len)
                return false;

            // testing against maxInt permits to avoid accessing the packed array
            return curr < self.sparse.items.len and self.sparse.items[curr] != std.math.maxInt(DenseT);
        }

        /// Returns the position of an entity in a sparse set
        pub fn index(self: Self, sparse: SparseT) DenseT {
            std.debug.assert(self.contains(sparse));
            return self.sparse.items[self.offset(sparse)];
        }

        /// Assigns an entity to a sparse set
        pub fn add(self: *Self, sparse: SparseT) void {
            std.debug.assert(!self.contains(sparse));

            // assure(page(entt))[offset(entt)] = packed.size()
            self.assure(self.page(sparse))[self.offset(sparse)] = @intCast(DenseT, self.dense.items.len);
            _ = self.dense.append(sparse) catch unreachable;
        }

        /// Removes an entity from a sparse set
        pub fn remove(self: *Self, sparse: SparseT) void {
            std.debug.assert(self.contains(sparse));

            const curr = self.page(sparse);
            const pos = self.offset(sparse);
            const last_dense = self.dense.items[self.dense.items.len - 1];

            self.dense.items[self.sparse.items[curr]] = last_dense;
            self.sparse.items[self.page(last_dense)] = self.sparse.items[curr];
            self.sparse.items[curr] = std.math.maxInt(DenseT);

            _ = self.dense.pop();
        }

        /// Swaps two entities in the internal packed and sparse arrays
        pub fn swap(self: *Self, sparse_l: SparseT, sparse_r: SparseT) void {
            var from = &self.sparse.items[sparse_l];
            var to = &self.sparse.items[sparse_r];

            std.mem.swap(SparseT, &self.dense.items[from.*], &self.dense.items[to.*]);
            std.mem.swap(DenseT, from, to);
        }

        /// Sort elements according to the given comparison function
        pub fn sort(self: *Self, sortFn: fn (SparseT, SparseT) bool) void {
            std.sort.insertionSort(SparseT, self.dense.items, sortFn);

            var i = @as(usize, 0);
            for (self.dense.items) |sparse| {
                // self.assure(self.page(sparse))[self.offset(sparse)] = @intCast(DenseT, sparse);
                self.sparse.items[self.page(sparse)] = @intCast(DenseT, sparse);
            }
        }

        /// Sort entities according to their order in another sparse set. Other is the master in this case.
        pub fn respect(self: *Self, other: *Self) void {
            var pos = @as(DenseT, 0);
            var i = @as(DenseT, 0);
            while (i < other.dense.items.len) : (i += 1) {
                if (self.contains(other.dense.items[i])) {
                    if (other.dense.items[i] != self.dense.items[pos]) {
                        self.swap(self.dense.items[pos], other.dense.items[i]);
                    }
                    pos += 1;
                }
            }
        }

        pub fn clear(self: *Self) void {
            self.sparse.items.len = 0;
            self.dense.items.len = 0;
        }
    };
}

fn printSet(set: *SparseSet(u32, u8)) void {
    std.debug.warn("\nsparse -----\n", .{});
    for (set.sparse.items) |sparse| {
        std.debug.warn("{}\t", .{sparse});
    }

    std.debug.warn("\ndense -----\n", .{});
    for (set.dense.items) |dense| {
        std.debug.warn("{}\t", .{dense});
    }
    std.debug.warn("\n\n", .{});
}

test "add/remove/clear" {
    var set = SparseSet(u32, u8).initPtr(std.testing.allocator);
    defer set.deinit();

    set.add(4);
    set.add(3);
    std.testing.expectEqual(set.len(), 2);
    std.testing.expectEqual(set.index(4), 0);
    std.testing.expectEqual(set.index(3), 1);

    set.remove(4);
    std.testing.expectEqual(set.len(), 1);

    set.clear();
    std.testing.expectEqual(set.len(), 0);
}

test "grow" {
    var set = SparseSet(u32, u8).initPtr(std.testing.allocator);
    defer set.deinit();

    var i = @as(usize, std.math.maxInt(u8));
    while (i > 0) : (i -= 1) {
        set.add(@intCast(u32, i));
    }

    std.testing.expectEqual(set.len(), std.math.maxInt(u8));
}

test "swap" {
    var set = SparseSet(u32, u8).initPtr(std.testing.allocator);
    defer set.deinit();

    set.add(4);
    set.add(3);
    std.testing.expectEqual(set.index(4), 0);
    std.testing.expectEqual(set.index(3), 1);

    set.swap(4, 3);
    std.testing.expectEqual(set.index(3), 0);
    std.testing.expectEqual(set.index(4), 1);
}

test "data() synced" {
    var set = SparseSet(u32, u8).initPtr(std.testing.allocator);
    defer set.deinit();

    set.add(0);
    set.add(1);
    set.add(2);
    set.add(3);

    var data = set.data();
    std.testing.expectEqual(data.*[1], 1);
    std.testing.expectEqual(set.len(), data.len);

    set.remove(0);
    set.remove(1);
    std.testing.expectEqual(set.len(), data.len);
}

test "respect" {
    var set1 = SparseSet(u32, u8).initPtr(std.testing.allocator);
    defer set1.deinit();

    var set2 = SparseSet(u32, u8).initPtr(std.testing.allocator);
    defer set2.deinit();

    set1.add(3);
    set1.add(4);
    set1.add(5);
    set1.add(6);
    set1.add(7);

    set2.add(8);
    set2.add(6);
    set2.add(4);

    set1.respect(set2);

    std.testing.expectEqual(set1.dense.items[0], set2.dense.items[1]);
    std.testing.expectEqual(set1.dense.items[1], set2.dense.items[2]);
}

test "respect" {
    var set = SparseSet(u32, u8).initPtr(std.testing.allocator);
    defer set.deinit();

    set.add(5);
    set.add(2);
    set.add(4);
    set.add(1);
    set.add(3);

    set.sort(std.sort.desc(u32));

    for (set.dense.items) |item, i| {
        if (i < set.dense.items.len - 1) {
            std.debug.assert(item > set.dense.items[i + 1]);
        }
    }
}