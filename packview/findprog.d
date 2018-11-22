module packview.findprog;

auto tryFindProgram(inout(char)[] program)
{
    import std.process : environment;
    return tryFindProgramIn(program, PathRange(environment.get("PATH")));
}
auto tryFindProgramIn(inout(char)[] program, PathRange pathRange)
{
    import std.path : buildPath;
    import std.file : exists;
    foreach (path; pathRange)
    {
        // TODO: resolve '~' in path environment variable
        auto candidate = buildPath(path, program);
        import std.stdio;writefln("[DEBUG] findprog '%s'", candidate);
        if (exists(candidate))
            return candidate;
    }
    return null;
}

struct PathRange
{
    const char *limit;
    const(char)[] current;
    this(const(char)[] pathEnv)
    {
        this.current = pathEnv[0 .. 0];
        this.limit = pathEnv.ptr + pathEnv.length;
        popFront();
    }
    bool empty() const { return current.ptr == null; }
    auto front() const { return current; }
    void popFront()
    {
        auto next = current.ptr + current.length;
        for (;; next++)
        {
            if (next >= limit)
            {
                this.current = null;
                return;
            }
            if (next[0] != ':')
                break;
        }
        auto end = next + 1;
        for (; end < limit; end++)
        {
            if (end[0] == ':')
                break;
        }
        this.current = next[0 .. end - next];
    }
}

unittest
{
    // TODO: add unittests for PathRange
}
