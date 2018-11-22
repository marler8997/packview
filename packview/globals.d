module packview.globals;

struct Program
{
    const string programBasename;
    this(string programBasename)
    {
        this.programBasename = programBasename;
    }
    private bool looked;
    private string file;
    string getFile()
    {
        // TODO: synchronize if multi-threaded
        if (!looked)
        {
            import packview.findprog : tryFindProgram;
            file = tryFindProgram(programBasename);
            looked = true;
        }
        return file;
    }
}

struct Global
{

    // TODO: might make this configurable
    static __gshared string adminDir;
    static __gshared string adminAptDir;
    static __gshared string adminAptPacksDir;
    static __gshared string adminAptArchiveDir;
    static setAdminDir(string newAdminDir)
    {
        Global.adminDir = newAdminDir;
        Global.adminAptDir = newAdminDir ~ "/apt";
        Global.adminAptPacksDir = adminAptDir ~ "/packs";
        Global.adminAptArchiveDir = adminAptDir ~ "/archive";
    }

    static __gshared auto debootstrapProgram = Program("debootstrap");
    static __gshared auto aptGetProgram = Program("apt-get");
    static __gshared auto dpkgProgram = Program("dpkg");
}
