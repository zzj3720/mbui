///|
/// A page drawn by the system's settings: its words say them.
fn env_view(c : @ui.Ctx) -> Unit {
  c.column(fn() {
    c.text(if c.reduced_motion() { "still" } else { "moving" }, wrap=false) |> ignore
    c.text(if @ui.system_dark() { "dark" } else { "light" }, wrap=false) |> ignore
    c.text(if @ui.window_inset() { "inset" } else { "full" }, wrap=false) |> ignore
  })
  |> ignore
}

///|
test "the system's settings are kept with the run's frames, and given again as they were where they changed" {
  let t = @ui.Tester::new(env_view)
  t.start_tape()
  // (the tape's first frame a frame on from where the Tester began: the one drawing it again begins there)
  let begun = t.time()
  t.frame()
  t.set_reduce_motion(true)
  t.frame()
  t.set_dark(true)
  t.set_window_inset(true)
  t.frame()
  t.set_reduce_transparency(true)
  t.frame()
  let tape = t.tape()
  let envs = tape.split("\n").filter(fn(l) { l.has_prefix("ENV ") }).to_array()
  // the first frame's, then each change's: four
  assert_eq(envs.length(), 4)
  // drawn again by a Tester left as it was made (motion, light, no inset): each frame the run's
  let u = @ui.Tester::new(env_view, time=begun)
  let frames = u.replay_frames(tape)
  assert_true(frames.length() >= 4)
  for f in frames {
    assert_eq(f.1, f.2, msg="frame \{f.0}")
  }
  assert_true(u.find("still") is Some(_))
  assert_true(u.find("dark") is Some(_))
  assert_true(u.find("inset") is Some(_))
}

///|
test "the settings a run began with (an ENV line before its first frame) draw that first frame again, as the run did" {
  let t = @ui.Tester::new(env_view)
  t.set_reduce_motion(true)
  t.set_reduce_transparency(true)
  t.set_dark(true)
  t.draw()
  let begun = t.time()
  t.start_tape()
  t.frame()
  t.frame()
  let tape = t.tape()
  // a Tester made as by default, its first frame at the tape's first: drawn again by the run's settings
  let u = @ui.Tester::new(env_view, time=begun + 16.0)
  let frames = u.replay_frames(tape)
  assert_eq(frames.length(), 2)
  for f in frames {
    assert_eq(f.1, f.2, msg="frame \{f.0}")
  }
}
