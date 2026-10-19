// client/core-ts/test/wake.test.ts, ported (a white-box test, as the TS one imports the module's insides) (same names, same checks), each run
// over seeds: the ready fibers' order is drawn from the seed, and the host's
// answers come after a latency on the virtual clock (the TS FakeHost answers at
// once, and the tests `flush()` Node's event loop to let fibers move).

///|
fn wake(at : Int64, away : Int64) -> Wake {
  { at, away, network: false, retry: false }
}

///|
fn[X : Show] outcome(f : @effect.Fiber[X]) -> String {
  match f.poll() {
    None => "pending"
    Some(Succeeded(x)) => "ok \{x}"
    Some(Failed(e)) =>
      match e {
        HostError(m) => "error \{m}"
        _ => "other error \{e}"
      }
    Some(Interrupted) => "interrupted"
  }
}

///|
/// A host whose fetch answers `answer` after `latency` ms (FakeHost.onFetch).
fn sim_host(
  rt : @effect.Runtime,
  answer : (HttpRequest) -> HttpResponse,
  latency? : Int = 5,
) -> Host {
  {
    now_ms: () => rt.now(),
    fetch: r => {
      @effect.sleep(latency)
      answer(r)
    },
    fetch_stream: _ => @effect.never(),
    reset_connections: () => (),
    storage_get: _ => None,
  }
}

///|
let get : HttpRequest = { verb: "GET", url: "https://x/y", headers: [], body: None }

///|
fn body_of(f : @effect.Fiber[HttpResponse]) -> String {
  match f.poll() {
    None => "pending"
    Some(Succeeded(r)) => @utf8.decode_lossy(r.body)
    Some(Failed(e)) => "error \{e}"
    Some(Interrupted) => "interrupted"
  }
}

///|
test "a_request_long_unanswered_fails_when_the_page_is_back" {
  @effect.for_seeds(fn(seed) {
    let rt = @effect.Runtime::new(seed~)
    let wakes = Wakes::new()
    let request : @effect.Fiber[Unit] = rt.fork(() => unless_dropped(wakes, 1_000L, () => @effect.never()))
    ignore(rt.run_ready())
    // Back after a short while: it may still come.
    wakes.wake(wake(3_000L, 1_500L))
    ignore(rt.run_ready())
    assert_eq(outcome(request), "pending")
    // Away long enough, but it was only just sent (the page asking again as it came back): left alone.
    wakes.wake(wake(1_000L + quiet_ms - 1L, 60_000L))
    ignore(rt.run_ready())
    assert_eq(outcome(request), "pending")
    // Sent while the page was away (an app in the background still runs a while), unanswered since: given up.
    wakes.wake(wake(60_000L, 59_500L))
    ignore(rt.run_ready())
    assert_eq(outcome(request), "error \{dropped}")
  })
}

///|
test "a_read_under_way_is_asked_again_beside_itself_and_the_first_answer_is_its" {
  @effect.for_seeds(fn(seed) {
    let rt = @effect.Runtime::new(seed~)
    let asked = Ref(0)
    let host = sim_host(rt, _ => {
      asked.val += 1
      { status: 200, headers: [], body: @utf8.encode("second") }
    })
    let wakes = Wakes::new()
    // The first is on a connection that is gone: it never answers.
    let first_gone = Ref(true)
    let ask = async fn() {
      if first_gone.val {
        first_gone.val = false
        @effect.never()
      } else {
        (host.fetch)(get)
      }
    }
    let answer = rt.fork(() => hedged(wakes, host, ask))
    ignore(rt.run_ready())
    assert_eq(body_of(answer), "pending")
    wakes.wake({ at: (host.now_ms)(), away: 0L, network: true, retry: false })
    assert_true(rt.settle())
    assert_eq(body_of(answer), "second")
    assert_eq(asked.val, 1)
  })
}

///|
test "only_reads_and_what_says_so_are_asked_twice" {
  let request = fn(verb : String, headers : Array[(String, String)]) -> HttpRequest {
    { verb, url: "", headers, body: None }
  }
  assert_true(hedgeable(request("GET", [])))
  assert_true(!hedgeable(request("POST", [])))
  assert_true(hedgeable(request("POST", [(hedge, "1")])))
}

///|
test "the_network_changing_fails_every_request_under_way" {
  @effect.for_seeds(fn(seed) {
    let rt = @effect.Runtime::new(seed~)
    let wakes = Wakes::new()
    let request : @effect.Fiber[Unit] = rt.fork(() => unless_dropped(wakes, 1_000L, () => @effect.never()))
    ignore(rt.run_ready())
    assert_eq(outcome(request), "pending")
    wakes.wake({ at: 1_001L, away: 0L, network: true, retry: false })
    ignore(rt.run_ready())
    assert_eq(outcome(request), "error \{network}")
  })
}

///|
test "a_retry_fails_nothing_under_way_and_asks_a_read_again_beside_itself" {
  @effect.for_seeds(fn(seed) {
    let rt = @effect.Runtime::new(seed~)
    let wakes = Wakes::new()
    let retry = fn(at : Int64) -> Wake { { at, away: 0L, network: false, retry: true } }
    // A write under way: left to answer.
    let write : @effect.Fiber[Unit] = rt.fork(() => unless_dropped(wakes, 1_000L, () => @effect.never()))
    ignore(rt.run_ready())
    wakes.wake(retry(60_000L))
    ignore(rt.run_ready())
    assert_eq(outcome(write), "pending")
    // A read under way: asked again beside it, the first answer its.
    let host = sim_host(rt, _ => {
      status: 200,
      headers: [],
      body: @utf8.encode("\"again\""),
    })
    let first = Ref(true)
    let ask = async fn() {
      if first.val {
        first.val = false
        @effect.never()
      } else {
        (host.fetch)(get)
      }
    }
    let answer = rt.fork(() => hedged(wakes, host, ask))
    ignore(rt.run_ready())
    assert_eq(body_of(answer), "pending")
    wakes.wake(retry((host.now_ms)()))
    ignore(rt.settle(max_ms=1000))
    assert_eq(body_of(answer), "\"again\"")
    // And the connections are suspect: the links are tried against new ones.
    assert_true(retry(0L).suspects_connections())
    assert_true(!retry(0L).drops_stream(0L))
    // the write is still left to answer
    assert_eq(outcome(write), "pending")
  })
}

///|
test "a_stream_quiet_while_away_ends_and_one_that_spoke_goes_on" {
  @effect.for_seeds(fn(seed) {
    let rt = @effect.Runtime::new(seed~)
    let host = sim_host(rt, _ => abort("no fetch"))
    let wakes = Wakes::new()
    let queue : @effect.Queue[String] = @effect.Queue::unbounded()
    let frames = quiet_ends(host, wakes, { take: () => queue.take() })
    ignore(queue.try_offer("hello"))
    let first = rt.fork(() => (frames.take)())
    ignore(rt.run_ready())
    assert_eq(outcome(first), "ok hello")
    let heard = (host.now_ms)()
    let next = rt.fork(() => (frames.take)())
    ignore(rt.run_ready())
    assert_eq(outcome(next), "pending")
    // It said something while the page was away: it is there.
    wakes.wake(wake(heard + 1_000L, stream_away_ms + 5_000L))
    ignore(rt.run_ready())
    assert_eq(outcome(next), "pending")
    // Away not long enough to tell.
    wakes.wake(wake(heard + 20_000L, 10_000L))
    ignore(rt.run_ready())
    assert_eq(outcome(next), "pending")
    // Nothing since before the page went away: it ends.
    wakes.wake(wake(heard + stream_away_ms + 10_000L, stream_away_ms))
    ignore(rt.run_ready())
    assert_eq(outcome(next), "error \{gone}")
  })
}

///|
test "a_stream_opened_while_away_and_quiet_since_ends" {
  @effect.for_seeds(fn(seed) {
    let rt = @effect.Runtime::new(seed~)
    let host = sim_host(rt, _ => abort("no fetch"))
    let wakes = Wakes::new()
    let queue : @effect.Queue[String] = @effect.Queue::unbounded()
    let opened = (host.now_ms)()
    let frames = quiet_ends(host, wakes, { take: () => queue.take() })
    let next = rt.fork(() => (frames.take)())
    ignore(rt.run_ready())
    assert_eq(outcome(next), "pending")
    // The page went away before it opened (it was opened in the background), and nothing came since.
    wakes.wake(wake(opened + stream_away_ms, stream_away_ms + 60_000L))
    ignore(rt.run_ready())
    assert_eq(outcome(next), "error \{gone}")
  })
}

///|
/// Not in the TS tests (it would need real time or a hand-built clock there):
/// through `waking`, a read hedged on a sim network whose answers come back in
/// an order the seed draws; the answer is the first to arrive, and the
/// attempts still under way are interrupted (their finalizers run).
test "a_hedged_read_takes_the_first_answer_and_stops_the_others" {
  @effect.for_seeds(count=50, fn(seed) {
    let rt = @effect.Runtime::new(seed~)
    let stopped = Ref(0)
    let n = Ref(0)
    let inner = {
      ..sim_host(rt, _ => abort("unused")),
      fetch: _ => {
        n.val += 1
        let mine = n.val
        defer {
          stopped.val += 1
        }
        // the first went on a connection that is gone; the others answer
        // after a latency the seed draws
        if mine == 1 {
          @effect.never()
        }
        @effect.sleep(rt.rng.between(1, 200))
        { status: 200, headers: [], body: @utf8.encode("answer \{mine}") }
      },
    }
    let wakes = Wakes::new()
    let host = waking(inner, wakes)
    let answer = rt.fork(() => (host.fetch)(get))
    ignore(rt.run_ready())
    wakes.wake({ at: rt.now(), away: 0L, network: true, retry: false })
    ignore(rt.run_ready())
    wakes.wake({ at: rt.now(), away: 0L, network: true, retry: false })
    assert_true(rt.settle())
    let body = body_of(answer)
    assert_true(body == "answer 2" || body == "answer 3")
    // all three attempts ended (their `defer` ran): two interrupted, one answered
    assert_eq(stopped.val, 3)
    assert_eq(n.val, 3)
  })
}
