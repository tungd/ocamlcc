(* Regression test: mutually recursive [let rec] functions with outer
   captures use a single environment argument on the recursive path. The
   members accept saturated jumps with different arities, and individual
   closure wrappers preserve indirect application. *)

let find_substring ~sub s start =
  let sl = String.length s and nl = String.length sub in
  let rec loop i =
    if i + nl > sl then None
    else if String.sub s i nl = sub then Some i
    else loop (i + 1)
  in
  loop start

let contains_substring ~sub s = Option.is_some (find_substring ~sub s 0)

let run_qbe qbe_path ssa =
  let tmp = Filename.temp_dir "ocamlcc_mutrec_clos" "" in
  let ssa_path = Filename.concat tmp "mutrec_clos.ssa" in
  let oc = open_out_bin ssa_path in
  output_string oc ssa;
  close_out oc;
  let cmd =
    Printf.sprintf "%s %s > /dev/null 2>&1"
      (Filename.quote qbe_path) (Filename.quote ssa_path)
  in
  let rc = Sys.command cmd in
  (try Sys.remove ssa_path with _ -> ());
  (try Sys.rmdir tmp with _ -> ());
  rc

let check_entry_jumps ~header ~first ~second ssa =
  let find sub start = match find_substring ~sub ssa start with
    | Some pos -> pos
    | None -> failwith ("missing " ^ sub)
  in
  let start = find header 0 in
  let finish = find "\n}" start in
  let group = String.sub ssa start (finish - start) in
  if not (List.for_all (fun name ->
    contains_substring ~sub:("jmp @" ^ name ^ "_entry") group) [first; second])
  then failwith ("missing direct jumps in " ^ header);
  assert (not (contains_substring ~sub:"jmp @dispatch" group))

let () =
  let qbe_path =
    if Array.length Sys.argv >= 2 then Sys.argv.(1) else "vendor/qbe/qbe"
  in
  let source =
    {|
      external ( = ) : 'a -> 'a -> bool = "%equal"
      external ( + ) : int -> int -> int = "%addint"
      external ( - ) : int -> int -> int = "%subint"

      let rec plain k =
        if k = 0 then 0 else peer (k - 1) 1
      and peer k bonus =
        if k = 0 then bonus else plain (k - 1)

      (* Two mutually tail-recursive closures with different arities capturing
         an outer value [offset]. *)
      let run offset bonus start n f =
        let rec even_step k =
          if k = 0 then offset + bonus else odd_step (k - 1) 1
        and odd_step k acc =
          if k = 0 then start + acc else even_step (k - 1)
        in
        let indirect_even = f even_step in
        even_step n + indirect_even 2

      let run_general offset start n observe =
        let rec outer k =
          if k = 0 then (observe inner; offset) else inner (k - 1) 1
        and inner k bonus =
          if k = 0 then start + bonus else outer (k - 1)
        in
        outer n
    |}
  in
  match
    Pipeline.compile_source
      { (Pipeline.Request.create ~filename:"mutrec_clos.ml" ~modname:"Mutrec_clos") with
        nostdlib = true; nopervasives = true } source
  with
  | Error msg -> failwith ("Pipeline failed: " ^ msg)
  | Ok { Pipeline.Output.ssa = ssa; _ } ->
      let prefix = "function l $ocamlcc_Mutrec_clos_mutrec_dispatch(" in
      let header =
        match List.find_opt (String.starts_with ~prefix) (String.split_on_char '\n' ssa) with
        | Some header -> header
        | None -> failwith "expected one shared recursive dispatcher closure"
      in
      let params = List.length (String.split_on_char ',' header) in
      assert (params = 4);
      assert (contains_substring ~sub:"jmp @loop" ssa);
      check_entry_jumps ~header:"export function l $ocamlcc_Mutrec_clos_group"
        ~first:"plain" ~second:"peer" ssa;
      check_entry_jumps ~header:"\nfunction l $ocamlcc_Mutrec_clos_group"
        ~first:"outer" ~second:"inner" ssa;
      assert (run_qbe qbe_path ssa = 0);
      Printf.printf "mutrec_closure_tail_test: PASS\n"
