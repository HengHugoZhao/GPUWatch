import Foundation

/// The commands the app runs on each machine. All of them only read state.
public enum RemoteScripts {
    /// The lab's server sits behind the CS department's gateway.
    public static let serverMachine = Machine(
        name: "ZheServer", hostName: "regieleki01.cs.virginia.edu", jumpHost: "portal.cs.virginia.edu"
    )
    public static let hpcMachine = Machine(name: "UVA_HPC", hostName: "login.hpc.virginia.edu", jumpHost: nil)
    public static var serverHost: String { serverMachine.name }
    public static var hpcHost: String { hpcMachine.name }
    public static let labAccount = "takolab"

    public static var serverStoragePath: String { serverStorage.path }

    /// Its own 6 TiB volume, so `df` gives the right numbers.
    static let serverStorage = StorageTarget(
        path: "/p/simple",
        note: "The whole /p/simple volume, shared by everyone who uses it."
    )

    /// From `hdquota`, because `df` on /standard reports all of UVA's shared filesystem rather
    /// than the lab's quota, and on scratch reports the hard limit rather than the soft one.
    static func hpcStorage(for user: String) -> [StorageTarget] {
        [
            StorageTarget(
                path: "/home/\(user)/scratch",
                quotaLocation: "/scratch/\(user)",
                note: "Links to /scratch/\(user). The total is UVA's soft limit; the hard limit is higher."
            ),
            StorageTarget(path: "/standard/\(labAccount)", note: "The lab's shared quota."),
        ]
    }

    /// How far back the finished-jobs list goes. sacct refuses much wider ranges.
    public static let finishedWindowDays = 30

    static let squeueFields = [
        "JobID", "Partition", "State", "TimeUsed", "TimeLimit", "NumNodes", "NumCPUs", "MinMemory",
        "tres-per-node", "tres-per-job", "tres-alloc", "ReasonList", "SubmitTime", "StartTime", "EndTime",
        "Account", "WorkDir", "STDOUT", "Name",
    ]

    static let sacctFields = [
        "JobID", "Partition", "State", "Elapsed", "Timelimit", "ExitCode", "AllocTRES", "Submit", "Start", "End",
        "NodeList", "Account", "WorkDir", "JobName",
    ]

    static let allocationFields = ["Id", "StartTime", "EndTime", "Allocated", "Remaining", "Active", "Description"]

    /// `sstat` is the one command here that reaches compute nodes, so running jobs are capped.
    static let liveJobLimit = 50

    /// `df` gets a timeout because /p/simple is NFS: if its server stalls, that shouldn't cost
    /// the GPU view. `-k` because a hard mount ignores the polite signal while it's hung.
    public static let server = """
    echo '@@ME'; id -un
    echo '@@HOST'; hostname
    echo '@@GPUS'
    nvidia-smi --query-gpu=index,name,uuid,memory.used,memory.total,utilization.gpu,temperature.gpu,power.draw,power.limit --format=csv,noheader,nounits 2>&1
    echo "@@RC $?"
    echo '@@APPS'
    nvidia-smi --query-compute-apps=gpu_uuid,pid,used_memory,process_name --format=csv,noheader,nounits 2>/dev/null
    echo '@@PS'
    pids=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | tr -d ' ' | sort -u | paste -sd, -)
    if [ -n "$pids" ]; then ps -o pid=,user:32=,ppid=,etimes=,args= -p "$pids"; fi
    echo '@@CWD'
    for p in $(echo "$pids" | tr ',' ' '); do d=$(readlink "/proc/$p/cwd" 2>/dev/null) && echo "$p $d"; done
    echo '@@CPUS'; nproc
    echo '@@LOAD'; cat /proc/loadavg
    echo '@@MYPS'
    ps -u "$(id -un)" -o pid=,ppid=,cputimes=,rss= 2>/dev/null
    echo '@@MEM'
    grep -E '^(MemTotal|MemAvailable):' /proc/meminfo
    echo '@@DISK'
    timeout -k 2 10 df -B1 --output=size,used \(serverStorage.path) 2>&1
    echo "@@RC $?"
    echo '@@END'
    """

    /// `squeue -a` because hidden partitions would otherwise drop jobs from the list.
    /// Node output is filtered on the server: GPU nodes are about a tenth of the cluster.
    /// MAM directly rather than UVA's `allocations` wrapper, which always exits 0, hard-codes
    /// its Reserved column to 0 and has no CSV output. MAM queries can stall for minutes, so
    /// this one gets its own timeout rather than costing the page the whole fetch.
    public static let hpc: String = {
        let squeueFormat = squeueFields.map { "\($0):|" }.joined(separator: ",")
        let sacctFormat = sacctFields.joined(separator: ",")
        let allocationFormat = allocationFields.joined(separator: ",")
        return """
        echo '@@ME'; id -un
        echo '@@TZ'; date +%z; readlink -f /etc/localtime
        echo '@@NODES'
        nodes=$(scontrol show node -o 2>&1); rc=$?
        if [ $rc -eq 0 ]; then printf '%s\\n' "$nodes" | grep 'Gres=gpu'; else printf '%s\\n' "$nodes"; fi
        echo "@@RC $rc"
        echo '@@ACTIVE'
        squeue -a --me -h -O "\(squeueFormat)" 2>&1
        echo "@@RC $?"
        echo '@@FINISHED'
        sacct -X -n -P -u "$(id -un)" -S now-\(finishedWindowDays)days -o \(sacctFormat) 2>&1
        echo "@@RC $?"
        echo '@@STEPS'
        timeout -k 2 8 sacct -n -P -u "$(id -un)" -S now-\(finishedWindowDays)days -o JobID,JobIDRaw,TRESUsageInTot,TRESUsageInMax 2>&1
        echo "@@RC $?"
        echo '@@LIVE'
        ids=$(squeue -a --me -h -t R,CG -o %A 2>/dev/null | head -\(liveJobLimit) | paste -sd, -)
        status=0
        if [ -n "$ids" ]; then timeout -k 2 8 sstat -a -j "$ids" -n -P -o JobID,TRESUsageInTot,TRESUsageInMax 2>&1 || status=$?; fi
        echo "@@RC $status"
        echo '@@ALLOCATION'
        timeout 15 /opt/mam/current/bin/mam-list-allocations -a \(labAccount) --format csv --show \(allocationFormat) 2>&1
        echo "@@RC $?"
        echo '@@STORAGE'
        timeout -k 2 15 hdquota 2>&1
        echo "@@RC $?"
        echo '@@END'
        """
    }()

    /// How far back the job history goes, in calendar months before this one. Far enough to
    /// cover the grant before the current one, which runs for a year.
    public static let jobHistoryMonths = 24

    /// One query per calendar month, because Slurm caps a query at 31 days. Each takes about 30 ms.
    /// A month that fails ends the loop, and the whole fetch then counts as failed.
    public static func jobHistory(monthsBack: Int) -> String {
        """
        thisMonth=$(date +%Y-%m-01)
        echo '@@HISTORY_WINDOW'
        echo "$(date -d "$thisMonth -\(monthsBack) months" +%F) $(date +%F)"
        echo '@@HISTORY'
        status=0
        for n in $(seq \(monthsBack) -1 0); do
            from=$(date -d "$thisMonth -$n months" +%F)
            to=$(date -d "$from +1 month -1 second" +%FT%T)
            timeout -k 2 5 sacct -u "$(id -un)" -X -D --noheader --parsable2 -S "$from" -E "$to" -o JobID,Submit,Start,End,State,ElapsedRaw,AllocTRES 2>&1 || { status=$?; break; }
        done
        echo "@@RC $status"
        echo '@@END'
        """
    }

    /// Everyone on the lab's account, their names, and every running or queued job charged to it.
    public static let labMembers: String = {
        let squeueFormat = (["UserName"] + squeueFields).map { "\($0):|" }.joined(separator: ",")
        return """
        echo '@@TZ'; date +%z; readlink -f /etc/localtime
        echo '@@MEMBERS'
        users=$(timeout -k 2 15 sacctmgr -nP show assoc account=\(labAccount) format=User 2>&1); rc=$?
        printf '%s\\n' "$users" | sort -u
        echo "@@RC $rc"
        echo '@@NAMES'
        if [ $rc -eq 0 ]; then for u in $(printf '%s\\n' "$users" | sort -u); do getent passwd "$u" | cut -d: -f1,5; done; fi
        echo '@@LABJOBS'
        timeout -k 2 15 squeue -a -A \(labAccount) -h -O "\(squeueFormat)" 2>&1
        echo "@@RC $?"
        echo '@@END'
        """
    }()

    /// Anyone's running and pending jobs, looked up by computing ID. `getent` first, because
    /// `squeue` answers an unknown user with an error but still exits 0.
    public static func userLookup(_ id: String) -> String {
        let squeueFormat = squeueFields.map { "\($0):|" }.joined(separator: ",")
        return """
        echo '@@TZ'; date +%z; readlink -f /etc/localtime
        echo '@@WHO'
        getent passwd \(id) | cut -d: -f1,5
        echo '@@JOBS'
        if getent passwd \(id) >/dev/null; then timeout -k 2 15 squeue -a -u \(id) -h -O "\(squeueFormat)" 2>&1; else true; fi
        echo "@@RC $?"
        echo '@@END'
        """
    }
}

/// Fetching and parsing together, off the main actor.
/// The scripts ask the machine who they're running as, so signing in as someone is all it takes
/// to see their jobs.
public enum Fetch {
    public static func server(as user: String) async throws -> ServerSnapshot {
        try ServerSnapshot.parse(try await SSH.run(on: RemoteScripts.serverMachine, as: user, script: RemoteScripts.server, timeout: 30))
    }

    public static func hpc(as user: String) async throws -> HPCSnapshot {
        try HPCSnapshot.parse(try await SSH.run(on: RemoteScripts.hpcMachine, as: user, script: RemoteScripts.hpc, timeout: 60))
    }

    public static func jobHistory(monthsBack: Int, as user: String) async throws -> JobHistory {
        try JobHistory.parse(try await SSH.run(on: RemoteScripts.hpcMachine, as: user, script: RemoteScripts.jobHistory(monthsBack: monthsBack), timeout: 45))
    }

    public static func labMembers(as user: String) async throws -> LabMembers {
        try LabMembers.parse(try await SSH.run(on: RemoteScripts.hpcMachine, as: user, script: RemoteScripts.labMembers, timeout: 40), account: RemoteScripts.labAccount)
    }

    /// `id` must have been through `ComputingID.normalized`, since it goes into the script.
    public static func userLookup(_ id: String, as user: String) async throws -> UserLookup {
        try UserLookup.parse(try await SSH.run(on: RemoteScripts.hpcMachine, as: user, script: RemoteScripts.userLookup(id), timeout: 30), id: id)
    }
}
