// What the view reads of the layout as it builds, read back (as words_of is, words.mbt): a box's rect as this frame
// lays it out (Ctx::laid_rect), where a list is and how tall its rows are (Ctx::list_place, list_row_height). Each is
// what the last layout left; once this frame is laid out, what it read is looked at again, and what is not as it was
// read (a box grown, a list placed now where it was not) is a layout read back that moved (Ctx::read_changed): the
// frame is built again from it, before it is drawn, at most frame_passes_most times; one that never holds still is
// said (a Tester fails, saying which).

///|
/// Where box `id` is as this frame lays it out (x, y, w, h: its whole box, not cut to what clips it); None before it is
/// first laid out. For sizing what is built from it (room left by a box, a stage's size); read back: laid out
/// otherwise this frame, the frame is built again. Following a finger and hitting are Ctx::rect_of's (the hit area the
/// last frame drew, cut to its clips).
#callsite(autofill(loc))
pub fn Ctx::laid_rect(self : Ctx, id : Int, loc~ : SourceLoc) -> (Double, Double, Double, Double)? {
  let v = self.laid_rects.get(id)
  self.read_layout("laid_rect of box \{id}, read at \{loc}", v.to_string(), fn() {
    self.laid_rects.get(id).to_string()
  })
  v
}

///|
/// What of the layout the view read as it builds (`what` it is, `v` as read, `now` it read again): the first read of a
/// pass kept, looked at again once the pass is laid out (reads_after_layout).
fn Ctx::read_layout(self : Ctx, what : String, v : String, now : () -> String) -> Unit {
  if building.val && !self.layout_reads.contains(what) {
    self.layout_reads[what] = (v, now)
  }
}

///|
/// Once laid out: the boxes' rects kept (those with an id), and what was read looked at again; what moved is read back.
fn Ctx::reads_after_layout(self : Ctx) -> Unit {
  self.laid_rects.clear()
  for i in 0..<self.count {
    let n = self.nodes[i]
    if n.id != 0 {
      self.laid_rects[n.id] = (n.x, n.y, n.fw, n.fh)
    }
  }
  let moved = []
  self.layout_reads.each(fn(what, r) {
    if (r.1)() != r.0 {
      moved.push(what)
    }
  })
  self.layout_reads.clear()
  for m in moved {
    self.read_changed(m)
  }
}
