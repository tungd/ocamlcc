let get = function Ok value -> value | Error message -> failwith message

let () =
  let target = get (Target.resolve "linux-rv64") in
  assert (target.qbe_target = "rv64" && target.os = Target.Linux);
  let toolchain =
    get (Target.toolchain ~cc_path:"custom-cc" ~ar_path:"custom-ar"
           ~sysroot:"custom-root" target)
  in
  assert (toolchain.cc_prog = "custom-cc");
  assert (toolchain.ar_prog = "custom-ar");
  assert (toolchain.cc_base_args = ["--sysroot=custom-root"])
