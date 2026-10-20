// The native views' contract (docs/determinism.md, "What is compared, and where"; scripts/host_contract.sh HOST views):
// on a real host, MBUI_VIEWCHECK=1: a video's view placed between pixels (a 16:9 picture fitted in 366 across, its top
// 147.3625 down), what the app told the host on the log (VIEWTOLD, in device pixels: ui's native.mbt) beside where the
// host put it (VIEWAT, each host's own), then `VIEWCHECK done` and the app's end. The two the same, on whole device
// pixels, or the contract fails: else the row its edge half covers shows what is under the canvas.

///|
let view_check_view : Ref[@ui.NativeView?] = Ref(None)

///|
/// How long the view is left placed before the run ends: the host's placing done by then (Android's, on its main
/// thread, comes after the frame that told it).
let view_check_ms : Double = 500.0

///|
fn view_check_run(c : @ui.Ctx) -> Unit {
  let v = match view_check_view.val {
    Some(v) => v
    None => {
      let v = @ui.NativeView::video("video/mp4", fn(_offset, _length, answer) { answer(b"", -1.0) })
      view_check_view.val = Some(v)
      v
    }
  }
  // (a picture fitted between pixels: 147.3625 down, 205.875 tall)
  c.native(v, h=Px(400.0), content=Some((12.0, 147.3625, 366.0, 205.875))) |> ignore
  if @kit.after(c, "viewcheck", true, view_check_ms) {
    @host.log("VIEWCHECK done")
    @host.exit(0)
  }
}
