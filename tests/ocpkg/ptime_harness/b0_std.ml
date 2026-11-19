(** Test-only formatting surface used by the unchanged upstream Ptime tests. *)
module Fmt = struct
  let pf = Format.fprintf
  let int = Format.pp_print_int
  let failwith fmt = Format.kasprintf failwith fmt
  let option pp ppf = function
    | None -> Format.pp_print_string ppf "None"
    | Some value -> Format.fprintf ppf "Some (%a)" pp value
end
