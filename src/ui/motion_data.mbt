// Motion as data, not commands (docs/determinism.md): a motion is said once, as it starts (or anew when its target
// changes): where it goes, by what curve, from when, and so until when. Its value at a frame is a function of that
// frame's time. The framework draws frames while a motion said has not reached its end, and after it none; nothing
// asks for frames one by one. What never ends while shown (a spinner) is a cycle: its phase is a function of the
// frames' clock, and it is drawn while something shown reads it.

///|
/// The end of motion `id` (the frames' clock, ms): frames until then. Said once as it starts, or anew (a new end
/// replaces the old). An end already past says nothing.
pub fn Ctx::motion_until(self : Ctx, id : Int, end : Double) -> Unit {
  if end > self.now {
    self.motion_ends[id] = end
  } else {
    self.motion_ends.remove(id)
  }
}

///|
/// Where a cycle of `period` ms is now, from 0 to 1 (a spinner's turn, a breath): read by what shows it, a frame each
/// frame while it is shown.
pub fn Ctx::cycle(self : Ctx, period : Double) -> Double {
  self.cycling = true
  if period <= 0.0 {
    0.0
  } else {
    let p = self.now / period
    p - p.floor()
  }
}

///|
/// Whether a motion said has not reached its end (the next frame is owed to it); those that have are forgotten.
fn Ctx::motion_owed(self : Ctx) -> Bool {
  let done = []
  let mut owed = false
  self.motion_ends.each(fn(id, end) { if end > self.now { owed = true } else { done.push(id) } })
  for id in done {
    self.motion_ends.remove(id)
  }
  owed
}

///|
/// The latest end of the motions said (-1: none).
pub fn Ctx::motion_end(self : Ctx) -> Double {
  let mut e = -1.0
  self.motion_ends.each(fn(_, end) { if end > e { e = end } })
  e
}

// ── a spring, solved ─────────────────────────────────────────────────────────

///|
/// A damped spring's way from `x0` (moving at `v0`, per second) to rest at 0, `t` seconds on: where it is and how
/// fast it goes. Under-, critically and over-damped, in closed form.
fn spring_at(x0 : Double, v0 : Double, k : Double, c : Double, t : Double) -> (Double, Double) {
  let w0 = k.sqrt()
  let z = c / (2.0 * w0)
  if z < 1.0 - 1.0e-9 {
    let wd = w0 * (1.0 - z * z).sqrt()
    let a = x0
    let b = (v0 + z * w0 * x0) / wd
    let e = @math.exp(-z * w0 * t)
    let cs = @math.cos(wd * t)
    let sn = @math.sin(wd * t)
    let x = e * (a * cs + b * sn)
    let v = e * ((b * wd - z * w0 * a) * cs - (a * wd + z * w0 * b) * sn)
    (x, v)
  } else if z > 1.0 + 1.0e-9 {
    let r = w0 * (z * z - 1.0).sqrt()
    let r1 = -z * w0 + r
    let r2 = -z * w0 - r
    let c2 = (v0 - r1 * x0) / (r2 - r1)
    let c1 = x0 - c2
    let e1 = @math.exp(r1 * t)
    let e2 = @math.exp(r2 * t)
    (c1 * e1 + c2 * e2, c1 * r1 * e1 + c2 * r2 * e2)
  } else {
    let b = v0 + w0 * x0
    let e = @math.exp(-w0 * t)
    ((x0 + b * t) * e, (b - w0 * (x0 + b * t)) * e)
  }
}

///|
/// When (seconds on) a spring from `x0` at `v0` has come to rest: within `eps` of it and slower than `eps` a second,
/// for good (its envelope there). 0 when it is at rest already.
fn spring_end(x0 : Double, v0 : Double, k : Double, c : Double, eps : Double) -> Double {
  if x0.abs() < eps && v0.abs() < eps {
    return 0.0
  }
  let w0 = k.sqrt()
  let z = c / (2.0 * w0)
  // the slowest decay rate, and a bound of the amplitude
  let rate = if z < 1.0 { z * w0 } else { w0 * (z - (z * z - 1.0).sqrt()) }
  let amp = x0.abs() + (v0.abs() + z * w0 * x0.abs()) / (w0 * dmax(1.0e-6, (1.0 - z * z).abs().sqrt())) + 1.0
  let bound = dmax(amp, amp * w0)
  dmax(0.0, @math.ln(bound / eps) / rate)
}
