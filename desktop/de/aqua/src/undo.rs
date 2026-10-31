//! Undo (Undo.swift, P10.5, §6.3). **Per window, held rather than owned**:
//! a window holds an `UndoStack`, so a document model can take it over
//! later without changing a command. **Undo is a command like any other**
//! (`edit.undo`, `edit.redo`), and the Edit menu's two items are derived
//! from the stack: their titles and their enablement. **An undo can fail**,
//! because the world moved: it is refused with the reason, and stays on the
//! stack to try again.

use menu_model::{CommandResult, Enablement};
use std::cell::RefCell;
use std::rc::Rc;

type Step = Box<dyn Fn() -> CommandResult>;

/// One reversible change.
pub struct UndoEntry {
    /// What the menu calls it, without the verb: "Move to Trash".
    pub name: String,
    pub undo: Step,
    pub redo: Step,
}

impl UndoEntry {
    pub fn new(name: &str, undo: impl Fn() -> CommandResult + 'static, redo: impl Fn() -> CommandResult + 'static) -> UndoEntry {
        UndoEntry { name: name.into(), undo: Box::new(undo), redo: Box::new(redo) }
    }
}

pub struct UndoStack {
    done: RefCell<Vec<Rc<UndoEntry>>>,
    undone: RefCell<Vec<Rc<UndoEntry>>>,
    /// How much is remembered: the last few things, not a journal.
    pub limit: usize,
    on_change: RefCell<Option<Rc<dyn Fn()>>>,
}

impl Default for UndoStack {
    fn default() -> UndoStack {
        UndoStack::new(100)
    }
}

impl UndoStack {
    pub fn new(limit: usize) -> UndoStack {
        UndoStack { done: RefCell::default(), undone: RefCell::default(), limit, on_change: RefCell::new(None) }
    }

    /// Told whenever what the Edit menu says may have changed.
    pub fn on_change(&self, f: impl Fn() + 'static) {
        *self.on_change.borrow_mut() = Some(Rc::new(f))
    }

    fn changed(&self) {
        let f = self.on_change.borrow().clone();
        if let Some(f) = f {
            f()
        }
    }

    /// A reversible change. What was undone and not redone is forgotten: a
    /// new change starts a new future.
    pub fn push(&self, e: UndoEntry) {
        {
            let mut d = self.done.borrow_mut();
            d.push(Rc::new(e));
            let over = d.len().saturating_sub(self.limit);
            d.drain(..over);
        }
        self.undone.borrow_mut().clear();
        self.changed()
    }

    pub fn can_undo(&self) -> bool {
        !self.done.borrow().is_empty()
    }
    pub fn can_redo(&self) -> bool {
        !self.undone.borrow().is_empty()
    }

    /// "Undo Move to Trash", or "Undo" with nothing to undo.
    pub fn undo_title(&self) -> String {
        self.done.borrow().last().map_or("Undo".into(), |e| format!("Undo {}", e.name))
    }
    pub fn redo_title(&self) -> String {
        self.undone.borrow().last().map_or("Redo".into(), |e| format!("Redo {}", e.name))
    }

    pub fn undo_enablement(&self) -> Enablement {
        if self.can_undo() { Enablement::Enabled } else { Enablement::Disabled("there is nothing to undo".into()) }
    }
    pub fn redo_enablement(&self) -> Enablement {
        if self.can_redo() { Enablement::Enabled } else { Enablement::Disabled("there is nothing to redo".into()) }
    }

    pub fn undo(&self) -> CommandResult {
        self.step(&self.done, &self.undone, |e| (e.undo)(), "there is nothing to undo")
    }

    pub fn redo(&self) -> CommandResult {
        self.step(&self.undone, &self.done, |e| (e.redo)(), "there is nothing to redo")
    }

    /// Run the top of `from`; moved to `to` only if it worked. Not borrowed
    /// while it runs: a step may push.
    fn step(&self, from: &RefCell<Vec<Rc<UndoEntry>>>, to: &RefCell<Vec<Rc<UndoEntry>>>, run: impl Fn(&UndoEntry) -> CommandResult, empty: &str) -> CommandResult {
        let Some(e) = from.borrow().last().cloned() else { return CommandResult::Refused(empty.into()) };
        let r = run(&e);
        if matches!(r, CommandResult::Ok(_)) {
            from.borrow_mut().pop();
            to.borrow_mut().push(e);
            self.changed()
        }
        r
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    fn counter(name: &str, n: &Rc<Cell<i32>>, fail_undo: Option<Rc<Cell<bool>>>) -> UndoEntry {
        let (a, b) = (n.clone(), n.clone());
        UndoEntry::new(
            name,
            move || {
                if fail_undo.as_ref().is_some_and(|f| f.get()) {
                    return CommandResult::Refused("moved".into());
                }
                a.set(a.get() - 1);
                CommandResult::Ok(None)
            },
            move || {
                b.set(b.get() + 1);
                CommandResult::Ok(None)
            },
        )
    }

    #[test]
    fn titles_and_enablement_are_derived_from_the_stack() {
        let s = UndoStack::default();
        assert_eq!(s.undo_title(), "Undo");
        assert_eq!(s.undo_enablement(), Enablement::Disabled("there is nothing to undo".into()));
        assert_eq!(s.redo_enablement(), Enablement::Disabled("there is nothing to redo".into()));
        let n = Rc::new(Cell::new(1));
        s.push(counter("New Folder", &n, None));
        assert_eq!(s.undo_title(), "Undo New Folder");
        assert_eq!(s.undo(), CommandResult::Ok(None));
        assert_eq!(n.get(), 0);
        assert_eq!((s.undo_title().as_str(), s.redo_title().as_str()), ("Undo", "Redo New Folder"));
        assert_eq!(s.redo(), CommandResult::Ok(None));
        assert_eq!(n.get(), 1);
        assert_eq!(s.undo_title(), "Undo New Folder");
    }

    #[test]
    fn a_new_change_forgets_what_was_undone() {
        let s = UndoStack::default();
        let n = Rc::new(Cell::new(0));
        s.push(counter("A", &n, None));
        s.undo();
        assert!(s.can_redo());
        s.push(counter("B", &n, None));
        assert!(!s.can_redo(), "a new change starts a new future");
        assert_eq!(s.redo(), CommandResult::Refused("there is nothing to redo".into()));
    }

    #[test]
    fn an_undo_that_fails_is_refused_and_stays() {
        let s = UndoStack::default();
        let n = Rc::new(Cell::new(1));
        let moved = Rc::new(Cell::new(true));
        s.push(counter("Move to Trash", &n, Some(moved.clone())));
        assert_eq!(s.undo(), CommandResult::Refused("moved".into()));
        assert_eq!(s.undo_title(), "Undo Move to Trash", "still there to try again");
        moved.set(false);
        assert_eq!(s.undo(), CommandResult::Ok(None));
    }

    #[test]
    fn the_stack_is_bounded_and_says_when_it_changed() {
        let s = UndoStack::new(3);
        let changes = Rc::new(Cell::new(0));
        let c = changes.clone();
        s.on_change(move || c.set(c.get() + 1));
        let n = Rc::new(Cell::new(0));
        for i in 0..5 {
            s.push(counter(&i.to_string(), &n, None))
        }
        assert_eq!(changes.get(), 5);
        assert_eq!(s.undo_title(), "Undo 4");
        s.undo();
        s.undo();
        s.undo();
        assert!(!s.can_undo(), "only the last three were remembered");
        assert_eq!(changes.get(), 8);
    }
}
