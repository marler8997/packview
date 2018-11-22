module tbd.util;

immutable(T) asImmutable(T)(auto ref T t) pure nothrow
{
    return cast(immutable(T))t;
}
pragma(inline) T unconst(T)(const(T) obj)
{
    return cast(T)obj;
}
pragma(inline) T[] unconstElements(T)(const(T)[] obj)
{
    return cast(T[])obj;
}
