module packview.async;

//
// TODO: scheduler callback could be defined through a template type
//
alias Job = void delegate(/*Scheduler* scheduler*/);

struct Scheduler
{
    import core.sync.mutex;
    import std.array : Appender;

    private Appender!(Job[]) jobQueue;
    private uint runningJobCount;
    private Mutex mutex;
    pragma(inline)
    static auto create()
    {
        return Scheduler(new Mutex());
    }
    private this(Mutex mutex)
    {
        this.mutex = mutex;
    }
    auto getScopedLock()
    {
        mutex.lock();
        //{import std.stdio;writefln("AsyncGlobal.lock");}
        return InsideLock(&this);
    }
    void workerLoop()
    {
        Job job = null;
        for (;;)
        {
            {
                auto lock = getScopedLock();
                if (job !is null)
                    runningJobCount--;

                job = lock.popJob();
                if (!job)
                {
                    if (runningJobCount == 0)
                        return;
                    assert(0, "not impl: wait for more jobs");
                }
                runningJobCount++;
            }
            job(/*&this*/);
        }
    }

    private static struct InsideLock
    {
        Scheduler *scheduler;
        this(Scheduler *scheduler)
        {
            this.scheduler = scheduler;
        }
        ~this()
        {
            //import std.stdio;writefln("AsyncGlobal.unlock");
            scheduler.mutex.unlock();
        }
        pragma(inline)
        final void addJob(Job job) { scheduler.insideLockAddJob(job); }
        pragma(inline)
        final void addJobIfNotAdded(Job job) { scheduler.insideLockAddJobIfNotAdded(job); }
        pragma(inline)
        final Job popJob() { return scheduler.insideLockPopJob(); }
    }
    private void insideLockAddJob(Job job)
    {
        jobQueue.put(job);
    }
    private void insideLockAddJobIfNotAdded(Job job)
    {
        foreach(queuedJob; jobQueue.data)
        {
            if (queuedJob is job)
                return;
        }
        jobQueue.put(job);
    }
    private Job insideLockPopJob()
    {
        if (jobQueue.data.length == 0)
            return null;
        auto job = jobQueue.data[$-1];
        jobQueue.shrinkTo(jobQueue.data.length - 1);
        return job;
    }

    void addJobIfNotAdded(Job job)
    {
        auto lock = getScopedLock();
        lock.addJobIfNotAdded(job);
    }
}
