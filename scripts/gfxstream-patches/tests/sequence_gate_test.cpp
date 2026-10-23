// Tests gfxstream's SequenceGate (0001-sequence-gate.patch) on its own: the
// commands of one guest process, from several decoder threads, as VkDecoder
// runs them. run.sh builds it against a patched gfxstream tree.
#include <gfxstream/host/sequence_gate.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <functional>
#include <future>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

using gfxstream::host::SequenceGate;
using namespace std::chrono_literals;

namespace {

struct Process {
    explicit Process(SequenceGate::Clock::duration skipAfter, uint32_t start = 0) : counter(start), gate(&counter) {
        gate.setSkipAfter(skipAfter);
    }
    std::atomic<uint32_t> counter;
    SequenceGate gate;
    std::atomic<bool> exit{false};
    std::atomic<int> running{0};
    std::atomic<int> mostRunning{0};
    std::mutex lock;
    std::vector<uint32_t> order;
    std::vector<uint32_t> late;
    std::vector<std::pair<uint32_t, uint32_t>> skips;
};

// What VkDecoder does with one command: waits for its turn, runs it, and adds
// 1 to the counter (the generated code's fetch_add).
bool run(Process& p, uint32_t seqno, std::chrono::milliseconds work = 0ms) {
    SequenceGate::Ticket ticket;
    if (!p.gate.enter(seqno, p.exit, &ticket)) return false;
    int now = ++p.running;
    int most = p.mostRunning.load();
    while (now > most && !p.mostRunning.compare_exchange_weak(most, now)) {
    }
    {
        std::lock_guard<std::mutex> guard(p.lock);
        p.order.push_back(seqno);
        if (ticket.late) p.late.push_back(seqno);
        if (ticket.skipped) p.skips.push_back({ticket.skippedFirst, ticket.skippedLast});
    }
    if (work.count()) std::this_thread::sleep_for(work);
    --p.running;
    p.counter.fetch_add(1);
    return true;
}

int failures = 0;

void expect(bool ok, const std::string& what) {
    if (!ok) {
        std::printf("FAIL %s\n", what.c_str());
        failures++;
    }
}

std::string list(const std::vector<uint32_t>& numbers) {
    std::string out;
    for (uint32_t n : numbers) out += (out.empty() ? "" : " ") + std::to_string(n);
    return out;
}

// Four decoders, numbers dealt round-robin, every one sent at once: the gate
// runs them in order, one at a time, and skips nothing.
void inOrder() {
    Process p(1s);
    const uint32_t count = 400;
    std::vector<std::thread> decoders;
    for (uint32_t d = 0; d < 4; d++) {
        decoders.emplace_back([&p, d] {
            for (uint32_t seqno = d + 1; seqno <= count; seqno += 4) run(p, seqno);
        });
    }
    for (auto& t : decoders) t.join();
    std::vector<uint32_t> expected(count);
    for (uint32_t i = 0; i < count; i++) expected[i] = i + 1;
    expect(p.order == expected, "inOrder: order");
    expect(p.mostRunning == 1, "inOrder: one at a time");
    expect(p.late.empty() && p.skips.empty(), "inOrder: nothing late or skipped");
    expect(p.counter == count, "inOrder: counter");
    std::printf("ok   in order: %u commands from 4 decoders\n", count);
}

// The guest deadlock: thread A took 1 (a destroy) but sends it only after
// thread B's 2 and 3 (a submission and vkQueueWaitIdle inside the driver's
// lock) have run. Without skipping nothing ever runs; with it, 2 and 3 run
// after the wait, then 1 when it arrives, late.
void deadlock(bool skipping) {
    Process p(skipping ? 50ms : 0ms);
    std::promise<void> lockReleased;
    auto released = lockReleased.get_future();
    auto start = SequenceGate::Clock::now();
    std::thread b([&] {
        if (run(p, 2) && run(p, 3)) lockReleased.set_value();
    });
    std::thread a([&] {
        if (released.wait_for(skipping ? 5s : 300ms) == std::future_status::ready) run(p, 1);
    });
    a.join();
    if (!skipping) {
        expect(p.order.empty(), "deadlock without skipping: something ran");
        p.exit = true;
        b.join();
        std::printf("ok   without skipping: the deadlock stays (nothing ran in 300 ms)\n");
        return;
    }
    b.join();
    auto took = std::chrono::duration_cast<std::chrono::milliseconds>(SequenceGate::Clock::now() - start).count();
    expect(p.order == std::vector<uint32_t>({2, 3, 1}), "deadlock: order " + list(p.order));
    expect(p.late == std::vector<uint32_t>({1}), "deadlock: 1 late");
    expect(p.skips.size() == 1 && p.skips[0] == std::make_pair(1u, 1u), "deadlock: skipped 1 only");
    expect(p.mostRunning == 1, "deadlock: one at a time, the late one too");
    expect(p.counter == 3, "deadlock: counter");
    expect(took >= 50 && took < 2000, "deadlock: took " + std::to_string(took) + " ms");
    std::printf("ok   deadlock: %s after %lld ms, 1 ran late\n", list(p.order).c_str(), static_cast<long long>(took));
}

// 1 is missing, but 2 has arrived (its decoder waits): only 1 goes, 2 runs
// before 3 and 4, and 1 runs late.
void heldNumbersStay() {
    Process p(50ms);
    std::promise<void> done;
    auto doneFuture = done.get_future();
    std::thread c([&] { run(p, 2); });
    std::this_thread::sleep_for(5ms);
    std::thread b([&] {
        run(p, 3);
        run(p, 4);
        done.set_value();
    });
    std::thread a([&] {
        doneFuture.wait();
        run(p, 1);
    });
    a.join();
    b.join();
    c.join();
    expect(p.order == std::vector<uint32_t>({2, 3, 4, 1}), "heldNumbersStay: order " + list(p.order));
    expect(p.skips.size() == 1 && p.skips[0] == std::make_pair(1u, 1u), "heldNumbersStay: skipped 1 only");
    expect(p.mostRunning == 1, "heldNumbersStay: one at a time");
    std::printf("ok   held numbers stay: %s\n", list(p.order).c_str());
}

// Several missing (two threads blocked on the guest lock): all go at once.
void severalMissing() {
    Process p(50ms);
    std::promise<void> released;
    std::shared_future<void> releasedFuture = released.get_future().share();
    std::thread b([&] {
        run(p, 4);
        run(p, 5);
        released.set_value();
    });
    std::thread a1([&] {
        releasedFuture.wait();
        run(p, 2);
    });
    std::thread a2([&] {
        releasedFuture.wait();
        run(p, 1);
        run(p, 3);
    });
    a1.join();
    a2.join();
    b.join();
    expect(p.order.size() == 5 && p.order[0] == 4 && p.order[1] == 5, "severalMissing: 4 and 5 first: " + list(p.order));
    std::vector<uint32_t> late = p.late;
    std::sort(late.begin(), late.end());
    expect(late == std::vector<uint32_t>({1, 2, 3}), "severalMissing: 1 2 3 late");
    expect(p.skips.size() == 1 && p.skips[0] == std::make_pair(1u, 3u), "severalMissing: skipped 1..3 at once");
    expect(p.mostRunning == 1 && p.counter == 5, "severalMissing: one at a time, counter");
    std::printf("ok   several missing: %s\n", list(p.order).c_str());
}

// A command that runs long (a host wait) is not a gap: nothing is skipped.
void longCommand() {
    Process p(50ms);
    std::thread a([&] { run(p, 1, 300ms); });
    std::this_thread::sleep_for(10ms);
    std::thread b([&] { run(p, 2); });
    a.join();
    b.join();
    expect(p.order == std::vector<uint32_t>({1, 2}), "longCommand: order " + list(p.order));
    expect(p.skips.empty() && p.late.empty(), "longCommand: nothing skipped or late");
    std::printf("ok   a long command is no gap: %s\n", list(p.order).c_str());
}

// The numbers wrap around 2^32.
void wraps() {
    Process p(50ms, 0xfffffffeu);
    std::promise<void> released;
    auto releasedFuture = released.get_future();
    std::thread b([&] {
        run(p, 0u);
        run(p, 1u);
        released.set_value();
    });
    std::thread a([&] {
        releasedFuture.wait();
        run(p, 0xffffffffu);
    });
    a.join();
    b.join();
    expect(p.order == std::vector<uint32_t>({0u, 1u, 0xffffffffu}), "wraps: order " + list(p.order));
    expect(p.counter == 1u, "wraps: counter");
    std::printf("ok   wraps around\n");
}

}  // namespace

int main() {
    inOrder();
    deadlock(false);
    deadlock(true);
    heldNumbersStay();
    severalMissing();
    longCommand();
    wraps();
    if (failures) {
        std::printf("%d failed\n", failures);
        return 1;
    }
    std::printf("all passed\n");
    return 0;
}
