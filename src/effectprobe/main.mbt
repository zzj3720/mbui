// effect.mb on a target (the probe moonbitlang/async was put through): two
// fibers and an interruption, once on virtual time and once on the real clock,
// driven the way a host's run loop drives it (tick, then wait for next_timer).

///|
fn two_fibers(rt : @effect.Runtime, log : Array[String]) -> Unit {
  ignore(
    rt.fork(() => @effect.scoped(s => {
      let a = s.fork(async fn() {
        @effect.sleep(50)
        log.push("a woke")
        1
      })
      let b = s.fork(async fn() {
        defer log.push("b finalizer ran")
        @effect.sleep(10000)
        log.push("b woke (wrong)")
        2
      })
      @effect.sleep(100)
      b.interrupt()
      log.push("a=\{a.join()}")
    })),
  )
}

///|
fn main {
  // virtual time: a test's
  let vrt = @effect.Runtime::new(seed=1)
  let vlog = []
  two_fibers(vrt, vlog)
  ignore(vrt.settle())
  vlog.push("virtual ms: \{vrt.now()}")
  println("EFFECT-PROBE virtual \{vlog}")
  // the real clock, a host's loop: tick, then wait until the next timer
  let now = () => @env.now().reinterpret_as_int64()
  let t0 = now()
  let rt = @effect.Runtime::live(now)
  let log = []
  two_fibers(rt, log)
  let mut turns = 0
  while true {
    rt.tick()
    turns += 1
    match rt.next_timer() {
      Some(at) => while now() < at {  }
      None => break
    }
  }
  log.push("real ms: \{now() - t0} (under 1 s: \{now() - t0 < 1000L}), turns: \{turns}")
  println("EFFECT-PROBE live \{log}")
}
