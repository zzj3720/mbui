// The scheduler: one thread, a list of ready tasks and a heap of timers. It
// never runs on its own: whoever owns it (a test, or a host's run loop) says
// when it runs and how far time moves.
//
// - Virtual time (`Runtime::new`): `advance(ms)` moves the clock from timer to
//   timer, running what each wakes before the next; nothing waits for real
//   time. With a seed, which ready task runs next is drawn from it, so a test
//   can try many interleavings and replay any one of them exactly.
// - Host time (`Runtime::live`): the host calls `tick()` from its run loop (a
//   frame, a timer it set for `next_timer()`, a callback that completed a
//   Deferred); ready tasks run in FIFO order.

///|
priv enum Resume {
  Go
  Stop
}

///|
priv enum State {
  Running
  Parked((Resume) -> Unit)
  Ended
}

///|
priv enum End {
  NotYet
  Done
  Raised(Error)
  Cut
}

///|
/// A task: the code of one fiber, run by the scheduler between suspensions.
struct Task {
  id : Int
  rt : Runtime
  name : String
  mut state : State
  mut end : End
  /// Asked to stop: the next suspension (outside a shield) raises the
  /// cancellation signal.
  mut interrupted : Bool
  /// Inside `uninterruptible` (finalizers, acquisition): not cut.
  mut shield : Int
  mut queued : Bool
  watchers : Map[Int, () -> Unit]
}

///|
priv struct Timer {
  at : Int64
  seq : Int
  fire : () -> Unit
  mut live : Bool
}

///|
fn Timer::before(self : Timer, other : Timer) -> Bool {
  self.at < other.at || (self.at == other.at && self.seq < other.seq)
}

///|
/// A binary heap of timers: by time, then by when they were set.
priv struct Heap {
  items : Array[Timer]
}

///|
fn Heap::push(self : Heap, t : Timer) -> Unit {
  self.items.push(t)
  let mut i = self.items.length() - 1
  while i > 0 {
    let p = (i - 1) / 2
    if self.items[i].before(self.items[p]) {
      self.items.swap(i, p)
      i = p
    } else {
      break
    }
  }
}

///|
fn Heap::peek(self : Heap) -> Timer? {
  if self.items.is_empty() {
    None
  } else {
    Some(self.items[0])
  }
}

///|
fn Heap::pop(self : Heap) -> Timer? {
  let n = self.items.length()
  if n == 0 {
    return None
  }
  let top = self.items[0]
  let last = self.items.pop().unwrap()
  if n > 1 {
    self.items[0] = last
    let m = n - 1
    let mut i = 0
    while true {
      let l = 2 * i + 1
      let r = l + 1
      let mut s = i
      if l < m && self.items[l].before(self.items[s]) {
        s = l
      }
      if r < m && self.items[r].before(self.items[s]) {
        s = r
      }
      if s == i {
        break
      }
      self.items.swap(i, s)
      i = s
    }
  }
  Some(top)
}

///|
pub struct Runtime {
  priv mut time : Int64
  priv clock : (() -> Int64)?
  priv ready : Array[Task]
  priv timers : Heap
  priv mut seq : Int
  priv shuffle : Bool
  priv sched : Rng
  /// Draws for simulations (jitter, order, loss): apart from the scheduler's,
  /// from the same seed.
  rng : Rng
  /// The seed the run was made with (0: none, FIFO).
  seed : Int
  priv mut ids : Int
  priv mut root_scope : Scope?
  /// Told of a fiber of a scope that failed, or a finalizer (Runner.onDefect).
  priv mut defect : (Error) -> Unit
  /// Told when a task becomes ready outside a turn (a host's callback gave a
  /// Deferred its value): the host then schedules a `tick`.
  priv mut waker : () -> Unit
  priv mut turning : Bool
  /// What failed, as said, when nobody else was told.
  defects : Array[String]
  /// What the run said (`trace`), each line with its time.
  log : Array[String]
  /// Task resumptions so far.
  mut steps : Int
}

///|
let current : Ref[Task?] = Ref(None)

///|
fn Runtime::make(seed : Int, shuffle : Bool, start : Int64, clock : (() -> Int64)?) -> Runtime {
  let defects = []
  let rt = {
    time: start,
    clock,
    ready: [],
    timers: { items: [] },
    seq: 0,
    shuffle,
    sched: Rng::new(seed),
    rng: Rng::new(seed * 7919 + 17),
    seed,
    ids: 0,
    root_scope: None,
    defect: e => defects.push(e.to_string()),
    waker: () => (),
    turning: false,
    defects,
    log: [],
    steps: 0,
  }
  rt.root_scope = Some(Scope::make(rt, true))
  rt
}

///|
/// A runtime on virtual time from `start` (ms). With a `seed`, the ready task
/// that runs next is drawn from it; without, they run in the order they
/// became ready.
pub fn Runtime::new(seed? : Int, start? : Int64 = 0L) -> Runtime {
  match seed {
    Some(s) => Runtime::make(s, true, start, None)
    None => Runtime::make(0, false, start, None)
  }
}

///|
/// A runtime on the host's clock (ms): the host calls `tick` when it is due.
pub fn Runtime::live(now : () -> Int64) -> Runtime {
  Runtime::make(0, false, now(), Some(now))
}

///|
/// Who is told of failures nobody waited for (by default `defects` keeps them).
pub fn Runtime::on_defect(self : Runtime, f : (Error) -> Unit) -> Unit {
  self.defect = f
}

///|
fn Runtime::report(self : Runtime, e : Error) -> Unit {
  (self.defect)(e)
}

///|
/// Who is told that a task became ready while no turn runs (Runtime::live:
/// the host then calls `tick` soon, on its run loop).
pub fn Runtime::on_wake(self : Runtime, f : () -> Unit) -> Unit {
  self.waker = f
}

///|
/// The core's own scope: closing it ends everything.
pub fn Runtime::root(self : Runtime) -> Scope {
  self.root_scope.unwrap()
}

///|
pub fn Runtime::now(self : Runtime) -> Int64 {
  match self.clock {
    Some(f) => f()
    None => self.time
  }
}

///|
/// Notes a line in the run's log, with the time.
pub fn Runtime::trace(self : Runtime, s : String) -> Unit {
  self.log.push("\{self.now()} \{s}")
}

///|
/// The log as one text, a line each.
pub fn Runtime::trace_text(self : Runtime) -> String {
  self.log.join("\n")
}

///|
fn current_task() -> Task {
  match current.val {
    Some(t) => t
    None => abort("effect: not inside a task")
  }
}

///|
/// The runtime the running code is on.
pub fn runtime() -> Runtime {
  current_task().rt
}

///|
/// The time on the running code's clock (ms).
pub fn now() -> Int64 {
  current_task().rt.now()
}

///|
/// Notes a line in the run's log (`Runtime::trace`).
pub fn trace(s : String) -> Unit {
  current_task().rt.trace(s)
}

///|
fn Runtime::start(self : Runtime, name : String, body : async () -> Unit) -> Task {
  self.ids += 1
  let t : Task = {
    id: self.ids,
    rt: self,
    name,
    state: Ended,
    end: NotYet,
    interrupted: false,
    shield: 0,
    queued: false,
    watchers: {},
  }
  t.state = Parked(fn(r) {
    // Interrupted before it ever ran: it never does (as Effect has it).
    if r is Stop {
      t.end = Cut
      t.state = Ended
      t.finish()
      return
    }
    run_raw(() => {
      try capture_cancel(body, handler=() => t.end = Cut) catch {
        e => t.end = Raised(e)
      } noraise {
        _ => if t.end is NotYet { t.end = Done }
      }
      t.state = Ended
      t.finish()
    })
  })
  t.queued = true
  self.ready.push(t)
  if !self.turning {
    (self.waker)()
  }
  t
}

///|
fn Task::finish(self : Task) -> Unit {
  let ws = self.watchers.values().to_array()
  self.watchers.clear()
  for w in ws {
    w()
  }
}

///|
fn Task::watch(self : Task, f : () -> Unit) -> Int {
  self.rt.ids += 1
  let id = self.rt.ids
  self.watchers.set(id, f)
  id
}

///|
fn Task::wake(self : Task) -> Unit {
  if !self.queued && self.state is Parked(_) {
    self.queued = true
    self.rt.ready.push(self)
    if !self.rt.turning {
      (self.rt.waker)()
    }
  }
}

///|
fn Task::interrupt(self : Task) -> Unit {
  if self.end is NotYet {
    self.interrupted = true
    if self.shield == 0 {
      self.wake()
    }
  }
}

///|
/// Parks the running task until something wakes it; interrupted, it raises
/// the cancellation signal (outside a shield).
async fn park() -> Unit noraise {
  let t = current_task()
  if t.interrupted && t.shield == 0 {
    raise_cancel()
  }
  let r : Resume = suspend_raw(k => { t.state = Parked(k) })
  if r is Stop {
    raise_cancel()
  }
}

///|
async fn Task::wait_once(self : Task) -> Unit noraise {
  let me = current_task()
  let id = self.watch(() => me.wake())
  defer self.watchers.remove(id)
  park()
}

///|
async fn Task::await_end(self : Task) -> Unit noraise {
  while self.end is NotYet {
    self.wait_once()
  }
}

///|
/// Lets the other ready tasks run first.
pub async fn pause() -> Unit noraise {
  let t = current_task()
  if t.interrupted && t.shield == 0 {
    raise_cancel()
  }
  let r : Resume = suspend_raw(k => {
    t.state = Parked(k)
    t.queued = true
    t.rt.ready.push(t)
  })
  if r is Stop {
    raise_cancel()
  }
}

///|
fn Runtime::add_timer(self : Runtime, at : Int64, fire : () -> Unit) -> Timer {
  self.seq += 1
  let t = { at, seq: self.seq, fire, live: true }
  self.timers.push(t)
  t
}

///|
/// Calls `f` (sync code: a simulated host, a delivery) `ms` from now on the
/// runtime's clock.
pub fn Runtime::after(self : Runtime, ms : Int, f : () -> Unit) -> Unit {
  ignore(self.add_timer(self.now() + ms.to_int64(), f))
}

///|
/// Waits `ms` on the runtime's clock.
pub async fn sleep(ms : Int) -> Unit noraise {
  let t = current_task()
  let rt = t.rt
  let at = rt.now() + ms.to_int64()
  let timer = rt.add_timer(at, () => t.wake())
  defer {
    timer.live = false
  }
  while rt.now() < at {
    park()
  }
}

///|
fn Runtime::pick(self : Runtime) -> Task? {
  if self.ready.is_empty() {
    None
  } else if self.shuffle {
    Some(self.ready.remove(self.sched.below(self.ready.length())))
  } else {
    Some(self.ready.remove(0))
  }
}

///|
fn Runtime::step_task(self : Runtime, t : Task) -> Unit {
  t.queued = false
  guard t.state is Parked(k) else { return }
  t.state = Running
  let prev = current.val
  current.val = Some(t)
  self.steps += 1
  k(if t.interrupted && t.shield == 0 { Stop } else { Go })
  current.val = prev
}

///|
/// Runs ready tasks until none is; returns how many resumptions that took.
pub fn Runtime::run_ready(self : Runtime) -> Int {
  let outer = self.turning
  self.turning = true
  defer {
    self.turning = outer
  }
  let mut n = 0
  while self.pick() is Some(t) {
    self.step_task(t)
    n += 1
    if n > 10_000_000 {
      abort("effect: tasks kept each other ready without end (\{t.name})")
    }
  }
  n
}

///|
/// When the next timer is due, if one is set.
pub fn Runtime::next_timer(self : Runtime) -> Int64? {
  while self.timers.peek() is Some(t) && !t.live {
    ignore(self.timers.pop())
  }
  match self.timers.peek() {
    Some(t) => Some(t.at)
    None => None
  }
}

///|
/// Fires the timers due by `until`, one instant at a time, running what each
/// instant wakes before the next.
fn Runtime::fire_until(self : Runtime, until : Int64) -> Unit {
  let outer = self.turning
  self.turning = true
  defer {
    self.turning = outer
  }
  ignore(self.run_ready())
  while self.next_timer() is Some(at) && at <= until {
    if self.clock is None && at > self.time {
      self.time = at
    }
    while self.timers.peek() is Some(t) && t.at <= at {
      ignore(self.timers.pop())
      if t.live {
        t.live = false
        (t.fire)()
      }
    }
    ignore(self.run_ready())
  }
}

///|
/// Moves virtual time on `ms`: every timer due meanwhile fires at its time.
pub fn Runtime::advance(self : Runtime, ms : Int) -> Unit {
  guard self.clock is None else { abort("effect: advance on the host's clock") }
  let until = self.time + ms.to_int64()
  self.fire_until(until)
  self.time = until
}

///|
/// Runs until nothing is ready and no timer is set (true), moving virtual
/// time from timer to timer, at most `max_ms` on (false when it stopped there).
pub fn Runtime::settle(self : Runtime, max_ms? : Int = 3_600_000) -> Bool {
  guard self.clock is None else { abort("effect: settle on the host's clock") }
  let limit = self.time + max_ms.to_int64()
  ignore(self.run_ready())
  while self.next_timer() is Some(at) && at <= limit {
    self.fire_until(at)
  }
  self.ready.is_empty() && self.next_timer() is None
}

///|
/// The host's turn (Runtime::live): fires what is due on its clock and runs
/// what is ready. It then sets a timer for `next_timer()`, if any.
pub fn Runtime::tick(self : Runtime) -> Unit {
  self.fire_until(self.now())
}

///|
/// Nothing is ready to run.
pub fn Runtime::idle(self : Runtime) -> Bool {
  self.ready.is_empty()
}

///|
/// Starts `f` as a fiber of the root scope: interrupted when the runtime shuts
/// down; a failure is told to `on_defect`.
pub fn[X] Runtime::fork(self : Runtime, f : async () -> X, name? : String = "") -> Fiber[X] {
  self.root().fork(f, name~)
}

///|
/// Closes the root scope: everything is interrupted, finalizers run.
pub fn Runtime::shutdown(self : Runtime) -> Unit {
  self.root().close_now()
}
