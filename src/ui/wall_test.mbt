// The time of day for what is shown of it (wall.mbt): a Tester's as its test sets it, on with its frames' clock.

///|
test "a Tester's time of day: its own day at its start, set by the test, on as the frames' clock goes" {
  let shown : Ref[String] = Ref("")
  let since = 1790000000000.0 - 3.0 * 60000.0
  let t = @ui.Tester::new(fn(c) {
    let ago = ((@ui.wall_ms() - since) / 60000.0).floor().to_int()
    shown.val = "\{ago} 分钟前"
    c.text(shown.val, wrap=false) |> ignore
    // (a minute's word changes as the minute comes: a wake at it, the frames' clock's)
    c.every(60000.0) |> ignore
  })
  // its own day as it starts (its first frame a moment on)
  assert_true(@ui.wall_ms() >= @ui.tester_wall && @ui.wall_ms() - @ui.tester_wall < 1000.0)
  assert_eq(shown.val, "3 分钟前")
  // on with the frames' clock: its words follow run_for
  let minute = 60000.0
  let (w0, t0) = (@ui.wall_ms(), t.time())
  t.run_for(minute)
  assert_true((@ui.wall_ms() - w0 - (t.time() - t0)).abs() < 0.001)
  assert_eq(shown.val, "4 分钟前")
  // set by the test: from then on
  t.set_wall(since + 10.0 * minute)
  assert_eq(@ui.wall_ms(), since + 10.0 * minute)
  t.draw()
  assert_eq(shown.val, "10 分钟前")
}
