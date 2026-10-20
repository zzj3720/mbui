// What the view reads of the layout as it builds, read back (readback.mbt): a box's laid rect, a list's rows.

///|
test "a box sized by another's laid height follows it in the frame it changes, not a frame late" {
  let tall = Ref::new(40.0)
  let seen : Array[(Double, Double)] = []
  let t = @ui.Tester::new(
    fn(c) {
      let a = c.id("a")
      let h = match c.laid_rect(a) {
        Some((_, _, _, h)) => h
        None => 0.0
      }
      c.column(fn() {
        c.box(w=Px(50.0), h=Px(tall.val), id=a, fn() {  }) |> ignore
        c.box(w=Px(50.0), h=Px(h), fn() {  }) |> ignore
      })
      |> ignore
      seen.push((tall.val, h))
    },
    w=200.0,
    h=200.0,
  )
  // laid out once: the second box as tall as the first, in the first frame
  assert_eq(seen[seen.length() - 1], (40.0, 40.0))
  tall.val = 70.0
  t.draw()
  // grown: the frame that draws it built again from where it is laid out now
  assert_eq(seen[seen.length() - 1], (70.0, 70.0))
  t.assert_idle()
}

///|
test "a row's height read as the view builds is this frame's" {
  let tall = Ref::new(40.0)
  let read : Array[Double?] = []
  let t = @ui.Tester::new(
    fn(c) {
      read.push(c.list_row_height("rows", 0))
      c.list("rows", 3, 40.0, fn(i) {
        c.box(w=Fill(1.0), h=Px(if i == 0 { tall.val } else { 40.0 }), fn() {  }) |> ignore
      })
      |> ignore
    },
    w=200.0,
    h=300.0,
  )
  assert_eq(read[read.length() - 1], Some(40.0))
  tall.val = 90.0
  t.draw()
  assert_eq(read[read.length() - 1], Some(90.0))
  t.assert_idle()
}

///|
test "panic a box sized by its own laid width never holds still, and says which" {
  let t = @ui.Tester::new(
    fn(c) {
      let a = c.id("a")
      let w = match c.laid_rect(a) {
        Some((_, _, w, _)) => w + 10.0
        None => 10.0
      }
      c.box(w=Px(w), h=Px(10.0), id=a, fn() {  }) |> ignore
    },
    w=500.0,
    h=100.0,
  )
  t.draw()
}

///|
test "words read before they are first laid out are there in the frame that lays them out" {
  let read : Array[Bool] = []
  let t = @ui.Tester::new(
    fn(c) {
      read.push(c.words_of("w") is Some(_))
      let b = c.column(w=Px(100.0), fn() { c.rich([@ui.plain("hello")], size=10.0) |> ignore })
      c.words(b, "w")
    },
    w=300.0,
    h=100.0,
  )
  // the first frame: none as it first built, there as it was built again
  assert_eq(read, [false, true])
  t.assert_idle()
}
