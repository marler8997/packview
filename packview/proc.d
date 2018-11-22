module tbd.proc;

static import std.stdio;
import std.stdio : File;
import std.process : Config;

struct ProcessOptions
{
    static import std.stdio;
    import std.process : Config;

    string[string] env;
    Config config;
    const(char)[] workDir;
    @disable this();
    auto setWorkDir(const char[] workDir) { this.workDir = workDir; return this; }
}
auto processOptions()
{
    ProcessOptions opt = void;
    opt.env = opt.env.init;
    opt.config = Config.none;
    opt.workDir = null;
    return opt;
}

void printCommand(scope const(char[])[] args)
{
    import std.algorithm : canFind;
    import std.stdio;

    string prefix = "";
    foreach (arg; args)
    {
        write(prefix);
        prefix = " ";
        auto needQuotes = arg.canFind(' ');
        if (needQuotes)
            write("'");
        write(arg);
        if (needQuotes)
            write("'");
    }
}

int tryRun(scope const(char[])[] args, ProcessOptions options = processOptions,
    File stdin = std.stdio.stdin, File stdout = std.stdio.stdout, File stderr = std.stdio.stderr)
{
    import std.process;
    import std.stdio;

    write("[SPAWN] ");
    if (options.workDir)
        writef("cd '%s' && ", options.workDir);
    printCommand(args);
    writeln();
    auto proc = spawnProcess(args, stdin, stdout,
        stderr, options.env, options.config, options.workDir);
    return proc.wait();
}
void run(scope const(char[])[] args, ProcessOptions options = processOptions,
    File stdin = std.stdio.stdin, File stdout = std.stdio.stdout, File stderr = std.stdio.stderr)
{
    auto exitCode = tryRun(args, options, stdin, stdout, stderr);
    if (exitCode != 0)
    {
        import std.stdio;writefln("Error: last command exited with %s", exitCode);
        assert(0);
    }
}

auto readAll(File input)
{
    import std.array : appender;
    auto all = appender!(char[])();
    char[1024] buf;
    for (;;)
    {
        auto result = input.rawRead(buf);
        if (result.length == 0)
            return all.data;
        all.put(result);
    }
}

char[] runGetStdout(scope const(char[])[] args, ProcessOptions options = processOptions)
{
    import std.process;
    import std.stdio;
    write("[RUN_GET_STDOUT] ");
    if (options.workDir)
        writef("cd '%s' && ", options.workDir);
    printCommand(args);
    writeln();
    auto pipes = pipeProcess(args, Redirect.all,
        options.env, options.config, options.workDir);
    auto output = readAll(pipes.stdout);
    auto errors = readAll(pipes.stderr);
    auto exitCode = wait(pipes.pid);
    if (exitCode != 0)
    {
        writeln(errors);
        import std.stdio;writefln("Error: last command exiited with %s", exitCode);
        assert(0);
    }
    return output;
}

struct ProcBuilder
{
    import std.array : Appender;
    static ProcBuilder forExeFile(const(char)[] programFile)
    {
        return ProcBuilder(programFile);
    }

    private Appender!(const(char)[][]) args;

    @disable this();
    private this(const(char)[] programFile)
    {
        args.put(programFile);
    }

    auto put(const(char)[] arg) { return args.put(arg); }
    int tryRun() { return tbd.proc.tryRun(args.data); }
    void run() { tbd.proc.run(args.data); }
    auto runGetStdout() { return tbd.proc.runGetStdout(args.data); }
}
