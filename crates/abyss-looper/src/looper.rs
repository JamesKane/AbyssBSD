// SPDX-License-Identifier: BSD-2-Clause

//! The looper and its cooperative executor
//! (`docs/design/looper-framework.md` §4).
//!
//! A looper is one thread hosting a set of tasks. It polls a task when its
//! waker has fired, and blocks on its [`EventSource`] when none is
//! runnable — so an idle looper costs zero CPU. A task's waker may fire
//! from another thread (a reply arriving from another looper), so the
//! ready set is shared and the event source is woken.
//!
//! Tasks live in an arena of slots. A completed task's slot is freed and
//! reused, so a long-lived looper running an unbounded number of short
//! tasks holds a bounded arena. Each slot carries a generation; a waker
//! names a slot *and* a generation, so a wake aimed at a finished task
//! whose slot has since been reused is recognised as stale and ignored.
//!
//! Tasks added before [`run`](Looper::run) go on with [`spawn`](Looper::spawn).
//! A running looper takes new tasks through a [`Spawner`] — a cloneable,
//! `Send` handle (looper-framework §10): a task already on the looper, or
//! another thread, queues a future, and the looper installs it at its next
//! turn. `Cap::bind` uses one to spawn a received capability's `serve`
//! loop onto the looper that received it (`broker-and-transport.md` §3.5).

use std::collections::VecDeque;
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Wake, Waker};

use crate::event_source::{EventSource, ThreadPark};

type Task = Pin<Box<dyn Future<Output = ()> + Send>>;

/// Names a task: its slot in the arena, and the generation occupying that
/// slot. A waker carries a `TaskId`; once the slot is reused at a higher
/// generation, a wake from the stale waker is recognised by the generation
/// mismatch and ignored.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct TaskId {
    index: u32,
    generation: u32,
}

/// One slot in the looper's task arena.
struct Slot {
    /// The task, or `None` once it has completed and before the slot is
    /// reused.
    task: Option<Task>,
    /// The generation of the task currently — or last — in this slot.
    /// Bumped when a task completes, so a stale waker is recognised.
    generation: u32,
    /// The waker for the task in this slot — a [`TaskWaker`] carrying the
    /// slot's current [`TaskId`].
    waker: Waker,
}

/// A single-threaded cooperative executor: a thread, its task arena, and a
/// run loop that polls tasks and blocks on the event source when idle.
pub struct Looper {
    slots: Vec<Slot>,
    /// Indices of freed slots, awaiting reuse.
    free: Vec<u32>,
    live: usize,
    shared: Arc<Shared>,
}

/// Cross-thread state: the ready set, the queue of tasks awaiting
/// installation, and the event source that wakes the looper's thread.
struct Shared {
    ready: Mutex<VecDeque<TaskId>>,
    /// Tasks queued through a [`Spawner`], not yet given a slot. The run
    /// loop drains this at the start of every turn.
    incoming: Mutex<Vec<Task>>,
    event_source: Arc<dyn EventSource>,
}

/// A cloneable, `Send` handle for adding tasks to a looper while it runs
/// (looper-framework §10).
///
/// [`spawn`](Self::spawn) queues a future; the looper installs it — gives
/// it a slot and an initial poll — at its next turn. A `Spawner` may be
/// used from a task already running on the looper, or from another thread
/// entirely.
#[derive(Clone)]
pub struct Spawner {
    shared: Arc<Shared>,
}

impl Spawner {
    /// Queue `future` to run on the looper. It is installed and first
    /// polled at the looper's next turn; queuing wakes the looper so an
    /// idle one picks the task up at once.
    pub fn spawn(&self, future: impl Future<Output = ()> + Send + 'static) {
        self.shared.incoming.lock().unwrap().push(Box::pin(future));
        self.shared.event_source.wake();
    }
}

/// The waker for one task. Marking the task ready and waking the looper's
/// event source is all it does — and both are thread-safe, because a
/// reply waking this task commonly arrives on another looper's thread.
struct TaskWaker {
    shared: Arc<Shared>,
    id: TaskId,
}

impl Wake for TaskWaker {
    fn wake(self: Arc<Self>) {
        self.wake_by_ref();
    }

    fn wake_by_ref(self: &Arc<Self>) {
        self.shared.ready.lock().unwrap().push_back(self.id);
        self.shared.event_source.wake();
    }
}

/// The waker for the task identified by `id`.
fn make_waker(shared: &Arc<Shared>, id: TaskId) -> Waker {
    Waker::from(Arc::new(TaskWaker {
        shared: Arc::clone(shared),
        id,
    }))
}

impl Looper {
    /// A new looper with no tasks, on the in-process event source.
    pub fn new() -> Self {
        Looper::with_event_source(Arc::new(ThreadPark::new()))
    }

    /// A new looper driven by a specific [`EventSource`]. The FreeBSD IPC
    /// backend supplies a `kqueue`-based one
    /// (`docs/design/broker-and-transport.md` §2.3); [`new`](Self::new)
    /// uses the in-process default.
    pub fn with_event_source(event_source: Arc<dyn EventSource>) -> Self {
        Looper {
            slots: Vec::new(),
            free: Vec::new(),
            live: 0,
            shared: Arc::new(Shared {
                ready: Mutex::new(VecDeque::new()),
                incoming: Mutex::new(Vec::new()),
                event_source,
            }),
        }
    }

    /// Add a task — a future the looper will drive to completion. Tasks
    /// are added before [`run`](Self::run); a running looper takes new
    /// tasks through a [`Spawner`].
    pub fn spawn(&mut self, future: impl Future<Output = ()> + Send + 'static) {
        self.install(Box::pin(future));
    }

    /// A [`Spawner`] for this looper — a handle that adds tasks to it while
    /// it runs. Cloneable and `Send`.
    pub fn spawner(&self) -> Spawner {
        Spawner {
            shared: self.shared.clone(),
        }
    }

    /// Install `task`: give it a slot — a freed one reused if there is one,
    /// otherwise a fresh one — a waker, and a place in the ready set for
    /// its initial poll.
    fn install(&mut self, task: Task) {
        let id = match self.free.pop() {
            Some(index) => {
                // A freed slot's generation was bumped when it was freed,
                // so the id this reuse forms is already distinct.
                let slot = &mut self.slots[index as usize];
                let id = TaskId {
                    index,
                    generation: slot.generation,
                };
                slot.task = Some(task);
                slot.waker = make_waker(&self.shared, id);
                id
            }
            None => {
                let index =
                    u32::try_from(self.slots.len()).expect("task-slot count stays within u32");
                let id = TaskId {
                    index,
                    generation: 0,
                };
                self.slots.push(Slot {
                    task: Some(task),
                    generation: 0,
                    waker: make_waker(&self.shared, id),
                });
                id
            }
        };
        self.live += 1;
        self.shared.ready.lock().unwrap().push_back(id);
    }

    /// Run on the current thread until every task has completed. A task
    /// completes when its future returns — for a handler's serve loop,
    /// when its inbox closes (`docs/design/looper-framework.md` §4, §8).
    pub fn run(mut self) {
        self.drive();
    }

    /// The run loop. Split from [`run`](Self::run) so a task can be driven
    /// without consuming the looper — `run` is the public, owned form.
    fn drive(&mut self) {
        self.shared.event_source.bind();
        loop {
            // Install any tasks queued through a `Spawner` since the last
            // turn — before snapshotting the ready set, so a freshly
            // installed task gets its initial poll this turn.
            let incoming: Vec<Task> = {
                let mut queue = self.shared.incoming.lock().unwrap();
                queue.drain(..).collect()
            };
            for task in incoming {
                self.install(task);
            }
            let batch: Vec<TaskId> = {
                let mut ready = self.shared.ready.lock().unwrap();
                ready.drain(..).collect()
            };
            if batch.is_empty() {
                if self.live == 0 {
                    break;
                }
                self.shared.event_source.wait();
                continue;
            }
            for id in batch {
                let index = id.index as usize;
                // A stale wake: the slot has been reused (its generation
                // moved on) or its task has already completed.
                if self.slots[index].generation != id.generation || self.slots[index].task.is_none()
                {
                    continue;
                }
                let waker = self.slots[index].waker.clone();
                let mut cx = Context::from_waker(&waker);
                let completed = self.slots[index]
                    .task
                    .as_mut()
                    .expect("task present")
                    .as_mut()
                    .poll(&mut cx)
                    .is_ready();
                if completed {
                    // Free the slot for reuse, and bump its generation so
                    // any waker still naming the finished task is ignored.
                    let slot = &mut self.slots[index];
                    slot.task = None;
                    slot.generation = slot.generation.wrapping_add(1);
                    self.free.push(id.index);
                    self.live -= 1;
                }
            }
        }
    }
}

impl Default for Looper {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::channel;
    use std::sync::Mutex;
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[test]
    fn a_task_spawns_another_through_a_spawner() {
        let mut looper = Looper::new();
        let spawner = looper.spawner();
        let log = Arc::new(Mutex::new(Vec::new()));

        let log_outer = Arc::clone(&log);
        looper.spawn(async move {
            log_outer.lock().unwrap().push("outer");
            // While the looper runs, queue a second task onto it.
            let log_inner = Arc::clone(&log_outer);
            spawner.spawn(async move {
                log_inner.lock().unwrap().push("inner");
            });
        });
        looper.run();

        assert_eq!(*log.lock().unwrap(), vec!["outer", "inner"]);
    }

    #[test]
    fn a_spawner_reaches_a_looper_from_another_thread() {
        let mut looper = Looper::new();
        let spawner = looper.spawner();
        let (tx, mut rx) = channel::<i32>(1);

        // A pre-run task keeps the looper alive until the message lands.
        let seen = Arc::new(Mutex::new(None));
        let seen_writer = Arc::clone(&seen);
        looper.spawn(async move {
            *seen_writer.lock().unwrap() = rx.recv().await.ok();
        });

        // Another thread spawns the task that sends — the spawn wakes the
        // looper whether it has parked on `recv` yet or not.
        let sender = std::thread::spawn(move || {
            spawner.spawn(async move {
                tx.send(7).await.expect("send onto the live looper");
            });
        });
        looper.run();
        sender.join().unwrap();

        assert_eq!(*seen.lock().unwrap(), Some(7));
    }

    #[test]
    fn completed_tasks_free_their_slots_for_reuse() {
        // A chain of short tasks: each, as it runs, queues the next through
        // the Spawner and then completes. No two are ever live at once, so
        // one freed slot serves the whole chain — the arena does not grow.
        fn spawn_next(spawner: Spawner, left: Arc<AtomicUsize>) {
            let next = spawner.clone();
            spawner.spawn(async move {
                if left.fetch_sub(1, Ordering::SeqCst) > 1 {
                    spawn_next(next, left);
                }
            });
        }

        let mut looper = Looper::new();
        let left = Arc::new(AtomicUsize::new(64));
        spawn_next(looper.spawner(), Arc::clone(&left));
        looper.drive();

        assert_eq!(
            left.load(Ordering::SeqCst),
            0,
            "every task in the chain ran"
        );
        assert!(
            looper.slots.len() <= 2,
            "a 64-task sequential chain reused its slot — the arena holds {}",
            looper.slots.len(),
        );
    }
}
