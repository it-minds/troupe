//! reaper: run a command, and kill its whole process tree when our stdin
//! reaches EOF (i.e. when the Erlang port that owns us closes) or when the
//! command exits. Exits with the command's status.
//!
//! Unix:    fork, setsid (new process group), stdin from /dev/null, exec.
//!          poll(stdin) + waitpid(WNOHANG) loop. On EOF: SIGTERM the group,
//!          2s grace, SIGKILL the group.
//! Windows: CreateProcess suspended, assign to a Job Object with
//!          KILL_ON_JOB_CLOSE, resume. A thread blocks on ReadFile(stdin);
//!          on EOF the job is terminated.
//!
//! Written against libc / kernel32 declarations only, so it compiles with
//! any recent Zig without depending on std API churn.
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;

pub export fn main(argc: c_int, argv: [*][*:0]u8) c_int {
    if (argc < 2) return 2;
    if (is_windows) {
        return windowsMain();
    } else {
        return unixMain(argv);
    }
}

// ---------------------------------------------------------------- Unix ----

const pollfd = extern struct { fd: c_int, events: c_short, revents: c_short };

extern "c" fn fork() c_int;
extern "c" fn setsid() c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn dup2(a: c_int, b: c_int) c_int;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn _exit(code: c_int) noreturn;
extern "c" fn poll(fds: [*]pollfd, nfds: c_uint, timeout: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
extern "c" fn kill(pid: c_int, sig: c_int) c_int;
extern "c" fn usleep(usec: c_uint) c_int;

const POLLIN: c_short = 0x0001;
const POLLHUP: c_short = 0x0010;
const POLLNVAL: c_short = 0x0020;
const WNOHANG: c_int = 1;
const SIGKILL: c_int = 9;
const SIGTERM: c_int = 15;

fn unixMain(argv: [*][*:0]u8) c_int {
    const pid = fork();
    if (pid < 0) return 2;
    if (pid == 0) {
        _ = setsid();
        const fd = open("/dev/null", 0);
        if (fd >= 0) _ = dup2(fd, 0);
        const child_argv: [*:null]const ?[*:0]const u8 = @ptrCast(argv + 1);
        _ = execvp(argv[1], child_argv);
        _exit(127);
    }

    var fds = [_]pollfd{.{ .fd = 0, .events = POLLIN, .revents = 0 }};
    var buf: [256]u8 = undefined;
    while (true) {
        var status: c_int = 0;
        const w = waitpid(pid, &status, WNOHANG);
        if (w == pid) return exitCode(status);
        if (w < 0) return 2;

        const r = poll(&fds, 1, 100);
        if (r > 0) {
            if ((fds[0].revents & (POLLNVAL | POLLHUP)) != 0 and (fds[0].revents & POLLIN) == 0) {
                return killTree(pid);
            }
            const n = read(0, &buf, buf.len);
            if (n <= 0) return killTree(pid);
        }
    }
}

fn killTree(pid: c_int) c_int {
    _ = kill(-pid, SIGTERM);
    var status: c_int = 0;
    var waited: u32 = 0;
    while (waited < 2000) : (waited += 50) {
        const w = waitpid(pid, &status, WNOHANG);
        if (w == pid) {
            _ = kill(-pid, SIGKILL);
            return exitCode(status);
        }
        _ = usleep(50_000);
    }
    _ = kill(-pid, SIGKILL);
    _ = waitpid(pid, &status, 0);
    return exitCode(status);
}

fn exitCode(status: c_int) c_int {
    if ((status & 0x7f) == 0) return (status >> 8) & 0xff;
    return 128 + (status & 0x7f);
}

// ------------------------------------------------------------- Windows ----

const HANDLE = ?*anyopaque;

const SECURITY_ATTRIBUTES = extern struct {
    nLength: u32,
    lpSecurityDescriptor: ?*anyopaque,
    bInheritHandle: i32,
};

const STARTUPINFOW = extern struct {
    cb: u32,
    lpReserved: ?[*:0]u16,
    lpDesktop: ?[*:0]u16,
    lpTitle: ?[*:0]u16,
    dwX: u32,
    dwY: u32,
    dwXSize: u32,
    dwYSize: u32,
    dwXCountChars: u32,
    dwYCountChars: u32,
    dwFillAttribute: u32,
    dwFlags: u32,
    wShowWindow: u16,
    cbReserved2: u16,
    lpReserved2: ?*u8,
    hStdInput: HANDLE,
    hStdOutput: HANDLE,
    hStdError: HANDLE,
};

const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE,
    hThread: HANDLE,
    dwProcessId: u32,
    dwThreadId: u32,
};

const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
    PerProcessUserTimeLimit: i64,
    PerJobUserTimeLimit: i64,
    LimitFlags: u32,
    MinimumWorkingSetSize: usize,
    MaximumWorkingSetSize: usize,
    ActiveProcessLimit: u32,
    Affinity: usize,
    PriorityClass: u32,
    SchedulingClass: u32,
};

const IO_COUNTERS = extern struct {
    ReadOperationCount: u64,
    WriteOperationCount: u64,
    OtherOperationCount: u64,
    ReadTransferCount: u64,
    WriteTransferCount: u64,
    OtherTransferCount: u64,
};

const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
    BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION,
    IoInfo: IO_COUNTERS,
    ProcessMemoryLimit: usize,
    JobMemoryLimit: usize,
    PeakProcessMemoryUsed: usize,
    PeakJobMemoryUsed: usize,
};

extern "kernel32" fn GetCommandLineW() callconv(.winapi) [*:0]u16;
extern "kernel32" fn CreateJobObjectW(?*SECURITY_ATTRIBUTES, ?[*:0]const u16) callconv(.winapi) HANDLE;
extern "kernel32" fn SetInformationJobObject(HANDLE, u32, *anyopaque, u32) callconv(.winapi) i32;
extern "kernel32" fn AssignProcessToJobObject(HANDLE, HANDLE) callconv(.winapi) i32;
extern "kernel32" fn TerminateJobObject(HANDLE, u32) callconv(.winapi) i32;
extern "kernel32" fn CreateProcessW(
    ?[*:0]const u16,
    ?[*:0]u16,
    ?*SECURITY_ATTRIBUTES,
    ?*SECURITY_ATTRIBUTES,
    i32,
    u32,
    ?*anyopaque,
    ?[*:0]const u16,
    *STARTUPINFOW,
    *PROCESS_INFORMATION,
) callconv(.winapi) i32;
extern "kernel32" fn ResumeThread(HANDLE) callconv(.winapi) u32;
extern "kernel32" fn GetStdHandle(u32) callconv(.winapi) HANDLE;
extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*SECURITY_ATTRIBUTES, u32, u32, HANDLE) callconv(.winapi) HANDLE;
extern "kernel32" fn ReadFile(HANDLE, [*]u8, u32, *u32, ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn CreateEventW(?*SECURITY_ATTRIBUTES, i32, i32, ?[*:0]const u16) callconv(.winapi) HANDLE;
extern "kernel32" fn SetEvent(HANDLE) callconv(.winapi) i32;
extern "kernel32" fn CreateThread(?*SECURITY_ATTRIBUTES, usize, *const fn (?*anyopaque) callconv(.winapi) u32, ?*anyopaque, u32, ?*u32) callconv(.winapi) HANDLE;
extern "kernel32" fn WaitForMultipleObjects(u32, [*]const HANDLE, i32, u32) callconv(.winapi) u32;
extern "kernel32" fn GetExitCodeProcess(HANDLE, *u32) callconv(.winapi) i32;

const STD_INPUT_HANDLE: u32 = 0xFFFFFFF6;
const STD_OUTPUT_HANDLE: u32 = 0xFFFFFFF5;
const STD_ERROR_HANDLE: u32 = 0xFFFFFFF4;
const GENERIC_READ: u32 = 0x80000000;
const OPEN_EXISTING: u32 = 3;
const STARTF_USESTDHANDLES: u32 = 0x100;
const CREATE_SUSPENDED: u32 = 0x4;
const JobObjectExtendedLimitInformation: u32 = 9;
const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: u32 = 0x2000;
const INFINITE: u32 = 0xFFFFFFFF;
const WAIT_OBJECT_0: u32 = 0;

var stdin_event: HANDLE = null;

fn stdinThread(_: ?*anyopaque) callconv(.winapi) u32 {
    const h = GetStdHandle(STD_INPUT_HANDLE);
    var buf: [256]u8 = undefined;
    var n: u32 = 0;
    while (true) {
        const ok = ReadFile(h, &buf, buf.len, &n, null);
        if (ok == 0 or n == 0) break;
    }
    _ = SetEvent(stdin_event);
    return 0;
}

fn windowsMain() c_int {
    // The child's command line is our own command line minus argv[0].
    const full = GetCommandLineW();
    var i: usize = 0;
    if (full[0] == '"') {
        i = 1;
        while (full[i] != 0 and full[i] != '"') i += 1;
        if (full[i] == '"') i += 1;
    } else {
        while (full[i] != 0 and full[i] != ' ' and full[i] != '\t') i += 1;
    }
    while (full[i] == ' ' or full[i] == '\t') i += 1;
    if (full[i] == 0) return 2;

    var cmd: [32768]u16 = undefined;
    var j: usize = 0;
    while (full[i] != 0 and j < cmd.len - 1) : ({
        i += 1;
        j += 1;
    }) cmd[j] = full[i];
    cmd[j] = 0;
    const cmd_ptr: [*:0]u16 = @ptrCast(&cmd);

    const job = CreateJobObjectW(null, null);
    if (job == null) return 2;
    var limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = undefined;
    @memset(@as([*]u8, @ptrCast(&limits))[0..@sizeOf(JOBOBJECT_EXTENDED_LIMIT_INFORMATION)], 0);
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    _ = SetInformationJobObject(job, JobObjectExtendedLimitInformation, @ptrCast(&limits), @sizeOf(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));

    var sa = SECURITY_ATTRIBUTES{ .nLength = @sizeOf(SECURITY_ATTRIBUTES), .lpSecurityDescriptor = null, .bInheritHandle = 1 };
    const nul_name = [_:0]u16{ 'N', 'U', 'L' };
    const nul = CreateFileW(&nul_name, GENERIC_READ, 0, &sa, OPEN_EXISTING, 0, null);

    var si: STARTUPINFOW = undefined;
    @memset(@as([*]u8, @ptrCast(&si))[0..@sizeOf(STARTUPINFOW)], 0);
    si.cb = @sizeOf(STARTUPINFOW);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = nul;
    si.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
    si.hStdError = GetStdHandle(STD_ERROR_HANDLE);

    var pi: PROCESS_INFORMATION = undefined;
    @memset(@as([*]u8, @ptrCast(&pi))[0..@sizeOf(PROCESS_INFORMATION)], 0);

    if (CreateProcessW(null, cmd_ptr, null, null, 1, CREATE_SUSPENDED, null, null, &si, &pi) == 0) return 127;
    _ = AssignProcessToJobObject(job, pi.hProcess);
    _ = ResumeThread(pi.hThread);

    stdin_event = CreateEventW(null, 1, 0, null);
    _ = CreateThread(null, 0, &stdinThread, null, 0, null);

    const handles = [_]HANDLE{ pi.hProcess, stdin_event };
    const which = WaitForMultipleObjects(2, &handles, 0, INFINITE);
    if (which == WAIT_OBJECT_0) {
        var code: u32 = 1;
        _ = GetExitCodeProcess(pi.hProcess, &code);
        return @intCast(code & 0xff);
    }
    _ = TerminateJobObject(job, 137);
    return 137;
}
