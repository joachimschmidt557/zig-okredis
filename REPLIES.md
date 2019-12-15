# Parsing Redis Replies

## Intro
One of the main features of OkRedis is the ability of parsing Redis replies 
without having to resort to dynamic allocations when not stricly necessary.

The main way the user can negotiate reply parsing with the client is via the
first argument of `send` and `sendAlloc`.

Basic example:

```zig
// Send a command and discard the reply
try client.send(void, .{ "SET", "key", "42" });

// Ask for a `i64`
const reply = try client.send(i64, .{ "GET", "key" });
std.debug.warn("key = {}\n", .{reply});
```

What's interesting about this example is that Redis replies to the `GET` command 
with a string, but the user is asking for a number, and so the client will try
to parse a number out of the Redis string using `fmt.parseInt`.

As you can see, this is a bit more complex than just 1:1 type mapping, and this
document will try to explain how the client tries to be handy without appearing
too magical.


## The First And Second Rule Of Parsing Replies
Let's start with the two most important principles of parsing Redis replies.

Redis commands can be considered dynamically typed and, while in practice it's 
easy to know what to expect from a command (by reading the documentation), it's 
possible to get surprised occasionally (especially by thinking you don't need to
read the documentation). This brings us to the first rule:

**Asking for a type that ends up being incompatible with the reply will cause 
the client to return `error.UnsupportedConversion`.**

One way in which commands often surprise programmers is by returning errors or 
`nil`. For example calling `INCR` on a non-numeric string will return an error,
and `SET` with the `NX` option will return `nil` when the `NX` condition is not 
satisfied. OkRedis makes sure to never silently drop errors or `nil` replies, 
which brings us to the second rule:

**If the requested type doesn't account for the possiblity of receiving an error
or a `nil` reply, the client will return `error.GotErrorReply` or 
`error.GotNilReply` in such event.**

At the moment triggering any of these errors will result in a corrupted 
connection and will require you to close and reopen the client. This might 
change in the future.

Later in this document you will see how to properly parse errors, `nil` replies
and how to parse replies whose type you can't predict, for example when writing 
an interactive client.


## Decoding Basic Types

### Void
By using `void`, we indicate that we're not interested in inspecting the reply, 
so we don't even reserve memory in the function's frame for it. This will 
discard any reply Redis might send, **except for error replies**. If an error 
reply is recevied, the function will return `error.GotErrorReply`. Later we will 
see how to parse Redis error replies as values.

```zig
try client.send(void, .{ "SET", "key", 42 });
```

### Numbers
Numeric replies can be parsed directly to Integer or Float types. If Redis 
replies with a string, the parser will try to parse a number out of it using 
`fmt.parse{Int,Float}` (this is what happens with `GET`).

```zig
const reply = try client.send(i64, .{ "GET", "key" });
```

### Optionals
Optional types let you parse `nil` replies from Redis. When the expected type 
is not an optional, and Redis replies with a `nil`, then `error.GotNilReply` is 
returned instead. This is equivalent to how error replies are parsed: if the 
expected type doesn't account for the possibility, a Zig error is returned.

```zig
try client.send(void, .{ "DEL", "nokey" });
var maybe = try client.send(?i64, .{ "GET", "nokey" });
if (maybe) |val| {
    @panic();
} else {
    // Yep, the value is missing.
}
```

### Strings
Parsing strings without allocating is a bit trickier. It's possible to parse 
a string inside an array, but the two lengths must match, as there is no way to 
otherwise indicate the point up to which the array was filled.

For your convenience the library bundles a generic type called `FixBuf(N)`. A 
`FixBuf(N)` just an array of size `N` + a length, so it allows parsing strings 
shorter than `N` by using the length to mark where the string ends. If the 
buffer is not big enough, an error is returned. We will later see how types like 
`FixBuf(N)` can implement custom parsing logic.

```zig
const FixBuf = okredis.types.FixBuf;

try client.send(void, "SET", .{ "hellokey", "Hello World!" });
const hello = try client.send(FixBuf(30), .{ "GET", "hellokey" });

// .toSlice() lets you address the string inside FixBuf
if(std.mem.eql(u8, "Hello World!", hello.toSlice())) { 
    // Yep, the string was parsed
} else {
    @panic();
}

// Alternatively, if the string has a known fixed length (e.g., UUIDs)
const helloArray = try client.send([12]u8, .{ "GET", "hellokey" });
if(std.mem.eql(u8, "Hello World!", helloArray[0..])) { 
    // Yep, the string was parsed
} else {
   @panic();
}
```

### Structs

Map types in Redis (e.g., Hashes, Stream entries) can be parsed into structs.

```zig
const MyHash = struct {
    banana: FixBuf(11),
    price: f32,
};

// Create a hash with the same fields as our struct
try client.send(void, .{ "HSET", "myhash", "banana", "yes please", "price", "9.99" });

// Parse it directly into the struct
switch (try client.send(OrErr(MyHash), .{ "HGETALL", "myhash" })) {
    .Nil, .Err => unreachable,
    .Ok => |val| {
        std.debug.warn("{?}", val);
    },
}
```

The code above prints:

```
MyHash{ .banana = src.types.fixbuf.FixBuf(11){ .buf = yes please�, .len = 10 }, .price = 9.98999977e+00 }
```

## Parsing Errors As Values
We saw before that receiving an error reply from Redis causes a Zig error: 
`error.GotErrorReply`. This is because the types we tried to decode did not 
account for the possiblity of an error reply. Error replies are just strings 
with a `<ERROR CODE> <error message>` structure (e.g. "ERR unknown command"), 
but are tagged as errors in the underlying protocol. While it would be possible 
to decode them as normal strings, the parser doesn't support that possibility 
for two reasons:

1. Silently decoding errors as strings would make error-checking *error*-prone.
2. Errors should be programmatically inspected only by looking at the code.

To parse error replies OkRedis bundles `OrErr(T)`, a generic type that wraps
your expected return type inside a union. The union has three cases:

- `.Ok` for when the command succeeds, contains `T`
- `.Err` for when the reply is an error, contains the error code
- `.Nil` for when the reply is `nil`

The last case is there just for convenience, as it's basically equivalent to 
making the expected return type an optional.

**In general it's a good idea to wrap most reply types with `OrErr`.**

```zig
const FixBuf = okredis.types.FixBuf;
const OrErr = okredis.types.OrErr;

try client.send(void, .{ "SET", "stringkey", "banana" });

// Success
switch (try client.send(OrErr(FixBuf(100)), .{ "GET", "stringkey" })) {
    .Err, .Nil => @panic(),
    .Ok => |reply| std.debug.warn("stringkey = {}\n", reply.toSlice()),
}

// Error
switch (try client.send(OrErr(i64), .{ "INCR", "stringkey" })) {
    .Ok, .Nil => @panic(),
    .Err => |err| std.debug.warn("error code = {}\n", err.getCode()),
}
```

### Redis OK replies
`OrErr(void)` is a good way of parsing `OK` replies from Redis in case you want 
to inspect error codes. 

## Allocating Memory Dynamically

The examples above perform zero allocations but consequently make it awkward to 
work with strings. Using `sendAlloc` you can allocate dynamic memory every time 
the reply type is a pointer or a slice.

### Allocating Strings

```zig
const allocator = std.heap.direct_allocator;

// Create a big string key
try client.send(void, .{ "SET", "divine",
    \\When half way through the journey of our life
    \\I found that I was in a gloomy wood,
    \\because the path which led aright was lost.
    \\And ah, how hard it is to say just what
    \\this wild and rough and stubborn woodland was,
    \\the very thought of which renews my fear!
});

var inferno = try client.sendAlloc([]u8, allocator, .{ "GET", "divine" });
defer allocator.free(inferno);

// This call doesn't require to free anything.
_ = try client.sendAlloc(f64, allocator, .{ "HGET", "myhash", "price" });

// This does require a free
var allocatedNum = try client.sendAlloc(*f64, allocator, .{ "HGET", "myhash", "price" });
defer allocator.destroy(allocatedNum);
```

### Freeing complex replies

The previous examples produced types that are easy to free. Later we will see 
more complex examples where it becomes tedious to free everything by hand. For 
this reason heyredis includes `freeReply`, which frees recursively a value 
produced by `sendAlloc`. The following examples will showcase how to use it.

```zig
const freeReply = okredis.freeReply;
```

### Allocating Redis Error messages

When using `OrErr`, we were only saving the error code and throwing away the 
message. Using `OrFullErr` you will also be able to inspect the full error 
message. The error code doesn't need to be freed (it's written to a FixBuf), 
but the error message will need to be freed.

```zig
const OrFullErr = okredis.types.OrFullErr;

var incrErr = try client.sendAlloc(OrFullErr(i64), allocator, .{ "INCR", "divine" });
defer freeReply(incErr, allocator);

switch (incrErr) {
    .Ok, .Nil => @panic(),
    .Err => |err| {
        // This is where alternatively you would perform manual deallocation: 
        // defer allocator.free(err.message)
        std.debug.warn("error code = '{}'\n", err.getCode());
        std.debug.warn("error message = '{}'\n", err.message);
    },
}
```

The code above will print:

```
error code = 'ERR' 
error message = 'value is not an integer or out of range'
```

### Allocating structured types

Previously when we wanted to decode a struct we had to use a `FixBuf` to decode 
a `[]u8` field. Now we can just do it the normal way.

```zig
const MyDynHash = struct {
    banana: []u8,
    price: f32,
};

const dynHash = try client.sendAlloc(OrErr(MyDynHash), allocator, .{ "HGETALL", "myhash" });
defer freeReply(dynHash, allocator);

switch (dynHash) {
    .Nil, .Err => unreachable,
    .Ok => |val| std.debug.warn("{?}", val),
}
```

The code above will print:

```
MyDynHash{ .banana = yes please, .price = 9.98999977e+00 }
```

## Parsing Dynamic Replies

While most programs will use simple Redis commands and will know the shape of 
the reply, one might also be in a situation where the reply is unknown or 
dynamic, like when writing an interactive CLI, for example. To help with that, 
heyredis includes `DynamicReply`, a type that can be decoded as any possible 
Redis reply.

```zig
const DynamicReply = okredis.types.DynamicReply;

const dynReply = try client.sendAlloc(DynamicReply, allocator, .{ "HGETALL", "myhash" });
defer freeReply(dynReply, allocator);

switch (dynReply.data) {
    .Nil, .Bool, .Number, .Double, .Bignum, .String, .List => {},
    .Map => |kvs| {
        for (kvs) |kv| {
            std.debug.warn("[{}] => '{}'\n", kv.key.data.String, kv.value.data.String);
        }
    },
}
```

The code above will print:

```
[banana] => 'yes please'
[price] => '9.99'
```

## Bundled Types
For a full list of the types bundled with OkRedis, read 
[the documentation](https://kristoff.it/zig-okredis).

## Decoding Types In The Standard Library

## Implementing Decodable Types