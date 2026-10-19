// A run as data (PocketJS has it so: docs/DETERMINISM.md there): what each frame drew as one number, so two runs of
// the same steps are compared frame by frame (the same, or the first frame they part at) rather than by their last
// screen alone, and a test that gives the same steps another order of what comes from outside (a seed, a replay's
// pace) can say the frames that should not change did not.

///|
fn hash_mix(h : Int64, v : Int64) -> Int64 {
  (h ^ v) * 1099511628211L
}

///|
/// What the last frame drew, as one number (FNV-1a): every instance drawn (where, how large, its kind and colour, in
/// 1/64 px and 1/255 steps) and the laid-out tree with its words and carets (`dump`). The same steps give the same
/// number on every run and every machine.
pub fn Tester::frame_hash(self : Tester) -> Int64 {
  ignore(self)
  drawn_hash()
}

///|
fn drawn_hash() -> Int64 {
  let c = g()
  let mut h = -3750763034362895579L
  for k in 0..<(c.ninst * inst_size) {
    h = hash_mix(h, (c.inst[k] * 64.0).round().to_int64())
  }
  let sb = StringBuilder()
  dump_node(sb, 0, 0)
  for ch in sb.to_string() {
    h = hash_mix(h, ch.to_int().to_int64())
  }
  h
}

///|
/// MBUI_DRAW_LOG=1 on a real host: each frame's `frame_hash` on the log (DRAWHASH frame hash), for a Tester over the
/// host's kept text (textrec.mbt) to be checked against: -1 not asked yet, 0 no, 1 yes.
let draw_log : Ref[Int] = Ref::new(-1)

///|
let draw_frames : Ref[Int] = Ref::new(0)

///|
fn log_drawn() -> Unit {
  if draw_log.val < 0 {
    draw_log.val = if @host.env("MBUI_DRAW_LOG") == "1" { 1 } else { 0 }
  }
  if draw_log.val == 1 {
    draw_frames.val += 1
    @host.log("DRAWHASH \{draw_frames.val} \{drawn_hash()}")
  }
}

///|
/// `n` frames, `ms` apart: each one's hash (`frame_hash`) as it was drawn.
pub fn Tester::frames(self : Tester, n : Int, ms? : Double = 16.0) -> Array[Int64] {
  let out : Array[Int64] = []
  for _ in 0..<n {
    self.frame(ms~)
    out.push(self.frame_hash())
  }
  out
}

///|
/// The first frame at which two runs' hashes part (None: the same, frame for frame; one longer than the other parts
/// where the shorter ends).
pub fn first_difference(a : Array[Int64], b : Array[Int64]) -> Int? {
  let n = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<n {
    if a[i] != b[i] {
      return Some(i)
    }
  }
  if a.length() != b.length() {
    Some(n)
  } else {
    None
  }
}
