let () =
  let dir = Filename.temp_file "ocamlcc-sys-util-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  let file = Filename.concat dir "artifact" in
  let original = Filename.concat dir "original" in
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun path -> if Sys.file_exists path then Sys.remove path)
        [file; original];
      Unix.rmdir dir)
    (fun () ->
      Sys_util.write_if_changed file "first\000artifact";
      Unix.chmod file 0o640;
      Unix.link file original;
      let inode path = (Unix.stat path).st_ino in
      Sys_util.write_if_changed file "first\000artifact";
      assert (inode file = inode original);
      Sys_util.write_if_changed file "second\000artifact";
      assert (inode file <> inode original);
      assert ((Unix.stat file).st_perm = 0o640);
      let read path = In_channel.with_open_bin path In_channel.input_all in
      assert (read original = "first\000artifact");
      assert (read file = "second\000artifact"))
