module packview.url;

class UrlException : Exception
{
    this(string msg) { super(msg); }
}

enum Protocol
{
    file,
    http,
    https,
}

struct Url(T)
{
    T[] text;
    Protocol proto;
    private ushort endOfScheme;
    private ushort endOfHost;
    private ushort endOfPort;

    T[] host() const { return cast(T[])text[endOfScheme .. endOfHost]; }
    T[] port() const { return cast(T[])text[endOfHost .. endOfPort]; }
    T[] path() const { return cast(T[])text[endOfPort .. $]; }
    T[] pathAsRelative() const
    {
        import std.string : stripLeft;
        return cast(T[])text[endOfPort .. $].stripLeft("/");
    }

    this(T[] text)
    {
        import std.string : indexOf, lastIndexOf;
        import std.format : format;
        import std.array : appender;
        import packview.file;
        this.text = text;
        if (text.length > ushort.max)
            throw new UrlException(format("url is too long (%s, max is %s)", text.length, ushort.max));

        {
            const colonDoubleSlash = text.indexOf("://");
            if (colonDoubleSlash == -1)
            {
                import std.format : format;
                throw new UrlException(format("url '%s' is missing a scheme", text));
            }
            const scheme = text[0 .. colonDoubleSlash];
            this.endOfScheme = cast(ushort)(colonDoubleSlash + 3);
            if (scheme == "file")
                this.proto = Protocol.file;
            else if (scheme == "http")
                this.proto = Protocol.http;
            else if (scheme == "https")
                this.proto = Protocol.https;
            else
                throw new UrlException(format("url '%s' has unknown scheme '%s://'", text, scheme));
        }

        this.endOfHost = this.endOfScheme;
        if (this.proto == Protocol.file)
        {
            this.endOfPort = this.endOfScheme;
            return;
        }
        for (; this.endOfHost < text.length; this.endOfHost++) {
            const c = text[this.endOfHost];
            if (c == ':')
            {
                this.endOfPort = cast(ushort)(this.endOfHost + 1);
                for (; this.endOfPort < text.length; this.endOfPort++)
                {
                    const c2 = text[this.endOfPort];
                    if (c2 == '/')
                    {
                        break;
                    }
                }
                break;
            }
            if (c == '/')
            {
                this.endOfPort = this.endOfHost;
                break;
            }
        }
    }
    void toString(scope void delegate(const(char)[]) sink) const
    {
        sink(text);
    }
}

unittest
{
    auto u = Url!(const(char))("http://a.com/a/b");
    assert(u.proto == Protocol.http);
    assert(u.host == "a.com");
    assert(u.port == "");
    assert(u.path == "/a/b");
    assert(u.pathAsRelative == "a/b");
}