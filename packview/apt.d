module packview.apt;

import core.sync.mutex;

import std.array : Appender, appender;
import std.path : buildPath, dirName;

import packview.util : asImmutable;
import packview.async;
import packview.globals;
import packview.url : Url;
import packview.proc : run, runGetStdout, processOptions;

import packview.manager;

enum TempPostfix = ".temp";
auto buildDepsFileTemp(const(char)[] nameNoColons)
{
    return buildPath(Global.adminAptPacksDir, nameNoColons, "deps" ~ TempPostfix);
}
auto getNameNoColons(const(char)[] name)
{
    import std.string : tr;
    return tr(name, ":", "_");
}

class Package
{
    string name;
    string depsFileTemp;
    string depsFile;
    string sysrootTemp;
    string sysroot;
    this(string name)
    {
        this.name = name;
        // can't use colons because overlay mount options use colon as directory separators
        const nameNoColons = getNameNoColons(name);
        this.depsFileTemp = buildDepsFileTemp(nameNoColons);
        this.depsFile = this.depsFileTemp[0 .. $ - TempPostfix.length];
        this.sysrootTemp = buildPath(Global.adminAptPacksDir, nameNoColons, "sysroot" ~ TempPostfix);
        this.sysroot = this.sysrootTemp[0 .. $ - TempPostfix.length];
    }
    auto readDeps()
    {
        import std.string : lineSplitter;
        import std.file : readText;
        auto depends = parseAptDepends(name, lineSplitter(readText(depsFile)));
        //depends.dump();
        return depends.range();
    }
}

private struct AptGlobal
{
    // keeps track of which packages have been queued to be installed.
    private static __gshared bool[string] packagesQueuedToInstall;

    private static shared Mutex mutex;
    static this()
    {
        mutex = new shared Mutex();
    }
    private static struct InsideLock
    {
        ~this()
        {
            //import std.stdio;writefln("AptGlobal.unlock");
            mutex.unlock();
        }
        pragma(inline)
        final bool setPackageQueuedToInstall(string name) const
        {
            return insideLockSetPackageQueuedToInstall(name);
        }
    }
    static auto getScopedLock()
    {
        mutex.lock();
        //{import std.stdio;writefln("AptGlobal.lock");}
        return InsideLock();
    }
    // returns true if it was added, false if it was already added
    private static bool insideLockSetPackageQueuedToInstall(string name)
    {
        if (packagesQueuedToInstall.get(name, false))
            return false;
        packagesQueuedToInstall[name] = true;
        return true;
    }
}

Manager createAptManager(Scheduler* scheduler) { return new AptManager(scheduler); }
class AptManager : Manager
{
    private Scheduler* scheduler;
    private Mutex mutex;
    // packages to install directly (not their dependencies)
    private Appender!(Package[]) shallowInstallQueue;
    // packages that we need to get dependencies for and then install those dependencies
    private Appender!(Package[]) getDependenciesQueue;

    @disable this();
    this(Scheduler* scheduler)
    {
        this.scheduler = scheduler;
        this.mutex = new Mutex();
    }

    private static struct InsideLock
    {
        private AptManager manager;
        this(AptManager manager) { this.manager = manager; }
        ~this()
        {
            if (manager.getDependenciesQueue.data.length > 0)
                manager.scheduler.addJobIfNotAdded(&manager.getDependenciesJob);
            if (manager.shallowInstallQueue.data.length > 0)
                manager.scheduler.addJobIfNotAdded(&manager.shallowInstallJob);
            //import std.stdio;writefln("AptManager.unlock");
            manager.mutex.unlock();
        }
        pragma(inline)
        final takeShallowInstallQueue()
        {
            return manager.insideLockTakeShallowInstallQueue();
        }
        pragma(inline)
        final takeGetDependenciesQueue()
        {
            return manager.insideLockTakeGetDependenciesQueue();
        }
        pragma(inline)
        final void addPackageToInstall(string packageName)
        {
            manager.insideLockAddPackageToInstall(packageName);
        }
        pragma(inline)
        final void addDepsToInstall(Package pkg)
        {
            manager.insideLockAddDepsToInstall(pkg);
        }
    }
    auto getScopedLock()
    {
        mutex.lock();
        //{import std.stdio;writefln("AptGlobal.lock");}
        return InsideLock(this);
    }
    private final Package[] insideLockTakeShallowInstallQueue()
    {
        auto copy = shallowInstallQueue.data.dup;
        shallowInstallQueue.clear();
        return copy;
    }
    private final Package[] insideLockTakeGetDependenciesQueue()
    {
        auto copy = getDependenciesQueue.data.dup;
        getDependenciesQueue.clear();
        return copy;
    }
    private void insideLockAddPackageToInstall(string packageName)
    {
        import std.file : exists;

        {
            auto lock = AptGlobal.getScopedLock();
            if (!lock.setPackageQueuedToInstall(packageName))
            {
                // this package has already been queued for install
                return;
            }
        }
        auto pkg = new Package(packageName);
        if (pkg.name[0] == '<')
            {import std.stdio;writefln("[APT-INSTALLER] package '%s' is a virtual package", packageName);}
        else if (exists(pkg.sysroot))
            {import std.stdio;writefln("[APT-INSTALLER] package '%s' already installed", packageName);}
        else
            shallowInstallQueue.put(pkg);

        if (exists(pkg.depsFile))
            insideLockAddDepsToInstall(pkg);
        else
            getDependenciesQueue.put(pkg);
    }
    private void insideLockAddDepsToInstall(Package pkg)
    {
        import std.string : lineSplitter;
        import std.file : readText;

        foreach (optionSet; pkg.readDeps)
        {
            if (optionSet.length > 1)
            {
                import std.stdio;
                writefln("Package '%s' has %s options (defaulting to first)",
                    pkg.name, optionSet.length);
                foreach (i, option; optionSet.options)
                {
                    writef(" [%s]", i);
                    foreach (depPackage; option.packages)
                    {
                        writef(" %s", depPackage);
                    }
                    writeln();
                }
            }
            foreach (depPackage; optionSet[0].packages)
            {
                insideLockAddPackageToInstall(depPackage);
            }
        }
    }

    private void getDependenciesJob()
    {
        import std.string : lineSplitter;

        Package[] packages;
        {
            auto lock = getScopedLock();
            packages = lock.takeGetDependenciesQueue();
        }
        if (packages.length == 0)
        {
            import std.stdio;writefln("get dependencies job was started, but no packages in queue");
            return;
        }
        auto args = ["apt-cache", "depends", "--recurse",
            "--no-suggests",
            "--no-recommends",
            "--no-conflicts",
            "--no-enhances",
            "--no-replaces",
            "--no-breaks"];
        foreach (pkg; packages)
        {
            args ~= pkg.name;
        }
        const aptDependsOutput = runGetStdout(args).asImmutable;
        install(writeDependencyFiles(lineSplitter(aptDependsOutput)));
    }
    private void shallowInstallJob()
    {
        Package[] packages;
        {
            auto lock = getScopedLock();
            packages = lock.takeShallowInstallQueue();
        }
        if (packages.length == 0)
        {
            import std.stdio;writefln("shallow install job was started, but no packages in queue");
            return;
        }
        {
            auto schedulerLock = scheduler.getScopedLock();
            foreach (pkg; packages)
            {
                schedulerLock.addJob(&new ShallowPackageInstallJob(pkg).doJob);
            }
        }
    }

    //
    // Manager methods
    //
    final override void install(const string[] packages)
    {
        auto lock = getScopedLock();
        foreach (pkg; packages)
        {
            lock.addPackageToInstall(pkg);
        }
    }
    final override void putDirs(const string[] packageNames, scope void delegate(const(char)[]) sink)
    {
        bool[string] added;
        .putDirs(packageNames, sink, &added);
    }
}

private void putDirs(const string[] packageNames, scope void delegate(const(char)[]) sink, bool[string]* added)
{
    import std.file : exists;

    foreach (packageName; packageNames)
    {
        // skip virtual packages
        if (packageName[0] == '<')
            continue;
        if (!added.get(packageName, false))
        {
            (*added)[packageName] = true;
            auto pkg = new Package(packageName);
            sink(pkg.sysroot);
            if (!exists(pkg.depsFile))
            {
                import std.stdio;writefln("Error: package '%s' deps file does not exist '%s'", packageName, pkg.depsFile);
                throw new Exception("package deps file missing");
            }
            foreach (optionSet; pkg.readDeps)
            {
                if (optionSet.length > 1)
                {
                    import std.stdio;
                    writefln("Package '%s' has %s options (defaulting to first)",
                        pkg.name, optionSet.length);
                    foreach (i, option; optionSet.options)
                    {
                        writef(" [%s]", i);
                        foreach (depPackage; option.packages)
                        {
                            writef(" %s", depPackage);
                        }
                        writeln();
                    }
                }
                putDirs(optionSet[0].packages, sink, added);
            }
        }
    }
}


class ShallowPackageInstallJob
{
    Package pkg;
    this(Package pkg)
    {
        this.pkg = pkg;
    }
    void doJob()
    {
        import std.file : exists, rename;
        import packview.file : mkdirs;

        {import std.stdio;writefln("[APT-INSTALLER] installing '%s'", pkg.name);}
        auto url = getPackageUrl(pkg.name);
        //{import std.stdio;writefln("[DEBUG] package '%s' url is '%s'", pkg.name, url);}

        // TODO: download deb file to global apt archive

        // download deb file
        auto debFile = buildPath(Global.adminAptArchiveDir, url.pathAsRelative);
        if (exists(debFile))
        {
            import std.stdio;writefln("[DEBUG] '%s' is already downloaded", debFile);
        }
        else
        {
            mkdirs(dirName(debFile));
            run(["wget", "--output-document=" ~ debFile, url.text]);
        }

        mkdirs(pkg.sysrootTemp);
        // install doesn't seem to work without root
        //run(["dpkg", "--admindir=" ~ Global.adminAptPacksDir, "--instdir=" ~ installDir, "--install", debFile]);
        run(["dpkg", "--admindir=" ~ Global.adminAptDir, "--extract", debFile, pkg.sysrootTemp]);
        rename(pkg.sysrootTemp, pkg.sysroot);
    }
}

Url!(immutable(char)) getPackageUrl(string packageName)
{
    import std.string : stripRight, indexOf, lastIndexOf, startsWith;
    import std.format : format;

    // NOTE: this doesn't always work because under the hood it's actually
    //       trying to do a "dry-run" install, so if there's something preventing
    //       it from actually being installed on the host, you can't get the url
    //auto aptGetOut = runGetStdout(["apt-get", "install", "--yes", "--no-download",
    //    "--reinstall", "--print-uris", packageName]).stripRight("\n");
    auto aptGetOut = runGetStdout(["apt-get", "download", "--yes", "--no-download",
        "--print-uris", packageName]).stripRight("\n");
    if (aptGetOut.length == 0)
        throw new Exception("apt-get install output is empty");
    auto lastNewlineIndex = aptGetOut.lastIndexOf('\n');
    auto lastLine = (lastNewlineIndex >= 0) ?
        aptGetOut[lastNewlineIndex + 1 .. $] :
        aptGetOut;
    if (!lastLine.startsWith("'"))
        throw new Exception(format("last line of apt-get install output does not start with \"'\", it is \"%s\"", lastLine));
    lastLine = lastLine[1 .. $];
    auto urlEnd = lastLine.indexOf('\'');
    if (urlEnd == -1)
        throw new Exception(format("last line of apt-get install output is missing single quote to end url \"%s\"", lastLine));
    return Url!(immutable(char))(lastLine[0 .. urlEnd].idup);
}

class PackageSet
{
    private string[] packages;
    this(string[] packages) { this.packages = packages; }
    void addPackage(string pkg) { this.packages ~= pkg; }
    void dump(string prefix)
    {
        import std.stdio;
        foreach (pkg; packages)
        {
            writefln("%s%s", prefix, pkg);
        }
    }
}
struct PackageSetOptions
{
    PackageSet[] options;
    auto length() const { return options.length; }
    inout(PackageSet) opIndex(size_t i) inout { return options[i]; }
}
class AptDepends
{
    string packageName;
    string allDepOutput;
    static immutable __gshared listPrefixes = [
        "Depends: ",
        "PreDepends: ",
        "Suggests: ",
        "Recommends: ",
        "Conflicts: ",
        "Breaks: ",
        "Replaces: ",
    ];
    union
    {
        struct
        {
            PackageSetOptions[] depends;
            PackageSetOptions[] preDepends;
            PackageSetOptions[] suggests;
            PackageSetOptions[] recommends;
            PackageSetOptions[] conflicts;
            PackageSetOptions[] breaks;
            PackageSetOptions[] replaces;
        }
        PackageSetOptions[][listPrefixes.length] lists;
    }
    this(string packageName)
    {
        this.packageName = packageName;
    }
    auto range()
    {
        import std.range : chain;
        return chain(preDepends, depends);
    }
    void dump()
    {
        import std.stdio;
        writeln("--------------------------------------------------------------------------------");
        writefln("Depends for '%s'", packageName);
        writeln("--------------------------------------------------------------------------------");
        foreach (optionSet; range)
        {
            if (optionSet.length > 1)
            {
                import std.stdio;
                writefln("Package '%s' has %s options (defaulting to first)",
                    packageName, optionSet.length);
                foreach (i, option; optionSet.options)
                {
                    writef(" [%s]", i);
                    foreach (depPackage; option.packages)
                    {
                        writef(" %s", depPackage);
                    }
                    writeln();
                }
            }
            foreach (depPackage; optionSet[0].packages)
            {
                writefln("%s", depPackage);
            }
        }
        /+
        foreach (listIndex; 0 .. listPrefixes.length)
        {
            writefln("%s", listPrefixes[listIndex]);
            foreach (options; lists[listIndex])
            {
                if (options.length == 1)
                    options[0].dump("  ");
                else
                {
                    foreach (i; 0 .. options.length)
                    {
                        writefln("  Option %s:", i);
                        options[i].dump("    ");
                    }
                }
            }
        }
        +/
        writeln("--------------------------------------------------------------------------------");
    }
}

private struct TempFile
{
    import std.file : rename;
    import std.stdio : File;

    enum postfix = ".temp";

    private string filename;
    private string tempFilename;
    private File file;
    auto getFile() { return file; }
    bool isNull() const { return filename is null; }
    void open(string tempFilename)
    {
        this.tempFilename = tempFilename;
        this.filename = tempFilename[0 .. $ - postfix.length];
        file = File(this.tempFilename, "w");
    }
    void close()
    {
        if (filename)
        {
            file.close();
            rename(tempFilename, filename);
            filename = null;
        }
    }
}

string[] writeDependencyFiles(T)(T lines)
{
    import std.string : stripRight;
    import std.format : format;
    import packview.file : mkdirs;

    if (lines.empty)
        return null;
    auto packages = appender!(string[]);

    TempFile currentDepFile;
    uint lineNumber = 1;
    for (; !lines.empty; lines.popFront, lineNumber++)
    {
        auto line = lines.front.stripRight();
        if (line.length == 0)
            throw new Exception(format("apt-cache depends line %s: line is empty?", lineNumber));
        if (line[0] != ' ')
        {
            currentDepFile.close();
            packages.put(line);
            //import std.stdio;writefln("[APT-DEP-PACKAGE] '%s'", line);
            auto depsFileTemp = buildDepsFileTemp(getNameNoColons(line));
            mkdirs(dirName(depsFileTemp));
            currentDepFile.open(depsFileTemp);
        }
        if (currentDepFile.isNull)
            throw new Exception("apt-cache depends output does not start with package name");
        currentDepFile.getFile.writeln(line);
    }
    currentDepFile.close();
    return packages.data;
}
AptDepends parseAptDepends(T)(string expectedPackageName, T lines)
{
    import std.algorithm : skipOver;
    import std.string : stripRight;
    import std.format : format;

    if (lines.empty)
        throw new Exception("apt-cache depends output is empty");
    {
        const line = lines.front.stripRight;
        if (line != expectedPackageName)
            throw new Exception(format("expected first line of deps file to be package '%s' but is '%s'",
                expectedPackageName, line));
    }
    lines.popFront();

    auto depends = new AptDepends(expectedPackageName);
    bool previousIsOr = false;
    PackageSet currentPackageSet = null;
    uint lineNumber = 2;
    for (; !lines.empty; lines.popFront, lineNumber++)
    {
        auto line = lines.front.stripRight();
        //import std.stdio;writeln(line);
        if (line.length == 0)
            throw new Exception(format("apt-cache depends line %s: line is empty?", lineNumber));
        if (line.skipOver("    "))
        {
            if (currentPackageSet is null)
                throw new Exception(format(
                    "apt-cache depends line %s: got indented package name '%s' but there is no current package list",
                    lineNumber, line));
            currentPackageSet.addPackage(line);
            continue;
        }

        bool currentIsOr;
        if (line.skipOver("  "))
            currentIsOr = false;
        else if (line.skipOver(" |"))
            currentIsOr = true;
        else
            throw new Exception(format(
                "apt-cache depends line %s: expected line to start with package name, '    ', '  ' or ' |' but got '%s'",
                lineNumber, line));

        ubyte listIndex = ubyte.max;
        foreach (ubyte i; 0 .. AptDepends.listPrefixes.length)
        {
            if (line.skipOver(AptDepends.listPrefixes[i]))
            {
                listIndex = i;
                break;
            }
        }
        currentPackageSet = new PackageSet([line]);
        if (previousIsOr)
        {
            assert(depends.lists[listIndex].length > 0, "code bug or bad apt-cache depends output 1");
            assert(depends.lists[listIndex][$-1].options.length > 0, "code bug or bad apt-cache depends output 2");
            depends.lists[listIndex][$-1].options ~= currentPackageSet;
        }
        else
        {
            depends.lists[listIndex] ~= PackageSetOptions([currentPackageSet]);
        }
        previousIsOr = currentIsOr;
    }
    return depends;
}
