// Parser and classification checks. Run from the package root: `swift run GPUWatchChecks`
//   --live <id>       fetch both machines for real, signed in as <id>, and print what the app would show
//   --squeue <file>   count rows of raw squeue output (in the app's format) that fail to parse
//   --sacct <file>    the same for raw sacct output
import Foundation
@testable import GPUWatchCore

var failures = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    if !condition() {
        failures += 1
        print("FAIL line \(line): \(message)")
    }
}

func fixture(_ name: String) -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(name).txt")
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

func summary(_ c: GPUCounts) -> String {
    "ready \(c.ready), backfill \(c.backfill), stranded \(c.stranded), in use \(c.inUse), offline \(c.offline), total \(c.total)"
}

func checkServer() throws {
    let snapshot = try ServerSnapshot.parse(fixture("ZheServer"))
    check(snapshot.me == "me" && snapshot.hostname == "regieleki01", "identity")
    check(snapshot.gpus.count == 8, "gpu count")
    check(snapshot.count(.free) == 2, "free count is \(snapshot.count(.free))")
    check(snapshot.count(.partlyFree) == 3, "partly free count is \(snapshot.count(.partlyFree))")
    check(snapshot.count(.full) == 3, "full count is \(snapshot.count(.full))")

    check(snapshot.gpus[2].processes.first?.user == "me", "process owner joined by pid")
    check(snapshot.gpus[2].processes.first?.shortCommand == "python3.12 train.py", "short command skips flags and paths")
    check(snapshot.gpus[0].processes.first?.user == "colleague", "other user's process")

    // 12 GB used with nothing visible: something is there, so it is not "free".
    check(snapshot.gpus[6].availability == .partlyFree, "memory without a process isn't free")
    check(snapshot.gpus[6].powerDrawW == nil, "[N/A] power reads as missing")

    let seventh = snapshot.gpus[7]
    check(seventh.processes.count == 2, "two processes on one GPU")
    check(seventh.processes[1].memoryMiB == nil && seventh.processes[1].user == nil, "[N/A] memory, pid missing from ps")
    check(seventh.availability == .partlyFree || seventh.availability == .full, "80/98 GB used")

    check(snapshot.hardwareSummary == "8 × NVIDIA RTX PRO 6000 Blackwell Server Edition", "hardware summary")

    // 1584953792 kB total, 1527895964 kB available.
    check(snapshot.memory?.totalMB == 1_547_806, "memory total: \(String(describing: snapshot.memory))")
    check(snapshot.memory?.availableMB == 1_492_085, "memory available: \(String(describing: snapshot.memory))")
    check(snapshot.memory?.usedMB == 55_721, "memory in use is total minus available")
    check(SystemMemory(meminfo: ["MemTotal: 100 kB"]) == nil, "needs both meminfo lines")

    let withoutMemory = try ServerSnapshot.parse("@@GPUS\n0, X, u, 1, 2, 3, 4, 5, 6\n@@RC 0\n@@MEM\ngrep: /proc/meminfo: No such file\n@@END\n")
    check(withoutMemory.memory == nil && withoutMemory.gpus.count == 1, "missing memory doesn't cost the GPU view")

    do {
        _ = try ServerSnapshot.parse("@@GPUS\n0, X, u, 1, 2, 3, 4, 5, 6\n@@RC 0\n")
        check(false, "output without @@END must be rejected")
    } catch let failure as FetchFailure {
        check(failure.headline.contains("dropped"), "truncation message")
    }
    do {
        _ = try ServerSnapshot.parse("@@GPUS\nNVIDIA-SMI has failed\n@@RC 9\n@@END\n")
        check(false, "failed nvidia-smi must be rejected")
    } catch let failure as FetchFailure {
        check(failure.detail == "NVIDIA-SMI has failed", "nvidia-smi error is passed through")
    }
}

func checkServerJobs() throws {
    let fixtureJobs = try ServerSnapshot.parse(fixture("ZheServer")).myJobs
    check(fixtureJobs.map(\.pids) == [[700001], [644095], [644096]], "newest first, same parent but different arguments stay apart: \(fixtureJobs.map(\.pids))")
    check(fixtureJobs[0].gpuIndexes == [7] && fixtureJobs[0].memoryMiB == 40000 && fixtureJobs[0].elapsedSeconds == 912, "one-GPU job")
    check(fixtureJobs[1].workDir == "/p/simple/run with space", "working directory: \(fixtureJobs[1].workDir ?? "nil")")
    check(fixtureJobs[0].shortCommand == "python3.12 eval.py", "job name")

    let serverSnapshot = try ServerSnapshot.parse(fixture("ZheServer"))
    check(serverSnapshot.gpus.map(\.utilizationPercent) == [100, 96, 14, 100, 0, 0, 0, 87], "utilization averaged over dmon's samples: \(serverSnapshot.gpus.map(\.utilizationPercent))")
    let utilRows = "# gpu sm\n# Idx %\n    0     90\n    1      0\n    0      0\n    1      0\n    0     30\n    1     10\n"
    check(ServerSnapshot.parseUtilization(RemoteOutput("@@UTIL\n\(utilRows)@@RC 0\n@@END\n").sections["UTIL"]) == [0: 40, 1: 3], "a burst and an idle gap average out")
    check(ServerSnapshot.parseUtilization(RemoteOutput("@@UTIL\nFailed to initialize NVML\n@@RC 9\n@@END\n").sections["UTIL"]).isEmpty, "a failed dmon leaves the single reading")
    check(RemoteScripts.server.contains("nvidia-smi dmon -s u -c 3"), "three samples a second apart")

    // Streaming: a reading is done when every GPU has reported, or, without a count, when rows wrap.
    var counted = UtilizationStream(gpuCount: 2)
    let countedReadings = ["# gpu sm mem", "# Idx %  %", "    0     55      3", "    1      7      0", "    0     60      3"].compactMap { counted.feed($0) }
    check(countedReadings == [[0: 55, 1: 7]], "a second is complete once both GPUs report: \(countedReadings)")
    var uncounted = UtilizationStream(gpuCount: nil)
    let wrapped = ["0 10", "1 20", "0 30", "garbage", "1 -", "0 40"].compactMap { uncounted.feed($0) }
    check(wrapped == [[0: 10, 1: 20], [0: 30]], "without a count, a repeated index starts the next second: \(wrapped)")
    let live = serverSnapshot.withUtilization([7: 3])
    check(live.gpus.map(\.utilizationPercent) == [100, 96, 14, 100, 0, 0, 0, 3], "a live reading replaces only the GPUs it covers")
    check(serverSnapshot.withUtilization([:]).gpus.map(\.utilizationPercent) == serverSnapshot.gpus.map(\.utilizationPercent), "no reading leaves the snapshot alone")
    check(RemoteScripts.liveUtilization.contains("nvidia-smi dmon -s u -d 1") && RemoteScripts.liveUtilization.contains("timeout"), "live stream is capped")
    check(serverSnapshot.cpuCount == 256, "core count")
    check(serverSnapshot.loadAverage == 96.42, "load average")
    check(abs((serverSnapshot.cpuBusyFraction ?? 0) - 96.42 / 256) < 1e-9, "CPU busy fraction")
    let withWorkers = fixtureJobs[1]
    check(withWorkers.cpuSeconds == 24023 && abs((withWorkers.cpuCores ?? 0) - 24023.0 / 7523) < 0.0001, "children and grandchildren count, the launcher doesn't: \(withWorkers.cpuSeconds ?? -1)")
    check(withWorkers.ramMB == 5171, "RAM adds up across them: \(withWorkers.ramMB ?? -1)")
    check(withWorkers.gpuMemoryTotalMiB == 97887 && withWorkers.memoryMiB == 50208, "GPU memory out of its one GPU")
    check(fixtureJobs[0].cpuSeconds == 456 && fixtureJobs[0].ramMB == 2048, "a child on a GPU of its own isn't counted here too: \(fixtureJobs[0].cpuSeconds ?? -1)")
    check(fixtureJobs[2].cpuSeconds == 7523 && fixtureJobs[2].ramMB == 3436, "another job's children stay out: \(fixtureJobs[2].cpuSeconds ?? -1)")
    check(Format.cores(1.04) == "1.0 core" && Format.cores(3.19) == "3.2 cores", "core wording")
    check(OwnProcess(psLine: "bad line") == nil && OwnProcess(psLine: " 1 2 3 4")?.ramKB == 4, "ps rows")

    // The real shape on ZheServer: one launcher, one worker per GPU, the same command line.
    func snapshot(apps: String, ps: String, cwd: String = "") throws -> ServerSnapshot {
        let gpus = (0..<4).map { "\($0), X, GPU-\($0), 1, 2, 3, 4, 5, 6" }.joined(separator: "\n")
        return try ServerSnapshot.parse("@@ME\nme\n@@GPUS\n\(gpus)\n@@RC 0\n@@APPS\n\(apps)\n@@PS\n\(ps)\n@@CWD\n\(cwd)\n@@END\n")
    }
    let launcher = try snapshot(
        apps: "GPU-3, 13, 400, /bin/py\nGPU-1, 11, 200, /bin/py\nGPU-2, 12, [N/A], /bin/py\nGPU-0, 10, 100, /bin/py",
        ps: "10 me 9 500 /bin/py -u train.py --lr 1\n11 me 9 500 /bin/py -u train.py --lr 1\n12 me 9 501 /bin/py -u train.py --lr 1\n13 me 9 500 /bin/py -u train.py --lr 1",
        cwd: "10 /p/simple/run"
    ).myJobs
    check(launcher.count == 1, "workers from one launcher are one job: \(launcher.count)")
    check(launcher.first?.gpuIndexes == [0, 1, 2, 3] && launcher.first?.pids == [10, 11, 12, 13], "job spans its GPUs")
    check(launcher.first?.memoryMiB == 700, "known memory adds up: \(String(describing: launcher.first?.memoryMiB))")
    check(launcher.first?.elapsedSeconds == 501, "the job's age is its oldest worker")
    check(launcher.first?.workDir == "/p/simple/run" && launcher.first?.shortCommand == "py train.py", "job details")

    let ranked = try snapshot(
        apps: "GPU-0, 10, 100, /bin/py\nGPU-1, 11, 100, /bin/py",
        ps: "10 me 9 500 /bin/py train.py --local_rank=0 --lr 1\n11 me 9 500 /bin/py train.py --local-rank 1 --lr 1"
    ).myJobs
    check(ranked.count == 1, "a rank argument doesn't split a job: \(ranked.count)")

    let splitParents = try snapshot(
        apps: "GPU-0, 10, 100, /bin/py\nGPU-1, 11, 100, /bin/py",
        ps: "10 me 8 500 /bin/py train.py\n11 me 9 500 /bin/py train.py"
    ).myJobs
    check(splitParents.count == 2, "the same command from different parents is two jobs")

    let oneProcess = try snapshot(
        apps: "GPU-0, 10, 100, /bin/py\nGPU-1, 10, 50, /bin/py",
        ps: "10 me 9 500 /bin/py train.py"
    ).myJobs
    check(oneProcess.count == 1 && oneProcess.first?.pids == [10] && oneProcess.first?.gpuIndexes == [0, 1], "one process on two GPUs")
    check(oneProcess.first?.memoryMiB == 150, "its memory adds up across GPUs")

    let others = try snapshot(
        apps: "GPU-0, 10, 100, /bin/py\nGPU-1, 11, 100, /bin/py",
        ps: "10 colleague 9 500 /bin/py train.py"
    ).myJobs
    check(others.isEmpty, "someone else's job and an unknown owner aren't mine")
}

func checkNodes() throws {
    let snapshot = try HPCSnapshot.parse(fixture("UVA_HPC"))
    let nodes = Dictionary(uniqueKeysWithValues: snapshot.gpuTypes.flatMap(\.nodes).map { ($0.name, $0) })

    check(nodes["udc-aw38-6"] == nil && nodes["udc-ba07-38"] == nil, "dedicated partition nodes are left out")
    check(nodes["udc-an26-7"] == nil, "nodes with no visible partition are left out")
    check(!nodes.isEmpty && nodes.values.allSatisfy { $0.gpuTotal > 0 }, "CPU nodes are left out")

    // 4 GPUs unallocated, but only 200 MB of memory left on the node.
    let starved = nodes["udc-an25-20"]!.counts
    check(starved.stranded == 4 && starved.ready == 0 && starved.backfill == 0, "out of memory: \(summary(starved))")

    let fullyUsed = nodes["udc-an25-24"]!.counts
    check(fullyUsed.inUse == 8 && fullyUsed.total == 8, "all allocated: \(summary(fullyUsed))")

    // A free GPU on a MIXED node with memory and CPUs to spare.
    let ready = nodes["udc-ba02-35"]!.counts
    check(ready.ready == 1 && ready.inUse == 7, "ready: \(summary(ready))")

    // The same, but MIXED+PLANNED.
    let planned = nodes["udc-an36-25"]!
    check(planned.isPlanned && planned.counts.backfill == 1 && planned.counts.ready == 0, "planned: \(summary(planned.counts))")
    check(planned.stateLabel == "Planned", "planned label")

    let draining = nodes["udc-an34-7"]!
    check(draining.counts.inUse == 1 && draining.counts.offline == 7 && draining.counts.ready == 0, "draining: \(summary(draining.counts))")
    check(draining.stateLabel == "Draining", "draining label")

    let down = nodes["udc-an36-13"]!
    check(down.counts.offline == 8 && down.stateLabel == "Down", "down: \(summary(down.counts))")
    check(down.reason != nil, "down node keeps its reason")

    // One of this node's eight GPUs is out of service: Gres says 7 while CfgTRES says 8.
    check(nodes["udc-an40-17"]!.gpuTotal == 7, "Gres count wins over CfgTRES")

    let types = snapshot.gpuTypes.map(\.type)
    check(types.contains("a100_80gb") && !types.contains("a100"), "A100 splits by memory variant: \(types)")
    check(types.contains("1g.24gb"), "MIG slices are their own type")
    check(snapshot.gpuTypes.allSatisfy { $0.counts.total == $0.nodes.map(\.gpuTotal).reduce(0, +) }, "every GPU lands in exactly one bucket")

    let starvedNode = nodes["udc-an25-20"]!
    check(abs(starvedNode.memoryFraction - Double(starvedNode.memoryAllocatedMB) / 257_000) < 0.0001, "node memory fraction")
    check(down.memoryFraction == 0, "a down node has nothing allocated")
    check(HPCNode(scontrolLine: "NodeName=n0 Gres=gpu:a40:8 State=DOWN Partitions=gpu")?.memoryFraction == 0, "no memory reported doesn't divide by zero")

    let a100Nodes = snapshot.gpuTypes.first { $0.type == "a100_80gb" }?.nodes ?? []
    check(a100Nodes.last?.isAvailable == false, "unavailable nodes sort last: \(a100Nodes.map(\.name))")

    let allNodes = Array(nodes.values)
    check(snapshot.memoryTotalMB == allNodes.map(\.memoryTotalMB).reduce(0, +), "cluster memory total adds up")
    check(snapshot.memoryAllocatedMB == allNodes.map(\.memoryAllocatedMB).reduce(0, +), "cluster memory allocated adds up")
    check(snapshot.memoryTotalMB == snapshot.gpuTypes.map(\.memoryTotalMB).reduce(0, +), "per-type memory sums to the cluster's")
    let a6000 = snapshot.gpuTypes.first { $0.type == "a6000" }
    check(a6000?.memoryTotalMB == a6000?.nodes.map(\.memoryTotalMB).reduce(0, +), "per-type memory total")

    let reservation = HPCNode(scontrolLine: "NodeName=n1 CPUAlloc=1 CPUEfctv=8 Gres=gpu:a40:8 RealMemory=64000 AllocMem=100 State=MIXED+RESERVED Partitions=gpu AllocTRES=gres/gpu=1")
    check(reservation?.counts.offline == 7, "reserved node isn't available")

    // CPUs ration the usable GPUs: 8 free, 2 CPUs left.
    let rationed = HPCNode(scontrolLine: "NodeName=n2 CPUAlloc=6 CPUEfctv=8 Gres=gpu:a40:8 RealMemory=640000 AllocMem=0 State=MIXED Partitions=gpu")
    check(rationed?.counts.ready == 2 && rationed?.counts.stranded == 6, "limited by CPUs")

    // Memory rations them too: 8 free, 13 GB left, 6 GB each.
    let tight = HPCNode(scontrolLine: "NodeName=n3 CPUAlloc=0 CPUEfctv=64 Gres=gpu:a40:8 RealMemory=13312 AllocMem=0 State=IDLE Partitions=gpu")
    check(tight?.counts.ready == 2 && tight?.counts.stranded == 6, "limited by memory")
}

func checkJobs() throws {
    let snapshot = try HPCSnapshot.parse(fixture("UVA_HPC"))
    let active = Dictionary(uniqueKeysWithValues: snapshot.activeJobs.map { ($0.id, $0) })
    let finished = Dictionary(uniqueKeysWithValues: snapshot.finishedJobs.map { ($0.id, $0) })

    check(snapshot.runningCount == 2 && snapshot.pendingCount == 3, "running \(snapshot.runningCount), pending \(snapshot.pendingCount)")
    check(snapshot.activeJobs.first?.phase == .running && snapshot.activeJobs.last?.phase == .pending, "running sorts above pending")

    let running = active["22300101"]!
    check(running.gpus == "2 × a6000", "typed GPU request: \(running.gpus ?? "nil")")
    check(running.elapsedSeconds == 86_400 + 14 * 3600 + 17 * 60 + 40, "elapsed")
    check(running.limitSeconds == 3 * 86_400, "limit")
    check(running.nodesOrReason == "udc-an38-13", "node list")
    check(running.started != nil && running.ended != nil, "dates parse")

    check(active["22300102_3"]?.name == "l2_b|sweep", "a | in a job name survives")
    check(active["22300102_3"]?.gpus == "2 GPUs", "untyped GPU request")

    let queued = active["22300103"]!
    check(queued.pendingExplanation == "Behind higher-priority jobs", "reason words: \(queued.pendingExplanation ?? "nil")")
    check(queued.started != nil && queued.ended == nil, "estimated start present, N/A end absent")
    check(queued.gpus == "1 × a100", "pending typed request")

    check(active["22300104_[0-3%1]"]?.pendingExplanation == "Waiting on a job dependency", "array job id")
    check(active["22300105"]?.pendingExplanation == "A required node is unavailable", "multi-part reason")

    check(finished["22300101"] == nil, "a running job isn't also listed as finished")
    check(snapshot.finishedJobs.first?.id == "22200004", "newest finished first")
    check(finished["22200001"]?.phase == .completed && finished["22200001"]?.exitSummary == nil, "clean exit")
    check(finished["22200001"]?.gpus == "2 GPUs", "untyped sacct GPUs")
    check(finished["22200002"]?.phase == .failed && finished["22200002"]?.exitSummary == "exit 1", "failed job")
    check(finished["22200002"]?.gpus == "1 × a100", "typed sacct GPUs")
    check(finished["22200003"]?.phase == .outOfMemory && finished["22200003"]?.exitSummary == "signal 125", "OOM job")
    check(finished["22200004"]?.phase == .cancelled, "CANCELLED by N")
    check(finished["22200004"]?.started == nil && finished["22200004"]?.nodesOrReason == nil, "never-started job")
    check(finished["20550949"]?.phase == .timedOut && finished["20550949"]?.gpus == nil, "CPU job timing out")
    check(finished["20550949"]?.elapsedSeconds == 86_419, "day-prefixed elapsed")

    // One part failing must leave the others readable.
    let partial = try HPCSnapshot.parse("@@ME\nme\n@@TZ\n-0400\n@@NODES\n@@RC 0\n@@ACTIVE\n@@RC 0\n@@FINISHED\nsacct: error: slurmdbd down\n@@RC 1\n@@END\n")
    check(partial.finishedJobsError == "sacct: error: slurmdbd down", "section error kept")
    check(partial.activeJobsError == nil && partial.finishedJobs.isEmpty, "other sections unaffected")
}

func checkAllocation() throws {
    let allocation = try HPCSnapshot.parse(fixture("UVA_HPC")).allocation
    check(allocation?.account == "takolab", "account")
    check(allocation?.grants.map(\.id) == [3922, 4807, 3346], "active soonest-ending first, then the rest: \(allocation?.grants.map(\.id) ?? [])")
    check(allocation?.activeGrants.map(\.id) == [3922, 4807], "shown grants: \(allocation?.activeGrants.map(\.id) ?? [])")
    check(allocation?.inactiveGrants.map(\.id) == [3346], "folded grants: \(allocation?.inactiveGrants.map(\.id) ?? [])")

    let renewal = allocation?.grants[0]
    check(renewal?.used == 112_039 && renewal?.description == "renewal", "renewal row")
    // MAM's own PercentUsed for these two rows: 1.12 and 14.09.
    check(Int(((renewal?.usedFraction ?? 0) * 10_000).rounded()) == 112, "renewal percent")
    let expired = allocation?.grants[2]
    check(Int(((expired?.usedFraction ?? 0) * 10_000).rounded()) == 1409, "expired percent")
    check(allocation?.grants[1].description == "", "blank description")
    check(allocation?.grants[1].usedFraction == 0, "untouched grant")

    let now = AllocationGrant.day("2026-10-30")!
    check(renewal?.phase(now: now) == .active, "active phase")
    check(expired?.phase(now: now) == .expired, "expired phase")

    let header = "Id,StartTime,EndTime,Allocated,Remaining,Active,Description"
    check(AllocationGrant(csvLine: header) == nil, "the header isn't a grant")
    check(header == RemoteScripts.allocationFields.joined(separator: ","), "parser and script agree on the columns")
    let quoted = AllocationGrant(csvLine: #"7,2026-01-01 00:00:00,infinity,100.000,40.500,True,"Dean's fund, ""year 2"""#)
    check(quoted?.description == #"Dean's fund, "year 2""#, "quoted description: \(quoted?.description ?? "nil")")
    check(quoted?.ends == nil && quoted?.starts != nil, "open-ended grant")
    check(quoted?.remaining == 41 && quoted?.used == 59, "fractional SUs round")
    let paused = AllocationGrant(csvLine: "8,2026-01-01 00:00:00,2099-01-01,100.000,100.000,False,")
    check(paused?.phase(now: now) == .inactive, "inactive before its end date isn't expired")
    let overdrawn = AllocationGrant(csvLine: "9,2026-01-01 00:00:00,2099-01-01,100.000,-5.000,True,")
    check(overdrawn?.used == 105 && overdrawn?.usedFraction == 1.05, "overdrawn")
    let empty = AllocationGrant(csvLine: "10,2026-01-01 00:00:00,2099-01-01,0.000,0.000,True,")
    check(empty?.usedFraction == 0, "an empty grant doesn't divide by zero")

    func parsed(_ section: String) throws -> HPCSnapshot {
        try HPCSnapshot.parse("@@ME\nme\n@@NODES\n@@RC 0\n@@ACTIVE\n@@RC 0\n@@FINISHED\n@@RC 0\n\(section)@@END\n")
    }
    // These are what MAM really printed: nothing at all for an unknown account, with exit 0.
    let unknown = try parsed("@@ALLOCATION\n@@RC 0\n")
    check(unknown.allocation == nil && unknown.allocationError == "No allocations listed for takolab", "unknown account: \(unknown.allocationError ?? "nil")")
    let stalled = try parsed("@@ALLOCATION\n@@RC 124\n")
    check(stalled.allocation == nil && stalled.allocationError == "Timed out", "timeout: \(stalled.allocationError ?? "nil")")
    let failed = try parsed("@@ALLOCATION\nFailed sending message\n@@RC 74\n")
    check(failed.allocationError == "Failed sending message" && failed.activeJobsError == nil, "failure stays in its section")
    // Only expired grants is still an answer, not an error.
    let lapsed = try parsed("@@ALLOCATION\n3346,2025-09-24 10:55:09,2026-09-24,10.000,8.000,False,new\n@@RC 0\n")
    check(lapsed.allocationError == nil && lapsed.allocation?.grants.first?.isActive == false, "no active grants")
}

func checkJobUsage() throws {
    let snapshot = try HPCSnapshot.parse(fixture("UVA_HPC"))
    check(snapshot.jobUsageError == nil, "a job with no steps yet isn't an error: \(snapshot.jobUsageError ?? "")")
    let active = Dictionary(uniqueKeysWithValues: snapshot.activeJobs.map { ($0.id, $0) })
    let finished = Dictionary(uniqueKeysWithValues: snapshot.finishedJobs.map { ($0.id, $0) })

    // Matches `seff` on the real job this came from, given its 10,089 seconds.
    let real = snapshot.jobUsage["22200001"]
    check(real?.cpuSeconds == 18636, "CPU time adds up across steps: \(real?.cpuSeconds ?? -1)")
    let realFraction = real?.cpuFraction(cpus: 8, elapsedSeconds: 10089) ?? 0
    check(abs(realFraction - 0.2309) < 0.0001, "CPU share as seff has it: \(realFraction)")
    check(real?.peakMemoryMB == 36557 && real?.currentMemoryMB == nil, "the biggest step, and no current RAM once finished: \(String(describing: real))")
    check(real?.gpuMemoryMB == 186926, "GPU memory: \(real?.gpuMemoryMB ?? -1)")
    let realGPU = real?.gpuFraction(gpus: finished["22200001"]?.gpuCount) ?? 0
    check(abs(realGPU - 0.905) < 0.0001, "GPU utilization per GPU: \(realGPU)")
    check(finished["22200001"]?.allocatedMemoryMB == 64 * 1024, "RAM reserved")

    let unsized = snapshot.gpuTypes.map(\.type).filter { HPCNode.gpuMemoryGB[$0] == nil }
    check(unsized.isEmpty, "every GPU type has a memory size: \(unsized)")
    check(finished["22200001"].flatMap(snapshot.gpuMemoryTotalMB) == 2 * 180 * 1024, "both GPUs' memory, going by the node")
    check((real?.gpuMemoryMB ?? .max) <= finished["22200001"].flatMap(snapshot.gpuMemoryTotalMB) ?? 0, "a real reading fits inside the total")
    check(finished["22200002"].flatMap(snapshot.gpuMemoryTotalMB) == nil, "a node the app hasn't listed has no total")
    check(active["22300103"].flatMap(snapshot.gpuMemoryTotalMB) == nil, "a pending job's reason isn't a node")

    let running = snapshot.jobUsage["22300101"]
    check(running?.cpuSeconds == 22 * 3600, "a finished step and a live one both count: \(running?.cpuSeconds ?? -1)")
    check(running?.currentMemoryMB == 30720 && running?.peakMemoryMB == 51200, "current and peak RAM: \(String(describing: running))")
    check(running?.gpuUtilization == 176 && running?.gpuMemoryMB == 170000, "GPU now, not from the finished step: \(String(describing: running))")

    let task = snapshot.jobUsage["22300102_3"]
    check(task != nil && task == snapshot.jobUsage["22341003"], "an array task is found by either ID")
    check(active["22300102_3"].map { task?.gpuFraction(gpus: $0.gpuCount) == nil } == true, "a live GPU job with no GPU numbers has no reading")

    check(snapshot.jobUsage["22200002"]?.hasGPUReading == false, "zero for both is no reading")
    check(abs((snapshot.jobUsage["22200002"]?.cpuSeconds ?? 0) - 446.402) < 0.001, "a fraction of a second")
    check(snapshot.jobUsage["22200003"]?.gpuFraction(gpus: 1) == 0, "memory held at 0% really is idle")
    check(snapshot.jobUsage["20550949"]?.cpuSeconds == 33 * 3600 + 42 * 60 + 24, "days in CPU time: \(snapshot.jobUsage["20550949"]?.cpuSeconds ?? -1)")
    check(snapshot.jobUsage["22200004"] == nil && snapshot.jobUsage["22300103"] == nil, "no steps, no usage")
    check(real?.cpuFraction(cpus: 8, elapsedSeconds: 0) == nil, "a job that hasn't run has no share")

    check(SlurmFormat.megabytes("37434428K") == 36557 && SlurmFormat.megabytes("186926M") == 186926 && SlurmFormat.megabytes("64G") == 65536, "memory units")
    check(SlurmFormat.megabytes("0") == 0 && SlurmFormat.megabytes("N/A") == nil, "no unit is bytes, and rubbish is nil")
    check(SlurmFormat.cpuSeconds("1-00:00:01") == 86401 && SlurmFormat.cpuSeconds("") == nil, "CPU time")

    let failed = try HPCSnapshot.parse("""
    @@STEPS
    9.batch|9.batch|cpu=00:01:00,mem=1024K|cpu=00:01:00,mem=1024K
    sacct: error: slurmdbd unavailable
    @@RC 1
    @@LIVE
    @@RC 124
    @@END
    """.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n"))
    check(failed.jobUsageError == "sacct: sacct: error: slurmdbd unavailable", "failure reported without the rows: \(failed.jobUsageError ?? "nil")")
    check(failed.jobUsage["9"]?.cpuSeconds == 60, "rows from before the failure are kept")
    let stalled = try HPCSnapshot.parse("@@STEPS\n@@RC 0\n@@LIVE\n@@RC 124\n@@END\n")
    check(stalled.jobUsageError == "sstat: Timed out", "a stalled sstat is reported: \(stalled.jobUsageError ?? "nil")")
    check(RemoteScripts.hpc.contains("sstat -a -j") && RemoteScripts.hpc.contains("TRESUsageInTot"), "the script asks for usage")
}

func checkJobHistory() throws {
    let history = try JobHistory.parse(fixture("UVA_HPC"))
    check(history.jobs.count == 10, "a job from two months' queries, or requeued, counts once: \(history.jobs.count)")
    check(history.jobs["100"]?.charge == 1000 && history.jobs["102_0"]?.charge == 147, "charges follow the billing rate")
    check(history.jobs["101"]?.charge == 0 && history.jobs["102_1"]?.charge == 0, "cancelled and failed jobs are free")
    check(history.jobs["103"]?.charge == 22, "a timed out job is charged")
    check(history.jobs["105"]?.charge == 0 && history.jobs["106"]?.charge == 0, "nothing is charged until a job ends")

    var sundayFirst = Calendar(identifier: .gregorian)
    sundayFirst.firstWeekday = 1
    let week = history.week(calendar: sundayFirst)
    check(week.count == 7 && week.map(\.count) == [0, 1, 0, 0, 0, 2, 0], "this week by day: \(week.map(\.count))")
    let month = history.month(calendar: sundayFirst)
    check(month.count == 31 && month.map(\.count).reduce(0, +) == 3, "this month by day: \(month.map(\.count))")
    let year = history.year(calendar: sundayFirst)
    check(year.map(\.count) == [1, 0, 1, 0, 0, 0, 0, 0, 4, 3, 0, 0], "counted when submitted, not when ended: \(year.map(\.count))")
    let totals = history.runningTotal(minimumMonths: 12, calendar: sundayFirst)
    check(totals.count >= 12 && totals.last?.count == history.jobs.count, "the running total ends at every job: \(totals.map(\.count))")
    check(zip(totals, totals.dropFirst()).allSatisfy { $0.count <= $1.count }, "a running total never falls")
    check(totals.first.map { sundayFirst.isDate($0.date, equalTo: history.firstSubmitted ?? .distantPast, toGranularity: .month) } == true
          || totals.count == 12, "the total starts at the first job's month, unless padded to a year")

    let grants = try HPCSnapshot.parse(fixture("UVA_HPC")).allocation?.grants ?? []
    let shares = history.charges(on: grants)
    check(shares[3346] == 1157, "charged on the grant open when the job ended: \(shares)")
    check(shares[3922] == 43, "overlapping grants charge the one ending soonest: \(shares)")
    check(shares[4807] == 0, "a newer grant nobody has charged yet: \(shares)")
    let narrow = try JobHistory.parse("@@HISTORY_WINDOW\n2026-01-01 2026-10-30\n@@HISTORY\n@@RC 0\n@@END\n")
    check(narrow.charges(on: grants)[3346] == nil, "a grant older than the history is left out")

    let newer = try JobHistory.parse("@@HISTORY_WINDOW\n2026-09-01 2026-10-31\n@@HISTORY\n105|2026-10-30T19:02:13|2026-10-30T19:02:13|2026-10-31T01:00:00|COMPLETED|3600|billing=100\n@@RC 0\n@@END\n")
    let merged = history.merged(with: newer)
    check(merged.jobs.count == 10 && merged.jobs["105"]?.charge == 10, "a newer fetch updates a job")
    check(merged.coveredFrom == history.coveredFrom && merged.today == newer.today, "merging keeps the widest coverage and the latest date")

    do {
        _ = try JobHistory.parse("@@HISTORY_WINDOW\n2026-01-01 2026-10-30\n@@HISTORY\n1|2026-01-02T00:00:00|2026-01-02T00:00:00|Unknown|RUNNING|0|\nsacct: error: Too wide of a date range in query\n@@RC 1\n@@END\n")
        check(false, "a failed month must be reported, not undercounted")
    } catch let failure as FetchFailure {
        check(failure.detail.hasPrefix("sacct: error"), "only the error reaches the message: \(failure.detail)")
    }
}

func checkLabMembers() throws {
    let lab = try LabMembers.parse(fixture("UVA_HPC"), account: "takolab")
    check(lab.members.map(\.id) == ["ab1cd", "me", "jl4kx", "tk2mq"], "busiest first, idle last: \(lab.members.map(\.id))")
    let alex = lab.members[0]
    check(alex.name == "Alex Doe" && alex.gpus == 4 && alex.cpus == 16 && alex.memoryMB == 256 * 1024, "Alex's running resources: \(alex.gpus) \(alex.cpus) \(alex.memoryMB)")
    check(alex.pendingJobs.map(\.id) == ["22300202"], "a queued job doesn't count as held")
    let me = lab.members[1]
    check(me.gpus == 2 && me.cpus == 12 && me.runningJobs.count == 2, "my running jobs: \(me.gpus) \(me.cpus)")
    check(lab.members[3].isIdle && lab.members[3].name == nil, "a member with no jobs and no name")
    check(lab.gpus == 6 && lab.activeCount == 3, "lab totals: \(lab.gpus) GPUs, \(lab.activeCount) active")
    check(RemoteScripts.labMembers.contains("squeue -a -A takolab -h -O \"UserName:|,JobID:|"), "user leads the squeue fields")
    check(RemoteScripts.labMembers.contains("printf '%s\\n' \"$users\""), "the shell gets a real newline escape")
}

func checkUserLookup() throws {
    let lookup = try UserLookup.parse(fixture("UVA_HPC"), id: "me")
    check(lookup.name == "Sam Student", "the name comes from getent: \(lookup.name ?? "nil")")
    check(lookup.runningGPUJobs.map(\.id) == ["22300101", "22300102_3"], "running GPU jobs: \(lookup.runningGPUJobs.map(\.id))")
    check(lookup.gpusNow == 4 && lookup.otherRunningCount == 1, "GPUs held now, and running jobs without any: \(lookup.gpusNow), \(lookup.otherRunningCount)")
    check(lookup.pendingGPUJobs.map(\.id) == ["22300103"], "pending GPU jobs: \(lookup.pendingGPUJobs.map(\.id))")
    let snapshot = try HPCSnapshot.parse(fixture("UVA_HPC"))
    let types = lookup.runningGPUJobs.map { snapshot.gpuType(of: $0) }
    check(types == ["a6000", "b200"], "a GPU's type comes from its node, also when the job didn't name one: \(types)")
    check(lookup.gpuSummary(snapshot: snapshot) == "2 × a6000, 2 × b200", "GPUs by type: \(lookup.gpuSummary(snapshot: snapshot))")

    let nobody = try UserLookup.parse("@@TZ\n-0400\n@@WHO\n@@JOBS\n@@RC 0\n@@END\n", id: "zz9zz")
    check(nobody.name == nil && !nobody.exists, "an ID the cluster doesn't know")
    let idle = try UserLookup.parse("@@TZ\n-0400\n@@WHO\nab1cd:\n@@JOBS\n@@RC 0\n@@END\n", id: "ab1cd")
    check(idle.exists && idle.gpusNow == 0 && idle.name == nil, "a known ID with nothing running and no name on file")
    check(RemoteScripts.userLookup("ab1cd").contains("squeue -a -u ab1cd"), "the script asks about that user")
}

func checkGPUHours() throws {
    let history = try JobHistory.parse(fixture("UVA_HPC"))
    let usage = history.gpuUsage
    check(abs(usage.totalHours - 43) < 0.001, "failed, cancelled and requeued runs held their GPUs, and a running job counts so far: \(usage.totalHours)")
    check(history.gpuRuns.count == 9, "no GPUs, or never started, means no hours; each run counts once: \(history.gpuRuns.count)")
    check(history.jobs["108"]?.charge == 10, "only a requeued job's last run is charged")

    var sundayFirst = Calendar(identifier: .gregorian)
    sundayFirst.firstWeekday = 1
    let months = usage.months(count: 12, through: history.today, calendar: sundayFirst).map(\.hours)
    check(months.count == 12 && months[0] == 20 && months[10] == 14 && months[11] == 6, "a job across two months is split between them: \(months)")
    let weeks = usage.weeks(count: 12, through: history.today, calendar: sundayFirst).map(\.hours)
    check(weeks.count == 12 && weeks[11] == 5 && weeks[10] == 0 && weeks[7] == 3, "hours per week, newest last: \(weeks)")
    let year = usage.year(holding: history.today, calendar: sundayFirst)
    let thisYear = sundayFirst.component(.year, from: history.today)
    let monthsThisYear = usage.months(count: 12, through: history.today, calendar: sundayFirst).filter { sundayFirst.component(.year, from: $0.date) == thisYear }
    check(year.count == 12 && year.allSatisfy { sundayFirst.component(.year, from: $0.date) == thisYear } && sundayFirst.component(.month, from: year[0].date) == 1,
          "this year is January to December: \(year.map(\.date))")
    check(abs(year.map(\.hours).reduce(0, +) - monthsThisYear.map(\.hours).reduce(0, +)) < 0.001 && year.map(\.hours).reduce(0, +) < usage.totalHours,
          "this year counts only its own months: \(year.map(\.hours))")
    let totals = usage.runningTotal(through: history.today, calendar: sundayFirst)
    check(totals.count == 12 && totals.first?.hours == 20 && abs((totals.last?.hours ?? 0) - 43) < 0.001, "the running total ends at the total: \(totals.map(\.hours))")
    check(GPUUsage(intervals: []).runningTotal(through: history.today).count == 1, "nothing used yet is still one month")
    check(GPUUsage(intervals: []).runningTotal(through: history.today, minimumMonths: 12).count == 12, "a short history still fills the chart")
    check(totals.count == usage.runningTotal(through: history.today, minimumMonths: 3, calendar: sundayFirst).count, "a longer history isn't cut short")

    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var ledger = ServerUsageLedger()
    ledger.observe(gpu: 0, pid: 10, elapsedSeconds: 3600, at: start)
    check(ledger.usage.totalHours == 1, "a process counts from when it really started: \(ledger.usage.totalHours)")
    ledger.observe(gpu: 0, pid: 10, elapsedSeconds: 7201, at: start.addingTimeInterval(3600))
    check(ledger.records.count == 1 && ledger.usage.totalHours == 2, "seeing it again extends it, across any gap: \(ledger.usage.totalHours)")
    ledger.observe(gpu: 0, pid: 11, elapsedSeconds: 1800, at: start.addingTimeInterval(3600))
    check(ledger.usage.totalHours == 2, "processes sharing a GPU count it once: \(ledger.usage.totalHours)")
    ledger.observe(gpu: 1, pid: 12, elapsedSeconds: 3600, at: start.addingTimeInterval(3600))
    check(ledger.usage.totalHours == 3, "another GPU adds its own: \(ledger.usage.totalHours)")
    ledger.observe(gpu: 0, pid: 10, elapsedSeconds: 3600, at: start.addingTimeInterval(86_400))
    check(ledger.records.count == 4 && ledger.usage.totalHours == 4, "a reused PID is a new process: \(ledger.usage.totalHours)")
    let saved = try ServerUsageLedger.decoded(from: ledger.encoded())
    check(saved == ledger, "the ledger survives saving")

    let snapshot = try ServerSnapshot.parse(fixture("ZheServer"))
    var seen = ServerUsageLedger()
    seen.observe(snapshot, at: start)
    let mine = snapshot.gpus.flatMap { $0.processes.filter { $0.user == snapshot.me } }
    check(!mine.isEmpty && seen.records.count == mine.count, "only the user's own processes are recorded: \(seen.records.count)")
}

func checkCharges() throws {
    // Real jobs: Slurm's billing weight against what MAM charged.
    for (billing, seconds, charged) in [(1468, 36742, 1498), (1468, 37437, 1527), (1499, 15388, 641), (1434, 13729, 547), (734, 21468, 438), (9, 86419, 22)] {
        let line = "1|gpu|RUNNING|\(seconds)||1|1|0|||billing=\(billing)||||||||n"
        let job = SlurmJob.parse(squeueLine: line, dates: SlurmFormat.dateParser(zoneLines: []))
        check(job?.billing == billing, "billing parsed from: \(line)")
        check(Int((job?.creditsSoFar ?? -1).rounded()) == charged, "billing \(billing) for \(seconds)s was charged \(charged), got \(job?.creditsSoFar ?? -1)")
    }

    let hpc = try HPCSnapshot.parse(fixture("UVA_HPC"))
    let running = hpc.runningJobs
    check(hpc.runningCount == 2 && running.allSatisfy { $0.billing != nil }, "running jobs carry billing: \(running.map(\.billing))")
    check(hpc.runningCreditsPerHour == running.compactMap(\.creditsPerHour).reduce(0, +), "rates add up")
    let pending = hpc.activeJobs.first { $0.phase == .pending }
    check(pending != nil && !running.contains { $0.id == pending?.id }, "a queued job isn't using SUs")

    check(Format.creditRate(1.6) == "1.6", "rate")
    check(Format.creditRate(1468) == "1,468.0", "large rate: \(Format.creditRate(1468))")
}

func checkStorage() throws {
    // 6597069766656 bytes total, 2085385928704 used.
    let server = try ServerSnapshot.parse(fixture("ZheServer"))
    check(server.storage?.path == "/p/simple" && server.storageError == nil, "server storage")
    check(server.storage?.totalMB == 6_291_456, "6 TiB in MB: \(String(describing: server.storage?.totalMB))")
    check(server.storage?.usedMB == 1_988_779, "used in MB: \(String(describing: server.storage?.usedMB))")

    func serverWith(_ section: String) throws -> ServerSnapshot {
        try ServerSnapshot.parse("@@GPUS\n0, X, u, 1, 2, 3, 4, 5, 6\n@@RC 0\n\(section)@@END\n")
    }
    // What df really printed for a bad path, and what a stalled NFS mount would leave behind.
    let badPath = try serverWith("@@DISK\ndf: /p/simple: No such file or directory\n@@RC 1\n")
    check(badPath.storage == nil && badPath.storageError == "df: /p/simple: No such file or directory", "df failure")
    check(badPath.gpus.count == 1, "a storage failure doesn't cost the GPU view")
    let stalled = try serverWith("@@DISK\n@@RC 124\n")
    check(stalled.storageError == "Timed out" && stalled.gpus.count == 1, "stalled NFS: \(stalled.storageError ?? "nil")")
    let killed = try serverWith("@@DISK\n@@RC 137\n")
    check(killed.storageError == "Timed out", "stalled NFS that needed SIGKILL: \(killed.storageError ?? "nil")")
    let autofsOnly = try serverWith("@@DISK\n    1B-blocks Used\n0 0\n@@RC 0\n")
    check(autofsOnly.storage == nil && autofsOnly.storageError == "Not reported", "a zero-size reply isn't a volume")

    let hpc = try HPCSnapshot.parse(fixture("UVA_HPC"))
    check(hpc.storageError == nil, "hpc storage error: \(hpc.storageError ?? "nil")")
    check(hpc.storage.map(\.path) == ["/home/me/scratch", "/standard/takolab"], "paths follow the signed-in user: \(hpc.storage.map(\.path))")
    let scratch = hpc.storage.first
    check(scratch?.totalMB == 10_485_760 && scratch?.usedMB == 558_694, "scratch sizes: \(String(describing: scratch))")
    check(Format.memory(mb: scratch?.usedMB ?? 0) == "546 GiB", "scratch used")
    let standard = hpc.storage.last
    check(Format.memory(mb: standard?.usedMB ?? 0) == "7.3 TiB" && Format.memory(mb: standard?.totalMB ?? 0) == "10.0 TiB", "standard sizes")

    let quota = StorageUsage.parseQuotaLine("Research Standard  /standard/takolab  10.0 TB  7.3 TB  2.7 TB  73%")
    check(quota?.location == "/standard/takolab", "a space in the first column")
    check(StorageUsage.parseQuotaLine("Storage Type       Location      Size  Used  Avail  Use%") == nil, "header")
    check(StorageUsage.parseQuotaLine("------------       --------      ----  ----  -----  ----") == nil, "rule")
    check(StorageUsage.parseQuotaLine(#"  File "/opt/rci/bin/hdquota", line 3, in <module>"#) == nil, "traceback")
    check(StorageUsage.parseQuotaLine("Scratch /scratch/x 10.0 XB 1.0 TB 9.0 TB 10%") == nil, "unknown unit")
    check(StorageUsage.parseQuotaLine("Scratch /scratch/x 12.0 TB 13.0 TB -1.0 TB 108%")?.used == 13_631_488, "over quota")

    func hpcWith(_ section: String) throws -> HPCSnapshot {
        try HPCSnapshot.parse("@@ME\nme\n@@NODES\n@@RC 0\n@@ACTIVE\n@@RC 0\n@@FINISHED\n@@RC 0\n\(section)@@END\n")
    }
    // hdquota skips a /standard directory it can't read, and still exits 0.
    let skipped = try hpcWith("@@STORAGE\nScratch /scratch/me 10.0 TB 1.0 TB 9.0 TB 10%\n@@RC 0\n")
    check(skipped.storage.map(\.path) == ["/home/me/scratch"], "the readable row stays")
    check(skipped.storageError == "Not reported for /standard/takolab", "skipped: \(skipped.storageError ?? "nil")")
    let failed = try hpcWith("@@STORAGE\nPermissionError: nope\n@@RC 1\n")
    check(failed.storage.isEmpty && failed.storageError == "PermissionError: nope", "hdquota failure")
    check(failed.activeJobsError == nil, "failure stays in its section")
    let timedOut = try hpcWith("@@STORAGE\n@@RC 124\n")
    check(timedOut.storageError == "Timed out", "hdquota timeout")
}

func checkFormats() {
    check(SlurmFormat.seconds("17:40") == 1060, "mm:ss")
    check(SlurmFormat.seconds("0:00") == 0, "zero")
    check(SlurmFormat.seconds("UNLIMITED") == nil, "unlimited")
    check(SlurmFormat.seconds("INVALID") == nil, "invalid")
    check(SlurmFormat.timeZone(offset: "-0400")?.secondsFromGMT() == -14400, "time zone offset")
    check(SlurmFormat.timeZone(offset: "garbage") == nil, "bad offset")

    // Slurm's real times for a 3-day job that crosses the end of daylight saving on Nov 1, 2026.
    let zoned = SlurmFormat.dateParser(zoneLines: ["-0400", "/usr/share/zoneinfo/America/New_York"])
    let start = zoned.date(from: "2026-10-30T18:30:02")!
    let end = zoned.date(from: "2026-11-02T17:30:03")!
    check(Int(end.timeIntervalSince(start)) == 3 * 86_400 + 1, "a job's span survives a clock change: \(end.timeIntervalSince(start))")
    let fallback = SlurmFormat.dateParser(zoneLines: ["-0400", "/etc/localtime"])
    check(fallback.timeZone.secondsFromGMT() == -14400, "without a zone name, the offset is the fallback")

    check(Format.duration(45) == "45s", "seconds")
    check(Format.duration(3 * 86_400 + 2 * 3600 + 5) == "3d 2h", "days and hours")
    check(Format.duration(5 * 3600 + 12 * 60) == "5h 12m", "hours and minutes")
    check(Format.duration(3 * 86_400) == "3d", "whole days")

    check(Format.memory(mb: 55_721) == "54 GiB", "tens of GiB: \(Format.memory(mb: 55_721))")
    check(Format.memory(mb: 200) == "0.2 GiB", "under 10 GiB keeps a decimal: \(Format.memory(mb: 200))")
    check(Format.memory(mb: 1_547_806) == "1.5 TiB", "TiB: \(Format.memory(mb: 1_547_806))")
    check(Format.memoryPair(usedMB: 13_841_203, totalMB: 29_989_273) == "13.2 / 28.6 TiB", "pair in TiB")
    check(Format.memoryPair(usedMB: 634_880, totalMB: 768_000) == "620 / 750 GiB", "pair in GiB")

    check(Format.credits(9_887_961) == "9,887,961", "credits: \(Format.credits(9_887_961))")
    check(Format.credits(0) == "0", "no credits")
    check(Format.percent(0.1409) == "14.1%", "percent: \(Format.percent(0.1409))")
    check(Format.percent(0) == "0%", "zero percent")
    check(Format.percent(0.00001) == "<0.1%", "a sliver doesn't read as zero")
    check(Format.day(AllocationGrant.day("2027-09-24")!) == "Sep 24, 2027", "day: \(Format.day(AllocationGrant.day("2027-09-24")!))")
    check(AllocationGrant.day("infinity") == nil, "infinity isn't a date")

    let timeout = SSH.describe(host: "UVA_HPC", user: "mst3k", stderr: "ssh: connect to host login.hpc.virginia.edu port 22: Operation timed out")
    check(timeout.headline.contains("VPN"), "HPC timeout mentions the VPN")
    let refused = SSH.describe(host: "ZheServer", user: "mst3k", stderr: "Permission denied (publickey).")
    check(refused.headline.contains("SSH key") && refused.headline.contains("mst3k"), "auth failure names the user: \(refused.headline)")
    // What the CS gateway answered for an ID it doesn't know.
    check(SSH.describe(host: "ZheServer", user: "x", stderr: "Received disconnect from 128.143.63.16 port 22:2: Too many authentication failures").headline.contains("SSH key"), "gateway refusal")
}

func checkSignIn() {
    check(ComputingID.normalized("  MST3K \n") == "mst3k", "trimmed and lowercased")
    check(ComputingID.normalized("abc1de") == "abc1de", "a plain ID")
    for bad in ["", "q", "5abc", "mst3k; rm -rf ~", "-oProxyCommand=x", "a b", "mst3k@host", "../etc"] {
        check(ComputingID.normalized(bad) == nil, "rejects \(bad.debugDescription)")
    }
    let direct = SSH.connectionArguments(machine: RemoteScripts.hpcMachine, user: "abc1de")
    check(direct == ["-l", "abc1de", "login.hpc.virginia.edu"], "HPC as the user: \(direct)")
    let jumped = SSH.connectionArguments(machine: RemoteScripts.serverMachine, user: "abc1de")
    check(jumped.suffix(3) == ["-l", "abc1de", "regieleki01.cs.virginia.edu"], "server as the user: \(jumped)")
    check(jumped.contains { $0.hasPrefix("ProxyCommand=") && $0.contains("BatchMode=yes") && $0.contains("-l abc1de") && $0.hasSuffix("portal.cs.virginia.edu") },
          "the gateway as the same user, never asking for a password")
    check(RemoteScripts.hpc.contains("--me") && !RemoteScripts.hpc.contains("/home/") && !RemoteScripts.hpc.contains("/scratch/"), "the HPC script names no user")
    check(!RemoteScripts.server.contains("/u/"), "the server script names no user")
}

func live(as user: String) async {
    do {
        let start = Date()
        let server = try await Fetch.server(as: user)
        print("ZheServer (\(server.hostname), as \(server.me)) in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
        print("  free \(server.count(.free)), partly \(server.count(.partlyFree)), full \(server.count(.full)) of \(server.gpus.count)")
        print("  utilization over 2 s: \(server.gpus.map { "\($0.index):\($0.utilizationPercent.map(String.init) ?? "?")%" }.joined(separator: " ")), load \(server.loadAverage.map { String($0) } ?? "?") on \(server.cpuCount ?? 0) cores")
        if let memory = server.memory {
            print("  CPU memory: \(Format.memory(mb: memory.usedMB)) / \(Format.memory(mb: memory.totalMB)) in use, \(Format.memory(mb: memory.availableMB)) available")
        }
        for job in server.myJobs {
            print("    usage: CPU \(job.cpuCores.map(Format.cores) ?? "?"), RAM \(job.ramMB.map { Format.memory(mb: $0) } ?? "?"), GPU memory \(job.memoryMiB.map { Format.memoryPair(usedMB: $0, totalMB: job.gpuMemoryTotalMiB) } ?? "?")")
            print("  my job: \(job.shortCommand), GPUs \(job.gpuIndexes), PIDs \(job.pids), \(job.memoryMiB.map { Format.gib(mib: $0) } ?? "?") GiB, \(job.elapsedSeconds.map(Format.duration) ?? "?"), in \(job.workDir ?? "?")")
        }
        if let storage = server.storage {
            print("  \(storage.path): \(Format.memory(mb: storage.usedMB)) / \(Format.memory(mb: storage.totalMB)) used")
        }
        if let error = server.storageError { print("  storage error: \(error)") }
        for gpu in server.gpus {
            let who = gpu.processes.map { "\($0.user ?? "?") \($0.shortCommand)" }.joined(separator: "; ")
            print("  GPU \(gpu.index): \(gpu.availability) \(Format.gib(mib: gpu.memoryUsedMiB))/\(Format.gib(mib: gpu.memoryTotalMiB)) GiB  \(who)")
        }
    } catch { print("ZheServer failed: \(error)") }
    do {
        let start = Date()
        let hpc = try await Fetch.hpc(as: user)
        print("UVA_HPC (as \(hpc.me)) in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
        print("  totals: \(summary(hpc.totals))")
        print("  CPU memory on GPU nodes: \(Format.memory(mb: hpc.memoryAllocatedMB)) / \(Format.memory(mb: hpc.memoryTotalMB)) allocated")
        for type in hpc.gpuTypes {
            print("  \(type.type) [\(type.partitions.joined(separator: ","))], \(type.nodes.count) nodes: \(summary(type.counts))")
            if HPCNode.gpuMemoryGB[type.type] == nil { print("    missing from HPCNode.gpuMemoryGB, so its jobs get no GPU memory bar") }
        }
        print("  jobs: \(hpc.runningCount) running, \(hpc.pendingCount) pending, \(hpc.finishedJobs.count) finished")
        for job in hpc.activeJobs + hpc.finishedJobs {
            guard let usage = hpc.jobUsage[job.id] else { continue }
            let cpu = usage.cpuFraction(cpus: job.cpus, elapsedSeconds: job.elapsedSeconds).map(Format.percent) ?? "?"
            let gpu = usage.gpuFraction(gpus: job.gpuCount).map(Format.percent) ?? "no reading"
            print("    \(job.id) \(job.phase.label): CPU \(cpu), RAM now \(usage.currentMemoryMB.map { Format.memory(mb: $0) } ?? "–"), peak \(Format.memory(mb: usage.peakMemoryMB)), GPU \(gpu), GPU memory \(Format.memory(mb: usage.gpuMemoryMB))")
        }
        if let error = hpc.jobUsageError { print("  job usage error: \(error)") }
        if let allocation = hpc.allocation {
            for grant in allocation.grants {
                print("    #\(grant.id) \(grant.phase(now: .now)) '\(grant.description)' \(grant.starts.map(Format.day) ?? "?") to \(grant.ends.map(Format.day) ?? "?"): \(Format.credits(grant.used)) / \(Format.credits(grant.allocated)), \(Format.percent(grant.usedFraction))")
            }
        }
        for storage in hpc.storage {
            print("  \(storage.path): \(Format.memory(mb: storage.usedMB)) / \(Format.memory(mb: storage.totalMB)) used")
        }
        for error in [hpc.nodesError, hpc.activeJobsError, hpc.finishedJobsError, hpc.allocationError, hpc.storageError].compactMap({ $0 }) { print("  section error: \(error)") }
    } catch { print("UVA_HPC failed: \(error)") }
    do {
        let history = try await Fetch.jobHistory(monthsBack: RemoteScripts.jobHistoryMonths, as: user)
        let total = { (slots: [ActivitySlot]) in slots.map(\.count).reduce(0, +) }
        print("Jobs submitted: \(total(history.week())) this week, \(total(history.month())) this month, \(total(history.year())) this year")
        let gpuUsage = history.gpuUsage
        print("GPU hours: \(Format.hours(gpuUsage.totalHours)) total, \(Format.hours(gpuUsage.months(count: 1, through: history.today)[0].hours)) this month, \(Format.hours(gpuUsage.weeks(count: 1, through: history.today)[0].hours)) this week")
        if let grants = try await Fetch.hpc(as: user).allocation?.grants {
            for grant in grants where grant.used > 0 {
                print("  Mine on \(grant.description.isEmpty ? "(unnamed)" : grant.description): \(history.charges(on: grants)[grant.id].map(Format.credits) ?? "unknown") of \(Format.credits(grant.used)) SUs")
            }
        }
    } catch { print("Job history failed: \(error)") }
    do {
        let lab = try await Fetch.labMembers(as: user)
        print("Lab members on \(lab.account): \(lab.members.count), \(lab.activeCount) running something, \(lab.gpus) GPUs held")
        for member in lab.members {
            print("  \(member.id): \(member.runningJobs.count) running, \(member.pendingJobs.count) queued, \(member.gpus) GPUs, \(member.cpus) CPUs, \(Format.memory(mb: member.memoryMB))")
        }
    } catch { print("Lab members failed: \(error)") }
}

func countParsed(path: String, parse: (String, DateFormatter) -> SlurmJob?) {
    let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    let dates = SlurmFormat.dateParser(zoneLines: ["-0400"])
    let lines = text.split(separator: "\n").map(String.init)
    let parsed = lines.compactMap { parse($0, dates) }
    let phases = Dictionary(grouping: parsed, by: \.phase.label).mapValues(\.count)
    let badDates = parsed.filter { $0.submitted == nil }.count
    print("\(lines.count) rows, \(parsed.count) parsed, \(badDates) without a submit time, phases: \(phases)")
}

let arguments = CommandLine.arguments.dropFirst()
/// Watches ZheServer's streamed utilization for a few seconds, as the app does while the page is open.
if arguments.first == "--stream" {
    guard let user = arguments.dropFirst().first.flatMap(ComputingID.normalized) else {
        print("usage: GPUWatchChecks --stream <computing ID>")
        exit(2)
    }
    let started = Date()
    var reader = UtilizationStream(gpuCount: nil)
    var readings = 0
    do {
        for try await line in SSH.lines(on: RemoteScripts.serverMachine, as: user, command: RemoteScripts.liveUtilization) {
            guard let reading = reader.feed(line) else { continue }
            readings += 1
            let busy = reading.keys.sorted().map { "\($0):\(reading[$0]!)%" }.joined(separator: " ")
            print(String(format: "%5.1fs  ", Date().timeIntervalSince(started)) + busy)
            if readings == 5 { break }
        }
    } catch {
        print("stream failed: \(error)")
        exit(1)
    }
    exit(0)
}

if arguments.first == "--live" {
    guard let user = arguments.dropFirst().first.flatMap(ComputingID.normalized) else {
        print("usage: GPUWatchChecks --live <computing ID>")
        exit(2)
    }
    await live(as: user)
    exit(0)
}
if arguments.first == "--squeue", let path = arguments.dropFirst().first {
    countParsed(path: path) { SlurmJob.parse(squeueLine: $0, dates: $1) }
    exit(0)
}
if arguments.first == "--sacct", let path = arguments.dropFirst().first {
    countParsed(path: path) { SlurmJob.parse(sacctLine: $0, dates: $1) }
    exit(0)
}

do {
    try checkServer()
    try checkServerJobs()
    try checkNodes()
    try checkJobs()
    try checkJobUsage()
    try checkAllocation()
    try checkStorage()
    try checkCharges()
    try checkJobHistory()
    try checkGPUHours()
    try checkUserLookup()
    try checkLabMembers()
    checkFormats()
    checkSignIn()
} catch {
    failures += 1
    print("FAIL: threw \(error)")
}
print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
