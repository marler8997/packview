module packview.manager;

import std.array : Appender;
import packview.async;

enum ManagerName
{
    apt,
    yum,
}
auto getManager(const ManagerName name) { return &managers[name]; }
auto createManager(const ManagerName name, Scheduler* scheduler)
{
    return managers[name].create(scheduler);
}

struct ManagerFactory
{
    string name;
    Manager function(Scheduler* scheduler) create;
}

import packview.apt : createAptManager;

__gshared immutable managers = [
    immutable ManagerFactory("apt", &createAptManager),
];

const(ManagerFactory)* tryParseManager(const(char)[] name)
{
    foreach (i; 0 .. managers.length)
    {
       if (managers[i].name == name)
           return &managers[i];
    }
    return null;
}

abstract class Manager
{
    abstract void install(const string[] packages);
    abstract void putDirs(const string[] packageNames, scope void delegate(const(char)[]) sink);
}
