(* TDD test for automatic QBE phi fan-in splitting (QBE parser limit NPred = 63). *)

let count_max_phi_args ssa =
  String.split_on_char '\n' ssa
  |> List.fold_left
       (fun acc line ->
         let trimmed = String.trim line in
         if String.contains trimmed '=' &&
            (let len = String.length trimmed in
             let rec has_phi i =
               if i + 5 > len then false
               else if String.sub trimmed i 5 = " phi " then true
               else has_phi (i + 1)
             in
             has_phi 0)
         then
           let commas =
             String.fold_left (fun c ch -> if ch = ',' then c + 1 else c) 0 trimmed
           in
           max acc (commas + 1)
         else acc)
       0

let run_qbe qbe_path ssa =
  let tmp = Filename.temp_dir "ocamlcc_phi_split" "" in
  let ssa_path = Filename.concat tmp "wide.ssa" in
  let oc = open_out_bin ssa_path in
  output_string oc ssa;
  close_out oc;
  let cmd = Printf.sprintf "%s %s > /dev/null 2>&1" (Filename.quote qbe_path) (Filename.quote ssa_path) in
  let rc = Sys.command cmd in
  (try Sys.remove ssa_path with _ -> ());
  (try Sys.rmdir tmp with _ -> ());
  rc

let make_wide_match_source n =
  let buf = Buffer.create 4096 in
  Buffer.add_string buf "let classify x =\n  match x with\n";
  for i = 0 to n - 1 do
    Buffer.add_string buf (Printf.sprintf "  | %d -> %d\n" i (i * 3 + 1))
  done;
  Buffer.add_string buf "  | _ -> -1\n\nlet res = classify 0 + classify 45 + classify 89\n";
  Buffer.contents buf

let () =
  let qbe_path = Sys.argv.(1) in
  let src = make_wide_match_source 90 in
  match
    Pipeline.compile_source
      { (Pipeline.Request.create ~filename:"wide_match.ml" ~modname:"Wide_match") with
        emit_entry = false } src
  with
  | Error msg -> failwith ("compile_source failed: " ^ msg)
  | Ok { Pipeline.Output.ssa = ssa; _ } ->
      let max_preds = count_max_phi_args ssa in
      if max_preds > 50 then
        failwith
          (Printf.sprintf "phi node exceeded fan-in cap: max_preds=%d (limit 50)" max_preds);
      let rc = run_qbe qbe_path ssa in
      if rc <> 0 then
        failwith (Printf.sprintf "qbe rejected wide match SSA (exit %d)" rc);
      print_endline "phi_split_test: PASS"
