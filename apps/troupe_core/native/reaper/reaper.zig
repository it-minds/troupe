//! reaper — run a command so that its entire process tree dies with our stdin.
//!
//! Contract, identical on every OS:
//!
//!   reaper <command> [args...]
//!
//!   * the command is started with stdin connected to the null device, so it can
//!     never steal the pipe we are watching;
//!   * stdout and stderr are inherited, so the caller reads them as usual;
//!   * we block reading OUR OWN stdin and never expect data on it. The only thing
//!     that ever happens to it is EOF;
//!   * on EOF we kill the command's whole process tree, then exit with the
//!     command's status (143 if we had to kill it).
//!
//! The Elixir side owns a Port running this program. Every way that owner can die —
//! an explicit cancel, an agent crash, a supervisor shutdown, SIGKILL on the whole
//! VM — closes the pipe, which is the EOF this program waits for. That is why there
//! is no cleanup code in the Elixir tool: the guarantee is structural, not defensive.
//!
//! Unix: the child gets its own session (and therefore process group) via setsid, and
//! we signal the group — TERM, a 2s grace, then KILL — so grandchildren go too.
//! Windows: the child is assigned to a Job Object with KILL_ON_JOB_CLOSE, so closing
//! our handle takes the whole tree down.
//!
//! The OS surface here is declared directly rather than taken from std: this program
//! is cross-compiled to five targets and has to behave identically on all of them,
//! and libc plus kernel32 are the parts of that surface that do not move.

const std = @import("std");
const builtin = @import("builtin");

const native_os = builtin.os.tag;
const is_windows = native_os == .windows;

const grace_ms: u64 = 2000;
/// 128 + SIGTERM, which is what a shell reports for a terminated command.
const killed_exit_code: u8 = 143;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);

    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "--version")) {
        note("reaper 1.0.0\n");
        return 0;
    }

    if (argv.len < 2) {
        note("usage: reaper <command> [args...]\n");
        return 2;
    }

    // `TROUPE_REAPER_STDIO`: the command speaks JSON-RPC over its standard streams (an
    // MCP server), so our stdin is forwarded to it rather than being the death signal
    // alone. Unix only; Windows runs such a command outside the reaper.
    if (!is_windows and c.getenv("TROUPE_REAPER_STDIO") != null) return runPosixStdio(argv[1..]);

    return if (is_windows) runWindows() else runPosix(argv[1..]);
}

/// Diagnostics go to stderr with a plain write: no formatting, no allocation, and
/// safe to call between fork and exec, where allocating would not be.
fn note(msg: []const u8) void {
    if (is_windows) {
        const h = GetStdHandle(std_error_handle) orelse return;
        var written: DWORD = 0;
        _ = WriteFile(h, msg.ptr, @intCast(msg.len), &written, null);
    } else {
        _ = c.write(stderr_fd, msg.ptr, msg.len);
    }
}

fn sleepMs(ms: u64) void {
    if (is_windows) {
        Sleep(@intCast(ms));
    } else {
        var req = timespec{
            .sec = @intCast(ms / 1000),
            .nsec = @intCast((ms % 1000) * 1_000_000),
        };
        // Restart across signal interruptions so a grace period really is one.
        while (c.nanosleep(&req, &req) == -1) {}
    }
}

// ---------------------------------------------------------------------------
// POSIX
// ---------------------------------------------------------------------------

const stdin_fd: c_int = 0;
const stderr_fd: c_int = 2;
const o_rdonly: c_int = 0;
const sigterm: c_int = 15;
const sigkill: c_int = 9;

const timespec = extern struct { sec: isize, nsec: isize };

const c = struct {
    extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
    extern "c" fn close(fd: c_int) c_int;
    extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
    extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
    extern "c" fn dup2(old_fd: c_int, new_fd: c_int) c_int;
    extern "c" fn fork() c_int;
    extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
    extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
    extern "c" fn kill(pid: c_int, sig: c_int) c_int;
    extern "c" fn setsid() c_int;
    extern "c" fn _exit(code: c_int) noreturn;
    extern "c" fn nanosleep(req: *const timespec, rem: ?*timespec) c_int;
    extern "c" fn pipe(fds: [*]c_int) c_int;
    extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;
};

/// Written by one thread and read by the other; atomics keep that honest.
var posix_pgid = std.atomic.Value(c_int).init(0);
var posix_child_done = std.atomic.Value(bool).init(false);
var posix_killed = std.atomic.Value(bool).init(false);

fn runPosix(args: []const [:0]const u8) u8 {
    // The child's argv must exist before the fork: between fork and exec only
    // async-signal-safe work is allowed, and allocating is not.
    var argv_buf: [512]?[*:0]const u8 = undefined;
    if (args.len + 1 > argv_buf.len) {
        note("reaper: too many arguments\n");
        return 2;
    }
    for (args, 0..) |arg, i| argv_buf[i] = arg.ptr;
    argv_buf[args.len] = null;

    const devnull = c.open("/dev/null", o_rdonly);
    if (devnull < 0) {
        note("reaper: cannot open /dev/null\n");
        return 2;
    }

    const pid = c.fork();
    if (pid < 0) {
        note("reaper: fork failed\n");
        return 2;
    }

    if (pid == 0) {
        // Child. setsid gives us a session of our own, so the parent can signal the
        // whole group and reach anything this command spawns.
        _ = c.setsid();
        _ = c.dup2(devnull, stdin_fd);
        if (devnull > 2) _ = c.close(devnull);

        const argv_z: [*:null]const ?[*:0]const u8 = @ptrCast(&argv_buf);
        _ = c.execvp(argv_buf[0].?, argv_z);
        // Only reachable when exec failed. 127 is what a shell reports for
        // "command not found".
        note("reaper: exec failed\n");
        c._exit(127);
    }

    _ = c.close(devnull);

    // The child called setsid, so its process group id equals its pid. Racing the
    // child's setsid is harmless — signalling the bare pid still reaches it, and any
    // EOF is many microseconds away.
    posix_pgid.store(pid, .release);

    const watchdog = std.Thread.spawn(.{}, posixWatchdog, .{}) catch {
        note("reaper: cannot spawn watchdog\n");
        killPosixTree();
        return 2;
    };
    watchdog.detach();

    const status = waitPosix(pid);
    posix_child_done.store(true, .release);

    // Sweep the group even after a clean exit: the command may have left background
    // grandchildren, and the contract is that nothing outlives us.
    killGroup(sigterm);

    return if (posix_killed.load(.acquire)) killed_exit_code else status;
}

fn waitPosix(pid: c_int) u8 {
    var status: c_int = 0;
    while (true) {
        const res = c.waitpid(pid, &status, 0);
        if (res < 0) return 1;
        const raw: u32 = @bitCast(status);
        const low = raw & 0x7f;
        if (low == 0) return @truncate((raw >> 8) & 0xff); // exited normally
        if (low != 0x7f) return 128 +| @as(u8, @truncate(low)); // killed by a signal
        // 0x7f means stopped — keep waiting.
    }
}

fn posixWatchdog() void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.read(stdin_fd, &buf, buf.len);
        if (n <= 0) break; // EOF (or a dead pipe): the owner is gone.
    }

    if (posix_child_done.load(.acquire)) return;

    posix_killed.store(true, .release);
    killPosixTree();

    // The main thread is blocked in waitpid; give it room to reap and return
    // normally, then force the exit so we can never outlive our own owner.
    sleepMs(500);
    c._exit(killed_exit_code);
}

// ---------------------------------------------------------------- stdio mode ----
//
// The command is an MCP server: it reads JSON-RPC lines on its stdin and answers on
// its stdout, so the owner's bytes have to reach it. Our stdin is forwarded through a
// pipe by a pump thread; stdout and stderr are inherited as in the plain mode, so the
// owner reads the answers as usual. EOF on our stdin still means the owner is gone:
// the pipe is closed — which is how an MCP server is told to exit — and the tree is
// taken down after the grace if it has not left on its own.

var stdio_pipe_write = std.atomic.Value(c_int).init(-1);

fn runPosixStdio(args: []const [:0]const u8) u8 {
    var argv_buf: [512]?[*:0]const u8 = undefined;
    if (args.len + 1 > argv_buf.len) {
        note("reaper: too many arguments\n");
        return 2;
    }
    for (args, 0..) |arg, i| argv_buf[i] = arg.ptr;
    argv_buf[args.len] = null;

    var fds: [2]c_int = undefined;
    if (c.pipe(&fds) != 0) {
        note("reaper: cannot open a pipe\n");
        return 2;
    }

    const pid = c.fork();
    if (pid < 0) {
        note("reaper: fork failed\n");
        return 2;
    }

    if (pid == 0) {
        _ = c.setsid();
        _ = c.dup2(fds[0], stdin_fd);
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
        const argv_z: [*:null]const ?[*:0]const u8 = @ptrCast(&argv_buf);
        _ = c.execvp(argv_buf[0].?, argv_z);
        note("reaper: exec failed\n");
        c._exit(127);
    }

    _ = c.close(fds[0]);
    stdio_pipe_write.store(fds[1], .release);
    posix_pgid.store(pid, .release);

    const pump = std.Thread.spawn(.{}, posixStdioPump, .{}) catch {
        note("reaper: cannot spawn pump\n");
        killPosixTree();
        return 2;
    };
    pump.detach();

    const status = waitPosix(pid);
    posix_child_done.store(true, .release);
    killGroup(sigterm);

    return if (posix_killed.load(.acquire)) killed_exit_code else status;
}

fn posixStdioPump() void {
    var buf: [4096]u8 = undefined;
    const out = stdio_pipe_write.load(.acquire);

    while (true) {
        const n = c.read(stdin_fd, &buf, buf.len);
        if (n <= 0) break; // EOF: the owner is gone.
        const len: usize = @intCast(n);
        var off: usize = 0;
        while (off < len) {
            const w = c.write(out, buf[off..].ptr, len - off);
            if (w <= 0) break;
            off += @intCast(w);
        }
    }

    // Closing the server's stdin is its cue to exit; give it the grace to do so.
    _ = c.close(out);
    var waited: u64 = 0;
    while (waited < grace_ms and !posix_child_done.load(.acquire)) : (waited += 50) sleepMs(50);
    if (posix_child_done.load(.acquire)) return;

    posix_killed.store(true, .release);
    killPosixTree();
    sleepMs(500);
    c._exit(killed_exit_code);
}

fn killPosixTree() void {
    killGroup(sigterm);
    sleepMs(grace_ms);
    if (!posix_child_done.load(.acquire)) killGroup(sigkill);
}

fn killGroup(sig: c_int) void {
    const group = posix_pgid.load(.acquire);
    if (group == 0) return;
    // A negative pid targets the entire process group.
    _ = c.kill(-group, sig);
}


// ---------------------------------------------------------------------------
// Windows
// ---------------------------------------------------------------------------

var win_job = std.atomic.Value(usize).init(0);
var win_child_done = std.atomic.Value(bool).init(false);
var win_killed = std.atomic.Value(bool).init(false);

fn runWindows() u8 {
    // Pass the caller's command line through verbatim rather than re-quoting a parsed
    // argv: round-tripping Windows quoting rules is the classic way to mangle a
    // command, and the Elixir side already built the string it wants run.
    const child_cmd = stripArgv0(GetCommandLineW());
    if (child_cmd[0] == 0) {
        note("usage: reaper <command> [args...]\n");
        return 2;
    }

    const job = CreateJobObjectW(null, null) orelse {
        note("reaper: CreateJobObject failed\n");
        return 2;
    };

    var limits = std.mem.zeroes(JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
    limits.BasicLimitInformation.LimitFlags = job_object_limit_kill_on_job_close;
    if (SetInformationJobObject(
        job,
        job_object_extended_limit_information,
        &limits,
        @sizeOf(JOBOBJECT_EXTENDED_LIMIT_INFORMATION),
    ) == 0) {
        note("reaper: SetInformationJobObject failed\n");
        return 2;
    }

    win_job.store(@intFromPtr(job), .release);

    const nul = openNulDevice() orelse {
        note("reaper: cannot open NUL\n");
        return 2;
    };

    var startup = std.mem.zeroes(STARTUPINFOW);
    startup.cb = @sizeOf(STARTUPINFOW);
    startup.dwFlags = startf_usestdhandles;
    startup.hStdInput = nul;
    startup.hStdOutput = GetStdHandle(std_output_handle);
    startup.hStdError = GetStdHandle(std_error_handle);

    var info = std.mem.zeroes(PROCESS_INFORMATION);

    // CREATE_SUSPENDED, then resume after the job assignment, closes the window in
    // which a fast-starting child could spawn a grandchild outside the job.
    const created = CreateProcessW(
        null,
        @constCast(child_cmd),
        null,
        null,
        1, // bInheritHandles
        create_suspended | create_unicode_environment,
        null,
        null,
        &startup,
        &info,
    );

    _ = CloseHandle(nul);

    if (created == 0) {
        note("reaper: CreateProcess failed\n");
        return 127;
    }

    if (AssignProcessToJobObject(job, info.hProcess) == 0) {
        note("reaper: AssignProcessToJobObject failed\n");
    }

    _ = ResumeThread(info.hThread);
    _ = CloseHandle(info.hThread);

    const watchdog = std.Thread.spawn(.{}, windowsWatchdog, .{}) catch {
        note("reaper: cannot spawn watchdog\n");
        closeJob();
        return 2;
    };
    watchdog.detach();

    _ = WaitForSingleObject(info.hProcess, infinite);

    var code: DWORD = 1;
    _ = GetExitCodeProcess(info.hProcess, &code);
    _ = CloseHandle(info.hProcess);

    win_child_done.store(true, .release);
    // Closing the job kills anything the command left running.
    closeJob();

    if (win_killed.load(.acquire)) return killed_exit_code;
    return @truncate(code);
}

/// Drop the program name from a Windows command line, using the same rules
/// CreateProcess itself applies: a quoted argv[0] ends at the closing quote, an
/// unquoted one at the first space or tab.
fn stripArgv0(cmd: [*:0]const u16) [*:0]const u16 {
    var i: usize = 0;
    if (cmd[0] == '"') {
        i = 1;
        while (cmd[i] != 0 and cmd[i] != '"') : (i += 1) {}
        if (cmd[i] == '"') i += 1;
    } else {
        while (cmd[i] != 0 and cmd[i] != ' ' and cmd[i] != '\t') : (i += 1) {}
    }
    while (cmd[i] == ' ' or cmd[i] == '\t') : (i += 1) {}
    return cmd + i;
}

fn openNulDevice() ?HANDLE {
    const name = std.unicode.utf8ToUtf16LeStringLiteral("NUL");
    var sa = SECURITY_ATTRIBUTES{
        .nLength = @sizeOf(SECURITY_ATTRIBUTES),
        .lpSecurityDescriptor = null,
        .bInheritHandle = 1,
    };
    const h = CreateFileW(
        name,
        generic_read,
        file_share_read | file_share_write,
        &sa,
        open_existing,
        0,
        null,
    );
    return if (h == null or @intFromPtr(h.?) == invalid_handle) null else h;
}

fn windowsWatchdog() void {
    var buf: [4096]u8 = undefined;
    if (GetStdHandle(std_input_handle)) |h| {
        while (true) {
            var read: DWORD = 0;
            const ok = ReadFile(h, &buf, buf.len, &read, null);
            // A clean EOF (ok with 0 bytes) and a broken pipe (!ok) both mean the
            // owner is gone. Either way, reap.
            if (ok == 0 or read == 0) break;
        }
    }

    if (win_child_done.load(.acquire)) return;

    win_killed.store(true, .release);
    closeJob();

    sleepMs(500);
    ExitProcess(killed_exit_code);
}

fn closeJob() void {
    const raw = win_job.swap(0, .acq_rel);
    if (raw == 0) return;
    _ = CloseHandle(@ptrFromInt(raw));
}

// Win32 types and imports are declared here rather than taken from std.os.windows:
// zig 0.16 trimmed the kernel32 wrappers this needs, and a self-contained
// declaration is one less thing to re-check on the next zig bump.
const HANDLE = *anyopaque;
const DWORD = u32;
const WORD = u16;
const BYTE = u8;
const BOOL = c_int;
const LARGE_INTEGER = i64;
const LPWSTR = [*:0]u16;

const std_input_handle: DWORD = @bitCast(@as(i32, -10));
const std_output_handle: DWORD = @bitCast(@as(i32, -11));
const std_error_handle: DWORD = @bitCast(@as(i32, -12));

const job_object_extended_limit_information: c_int = 9;
const job_object_limit_kill_on_job_close: DWORD = 0x0000_2000;
const create_suspended: DWORD = 0x0000_0004;
const create_unicode_environment: DWORD = 0x0000_0400;
const startf_usestdhandles: DWORD = 0x0000_0100;
const generic_read: DWORD = 0x8000_0000;
const file_share_read: DWORD = 0x0000_0001;
const file_share_write: DWORD = 0x0000_0002;
const open_existing: DWORD = 3;
const infinite: DWORD = 0xFFFF_FFFF;
const invalid_handle: usize = std.math.maxInt(usize);

const SECURITY_ATTRIBUTES = extern struct {
    nLength: DWORD,
    lpSecurityDescriptor: ?*anyopaque,
    bInheritHandle: BOOL,
};

const STARTUPINFOW = extern struct {
    cb: DWORD,
    lpReserved: ?LPWSTR,
    lpDesktop: ?LPWSTR,
    lpTitle: ?LPWSTR,
    dwX: DWORD,
    dwY: DWORD,
    dwXSize: DWORD,
    dwYSize: DWORD,
    dwXCountChars: DWORD,
    dwYCountChars: DWORD,
    dwFillAttribute: DWORD,
    dwFlags: DWORD,
    wShowWindow: WORD,
    cbReserved2: WORD,
    lpReserved2: ?*BYTE,
    hStdInput: ?HANDLE,
    hStdOutput: ?HANDLE,
    hStdError: ?HANDLE,
};

const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE,
    hThread: HANDLE,
    dwProcessId: DWORD,
    dwThreadId: DWORD,
};

const IO_COUNTERS = extern struct {
    ReadOperationCount: u64,
    WriteOperationCount: u64,
    OtherOperationCount: u64,
    ReadTransferCount: u64,
    WriteTransferCount: u64,
    OtherTransferCount: u64,
};

const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
    PerProcessUserTimeLimit: LARGE_INTEGER,
    PerJobUserTimeLimit: LARGE_INTEGER,
    LimitFlags: DWORD,
    MinimumWorkingSetSize: usize,
    MaximumWorkingSetSize: usize,
    ActiveProcessLimit: DWORD,
    Affinity: usize,
    PriorityClass: DWORD,
    SchedulingClass: DWORD,
};

const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
    BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION,
    IoInfo: IO_COUNTERS,
    ProcessMemoryLimit: usize,
    JobMemoryLimit: usize,
    PeakProcessMemoryUsed: usize,
    PeakJobMemoryUsed: usize,
};

extern "kernel32" fn GetCommandLineW() callconv(.winapi) [*:0]const u16;

extern "kernel32" fn GetStdHandle(nStdHandle: DWORD) callconv(.winapi) ?HANDLE;

extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;

extern "kernel32" fn ReadFile(
    hFile: HANDLE,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: DWORD,
    lpNumberOfBytesRead: ?*DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) BOOL;

extern "kernel32" fn WriteFile(
    hFile: HANDLE,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: DWORD,
    lpNumberOfBytesWritten: ?*DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) BOOL;

extern "kernel32" fn CreateJobObjectW(
    lpJobAttributes: ?*anyopaque,
    lpName: ?[*:0]const u16,
) callconv(.winapi) ?HANDLE;

extern "kernel32" fn SetInformationJobObject(
    hJob: HANDLE,
    JobObjectInformationClass: c_int,
    lpJobObjectInformation: *anyopaque,
    cbJobObjectInformationLength: DWORD,
) callconv(.winapi) BOOL;

extern "kernel32" fn AssignProcessToJobObject(
    hJob: HANDLE,
    hProcess: HANDLE,
) callconv(.winapi) BOOL;

extern "kernel32" fn CreateProcessW(
    lpApplicationName: ?[*:0]const u16,
    lpCommandLine: ?[*:0]u16,
    lpProcessAttributes: ?*anyopaque,
    lpThreadAttributes: ?*anyopaque,
    bInheritHandles: BOOL,
    dwCreationFlags: DWORD,
    lpEnvironment: ?*anyopaque,
    lpCurrentDirectory: ?[*:0]const u16,
    lpStartupInfo: *STARTUPINFOW,
    lpProcessInformation: *PROCESS_INFORMATION,
) callconv(.winapi) BOOL;

extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const u16,
    dwDesiredAccess: DWORD,
    dwShareMode: DWORD,
    lpSecurityAttributes: ?*SECURITY_ATTRIBUTES,
    dwCreationDisposition: DWORD,
    dwFlagsAndAttributes: DWORD,
    hTemplateFile: ?HANDLE,
) callconv(.winapi) ?HANDLE;

extern "kernel32" fn ResumeThread(hThread: HANDLE) callconv(.winapi) DWORD;

extern "kernel32" fn WaitForSingleObject(
    hHandle: HANDLE,
    dwMilliseconds: DWORD,
) callconv(.winapi) DWORD;

extern "kernel32" fn GetExitCodeProcess(
    hProcess: HANDLE,
    lpExitCode: *DWORD,
) callconv(.winapi) BOOL;

extern "kernel32" fn Sleep(dwMilliseconds: DWORD) callconv(.winapi) void;

extern "kernel32" fn ExitProcess(uExitCode: c_uint) callconv(.winapi) noreturn;
