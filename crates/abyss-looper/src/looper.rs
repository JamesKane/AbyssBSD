//! The looper and its cooperative executor
//! (`docs/design/looper-framework.md` §4).
//!
//! A looper is one thread hosting a set of tasks. It polls a task when its
//! waker has fired, and parks the thread when none is runnable — so an
//! idle looper costs zero CPU. A task's waker may fire from another
//! thread (a reply arriving from another looper), so the ready set is
//! shared and the thread is unparked.

use std::collections::VecDeque;
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Wake, Waker};
use std::thread::{self, Thread};

type Task = Pin<Box<dyn Future<Output = ()> + Send>>;

/// A single-threaded cooperative executor: a thread, its tasks, and a run
/// loop that polls them and parks when idle.
pub struct Looper {
    tasks: Vec<Option<Task>>,
    wakers: Vec<Waker>,
    live: usize,
    shared: Arc<Shared>,
}

/// Cross-thread state: the ready set and the means to wake the thread.
struct Shared {
    ready: Mutex<VecDeque<usize>>,
    unparker: Mutex<Option<Thread>>,
}

/// The waker for one task. Marking the task ready and unparking the
/// looper's thread is all it does — and both are thread-safe, because a
/// reply waking this task commonly arrives on another looper's thread.
struct TaskWaker {
    shared: Arc<Shared>,
    id: usize,
}

impl Wake for TaskWaker {
    fn wake(self: Arc<Self>) {
        self.wake_by_ref();
    }

    fn wake_by_ref(self: &Arc<Self>) {
        self.shared.ready.lock().unwrap().push_back(self.id);
        if let Some(thread) = self.shared.unparker.lock().unwrap().as_ref() {
            thread.unpark();
        }
    }
}

impl Looper {
    /// A new looper with no tasks.
    pub fn new() -> Self {
        Looper {
            tasks: Vec::new(),
            wakers: Vec::new(),
            live: 0,
            shared: Arc::new(Shared {
                ready: Mutex::new(VecDeque::new()),
                unparker: Mutex::new(None),
            }),
        }
    }

    /// Add a task — a future the looper will drive to completion. Tasks
    /// are added before [`run`](Self::run).
    pub fn spawn(&mut self, future: impl Future<Output = ()> + Send + 'static) {
        let id = self.tasks.len();
        let waker = Waker::from(Arc::new(TaskWaker {
            shared: self.shared.clone(),
            id,
        }));
        self.tasks.push(Some(Box::pin(future)));
        self.wakers.push(waker);
        self.live += 1;
    }

    /// Run on the current thread until every task has completed. A task
    /// completes when its future returns — for a handler's serve loop,
    /// when its inbox closes (`docs/design/looper-framework.md` §4, §8).
    pub fn run(mut self) {
        *self.shared.unparker.lock().unwrap() = Some(thread::current());
        // Every spawned task gets an initial poll.
        {
            let mut ready = self.shared.ready.lock().unwrap();
            for id in 0..self.tasks.len() {
                ready.push_back(id);
            }
        }
        loop {
            let batch: Vec<usize> = {
                let mut ready = self.shared.ready.lock().unwrap();
                ready.drain(..).collect()
            };
            if batch.is_empty() {
                if self.live == 0 {
                    break;
                }
                thread::park();
                continue;
            }
            for id in batch {
                if self.tasks[id].is_none() {
                    continue; // already completed; a stale wake
                }
                let waker = self.wakers[id].clone();
                let mut cx = Context::from_waker(&waker);
                let ready = self.tasks[id]
                    .as_mut()
                    .expect("task present")
                    .as_mut()
                    .poll(&mut cx)
                    .is_ready();
                if ready {
                    self.tasks[id] = None;
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
