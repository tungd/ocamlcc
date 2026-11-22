module Step = struct
  type t = {
    modname : string;
    kind : [ `Mli | `Ml ];
    path : string;
  }
end

let parse_deps ~(kind : [ `Mli | `Ml ]) path =
  try
    let src = Sys_util.read_file path in
    let lb = Lexing.from_string src in
    lb.Lexing.lex_curr_p <- { lb.Lexing.lex_curr_p with pos_fname = path };
    let saved = !Depend.free_structure_names in
    Fun.protect
      ~finally:(fun () -> Depend.free_structure_names := saved)
      (fun () ->
        Depend.free_structure_names := Depend.String.Set.empty;
        (match kind with
        | `Mli ->
            let sg = Parse.interface lb in
            Depend.add_signature Depend.String.Map.empty sg
        | `Ml ->
            let impl = Parse.implementation lb in
            Depend.add_implementation Depend.String.Map.empty impl);
        Ok (Depend.String.Set.elements !Depend.free_structure_names))
  with exn ->
    Error (Printf.sprintf "dependency parse failed for %s: %s" path (Printexc.to_string exn))

let plan_build_order (ocaml_files : string list) : (Step.t list, string) result =
  let mli_by_mod : (string, int * string) Hashtbl.t = Hashtbl.create 16 in
  let ml_by_mod : (string, int * string) Hashtbl.t = Hashtbl.create 16 in
  let order_counter = ref 0 in
  let next_ord () =
    let v = !order_counter in
    incr order_counter;
    v
  in
  let rec collect = function
    | [] -> Ok ()
    | f :: rest ->
        let modname = Pipeline.module_name_of_file f in
        let ord = next_ord () in
        if Filename.check_suffix f ".mli" then begin
          if Hashtbl.mem mli_by_mod modname then
            Error ("duplicate .mli for module " ^ modname)
          else begin
            Hashtbl.add mli_by_mod modname (ord, f);
            collect rest
          end
        end
        else if Filename.check_suffix f ".ml" then begin
          if Hashtbl.mem ml_by_mod modname then
            Error ("duplicate .ml for module " ^ modname)
          else begin
            Hashtbl.add ml_by_mod modname (ord, f);
            collect rest
          end
        end
        else Error ("expected .ml or .mli input: " ^ f)
  in
  match collect ocaml_files with
  | Error _ as e -> e
  | Ok () ->
      (* Build graph nodes (modname, `Mli | `Ml) with input order index. *)
      let nodes = ref [] in
      Hashtbl.iter
        (fun modname (ord, path) ->
          nodes := ({ Step.modname; kind = `Mli; path }, ord) :: !nodes)
        mli_by_mod;
      Hashtbl.iter
        (fun modname (ord, path) ->
          nodes := ({ Step.modname; kind = `Ml; path }, ord) :: !nodes)
        ml_by_mod;
      let nodes =
        List.sort (fun (_, a) (_, b) -> compare a b) !nodes |> List.map fst
      in
      let key_of (s : Step.t) =
        (s.modname, match s.kind with `Mli -> 0 | `Ml -> 1)
      in
      let node_set = Hashtbl.create 32 in
      List.iteri (fun idx s -> Hashtbl.add node_set (key_of s) (idx, s)) nodes;
      let n = List.length nodes in
      let hard_deps = Array.make n [] in
      let soft_deps = Array.make n [] in
      let soft_rev = Array.make n [] in
      let dep_res = ref (Ok ()) in
      List.iteri
        (fun i (s : Step.t) ->
          if !dep_res = Ok () then
            match parse_deps ~kind:s.kind s.path with
            | Error _ as e -> dep_res := e
            | Ok mod_refs ->
                let add_edge ~hard target_key =
                  match Hashtbl.find_opt node_set target_key with
                  | Some (j, _) when j <> i ->
                      if hard && not (List.mem j hard_deps.(i)) then
                        hard_deps.(i) <- j :: hard_deps.(i);
                      if not (List.mem j soft_deps.(i)) then begin
                        soft_deps.(i) <- j :: soft_deps.(i);
                        soft_rev.(j) <- i :: soft_rev.(j)
                      end
                  | _ -> ()
                in
                (match s.kind with
                | `Ml -> add_edge ~hard:true (s.modname, 0)
                | `Mli -> ());
                List.iter
                  (fun dep_mod ->
                    if dep_mod <> s.modname then begin
                      if Hashtbl.mem mli_by_mod dep_mod then begin
                        add_edge ~hard:true (dep_mod, 0);
                        if s.kind = `Ml && Hashtbl.mem ml_by_mod dep_mod then
                          add_edge ~hard:false (dep_mod, 1)
                      end
                      else if Hashtbl.mem ml_by_mod dep_mod then
                        add_edge ~hard:true (dep_mod, 1)
                    end)
                  mod_refs)
        nodes;
      match !dep_res with
      | Error _ as e -> e
      | Ok () -> (
          (* Compute Tarjan SCCs on soft_rev so .mli-mediated mutual .ml
             dependencies form one SCC while preserving dependency order
             between SCCs. *)
          let index = Array.make n (-1) in
          let lowlink = Array.make n 0 in
          let on_stack = Array.make n false in
          let stack = ref [] in
          let next_idx = ref 0 in
          let sccs = ref [] in
          let rec strongconnect v =
            index.(v) <- !next_idx;
            lowlink.(v) <- !next_idx;
            incr next_idx;
            stack := v :: !stack;
            on_stack.(v) <- true;
            List.iter
              (fun w ->
                if index.(w) = -1 then begin
                  strongconnect w;
                  lowlink.(v) <- min lowlink.(v) lowlink.(w)
                end
                else if on_stack.(w) then
                  lowlink.(v) <- min lowlink.(v) index.(w))
              soft_rev.(v);
            if lowlink.(v) = index.(v) then begin
              let rec pop acc =
                match !stack with
                | [] -> acc
                | w :: rest ->
                    stack := rest;
                    on_stack.(w) <- false;
                    let acc = w :: acc in
                    if w = v then acc else pop acc
              in
              sccs := List.sort compare (pop []) :: !sccs
            end
          in
          for v = 0 to n - 1 do
            if index.(v) = -1 then strongconnect v
          done;
          let scc_arr = Array.of_list !sccs in
          let num_sccs = Array.length scc_arr in
          let scc_of = Array.make n 0 in
          Array.iteri
            (fun cid members ->
              List.iter (fun u -> scc_of.(u) <- cid) members)
            scc_arr;
          (* Topological order over condensation DAG via Kahn with node-index tie-break. *)
          let c_rev = Array.make num_sccs [] in
          let c_indeg = Array.make num_sccs 0 in
          for i = 0 to n - 1 do
            let ci = scc_of.(i) in
            List.iter
              (fun j ->
                let cj = scc_of.(j) in
                if ci <> cj && not (List.mem ci c_rev.(cj)) then begin
                  c_rev.(cj) <- ci :: c_rev.(cj);
                  c_indeg.(ci) <- c_indeg.(ci) + 1
                end)
              soft_deps.(i)
          done;
          let min_node cid = List.hd scc_arr.(cid) in
          let cmp_cid a b = compare (min_node a) (min_node b) in
          let ready_c = ref [] in
          for cid = 0 to num_sccs - 1 do
            if c_indeg.(cid) = 0 then ready_c := cid :: !ready_c
          done;
          ready_c := List.sort cmp_cid !ready_c;
          let topo_hard members =
            let m_set = Hashtbl.create 8 in
            List.iter (fun u -> Hashtbl.add m_set u ()) members;
            let indeg = Hashtbl.create 8 in
            let rev = Hashtbl.create 8 in
            List.iter
              (fun u ->
                Hashtbl.add indeg u 0;
                Hashtbl.add rev u [])
              members;
            List.iter
              (fun i ->
                List.iter
                  (fun j ->
                    if Hashtbl.mem m_set j then begin
                      Hashtbl.replace indeg i (Hashtbl.find indeg i + 1);
                      Hashtbl.replace rev j (i :: Hashtbl.find rev j)
                    end)
                  hard_deps.(i))
              members;
            let ready = ref [] in
            List.iter
              (fun u -> if Hashtbl.find indeg u = 0 then ready := u :: !ready)
              members;
            ready := List.sort compare !ready;
            let out = ref [] in
            while !ready <> [] do
              let cur = List.hd !ready in
              ready := List.tl !ready;
              out := cur :: !out;
              List.iter
                (fun nxt ->
                  let d = Hashtbl.find indeg nxt - 1 in
                  Hashtbl.replace indeg nxt d;
                  if d = 0 then ready := List.sort compare (nxt :: !ready))
                (Hashtbl.find rev cur)
            done;
            if List.length !out <> List.length members then None
            else Some (List.rev !out)
          in
          let result = ref [] in
          let cyclic = ref false in
          while !ready_c <> [] && not !cyclic do
            let cid = List.hd !ready_c in
            ready_c := List.tl !ready_c;
            (match topo_hard scc_arr.(cid) with
            | None -> cyclic := true
            | Some sorted ->
                List.iter
                  (fun idx -> result := List.nth nodes idx :: !result)
                  sorted);
            List.iter
              (fun nxt ->
                c_indeg.(nxt) <- c_indeg.(nxt) - 1;
                if c_indeg.(nxt) = 0 then
                  ready_c := List.sort cmp_cid (nxt :: !ready_c))
              c_rev.(cid)
          done;
          if !cyclic || List.length !result <> n then
            Error "cyclic module dependency detected"
          else Ok (List.rev !result))

let references (step : Step.t) = parse_deps ~kind:step.kind step.path
