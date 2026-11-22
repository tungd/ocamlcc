open Sys_util
open Result_syntax

module Request = struct
  type t = {
    steps : Dep_graph.Step.t list;
    work_dir : string;
    include_dirs : string list;
    stdlib : Stdlib_build.t;
    nostdlib : bool;
    nopervasives : bool;
    single_thread : bool;
    include_main : bool;
    publish_object : bool;
    qbe : string;
    target : Target.t;
    verbose : bool;
  }
end

type compiled = {
  assemblies : string list;
  object_interface : (string * string * Anf.exports) option;
}

let compile (request : Request.t) =
  let { Request.steps; work_dir; include_dirs; stdlib; nostdlib; nopervasives;
        single_thread; include_main; publish_object; qbe; target; verbose } =
    request
  in
  let cmi_dir = Filename.concat work_dir "cmi" in
  mkdir_p cmi_dir;
  let implementations, interfaces =
    List.partition (fun (step : Dep_graph.Step.t) -> step.kind = `Ml) steps
  in
  let local_units =
    List.map (fun (step : Dep_graph.Step.t) -> step.modname) implementations
  in
  let entry_unit = match List.rev implementations with
    | step :: _ when include_main -> Some step.path
    | _ -> None
  in
  let stdlib_dir = Stdlib_build.interface_dir stdlib in
  let archive = Stdlib_build.archive stdlib in
  let summaries =
    Some (Export_summary.Loader.create ?archive ~exclude_units:local_units ())
  in
  let rec compile_steps imports assemblies object_interface = function
    | [] -> Ok { assemblies = List.rev assemblies; object_interface }
    | (step : Dep_graph.Step.t) :: rest ->
        let base = String.uncapitalize_ascii step.modname in
        let prefix = Filename.concat cmi_dir base in
        let request =
          { (Pipeline.Request.create ~filename:step.path ~modname:step.modname) with
            include_dirs; output_prefix = Some prefix; nopervasives; nostdlib }
        in
        match step.kind with
        | `Mli ->
            let* _ = Pipeline.compile_interface_file request in
            Gc.full_major ();
            compile_steps imports assemblies object_interface rest
        | `Ml ->
            let has_mli =
              List.exists (fun (interface : Dep_graph.Step.t) ->
                  interface.modname = step.modname) interfaces
            in
            let request =
              { request with stdlib_dir; summaries; imports;
                emit_cmi = not has_mli; emit_entry = false;
                export_policy = (if publish_object then Seal else Collect);
                inline_single_thread_rc = single_thread }
            in
            let* output = Pipeline.compile_file request in
            let ssa = Filename.concat work_dir (base ^ ".ssa") in
            let asm = Filename.concat work_dir (base ^ ".s") in
            let startup =
              if entry_unit = Some step.path then
                Qbe_il.to_string { funcs = [Codegen.entry_point local_units]; datas = [] }
              else ""
            in
            write_file ssa (output.ssa ^ startup);
            let* () = run_cmd ~verbose ~stdout_file:asm qbe ["-t"; target.qbe_target; ssa] in
            let object_interface = match output.interface with
              | Some cmi when publish_object -> Some (step.modname, cmi, output.exports)
              | _ -> object_interface
            in
            Gc.full_major ();
            compile_steps ((step.modname, output.exports) :: imports) (asm :: assemblies)
              object_interface rest
  in
  let imports =
    Stdlib_build.imports stdlib |> List.filter (fun (name, _) -> not (List.mem name local_units))
  in
  compile_steps imports [] None steps
