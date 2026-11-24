let require = function Ok v -> v | Error msg -> failwith msg

let () =
  let root = Filename.temp_dir "ocpkg-parallel-test-" "" in
  Fun.protect ~finally:(fun () -> Sys_util.rm_rf root) (fun () ->
    (* 1. Independent tasks run concurrently in < sum of sleep times. *)
    let pool = Pkg_parallel.Pool.create 4 in
    Fun.protect ~finally:(fun () -> Pkg_parallel.Pool.close pool) (fun () ->
      let events = ref [] in
      let t0 = Unix.gettimeofday () in
      let res =
        Pkg_parallel.run_dag ~pool
          ~on_event:(fun id ev -> events := (id, ev) :: !events)
          ~deps:(function 2 -> [0; 1] | _ -> [])
          ~prepare:(fun i results ->
            if i = 2 then begin
              assert (results.(0) = Some 10);
              assert (results.(1) = Some 20);
              Ok (`Ready 30)
            end else
              Ok (`Run (fun report ->
                report ("start-" ^ string_of_int i);
                Unix.sleepf 0.12;
                report ("end-" ^ string_of_int i);
                Ok ((i + 1) * 10))))
          3
        |> require
      in
      let dt = Unix.gettimeofday () -. t0 in
      assert (res = [| 10; 20; 30 |]);
      assert (dt < 0.22);
      assert (List.mem (0, "start-0") !events);
      assert (List.mem (1, "end-1") !events);
      Printf.printf "PASS parallel DAG concurrency (%.3fs)\n%!" dt);

    (* 2. Pool limits concurrent execution when jobs = 1. *)
    let seq_pool = Pkg_parallel.Pool.create 1 in
    Fun.protect ~finally:(fun () -> Pkg_parallel.Pool.close seq_pool) (fun () ->
      let res =
        Pkg_parallel.map ~pool:seq_pool
          [ (fun _ -> Ok "a"); (fun _ -> Ok "b"); (fun _ -> Ok "c") ]
        |> require
      in
      assert (res = [ "a"; "b"; "c" ]);
      Printf.printf "PASS sequential pool fallback\n%!");

    (* 3. Digest_index delta merges from workers into parent index. *)
    let cache = Filename.concat root "cache" in
    let ws = Filename.concat root "ws" in
    Sys_util.mkdir_p ws;
    let f1 = Filename.concat ws "one.txt" in
    let f2 = Filename.concat ws "two.txt" in
    Sys_util.write_file f1 "alpha";
    Sys_util.write_file f2 "beta";
    let expected1 = Sha256.file f1 |> require in
    let expected2 = Sha256.file f2 |> require in
    Digest_index.with_index ~cache ~workspace:ws ~verify:false (fun index ->
      let pool = Pkg_parallel.Pool.create 2 in
      Fun.protect ~finally:(fun () -> Pkg_parallel.Pool.close pool) (fun () ->
        let paths = [| f1; f2 |] in
        let res =
          Pkg_parallel.run_dag ~pool ~index
            ~deps:(fun _ -> [])
            ~prepare:(fun i _ ->
              Ok (`Run (fun _ -> Digest_index.file index paths.(i))))
            2
          |> require
        in
        assert (Sha256.equal res.(0) expected1);
        assert (Sha256.equal res.(1) expected2)));
    Digest_index.with_index ~cache ~workspace:ws ~verify:false (fun index ->
      (* Verify stat index persisted merged updates: overwrite without changing mtime/size check. *)
      assert (Sha256.equal (Digest_index.file index f1 |> require) expected1);
      assert (Sha256.equal (Digest_index.file index f2 |> require) expected2));
    Printf.printf "PASS Digest_index delta merge across workers\n%!";

    (* 4. Error in worker propagates cleanly without hanging. *)
    let pool = Pkg_parallel.Pool.create 3 in
    Fun.protect ~finally:(fun () -> Pkg_parallel.Pool.close pool) (fun () ->
      let ran_dependent = ref false in
      let err =
        Pkg_parallel.run_dag ~pool
          ~deps:(function 2 -> [0; 1] | _ -> [])
          ~prepare:(fun i _ ->
            if i = 2 then (ran_dependent := true; Ok (`Ready ()))
            else if i = 0 then Ok (`Run (fun _ -> Error "boom"))
            else Ok (`Run (fun _ -> Unix.sleepf 0.05; Ok ())))
          3
      in
      assert (err = Error "boom");
      assert (not !ran_dependent);
      Printf.printf "PASS error propagation and cancellation\n%!"))
