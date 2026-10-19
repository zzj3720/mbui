// Toasts (Radix's Toast): short messages in a corner of the window that go by themselves, the list of them the
// view's. Each goes once it has shown `duration` ms; the time stops while the pointer is over them or the focus is in
// one (so that it can be read and acted on). Each has a close button and may have an action; a swipe to the right
// (past a third of it, or quick) puts it away. Read out politely as they come (a status). A toast put away comes out
// by `presence` before it is gone. (Radix's F8, the key to their region, waits for the hosts to send function keys.)

///|
/// A toast: its id (the view's, unique among those showing), its title, its description ("" none), its action's
/// words ("" none).
pub(all) struct Toast {
  id : String
  title : String
  description : String
  action : String
} derive(Eq, Show)

///|
/// A toast of `title` (its id `id`).
pub fn toast(id : String, title : String, description? : String = "", action? : String = "") -> Toast {
  { id, title, description, action }
}

///|
/// What a toast's look is given: the toast, how far in it is (0 … 1), how far it is swiped (to the right), pointed at.
pub(all) struct ToastState {
  toast : Toast
  t : Double
  dx : Double
  hovered : Bool
}

///|
/// What the toasts report: those still showing (what the view keeps), and the id of the one whose action was taken
/// (it goes too).
pub(all) struct Toasts {
  open : Array[Toast]
  acted : String?
}

///|
/// A viewport's toasts as drawn last frame, in order, and those of them put away (coming out).
priv struct Kept {
  mut drawn : Array[Toast]
  gone : Map[String, Bool]
}

///|
/// `key`'s toasts (see the file's head), `toasts` showing, the newest last, in the window's bottom right corner, `w`
/// wide; each goes after `duration` ms; named `label` for the semantics tree, and their close buttons `close_label`.
pub fn toaster(
  c : @ui.Ctx,
  key : String,
  toasts : Array[Toast],
  duration? : Double = 5000.0,
  w? : Double = 356.0,
  label? : String = "通知",
  close_label? : String = "关闭",
  look? : (@ui.Ctx, ToastState, () -> Unit) -> Unit = toast_look,
) -> Toasts {
  install()
  let vid = c.id(key)
  let kept = match kit.val.toasts.get(vid) {
    Some(k) => k
    None => {
      let k = { drawn: [], gone: {} }
      kit.val.toasts[vid] = k
      k
    }
  }
  // as drawn last frame (those no longer given put away), then the new ones
  let order : Array[Toast] = []
  for to in kept.drawn {
    match toasts.search_by(fn(x) { x.id == to.id }) {
      Some(k) => order.push(toasts[k])
      None => {
        kept.gone[to.id] = true
        order.push(to)
      }
    }
  }
  for to in toasts {
    if !kept.drawn.iter().any(fn(x) { x.id == to.id }) {
      order.push(to)
    }
  }
  let open : Array[Toast] = []
  let mut acted : String? = None
  let drawn : Array[Toast] = []
  if order.is_empty() {
    kept.drawn = drawn
    return { open, acted }
  }
  // the time stops while the pointer is over them or the focus is in one
  let rid = c.id(key + "/region")
  let paused = pointer_in(c, rid) || order.iter().any(fn(to) { focus_in(c, key, to.id) })
  let (ww, wh) = c.window_size()
  let width = dmin(w, ww - 32.0)
  c.overlay(key, escape=false, outside=false, initial_focus=0, fn() {
    let region = c.box(id=rid, w=Px(width), gap=8.0, tx=ww - width - 16.0, ty=wh - height_of(c, rid) - 16.0, fn() {
      for to in order {
        let k = key + "/" + to.id
        let tid = c.id(k)
        let mut live = !kept.gone.contains(to.id)
        let mut dx = 0.0
        if live {
          let mut away = after(c, k, !paused, duration, keep=true)
          // the swipe: followed while held, put away past a third or quick, else back
          match c.drag_of(tid) {
            Some(d) => {
              if d.down && d.moving {
                dx = dmax(0.0, d.x - d.x0)
              }
              if d.take_end() && (d.x - d.x0 > width / 3.0 || d.vx > 0.5) {
                away = true
              }
            }
            None => ()
          }
          if away {
            kept.gone[to.id] = true
            live = false
          }
        }
        let p = presence(c, k, live)
        if !p.built {
          kept.gone.remove(to.id)
          continue
        }
        drawn.push(to)
        let st = {
          toast: to,
          t: p.t,
          dx: if live { dx } else { (1.0 - p.t) * width * 0.5 },
          hovered: c.hovered(tid),
        }
        let i = c.drag_area(if live { tid } else { 0 }, axis=Horizontal, fn() {
          look(c, st, fn() {
            if !live {
              return
            }
            if to.action != "" {
              c.box(dir=Row, pt=8.0, fn() {
                if button(c, to.action, key=k + "/action", variant=Outline).clicked {
                  acted = Some(to.id)
                  live = false
                }
              })
              |> ignore
            }
            if close_button(c, k + "/close", close_label) {
              live = false
            }
          })
        })
        c.semantics(i, Status, label=to.title, description=to.description)
        if live {
          open.push(to)
        } else {
          kept.gone[to.id] = true
        }
      }
    })
    c.semantics(region, Region, label~)
  })
  |> ignore
  kept.drawn = drawn
  { open, acted }
}

///|
/// The height `id` was drawn last frame (0 not yet: a frame is asked for).
fn height_of(c : @ui.Ctx, id : Int) -> Double {
  match c.rect_of(id) {
    Some((_, _, _, h)) => h
    None => {
      c.request_frame()
      0.0
    }
  }
}

///|
/// Whether the keyboard's focus is on toast `id`'s action or close button.
fn focus_in(c : @ui.Ctx, key : String, id : String) -> Bool {
  c.has_focus(c.id(key + "/" + id + "/action")) || c.has_focus(c.id(key + "/" + id + "/close"))
}

///|
/// A toast's default look: the theme's surface, a line round it and a shadow, its title over its description, then
/// what `actions` builds (its action, its close button); it fades and slides as it comes in, goes out and is swiped.
pub fn toast_look(c : @ui.Ctx, s : ToastState, actions : () -> Unit) -> Unit {
  let t = c.theme()
  let k = if s.t > 1.0 { 1.0 } else if s.t < 0.0 { 0.0 } else { s.t }
  c.box(
    w=Fill(1.0),
    pad=16.0,
    pr=44.0,
    gap=4.0,
    bg=t.surface,
    radius=t.radius_lg,
    border=1.0,
    border_color=t.border,
    shadow=20.0,
    shadow_color=t.shadow,
    shadow_y=4.0,
    tx=s.dx,
    ty=(1.0 - k) * 16.0,
    opacity=k,
    fn() {
      c.text(s.toast.title, size=t.font, weight=600) |> ignore
      if s.toast.description != "" {
        c.text(s.toast.description, size=t.font_sm, color=t.muted) |> ignore
      }
      // its action, and its close button over its corner
      actions()
    },
  )
  |> ignore
}
