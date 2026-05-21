//! The Phase 2 multi-looper harness — the framework proven end to end on
//! the in-process backend (`docs/design/looper-framework.md` §11).

use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use abyss_cap::{Cap, Interface, Rights, SubsetOf, cap_channel};
use abyss_looper::{Ctx, Handler, Looper, RingClosed, Sender, block_on};

// --- test interfaces -------------------------------------------------------

#[allow(dead_code)] // a marker type — only ever used as a type parameter
struct Echo;
impl Interface for Echo {
    type Message = EchoMsg;
}

/// One request: reply to `reply` with `value`.
enum EchoMsg {
    Ping { value: i32, reply: Sender<i32> },
}

#[allow(dead_code)]
struct Work;
impl Interface for Work {
    type Message = i32;
}

// --- test rights -----------------------------------------------------------

#[allow(dead_code)]
struct Full;
#[allow(dead_code)]
struct ReadOnly;
impl Rights for Full {}
impl Rights for ReadOnly {}
impl SubsetOf<Full> for ReadOnly {}

// --- handlers --------------------------------------------------------------

/// A trace step, so a test can assert the exact processing order.
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
enum Step {
    Start(i32),
    End(i32),
    Note(i32),
}

/// Replies to every `Ping` with its value.
struct EchoHandler;
impl Handler for EchoHandler {
    type Message = EchoMsg;
    async fn handle(&mut self, msg: EchoMsg, _ctx: &Ctx) {
        let EchoMsg::Ping { value, reply } = msg;
        let _ = reply.send(value).await;
    }
}

/// For each work item: record `Start`, make a call that suspends this
/// handler, then record `End`.
struct WorkHandler {
    helper: Cap<Echo, Full>,
    log: Arc<Mutex<Vec<Step>>>,
}
impl Handler for WorkHandler {
    type Message = i32;
    async fn handle(&mut self, n: i32, _ctx: &Ctx) {
        self.log.lock().unwrap().push(Step::Start(n));
        let _ = self
            .helper
            .call(|reply| EchoMsg::Ping { value: n, reply })
            .await;
        self.log.lock().unwrap().push(Step::End(n));
    }
}

/// Synchronous — records `Note` and is done; never `.await`s.
struct NoteHandler {
    log: Arc<Mutex<Vec<Step>>>,
}
impl Handler for NoteHandler {
    type Message = i32;
    async fn handle(&mut self, n: i32, _ctx: &Ctx) {
        self.log.lock().unwrap().push(Step::Note(n));
    }
}

// --- tests -----------------------------------------------------------------

#[test]
fn call_reply_across_loopers() {
    let (echo_cap, echo_rx) = cap_channel::<Echo, Full>(8);
    let mut svc = Looper::new();
    svc.attach(EchoHandler, echo_rx);
    let svc_thread = thread::spawn(move || svc.run());

    let reply = block_on(echo_cap.call(|reply| EchoMsg::Ping { value: 99, reply })).unwrap();
    assert_eq!(reply, 99);

    drop(echo_cap); // service inbox closes → serve loop ends → run returns
    svc_thread.join().unwrap();
}

#[test]
fn per_handler_serialization_holds_across_await() {
    let (helper_cap, helper_rx) = cap_channel::<Echo, Full>(8);
    let mut helper = Looper::new();
    helper.attach(EchoHandler, helper_rx);
    let helper_thread = thread::spawn(move || helper.run());

    let log = Arc::new(Mutex::new(Vec::new()));
    let (work_cap, work_rx) = cap_channel::<Work, Full>(8);
    let mut worker = Looper::new();
    worker.attach(
        WorkHandler {
            helper: helper_cap,
            log: Arc::clone(&log),
        },
        work_rx,
    );
    let worker_thread = thread::spawn(move || worker.run());

    // Three items queued before the worker can finish the first. Each
    // `handle` suspends on a helper call mid-processing.
    for n in 0..3 {
        block_on(work_cap.send(n)).unwrap();
    }
    drop(work_cap);
    worker_thread.join().unwrap();
    helper_thread.join().unwrap();

    // Strictly one at a time, in order — never interleaved.
    assert_eq!(
        *log.lock().unwrap(),
        [
            Step::Start(0),
            Step::End(0),
            Step::Start(1),
            Step::End(1),
            Step::Start(2),
            Step::End(2),
        ],
    );
}

#[test]
fn other_handlers_progress_while_one_awaits() {
    let (helper_cap, helper_rx) = cap_channel::<Echo, Full>(8);
    let mut helper = Looper::new();
    helper.attach(EchoHandler, helper_rx);
    let helper_thread = thread::spawn(move || helper.run());

    let log = Arc::new(Mutex::new(Vec::new()));

    // One looper, two handlers. `A` (work) suspends on a helper call;
    // `B` (note) is synchronous. Each is given one message up front.
    let (a_cap, a_rx) = cap_channel::<Work, Full>(8);
    let (b_cap, b_rx) = cap_channel::<Work, Full>(8);
    a_cap.try_send(0).unwrap();
    b_cap.try_send(100).unwrap();
    drop(a_cap);
    drop(b_cap);

    let mut looper = Looper::new();
    looper.attach(
        WorkHandler {
            helper: helper_cap,
            log: Arc::clone(&log),
        },
        a_rx,
    );
    looper.attach(
        NoteHandler {
            log: Arc::clone(&log),
        },
        b_rx,
    );
    let looper_thread = thread::spawn(move || looper.run());

    looper_thread.join().unwrap();
    helper_thread.join().unwrap();

    // A starts and suspends on its call; B runs to completion during that
    // suspension; A then resumes — concurrency between handlers, with
    // each handler still strictly sequential.
    assert_eq!(
        *log.lock().unwrap(),
        [Step::Start(0), Step::Note(100), Step::End(0)],
    );
}

#[test]
fn a_narrowed_capability_still_works() {
    let (echo_cap, echo_rx) = cap_channel::<Echo, Full>(8);
    let mut svc = Looper::new();
    svc.attach(EchoHandler, echo_rx);
    let svc_thread = thread::spawn(move || svc.run());

    let limited: Cap<Echo, ReadOnly> = echo_cap.narrow::<ReadOnly>();
    let reply = block_on(limited.call(|reply| EchoMsg::Ping { value: 5, reply })).unwrap();
    assert_eq!(reply, 5);

    drop(limited);
    svc_thread.join().unwrap();
}

#[test]
fn a_call_to_a_gone_service_is_ring_closed() {
    let (echo_cap, echo_rx) = cap_channel::<Echo, Full>(2);
    drop(echo_rx); // no service ever attached
    let result = block_on(echo_cap.call(|reply| EchoMsg::Ping { value: 1, reply }));
    assert_eq!(result, Err(RingClosed));
}

#[test]
fn a_looper_survives_an_idle_period() {
    let (echo_cap, echo_rx) = cap_channel::<Echo, Full>(8);
    let mut svc = Looper::new();
    svc.attach(EchoHandler, echo_rx);
    let svc_thread = thread::spawn(move || svc.run());

    // The looper goes fully idle — it must park (zero CPU), not spin or
    // exit — and still be responsive afterward.
    thread::sleep(Duration::from_millis(50));

    let reply = block_on(echo_cap.call(|reply| EchoMsg::Ping { value: 42, reply })).unwrap();
    assert_eq!(reply, 42);

    drop(echo_cap);
    svc_thread.join().unwrap();
}
