// SPDX-License-Identifier: BSD-2-Clause

//! The Phase 2 multi-looper harness — the framework proven end to end on
//! the in-process backend (`docs/design/looper-framework.md` §11).

use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll, Waker};
use std::thread;
use std::time::Duration;

use abyss_cap::{Cap, Interface, Rights, SubsetOf, cap_channel};
use abyss_looper::{Ctx, Handler, Looper, RingClosed, block_on};
use abyss_msg_derive::{Method, Request};

// --- test interfaces -------------------------------------------------------

#[allow(dead_code)] // a marker type — only ever used as a type parameter
struct Echo;
impl Interface for Echo {
    const ID: u32 = 1;
    type Message = EchoMsg;
}

/// The one request `Echo` carries — `Ping`, answered with its value.
#[derive(Method, Request)]
enum EchoMsg {
    #[request(reply = i32)]
    Ping(Ping),
}

/// A `Ping` request payload.
struct Ping {
    value: i32,
}

#[allow(dead_code)]
struct Work;
impl Interface for Work {
    const ID: u32 = 2;
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

/// Replies to every `Ping` with its value, through the responder the
/// framework delivered in the `Ctx`.
struct EchoHandler;
impl Handler for EchoHandler {
    type Message = EchoMsg;
    async fn handle(&mut self, msg: EchoMsg, ctx: &Ctx) {
        let EchoMsg::Ping(ping) = msg;
        if let Some(responder) = ctx.responder::<i32>() {
            let _ = responder.send(ping.value);
        }
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
        let _ = self.helper.call(Ping { value: n }).await;
        self.log.lock().unwrap().push(Step::End(n));
    }
}

/// A one-shot gate: [`Gate::wait`] parks the caller until [`Gate::open`].
///
/// This gives the multi-handler scheduling test a *deterministic*
/// suspension point. A cross-looper `call` suspends only if its reply has
/// not already arrived — a race the in-process backend loses on a fast
/// host — so concurrency between handlers is tested against a gate the
/// test itself controls, not against thread timing.
#[derive(Clone)]
struct Gate(Arc<Mutex<GateState>>);

struct GateState {
    open: bool,
    waker: Option<Waker>,
}

impl Gate {
    fn new() -> Self {
        Gate(Arc::new(Mutex::new(GateState {
            open: false,
            waker: None,
        })))
    }

    /// Open the gate, waking the parked waiter if there is one.
    fn open(&self) {
        let mut g = self.0.lock().unwrap();
        g.open = true;
        if let Some(w) = g.waker.take() {
            w.wake();
        }
    }

    /// A future that is `Pending` until [`open`](Self::open) is called.
    fn wait(&self) -> GateWait {
        GateWait(self.0.clone())
    }
}

struct GateWait(Arc<Mutex<GateState>>);

impl Future for GateWait {
    type Output = ();
    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<()> {
        let mut g = self.0.lock().unwrap();
        if g.open {
            Poll::Ready(())
        } else {
            g.waker = Some(cx.waker().clone());
            Poll::Pending
        }
    }
}

/// Parks on the gate mid-handling: records `Start`, waits, records `End`.
struct GateWaiter {
    gate: Gate,
    log: Arc<Mutex<Vec<Step>>>,
}
impl Handler for GateWaiter {
    type Message = i32;
    async fn handle(&mut self, n: i32, _ctx: &Ctx) {
        self.log.lock().unwrap().push(Step::Start(n));
        self.gate.wait().await;
        self.log.lock().unwrap().push(Step::End(n));
    }
}

/// Synchronous: records `Note`, then opens the gate to release the waiter.
struct GateOpener {
    gate: Gate,
    log: Arc<Mutex<Vec<Step>>>,
}
impl Handler for GateOpener {
    type Message = i32;
    async fn handle(&mut self, n: i32, _ctx: &Ctx) {
        self.log.lock().unwrap().push(Step::Note(n));
        self.gate.open();
    }
}

// --- tests -----------------------------------------------------------------

#[test]
fn call_reply_across_loopers() {
    let (echo_cap, echo_rx) = cap_channel::<Echo, Full>(8);
    let mut svc = Looper::new();
    svc.attach_service(EchoHandler, echo_rx);
    let svc_thread = thread::spawn(move || svc.run());

    let reply = block_on(echo_cap.call(Ping { value: 99 })).unwrap();
    assert_eq!(reply, 99);

    drop(echo_cap); // service inbox closes → serve loop ends → run returns
    svc_thread.join().unwrap();
}

#[test]
fn per_handler_serialization_holds_across_await() {
    let (helper_cap, helper_rx) = cap_channel::<Echo, Full>(8);
    let mut helper = Looper::new();
    helper.attach_service(EchoHandler, helper_rx);
    let helper_thread = thread::spawn(move || helper.run());

    let log = Arc::new(Mutex::new(Vec::new()));
    let (work_cap, work_rx) = cap_channel::<Work, Full>(8);
    let mut worker = Looper::new();
    worker.attach_service(
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
    let log = Arc::new(Mutex::new(Vec::new()));
    let gate = Gate::new();

    // One looper, two handlers, each given one message up front. `A` (the
    // waiter) parks on the gate mid-handling; `B` (the opener) is
    // synchronous and opens it. The gate makes the suspension
    // deterministic — the test does not race thread timing.
    let (a_cap, a_rx) = cap_channel::<Work, Full>(8);
    let (b_cap, b_rx) = cap_channel::<Work, Full>(8);
    a_cap.try_send(0).unwrap();
    b_cap.try_send(100).unwrap();
    drop(a_cap);
    drop(b_cap);

    let mut looper = Looper::new();
    looper.attach_service(
        GateWaiter {
            gate: gate.clone(),
            log: Arc::clone(&log),
        },
        a_rx,
    );
    looper.attach_service(
        GateOpener {
            gate,
            log: Arc::clone(&log),
        },
        b_rx,
    );
    let looper_thread = thread::spawn(move || looper.run());
    looper_thread.join().unwrap();

    // A starts and parks on the gate; B runs to completion and opens it;
    // A then resumes — concurrency between handlers, with each handler
    // still strictly sequential within itself.
    assert_eq!(
        *log.lock().unwrap(),
        [Step::Start(0), Step::Note(100), Step::End(0)],
    );
}

#[test]
fn a_narrowed_capability_still_works() {
    let (echo_cap, echo_rx) = cap_channel::<Echo, Full>(8);
    let mut svc = Looper::new();
    svc.attach_service(EchoHandler, echo_rx);
    let svc_thread = thread::spawn(move || svc.run());

    let limited: Cap<Echo, ReadOnly> = echo_cap.narrow::<ReadOnly>();
    let reply = block_on(limited.call(Ping { value: 5 })).unwrap();
    assert_eq!(reply, 5);

    drop(limited);
    svc_thread.join().unwrap();
}

#[test]
fn a_call_to_a_gone_service_is_ring_closed() {
    let (echo_cap, echo_rx) = cap_channel::<Echo, Full>(2);
    drop(echo_rx); // no service ever attached
    let result = block_on(echo_cap.call(Ping { value: 1 }));
    assert_eq!(result, Err(RingClosed));
}

#[test]
fn a_looper_survives_an_idle_period() {
    let (echo_cap, echo_rx) = cap_channel::<Echo, Full>(8);
    let mut svc = Looper::new();
    svc.attach_service(EchoHandler, echo_rx);
    let svc_thread = thread::spawn(move || svc.run());

    // The looper goes fully idle — it must park (zero CPU), not spin or
    // exit — and still be responsive afterward.
    thread::sleep(Duration::from_millis(50));

    let reply = block_on(echo_cap.call(Ping { value: 42 })).unwrap();
    assert_eq!(reply, 42);

    drop(echo_cap);
    svc_thread.join().unwrap();
}
