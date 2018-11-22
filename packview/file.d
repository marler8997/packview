module packview.file;

/**
Returns: a slice of `s` after the last index of '/'
         If s ends with a '/', will return an empty string.
*/
auto sliceBaseName(inout(char)[] s)
{
    for (size_t i = s.length; i > 0;)
    {
        i--;
        if (s[i] == '/')
            return s[i+1 .. $];
    }
    return s;
}
unittest
{
    assert(null == sliceBaseName(null));
    assert("" == sliceBaseName(""));
    assert("" == sliceBaseName("/"));
    assert("" == sliceBaseName("a/"));
    assert("b" == sliceBaseName("a/b"));
    assert("" == sliceBaseName("foo/"));
    assert("b" == sliceBaseName("foo/b"));
    assert("bar" == sliceBaseName("foo/bar"));
}

/**
Returns: index of the extension (index of '.')
         size_t.max if no extension found
*/
auto indexOfExt(const(char)[] s, size_t minIndex)
{
    for (size_t i = s.length; i > minIndex;)
    {
        i--;
        if (s[i] == '.')
            return i;
    }
    return size_t.max;
}
unittest
{
    foreach (minIndex; 1 .. 4)
    {
        assert(indexOfExt("foo.bar", minIndex) == 3);
    }
    assert(indexOfExt("foo.bar", 4) == size_t.max);
}


void mkdirIfDoesNotExist(const(char)[] dir)
{
    import std.file : exists, mkdir;

    if (!exists(dir))
    {
        import std.stdio;writefln("mkdir '%s'", dir);
        mkdir(dir);
    }
}

void mkdirs(const(char)[] dir)
{
    import std.path : dirName;
    import std.file : exists, mkdir;
    if (!exists(dir))
    {
        auto parentDir = dirName(dir);
        if (parentDir != dir)
        {
            if (!exists(parentDir))
                mkdirs(parentDir);
        }
        import std.stdio;writefln("mkdir '%s'", dir);
        mkdir(dir);
    }
}