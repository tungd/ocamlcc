let get = function Ok value -> value | Error message -> failwith message

let () =
  let dir = Filename.temp_dir "ocamlcc-linker-" "" in
  Fun.protect ~finally:(fun () -> Sys_util.rm_rf dir) (fun () ->
      let user = Filename.concat dir "user.o" in
      let runtime = Filename.concat dir "runtime.o" in
      let output = Filename.concat dir "result.a" in
      let target = get (Target.resolve "host") in
      let toolchain = get (Target.toolchain ~ar_path:"ar" target) in
      let object_file name output =
        let source = Filename.concat dir (name ^ ".c") in
        Sys_util.write_file source ("int " ^ name ^ "(void) { return 0; }");
        get (Linker.compile_source ~verbose:false toolchain [] source output)
      in
      object_file "user" user;
      object_file "runtime" runtime;
      let built = get (Linker.link
        { mode = Static; target; toolchain; work_dir = dir; output;
          user_objects = [user]; internal_objects = [runtime];
          extra_ldflags = []; verbose = false }) in
      assert (built = output);
      let members =
        get (Sys_util.capture_cmd "ar" ["-t"; output])
        |> String.split_on_char '\n'
        |> List.filter (fun member -> Filename.check_suffix member ".o")
      in
      assert (members = ["user.o"; "runtime.o"]))
