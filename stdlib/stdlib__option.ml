external raise : exn -> 'a = "%raise"
external ( = ) : 'a -> 'a -> bool = "%equal"

type 'a t = 'a option = None | Some of 'a

let none = None
let some v = Some v

let value o ~default =
  match o with
  | Some v -> v
  | None -> default

let get = function
  | Some v -> v
  | None -> raise (Invalid_argument "option is None")

let bind o f =
  match o with
  | None -> None
  | Some v -> f v

let join = function
  | Some (Some _ as o) -> o
  | Some None | None -> None

let map f o =
  match o with
  | None -> None
  | Some v -> Some (f v)

let fold ~none ~some = function
  | Some v -> some v
  | None -> none

let iter f = function
  | Some v -> f v
  | None -> ()

let is_none = function
  | None -> true
  | Some _ -> false

let is_some = function
  | None -> false
  | Some _ -> true

let equal eq o0 o1 =
  match (o0, o1) with
  | Some v0, Some v1 -> eq v0 v1
  | None, None -> true
  | _ -> false

let compare cmp o0 o1 =
  match (o0, o1) with
  | Some v0, Some v1 -> cmp v0 v1
  | None, None -> 0
  | None, Some _ -> -1
  | Some _, None -> 1

let to_list = function
  | None -> []
  | Some v -> [ v ]
