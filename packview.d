module __none;

import core.stdc.stdlib : exit;
import std.array : appender;
import std.string : startsWith;
import std.file : exists, mkdir;

import packview.util : asImmutable;
import packview.async;
import packview.globals;
import packview.manager;
import packview.apt : createAptManager;

enum DefaultAdminDir = "/var/cache/packview";

extern (C) int mount(const char* source, const char* target,
    const char* filesystemtype, uint mountflags, void* data);

auto formatCString(const(char)* cstr)
{
    static struct Formatter
    {
        const(char)* str;
        void toString(scope void delegate(const(char)[]) sink) const
        {
            import core.stdc.string : strlen;
            sink(str[0 .. strlen(str)]);
        }
    }
    return Formatter(cstr);
}

int loggy_mount(const(char)* source, const(char)* target,
                const(char)* filesystemtype, const char* options)
{
    import core.stdc.errno : errno;
    import std.stdio;

    writefln("mount%s%s%s%s %s %s",
        filesystemtype ? " -t " : "",
        formatCString(filesystemtype ? filesystemtype : ""),
        options ? " -o " : "",
        formatCString(options ? options : ""),
        formatCString(source ? source : "\"\""),
        formatCString(target));
    if (-1 == mount(source, target, filesystemtype, 0, cast(void*)options)) {
        writefln("Error: mount failed (e=%s)", errno);
        return -1;
    }
    return 0; // success
}

auto getOptArg(string[] args, size_t* i)
{
    import std.stdio;
    (*i)++;
    if ((*i) >= args.length)
    {
        writefln("Error: option '%s' expects an argument", args[(*i) - 1]);
        exit(1);
    }
    return args[*i];
}

struct SentinelString
{
    string value;
    alias value this;
    auto cstr() const { return value.ptr; }
}
SentinelString assumeSentinel(string str)
{
    return SentinelString(str);
}
SentinelString makeSentinel(string str)
{
    auto buf = new char[str.length + 1];
    buf[0 .. str.length] = str[];
    buf[str.length] = '\0';
    return SentinelString(buf[0 .. str.length].asImmutable);
}
template strlit(string s)
{
    enum strlit = SentinelString(s);
}

struct PackageSet
{
    ManagerName name;
    string[] packages;
    Manager manager;
}

enum Ops
{
    downloadOnly,
    downloadAndPrintDirs,
    downloadAndMakeView,
}

void usage()
{
    import std.stdio;

    writeln("Usage: packview [-options] <view_dir> ([--<pkg-manager>] <packages>...)...");
    writeln();
    writeln("Options:");
    writeln ("  --apt                 specify apt packages");
    writeln ("  --yum                 specify yum packages");
    writeln ("  --download            just download packages, not not make a pack view");
    writeln ("  --dirs                download and print dirs (dirs will be on last line)");
    writeln ("  --dirs-out <file>     write the dirs to the given output file");
    writeln ("  --dir-delimiter <str> the string to use as the delimiter between directories");
    writeln ("  --dir-prefix <str>    the string to use as the prefix for each directory");
    writeln ("  --dir-postfix <str>   the string to use as the postfix for each directory");
    //writefln("  --archive <dir>     default=%s", DefaultArchiveDir);
}
int main(string[] args)
{
    args = args[1 .. $];

    Ops ops = Ops.downloadAndMakeView;

    auto viewDir = SentinelString();
    string[] defaultManagerPackages;
    PackageSet[] packageSets = [
        PackageSet(ManagerName.apt),
        PackageSet(ManagerName.yum),
    ];
    string dirsOutFile = null;
    string dirDelimiter = ":";
    string dirPrefix = "";
    string dirPostfix = "";

    {
        // if we are in --dirs mode then there is no viewDir
        // so we need to save which manager was active when we got
        // the viewDir arguments
        string[]* managerPackagesForViewDir = null;
        string adminDir = DefaultAdminDir;
        string[]* currentList = &defaultManagerPackages;
        size_t newArgsLength = 0;
        scope (exit) args.length = newArgsLength;
        for (size_t i = 0; i < args.length; i++)
        {
           auto arg = args[i];
           if (!arg.startsWith("-"))
           {
               if (viewDir)
                   (*currentList) ~= arg;
               else
               {
                   viewDir = arg.makeSentinel;
                   managerPackagesForViewDir = currentList;
               }
           }
           else if (arg == "--apt")
               currentList = &packageSets[0].packages;
           else if (arg == "--yum")
               currentList = &packageSets[1].packages;
           else if (arg == "--admindir")
               adminDir = getOptArg(args, &i);
           else if (arg == "--download")
               ops = Ops.downloadOnly;
           else if (arg == "--dirs")
               ops = Ops.downloadAndPrintDirs;
           else if (arg == "--dirs-out")
               dirsOutFile = getOptArg(args, &i);
           else if (arg == "--dir-delimiter")
               dirDelimiter = getOptArg(args, &i);
           else if (arg == "--dir-prefix")
               dirPrefix = getOptArg(args, &i);
           else if (arg == "--dir-postfix")
               dirPostfix = getOptArg(args, &i);
           //else if (arg == "--archive")
           //    archiveDir = getOptArg(args, &i);
           else
           {
               import std.stdio;writefln("Error: unknown command line option '%s'", arg);
               return 1;
           }
        }
        if (ops != Ops.downloadAndMakeView)
        {
            if (viewDir)
            {
                (*managerPackagesForViewDir) = [viewDir.value] ~ (*managerPackagesForViewDir);
                viewDir = null;
            }
        }
        else
        {
            if (viewDir is null)
            {
                usage();
                return 1;
            }
            // make sure the view does not exist or is empty
            if (exists(viewDir))
            {
                import std.stdio;writefln("Error: view '%s' already exists (TODO: allow it if it's empty)", viewDir);
                return 1;
            }
            {import std.stdio;writefln("mkdir '%s'", viewDir);}
            mkdir(viewDir);
        }
        Global.setAdminDir(adminDir);
    }

    if (defaultManagerPackages.length > 0)
    {
        // figure out which package to use, for now we will just default to apt
        packageSets[0].packages ~= defaultManagerPackages;
    }

    auto scheduler = Scheduler.create();
    foreach (ref set; packageSets)
    {
        if (set.packages.length > 0)
        {
            set.manager = createManager(set.name, &scheduler);
            set.manager.install(set.packages);
        }
    }
    // TODO: create multiple threads
    scheduler.workerLoop();
    if (ops == Ops.downloadOnly)
        return 0;

    if (ops == Ops.downloadAndPrintDirs)
    {
        auto dirs = appender!(char[]);
        auto dg = delegate(const(char)[] packageDir) {
            if (dirs.data.length > 0)
                dirs.put(dirDelimiter);
            dirs.put(dirPrefix);
            dirs.put(packageDir);
            dirs.put(dirPostfix);
        };
        foreach (ref set; packageSets)
        {
            if (set.packages.length > 0)
                set.manager.putDirs(set.packages, dg);
        }
        import std.stdio : File, stdout;

        File outFile;
        if (!dirsOutFile)
            outFile = stdout;
        else
        {
            outFile = File(dirsOutFile, "w");
        }
        outFile.write(dirs.data);
        return 0;
    }


    {
        auto overlayOptions = appender!(char[]);
        overlayOptions.put("lowerdir=");
        bool atFirst = true;
        auto dg = delegate(const(char)[] packageDir) {
            import std.stdio;
            if (atFirst)
                atFirst = false;
            else
                overlayOptions.put(':');
            overlayOptions.put(packageDir);
        };
        foreach (ref set; packageSets)
        {
            if (set.packages.length > 0)
                set.manager.putDirs(set.packages, dg);
        }
        overlayOptions.put('\0');
        if (-1 == loggy_mount(null, viewDir.cstr, strlit!"overlay".cstr,
            overlayOptions.data.asImmutable.assumeSentinel.cstr))
            return 1; // fail, error already logged
    }

    return 0;
}
