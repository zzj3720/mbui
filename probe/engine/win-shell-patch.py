"""The one change client/shell needs to build for Windows (core-engine-pc.md): sf_utc_offset_min used POSIX
localtime_r/tm_gmtoff; on Windows the CRT's _localtime64_s and _mkgmtime64 give the same offset."""
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = "#[unsafe(no_mangle)]\npub extern \"C\" fn sf_utc_offset_min(at_ms: f64) -> i32 {"
assert old in s, "sf_utc_offset_min not found"
s = s.replace(old, "#[cfg(not(windows))]\n" + old, 1)
s = s.replace("#[cfg(test)]\nmod tests {", '''#[cfg(windows)]
#[unsafe(no_mangle)]
pub extern "C" fn sf_utc_offset_min(at_ms: f64) -> i32 {
    unsafe extern "C" {
        fn _localtime64_s(tm: *mut libc::tm, time: *const i64) -> i32;
        fn _mkgmtime64(tm: *mut libc::tm) -> i64;
    }
    let at = (at_ms / 1000.0).floor() as i64;
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    // SAFETY: both pointers are valid for the calls.
    if unsafe { _localtime64_s(&mut tm, &at) } != 0 {
        return 0;
    }
    let local_as_utc = unsafe { _mkgmtime64(&mut tm) };
    ((local_as_utc - at) / 60) as i32
}

#[cfg(test)]
mod tests {''', 1)
open(p, "w", encoding="utf-8").write(s)
print("patched", p)
