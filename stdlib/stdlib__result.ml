external raise : exn -> 'a = "%raise"

type ('a, 'e) t = Ok of 'a | Error of 'e

let ok v = Ok v
let error e = Error e

let value r ~default =
  match r with
  | Ok v -> v
  | Error _ -> default

let get_ok = function
  | Ok v -> v
  | Error _ -> raise (Invalid_argument "result is Error")

let get_error = function
  | Error e -> e
  | Ok _ -> raise (Invalid_argument "result is Ok")

let bind r f =
  match r with
  | Ok v -> f v
  | Error _ as e -> e

let join = function
  | Ok r -> r
  | Error _ as e -> e

let map f = function
  | Ok v -> Ok (f v)
  | Error _ as e -> e

let map_error f = function
  | Error e -> Error (f e)
  | Ok _ as v -> v

let fold ~ok ~error = function
  | Ok v -> ok v
  | Error e -> error e

let iter f = function
  | Ok v -> f v
  | Error _ -> ()

let iter_error f = function
  | Error e -> f e
  | Ok _ -> ()

let is_ok = function
  | Ok _ -> true
  | Error _ -> false

let is_error = function
  | Ok _ -> false
  | Error _ -> true

let equal ~ok ~error r0 r1 =
  match (r0, r1) with
  | Ok v0, Ok v1 -> ok v0 v1
  | Error e0, Error e1 -> error e0 e1
  | _ -> false

let compare ~ok ~error r0 r1 =
  match (r0, r1) with
  | Ok v0, Ok v1 -> ok v0 v1
  | Error e0, Error e1 -> error e0 e1
  | Ok _, Error _ -> -1
  | Error _, Ok _ -> 1

let to_option = function
  | Ok v -> Some v
  | Error _ -> None

let to_list = function
  | Ok v -> [ v ]
  | Error _ -> []
