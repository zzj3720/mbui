// client/core-ts/src/wake.ts on effect.mb: the UI coming back after being
// away, or the network changing under it: what is under way is suspect.
//
// - a request still unanswered that has waited a while (QUIET_MS) fails, for
//   its caller to ask again;
// - a stream that heard nothing for a while ends, and is opened again;
// - what waits to reconnect stops waiting (`Wakes::next`);
// - the host lets its connections go (`Host.reset_connections`).
// When the network changed, everything under way fails. A person asking to try
// again (`retry`) is taken as the connections suspect, not gone. `waking`
// does the first two for everything that goes through the host.

///|
/// What a request given up fails with.
pub let dropped : String = "页面回到前台，重新请求"

///|
/// What a stream taken for gone ends with.
pub let gone : String = "页面回到前台，重新连接"

///|
/// What everything under way fails with when the network changed.
pub let network : String = "网络变了，重新连接"

///|
pub let request_away_ms : Int64 = 10_000L

///|
pub let quiet_ms : Int64 = 3_000L

///|
pub let stream_away_ms : Int64 = 30_000L

///|
pub suberror HostError {
  HostError(String)
} derive(Show)

///|
pub(all) struct Wake {
  at : Int64
  away : Int64
  network : Bool
  retry : Bool
} derive(Show)

///|
pub fn Wake::left(self : Wake) -> Int64 {
  self.at - self.away
}

///|
/// A request that may be asked twice, sent at `sent` and not answered yet, is
/// asked again beside it.
pub fn Wake::hedges_request(self : Wake, sent : Int64) -> Bool {
  (self.network || self.retry || self.away >= request_away_ms) && sent <= self.at
}

///|
/// A request sent at `sent` and not answered yet is given up.
pub fn Wake::drops_request(self : Wake, sent : Int64) -> Bool {
  self.network || (self.away >= request_away_ms && self.at - sent >= quiet_ms)
}

///|
/// A stream that last heard something at `heard` is taken for gone.
pub fn Wake::drops_stream(self : Wake, heard : Int64) -> Bool {
  self.network ||
  (self.away >= stream_away_ms && self.at - heard >= stream_away_ms)
}

///|
/// Long enough away that the connections under the core are taken for gone.
pub fn Wake::suspects_connections(self : Wake) -> Bool {
  self.network || self.retry || self.away >= stream_away_ms
}

///|
pub fn Wake::reason(self : Wake) -> String {
  if self.network {
    network
  } else {
    gone
  }
}

///|
/// Tells whoever waits that the UI is back.
pub struct Wakes {
  priv waiting : Map[Int, @effect.Deferred[Wake]]
  priv mut ids : Int
}

///|
pub fn Wakes::new() -> Wakes {
  { waiting: {}, ids: 0 }
}

///|
pub fn Wakes::wake(self : Wakes, wake : Wake) -> Unit {
  let waiting = self.waiting.values().to_array()
  self.waiting.clear()
  for d in waiting {
    ignore(d.succeed(wake))
  }
}

///|
/// The next time the UI comes back.
pub async fn Wakes::next(self : Wakes) -> Wake {
  let d = @effect.Deferred::new()
  self.ids += 1
  let id = self.ids
  self.waiting.set(id, d)
  defer self.waiting.remove(id)
  d.wait()
}

///|
/// The first wake `drops` says is the end of something.
pub async fn Wakes::until(self : Wakes, drops : (Wake) -> Bool) -> Wake {
  while true {
    let w = self.next()
    if drops(w) {
      return w
    }
  }
  abort("unreachable")
}

///|
pub(all) struct HttpRequest {
  /// `method` is a word MoonBit keeps for itself
  verb : String
  url : String
  headers : Array[(String, String)]
  body : Bytes?
}

///|
pub(all) struct HttpResponse {
  status : Int
  headers : Array[(String, String)]
  body : Bytes
}

///|
/// What a stream gives, one at a time (host.ts Pull).
pub(all) struct Pull[A] {
  take : async () -> A
}

///|
pub(all) struct StreamResponse {
  status : Int
  body : Pull[Bytes]
}

///|
/// The host the core runs on, as far as this needs it (host.ts Host).
pub(all) struct Host {
  now_ms : () -> Int64
  fetch : async (HttpRequest) -> HttpResponse
  fetch_stream : async (HttpRequest) -> StreamResponse
  reset_connections : () -> Unit
  storage_get : async (String) -> Bytes?
}

///|
/// What a request says to be one that may be asked twice though it is not a
/// read. Taken off before it goes.
pub let hedge : String = "x-stillfail-hedge"

///|
pub fn hedgeable(request : HttpRequest) -> Bool {
  let m = request.verb.to_upper()
  m == "GET" ||
  m == "HEAD" ||
  request.headers.iter().any(h => h.0.to_lower() == hedge)
}

///|
let hedges : Int = 3

///|
/// effect.mb's combinators raise `Error`; the host's callers are told
/// `HostError` (the typed channel of the Effect version), so what is not one
/// already is said as one here.
async fn[A] as_host_error(f : async () -> A) -> A raise HostError {
  f() catch {
    HostError(m) => raise HostError(m)
    e => raise HostError(e.to_string())
  }
}

///|
/// `pending`, unless a wake says it went out before the UI was away: then an
/// error.
pub async fn[A] unless_dropped(
  wakes : Wakes,
  sent : Int64,
  pending : async () -> A,
) -> A raise HostError {
  as_host_error(() => @effect.race_first(pending, async fn() {
    let w = wakes.until(w => w.drops_request(sent))
    raise HostError(if w.network { network } else { dropped })
  }))
}

///|
/// A request that may be asked twice: asked again at each wake that suspects
/// what it went on (up to `hedges` at once), the first answer its answer; one
/// that fails leaves it to the others.
pub async fn[A] hedged(
  wakes : Wakes,
  host : Host,
  ask : async () -> A,
) -> A raise HostError {
  as_host_error(() => @effect.scoped(s => {
    let done = @effect.Deferred::new()
    let open = Ref(0)
    let sent = Ref((host.now_ms)())
    let attempt = async fn() {
      open.val += 1
      try ask() catch {
        e => {
          open.val -= 1
          if open.val == 0 {
            ignore(done.fail(e))
          }
        }
      } noraise {
        a => {
          open.val -= 1
          ignore(done.succeed(a))
        }
      }
    }
    ignore(s.fork(attempt))
    ignore(
      s.fork(async fn() {
        while true {
          let w = wakes.until(w => w.hedges_request(sent.val))
          sent.val = w.at
          if open.val < hedges {
            ignore(s.fork(attempt))
          }
        }
      }),
    )
    done.wait()
  }))
}

///|
/// A pull that ends with an error at a wake when it heard nothing while the UI
/// was away.
pub fn[A] quiet_ends(host : Host, wakes : Wakes, pull : Pull[A]) -> Pull[A] {
  let heard = Ref((host.now_ms)())
  {
    take: () => as_host_error(() => @effect.race_first(
      async fn() {
        let a = (pull.take)()
        heard.val = (host.now_ms)()
        a
      },
      async fn() {
        let w = wakes.until(w => w.drops_stream(heard.val))
        raise HostError(w.reason())
      },
    )),
  }
}

///|
/// The host the core runs on, with the rules above for its requests and
/// streams (WakingHost): everything else is the inner host's.
pub fn waking(inner : Host, wakes : Wakes) -> Host {
  {
    ..inner,
    fetch: request => if hedgeable(request) {
      let r = {
        ..request,
        headers: request.headers.filter(h => h.0.to_lower() != hedge),
      }
      hedged(wakes, inner, () => (inner.fetch)(r))
    } else {
      unless_dropped(wakes, (inner.now_ms)(), () => (inner.fetch)(request))
    },
    fetch_stream: request => {
      let response = unless_dropped(wakes, (inner.now_ms)(), () => (inner.fetch_stream)(
        request,
      ))
      { ..response, body: quiet_ends(inner, wakes, response.body) }
    },
  }
}
