/*
 * CTABS Validation Benchmark
 *
 * Cache-Topology-Aware Binder Scheduling (CTABS) validation tool.
 * Extends the standard binder scheduling latency test with:
 *   - CPU topology discovery and per-tier latency tracking
 *   - CPU affinity pinning for controlled cluster experiments
 *   - Histogram + percentile statistics (p50/p90/p95/p99)
 *
 * Build: mmma native/libs/binder/tests (sibling of schd-dbg.cpp)
 * Usage:
 *   # Default mode — classify transactions by where they land organically
 *   schd-dbg-ctabs -i 10000 -pair 4
 *
 *   # Cluster-isolated: servers on cluster 0 (CPUs 0-3), clients on cluster 1 (CPUs 4-7)
 *   schd-dbg-ctabs -i 10000 -pair 4 -pin-servers 0f -pin-clients f0
 *
 *   # All threads on same cluster — CTABS should find same-cluster threads
 *   schd-dbg-ctabs -i 10000 -pair 4 -pin ff
 *
 *   # With tracing
 *   atrace --async_start sched binder_driver freq && \
 *     schd-dbg-ctabs -i 10000 -pair 4 -trace -deadline_us 2500
 */

#include <binder/Binder.h>
#include <binder/IBinder.h>
#include <binder/IPCThreadState.h>
#include <binder/IServiceManager.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#include <algorithm>
#include <iomanip>
#include <iostream>
#include <fstream>
#include <tuple>
#include <vector>

#include <pthread.h>
#include <sched.h>
#include <sys/wait.h>
#include <unistd.h>

using namespace std;
using namespace android;

/* ------------------------------------------------------------------ *
 *  Constants                                                         *
 * ------------------------------------------------------------------ */

enum BinderWorkerServiceCode {
    BINDER_NOP = IBinder::FIRST_CALL_TRANSACTION,
};

#define ASSERT(cond)                                                        \
    do {                                                                    \
        if (!(cond)) {                                                      \
            cerr << __func__ << ":" << __LINE__ << " condition:" << #cond   \
                 << " failed\n" << endl;                                    \
            exit(EXIT_FAILURE);                                             \
        }                                                                   \
    } while (0)

// A sync ratio above this threshold is considered "good"
#define GOOD_SYNC_MIN (0.6)

#define DUMP_PRECISION 2

/* ------------------------------------------------------------------ *
 *  CPU Topology Discovery                                             *
 * ------------------------------------------------------------------ *
 * Reads /sys/devices/system/cpu/cpuN/topology/{core_id,cluster_id}
 * at startup so we can classify each transaction pair into a tier.
 * On kernels that don't expose cluster_id, fall back to core_id
 * heuristics (cluster boundary = core_id reset to 0).
 */

struct CpuTopologyInfo {
    int cluster_id;     /* -1 if unknown */
    int core_id;        /* -1 if unknown */
    bool valid;
};

static CpuTopologyInfo g_topology[CPU_SETSIZE];
static int g_nr_cpus;

static int read_sysfs_int(const char *fmt, int cpu) {
    char path[256];
    snprintf(path, sizeof(path), fmt, cpu);
    ifstream f(path);
    int val = -1;
    f >> val;
    return val;
}

static void init_topology() {
    g_nr_cpus = min((int)sysconf(_SC_NPROCESSORS_CONF), CPU_SETSIZE);
    for (int cpu = 0; cpu < g_nr_cpus; cpu++) {
        g_topology[cpu].core_id = read_sysfs_int(
            "/sys/devices/system/cpu/cpu%d/topology/core_id", cpu);
        g_topology[cpu].cluster_id = read_sysfs_int(
            "/sys/devices/system/cpu/cpu%d/topology/cluster_id", cpu);
        g_topology[cpu].valid = (g_topology[cpu].core_id >= 0);
    }
}

/* Topology tier classification */
enum TopoTier : uint8_t {
    TIER_UNKNOWN        = 0,
    TIER_SAME_CORE,         /* same physical core (incl. same CPU) */
    TIER_SAME_CLUSTER,      /* same L2 cluster, different core    */
    TIER_CROSS_CLUSTER,     /* different cluster / package        */
    TIER_COUNT
};

static const char *TIER_NAME[] = {
    "unknown",
    "same_core",
    "same_cluster",
    "cross_cluster",
};

static TopoTier classify_tier(int cpu_a, int cpu_b) {
    if (cpu_a < 0 || cpu_b < 0 || cpu_a >= g_nr_cpus || cpu_b >= g_nr_cpus)
        return TIER_UNKNOWN;
    if (cpu_a == cpu_b)
        return TIER_SAME_CORE;
    if (g_topology[cpu_a].cluster_id >= 0 && g_topology[cpu_b].cluster_id >= 0 &&
        g_topology[cpu_a].cluster_id == g_topology[cpu_b].cluster_id)
        return TIER_SAME_CLUSTER;
    return TIER_CROSS_CLUSTER;
}

/* Apply CPU affinity mask to the current process.
 * mask_str is a hex string (e.g. "0f" for CPUs 0-3). */
static void set_affinity(const char *mask_str, const char *who) {
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);

    unsigned long mask;
    if (mask_str[0] == '0' && (mask_str[1] == 'x' || mask_str[1] == 'X'))
        mask = strtoul(mask_str + 2, nullptr, 16);
    else
        mask = strtoul(mask_str, nullptr, 16);

    for (int cpu = 0; cpu < g_nr_cpus && cpu < (int)sizeof(mask) * 8; cpu++) {
        if (mask & (1UL << cpu))
            CPU_SET(cpu, &cpuset);
    }

    int ret = sched_setaffinity(0, sizeof(cpuset), &cpuset);
    if (ret != 0) {
        perror("sched_setaffinity");
        cerr << who << ": failed to set affinity mask 0x" << hex << mask
             << dec << endl;
        exit(EXIT_FAILURE);
    }
}

/* ------------------------------------------------------------------ *
 *  Trace / deadline helpers                                          *
 * ------------------------------------------------------------------ */

static string trace_path = "/sys/kernel/debug/tracing";
static uint64_t deadline_us = 2500;
static int trace_mode = 0;          /* stop trace on deadline miss */

static bool trace_is_on() {
    fstream file;
    file.open(trace_path + "/tracing_on", ios::in);
    char on = '0';
    file >> on;
    return on == '1';
}

static void trace_stop() {
    ofstream file;
    file.open(trace_path + "/tracing_on", ios::out | ios::trunc);
    file << '0' << endl;
}

/* ------------------------------------------------------------------ *
 *  Pipe IPC helper                                                   *
 * ------------------------------------------------------------------ */

class Pipe {
    int m_readFd;
    int m_writeFd;
    Pipe(int readFd, int writeFd) : m_readFd{readFd}, m_writeFd{writeFd} {}
    Pipe(const Pipe &) = delete;
    Pipe &operator=(const Pipe &) = delete;
    Pipe &operator=(const Pipe &&) = delete;
public:
    Pipe(Pipe &&rval) noexcept {
        m_readFd = rval.m_readFd;
        m_writeFd = rval.m_writeFd;
        rval.m_readFd = 0;
        rval.m_writeFd = 0;
    }
    ~Pipe() {
        if (m_readFd) close(m_readFd);
        if (m_writeFd) close(m_writeFd);
    }
    void signal() { bool v = true; write(m_writeFd, &v, sizeof(v)); }
    void wait()   { bool v; read(m_readFd, &v, sizeof(v)); }
    template <typename T> void send(const T &v) { write(m_writeFd, &v, sizeof(T)); }
    template <typename T> void recv(T &v)       { read(m_readFd, &v, sizeof(T)); }

    static tuple<Pipe, Pipe> createPipePair() {
        int a[2], b[2];
        ASSERT(pipe(a) >= 0);
        ASSERT(pipe(b) >= 0);
        return make_tuple(Pipe(a[0], b[1]), Pipe(b[0], a[1]));
    }
};

/* ------------------------------------------------------------------ *
 *  Timing helpers                                                     *
 * ------------------------------------------------------------------ */

typedef chrono::time_point<chrono::high_resolution_clock> Tick;

static inline Tick tickNow() {
    return chrono::high_resolution_clock::now();
}

static inline uint64_t tickNanos(Tick &sta, Tick &end) {
    return uint64_t(chrono::duration_cast<chrono::nanoseconds>(end - sta).count());
}

/* ------------------------------------------------------------------ *
 *  EnhancedResults — histogram + percentile statistics                *
 * ------------------------------------------------------------------ *
 * Like the PerfTest.h Results class but self-contained so we don't
 * need to depend on libhwbinder.
 */

static const uint32_t kNumBuckets  = 128;
static const uint64_t kMaxBucketNS = 50ULL * 1000000;   /* 50 ms */
static const uint64_t kBucketNS    = kMaxBucketNS / kNumBuckets;

struct EnhancedResults {
    uint64_t  best         = UINT64_MAX;
    uint64_t  worst        = 0;
    uint64_t  transactions = 0;
    uint64_t  total_time   = 0;
    uint64_t  miss         = 0;          /* count of > deadline_us */
    uint32_t  buckets[kNumBuckets] = {0};
    bool      raw_dump     = false;
    list<uint64_t> *raw_data = nullptr;

    /* ---- modifiers ---- */

    void enable_raw() {
        raw_dump = true;
        if (!raw_data)
            raw_data = new list<uint64_t>;
        else
            raw_data->clear();
    }

    void add_time(uint64_t nano) {
        uint32_t idx = min(nano, kMaxBucketNS - 1) / kBucketNS;
        buckets[idx]++;

        best  = min(nano, best);
        worst = max(nano, worst);
        transactions++;
        total_time += nano;

        if (nano > deadline_us * 1000) {
            miss++;
            if (trace_mode) {
                trace_stop();
                cerr << endl
                     << "deadline triggered: halt & stop trace" << endl
                     << "log: " << trace_path << "/trace" << endl
                     << endl;
                exit(EXIT_FAILURE);
            }
        }

        if (raw_dump && raw_data)
            raw_data->push_back(nano);
    }

    /* ---- accessors ---- */

    double average_ms() const {
        return transactions ? (double)total_time / transactions / 1.0E6 : 0;
    }

    /* ---- JSON dumpers ---- */

    void dump_summary() const {
        double avg = average_ms();
        double bst = (double)best / 1.0E6;
        double wst = (double)worst / 1.0E6;
        cout << setprecision(DUMP_PRECISION)
             << "{\"avg\":"  << setw(DUMP_PRECISION + 2) << left << avg
             << ",\"wst\":"  << setw(DUMP_PRECISION + 2) << left << wst
             << ",\"bst\":"  << setw(DUMP_PRECISION + 2) << left << bst
             << ",\"miss\":" << left << miss
             << ",\"meetR\":" << setprecision(DUMP_PRECISION + 3) << left
             << (transactions ? (1.0 - (double)miss / transactions) : 0)
             << "}";
    }

    void dump_percentiles() const {
        uint64_t cur = 0;
        double p50 = 0, p90 = 0, p95 = 0, p99 = 0;
        for (uint32_t i = 0; i < kNumBuckets; i++) {
            double t = (double)(i * kBucketNS + kBucketNS / 2) / 1.0E6;
            cur += buckets[i];
            if (p50 == 0 && cur >= transactions * 0.50) p50 = t;
            if (p90 == 0 && cur >= transactions * 0.90) p90 = t;
            if (p95 == 0 && cur >= transactions * 0.95) p95 = t;
            if (p99 == 0 && cur >= transactions * 0.99) p99 = t;
        }
        cout << setprecision(DUMP_PRECISION + 1)
             << "{\"p50\":" << p50
             << ",\"p90\":" << p90
             << ",\"p95\":" << p95
             << ",\"p99\":" << p99
             << "}";
    }

    void flush_raw() {
        if (raw_dump && raw_data) {
            bool first = true;
            cout << "[";
            for (auto nano : *raw_data) {
                cout << (first ? "" : ",") << nano;
                first = false;
            }
            cout << "]" << endl;
            delete raw_data;
            raw_data = nullptr;
        }
    }
};

/* ------------------------------------------------------------------ *
 *  TieredStats — latency broken down by topology tier                 *
 * ------------------------------------------------------------------ */

struct TieredStats {
    EnhancedResults tier[TIER_COUNT];   /* indexed by TopoTier */
    uint64_t        count_by_tier[TIER_COUNT] = {0};

    void add_time(uint64_t nano, TopoTier t) {
        if (t < TIER_COUNT) {
            tier[t].add_time(nano);
            count_by_tier[t]++;
        }
    }

    void enable_raw() {
        for (int i = 0; i < TIER_COUNT; i++)
            tier[i].enable_raw();
    }

    /* Composite: combine all tiers into one total */
    EnhancedResults total() const {
        EnhancedResults sum;
        for (int i = 0; i < TIER_COUNT; i++) {
            const auto &t = tier[i];
            sum.transactions += t.transactions;
            sum.total_time   += t.total_time;
            sum.miss         += t.miss;
            if (t.best  < sum.best)  sum.best  = t.best;
            if (t.worst > sum.worst) sum.worst = t.worst;
            for (uint32_t b = 0; b < kNumBuckets; b++)
                sum.buckets[b] += t.buckets[b];
        }
        return sum;
    }

    void dump_tier(const char *label, int idx) const {
        cout << "      \"" << label << "\":";
        tier[idx].dump_summary();
        cout << "," << endl;
        cout << "      \"" << label << "_pct\":";
        tier[idx].dump_percentiles();
        cout << "," << endl;
        cout << "      \"" << label << "_n\":" << count_by_tier[idx];
    }

    void dump(const char *prefix) const {
        cout << "    \"" << prefix << "\": {" << endl;
        for (int i = 0; i < TIER_COUNT; i++) {
            dump_tier(TIER_NAME[i], i);
            if (i < TIER_COUNT - 1) cout << ",";
            cout << endl;
        }
        cout << "    }," << endl;
    }
};

/* Priority helper (free function so both onTransact and thread_start can use it) */
static int thread_pri() {
    struct sched_param param;
    int policy;
    pthread_getschedparam(pthread_self(), &policy, &param);
    return param.sched_priority;
}

/* ------------------------------------------------------------------ *
 *  BinderWorkerService — handles a NOP transaction                    *
 * ------------------------------------------------------------------ */

class BinderWorkerService : public BBinder {
public:
    BinderWorkerService() {}
    virtual ~BinderWorkerService() = default;

    virtual status_t onTransact(uint32_t code, const Parcel &data,
                                Parcel *reply, uint32_t flags = 0) {
        (void)flags;
        (void)data;
        (void)reply;
        switch (code) {
        case BINDER_NOP: {
            /*
             * Input:  [int32 caller_priority, int32 caller_cpu]
             * Output: [int32 priority_mismatch,
             *          int32 cpu_mismatch,
             *          int32 server_cpu]
             */
            int caller_prio = data.readInt32();
            int caller_cpu  = data.readInt32();

            int my_prio = thread_pri();
            int tier_h  = (caller_prio != my_prio) ? 1 : 0;

            int my_cpu   = sched_getcpu();
            int tier_s   = (my_cpu != caller_cpu) ? 1 : 0;

            reply->writeInt32(tier_h);
            reply->writeInt32(tier_s);
            reply->writeInt32(my_cpu);          /* CTABS: actual target CPU */
            return NO_ERROR;
        }
        default:
            return UNKNOWN_TRANSACTION;
        }
    }
};

/* ------------------------------------------------------------------ *
 *  Globals                                                            *
 * ------------------------------------------------------------------ */

static vector<sp<IBinder>> workers;

static int  g_no_process = 2;       /* total processes (servers + clients) */
static int  g_iterations = 100;
static int  g_payload_sz = 16;
static int  g_inherent   = 0;       /* global count of non-inherited prio */
static int  g_no_sync    = 0;       /* global count of non-sync txns */

/* Affinity masks (hex strings, null = no pinning) */
static const char *g_pin_servers = nullptr;
static const char *g_pin_clients = nullptr;

static String16 make_service_name(int num) {
    char buf[32];
    snprintf(buf, sizeof(buf), "%d", num);
    return String16("binderWorker") + String16(buf);
}

/* ------------------------------------------------------------------ *
 *  Transaction helpers                                                *
 * ------------------------------------------------------------------ */

static void fill_parcel(Parcel &data, int sz, int priority, int cpu) {
    ASSERT(sz >= (int)sizeof(uint32_t) * 2);
    data.writeInt32(priority);
    data.writeInt32(cpu);
    sz -= sizeof(uint32_t) * 2;
    while (sz > 0) {
        data.writeInt32(0);
        sz -= sizeof(uint32_t);
    }
}

struct ThreadArg {
    TieredStats *stats;
    int          target;
};

static void *thread_start(void *p) {
    ThreadArg *arg   = (ThreadArg *)p;
    int        target = arg->target;
    TieredStats *s   = arg->stats;

    Parcel data, reply;
    int caller_cpu = sched_getcpu();
    fill_parcel(data, g_payload_sz, thread_pri(), caller_cpu);

    Tick sta = tickNow();
    status_t ret = workers[target]->transact(BINDER_NOP, data, &reply);
    ASSERT(ret == NO_ERROR);
    Tick end = tickNow();
    uint64_t latency_ns = tickNanos(sta, end);

    /* Read extended reply: h, s, server_cpu */
    g_inherent += reply.readInt32();
    int cpu_mismatch = reply.readInt32();
    int server_cpu   = reply.readInt32();

    TopoTier tier = classify_tier(caller_cpu, server_cpu);
    s->add_time(latency_ns, tier);

    g_no_sync += cpu_mismatch;
    return nullptr;
}

/* Create a FIFO thread, send one transaction, wait for completion */
static void fifo_transaction(int target, TieredStats *stats) {
    pthread_t thread;
    pthread_attr_t attr;
    struct sched_param param;
    ThreadArg arg = { stats, target };

    ASSERT(!pthread_attr_init(&attr));
    ASSERT(!pthread_attr_setschedpolicy(&attr, SCHED_FIFO));
    param.sched_priority = sched_get_priority_max(SCHED_FIFO);
    ASSERT(!pthread_attr_setschedparam(&attr, &param));
    ASSERT(!pthread_create(&thread, &attr, thread_start, &arg));
    ASSERT(!pthread_join(thread, nullptr));
}

#define is_client(n)  ((n) >= (g_no_process / 2))

/* ------------------------------------------------------------------ *
 *  Worker process — server OR client half of a pair                   *
 * ------------------------------------------------------------------ */

static void worker_fx(int num, Pipe p) {
    ProcessState::self()->startThreadPool();
    sp<IServiceManager> sm = defaultServiceManager();
    sm->addService(make_service_name(num), new BinderWorkerService);

    /* Apply affinity pinning after service registration */
    if (is_client(num) && g_pin_clients)
        set_affinity(g_pin_clients, "client");
    else if (!is_client(num) && g_pin_servers)
        set_affinity(g_pin_servers, "server");

    /* Tell master we are ready */
    p.signal();
    p.wait();       /* wait for kick-off */

    int server_cnt = g_no_process / 2;
    for (int i = 0; i < server_cnt; i++) {
        if (num == i) continue;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        workers.push_back(sm->getService(make_service_name(i)));
#pragma clang diagnostic pop
    }

    /* Per-class + per-tier stats */
    TieredStats stats_fifo, stats_other;

    for (int i = 0; is_client(num) && i < g_iterations; i++) {
        int target = num % server_cnt;

        /* 1. FIFO thread transaction */
        fifo_transaction(target, &stats_fifo);

        /* 2. OTHER (calling thread) transaction */
        Parcel data, reply;
        int caller_cpu = sched_getcpu();
        fill_parcel(data, g_payload_sz, thread_pri(), caller_cpu);

        Tick sta = tickNow();
        ASSERT(NO_ERROR == workers[target]->transact(BINDER_NOP, data, &reply));
        Tick end = tickNow();
        uint64_t latency_ns = tickNanos(sta, end);

        g_inherent += reply.readInt32();
        int cpu_mismatch = reply.readInt32();
        int server_cpu   = reply.readInt32();
        g_no_sync += cpu_mismatch;

        TopoTier tier = classify_tier(caller_cpu, server_cpu);
        stats_other.add_time(latency_ns, tier);
    }

    /* Signal completion */
    p.signal();
    p.wait();

    /* Wait for kill signal, then dump results */
    p.wait();

    if (is_client(num)) {
        int     no_trans  = g_iterations * 2;
        double  sync_ratio = (double)(no_trans - g_no_sync) / no_trans;
        int     pair_idx   = num - server_cnt;

        cout << "  \"P" << pair_idx << "\": {" << endl;
        cout << "    \"SYNC\":\""
             << ((sync_ratio > GOOD_SYNC_MIN) ? "GOOD" : "POOR")
             << "\",\"S\":" << (no_trans - g_no_sync)
             << ",\"I\":" << no_trans
             << ",\"R\":" << sync_ratio << "," << endl;

        stats_fifo.dump("fifo_tiered");
        stats_other.dump("other_tiered");
        cout << "  }," << endl;
    }

    exit(g_inherent);
}

/* ------------------------------------------------------------------ *
 *  Process creation / orchestration helpers                           *
 * ------------------------------------------------------------------ */

static Pipe make_process(int num) {
    auto pair = Pipe::createPipePair();
    pid_t pid = fork();
    if (pid) {
        return std::move(get<0>(pair));
    } else {
        worker_fx(num, std::move(get<1>(pair)));
        return std::move(get<0>(pair));     /* never reached */
    }
}

static void wait_all(vector<Pipe> &v) {
    for (auto &p : v) p.wait();
}

static void signal_all(vector<Pipe> &v) {
    for (auto &p : v) p.signal();
}

/* ------------------------------------------------------------------ *
 *  Topology dump (for diagnostics)                                    *
 * ------------------------------------------------------------------ */

static void dump_topology() {
    cout << "  \"topology\": {" << endl;
    cout << "    \"nr_cpus\": " << g_nr_cpus << "," << endl;
    cout << "    \"cpus\": [";
    for (int cpu = 0; cpu < g_nr_cpus; cpu++) {
        if (cpu > 0) cout << ",";
        cout << endl;
        cout << "      {\"cpu\":" << cpu
             << ",\"core\":" << g_topology[cpu].core_id
             << ",\"cluster\":" << g_topology[cpu].cluster_id
             << "}";
    }
    cout << endl << "    ]" << endl;
    cout << "  }," << endl;
}

/* ------------------------------------------------------------------ *
 *  Help                                                               *
 * ------------------------------------------------------------------ */

static void usage(const char *prog) {
    cerr << "Usage: " << prog << " [options]" << endl
         << "  -i N               iterations per pair (default: 100)" << endl
         << "  -pair N            number of process pairs (default: 1)" << endl
         << "  -payload N         payload size in bytes (default: 16)" << endl
         << "  -deadline_us N     deadline in us (default: 2500)" << endl
         << "  -v                 verbose" << endl
         << "  -trace             stop trace on deadline miss" << endl
         << "  -pin MASK          pin all processes to MASK" << endl
         << "  -pin-servers MASK  pin server processes to MASK" << endl
         << "  -pin-clients MASK  pin client processes to MASK" << endl
         << endl
         << "  MASK is a hex CPU bitmap (e.g. 0f = CPUs 0-3)" << endl
         << endl
         << "  Examples:" << endl
         << "    " << prog << " -i 10000 -pair 4" << endl
         << "    " << prog << " -i 10000 -pair 4 -pin-servers 0f -pin-clients f0" << endl
         << "    " << prog << " -i 10000 -pair 4 -pin ff" << endl;
    exit(1);
}

/* ------------------------------------------------------------------ *
 *  Main                                                               *
 * ------------------------------------------------------------------ */

int main(int argc, char **argv) {
    /* Discover CPU topology first */
    init_topology();

    /* Parse arguments */
    for (int i = 1; i < argc; i++) {
        if (string(argv[i]) == "-h" || string(argv[i]) == "--help")
            usage(argv[0]);
        else if (string(argv[i]) == "-i") {
            g_iterations = atoi(argv[++i]);
        } else if (string(argv[i]) == "-pair") {
            g_no_process = 2 * atoi(argv[++i]);
        } else if (string(argv[i]) == "-payload") {
            g_payload_sz = atoi(argv[++i]);
        } else if (string(argv[i]) == "-deadline_us") {
            deadline_us = atoi(argv[++i]);
        } else if (string(argv[i]) == "-v") {
            /* verbose mode — accepted for backward compat */
        } else if (string(argv[i]) == "-trace") {
            trace_mode = 1;
        } else if (string(argv[i]) == "-pin") {
            const char *mask = argv[++i];
            g_pin_servers = mask;
            g_pin_clients = mask;
        } else if (string(argv[i]) == "-pin-servers") {
            g_pin_servers = argv[++i];
        } else if (string(argv[i]) == "-pin-clients") {
            g_pin_clients = argv[++i];
        } else {
            cerr << "Unknown option: " << argv[i] << endl;
            usage(argv[0]);
        }
    }

    if (trace_mode && !trace_is_on()) {
        cerr << "Trace is not running. Start with: atrace --async_start sched freq" << endl;
        exit(1);
    }

    /* Fork all worker processes */
    cout << "{" << endl;
    cout << "  \"cfg\": {" << endl;
    cout << "    \"pair\":" << (g_no_process / 2)
         << ",\"iterations\":" << g_iterations
         << ",\"payload\":" << g_payload_sz
         << ",\"deadline_us\":" << deadline_us;
    if (g_pin_servers)
        cout << ",\"pin_servers\":\"" << g_pin_servers << "\"";
    if (g_pin_clients && g_pin_clients != g_pin_servers)
        cout << ",\"pin_clients\":\"" << g_pin_clients << "\"";
    cout << endl << "  }," << endl;

    dump_topology();

    vector<Pipe> pipes;
    for (int i = 0; i < g_no_process; i++)
        pipes.push_back(make_process(i));

    wait_all(pipes);        /* init complete */
    signal_all(pipes);      /* kick-off    */
    wait_all(pipes);        /* done        */
    signal_all(pipes);      /* collect     */

    for (int i = 0; i < g_no_process; i++) {
        int status;
        pipes[i].signal();
        wait(&status);
        g_inherent += status;
    }

    cout << "  \"inheritance\": " << (g_inherent == 0 ? "\"PASS\"" : "\"FAIL\"") << endl;
    cout << "}" << endl;
    return -g_inherent;
}
