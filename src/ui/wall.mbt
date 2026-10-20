// The time of day, for what is shown of it only ("3 分钟前", a message's date): the host's (its machine's clock), a
// Tester's as the test sets it (Tester::set_wall), going on with its frames' clock. Never for when something happens
// or how far a motion is: those are the frames' clock's (a motion's, a timer's declared length; detlint's wall-clock
// lets it be read only as a source's `now`).

///|
/// What a Tester's time of day is at its start, unless the test sets it: 2026-09-21 14:13:20 UTC.
pub let tester_wall : Double = 1790000000000.0

///|
/// The time of day now, in ms since 1970 (UTC): to show how long ago something was, or its date. A Tester's is what
/// its test set (Tester::set_wall, by default tester_wall at its start), on as its frames' clock goes.
pub fn wall_ms() -> Double {
  h_wall_ms()
}

///|
/// The time of day, as @ui.wall_ms says it, is `ms` now (and goes on from it with the frames' clock): a run replayed
/// at the time it was made, a date the test shows.
pub fn Tester::set_wall(self : Tester, ms : Double) -> Unit {
  self.fake.wall = ms - self.fake.time
}
